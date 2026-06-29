// Fact load — resolves dim surrogate keys via Lookup, then inserts into fact.<Name>.
//
// Flow:
//   OLE_SRC ──► LKP Dim 1 (match) ──► LKP Dim 2 (match) ──► ... ──► DC Audit ──► OLE_DST Fact
//
// Each Lookup's no-match output is left unhooked (= rows that fail any lookup are
// silently dropped). Per the skill spec, an `etl.RowAudit` sink can be added later.

using System.Collections.Generic;
using System.Text;
using Microsoft.SqlServer.Dts.Runtime;
using Microsoft.SqlServer.Dts.Pipeline.Wrapper;

namespace SsisOmHost.Patterns
{
    internal static class FactLoad
    {
        public static void Build(IDictionary<string, object> meta, string outputPath)
        {
            string packageName    = MetadataHelpers.GetString(meta, "packageName",      required: true);
            string sourceConnName = MetadataHelpers.GetString(meta, "sourceConnection", required: true);
            string targetConnName = MetadataHelpers.GetString(meta, "targetConnection", required: true);
            string targetTable    = MetadataHelpers.GetString(meta, "targetTable",      required: true);

            if (!targetTable.StartsWith("fact.") && !targetTable.StartsWith("[fact]."))
            {
                throw new System.ArgumentException(
                    "fact metadata: targetTable '" + targetTable + "' must be in the 'fact' schema.");
            }

            var lookups = MetadataHelpers.GetArray(meta, "dimensionLookups", required: true);
            if (lookups.Count == 0)
            {
                throw new System.ArgumentException(
                    "fact metadata: dimensionLookups must list at least one dim -> SK mapping.");
            }

            // measureColumns is required by the schema (so the metadata authoring side fails
            // fast if missing), but the columns themselves flow through automatically by name.
            MetadataHelpers.GetArray(meta, "measureColumns", required: true);

            string sourceQuery = ResolveSourceQuery(meta);
            var srcConn = MetadataHelpers.ResolveConnection(meta, "source");
            var tgtConn = MetadataHelpers.ResolveConnection(meta, "target");

            var pkg = PackageBuilder.NewPackage(packageName);
            var src = PackageBuilder.AddOleDbConnection(pkg, sourceConnName, srcConn.Server, srcConn.Database);
            var tgt = string.Equals(sourceConnName, targetConnName, System.StringComparison.OrdinalIgnoreCase)
                ? src
                : PackageBuilder.AddOleDbConnection(pkg, targetConnName, tgtConn.Server, tgtConn.Database);

            var df = PackageBuilder.AddDataFlowTask(pkg, "DFT Load Fact");

            var oleSrc = PackageBuilder.AddOleDbSource(df, "OLE_SRC Stg", src, sourceQuery);

            Microsoft.SqlServer.Dts.Pipeline.Wrapper.IDTSComponentMetaData100 upstream = oleSrc;
            string upstreamOutput = null; // null = pick first non-error output

            foreach (var lkObj in lookups)
            {
                var lk = (IDictionary<string, object>)lkObj;
                string dimTable   = MetadataHelpers.GetString(lk, "dimTable",   required: true);
                string factColumn = MetadataHelpers.GetString(lk, "factColumn", required: true);
                string joinOn     = MetadataHelpers.GetString(lk, "joinOn",     required: true);

                string lookupSql =
                    "SELECT [" + factColumn + "], [" + joinOn + "] FROM " + dimTable + ";";

                // Lookup component names cannot contain '.' (the framework
                // uses '.' as a path separator in refIds). Substitute '_' to
                // turn 'dim.Customer' into 'LKP dim_Customer'.
                string compName = "LKP " + dimTable.Replace('.', '_');
                var joinCols = new Dictionary<string, string> { { joinOn, joinOn } };
                var returnCols = new List<string> { factColumn };

                // NoMatchBehavior=0 = FailComponent. Fact loads only wire
                // "Lookup Match Output"; an unmatched FK is a data quality
                // error and the package should fail rather than insert a
                // fact row with a NULL surrogate key.
                var lkComp = PackageBuilder.AddLookup(df, compName, tgt, lookupSql,
                    joinCols, returnCols, noMatchBehavior: 0,
                    upstream: upstream, fromOutputName: upstreamOutput);

                // The match output becomes the upstream for the next stage.
                upstream = lkComp;
                upstreamOutput = "Lookup Match Output";
            }

            // Audit columns appended just before the destination.
            var auditExprs = new List<DerivedColumnSpec>
            {
                DerivedColumnSpec.Timestamp("LoadedAt", "@[System::StartTime]")
            };
            var dcAudit = PackageBuilder.AddDerivedColumn(df, "DC Audit", auditExprs);
            PackageBuilder.ConnectComponents(df, upstream, dcAudit, fromOutputName: upstreamOutput);

            var dst = PackageBuilder.AddOleDbDestination(df, "OLE_DST Fact", tgt, targetTable);
            PackageBuilder.ConnectComponents(df, dcAudit, dst);
            PackageBuilder.InitializeOleDbDestinationMapping(dst);

            PackageBuilder.SavePackage(pkg, outputPath);
        }

        private static string ResolveSourceQuery(IDictionary<string, object> meta)
        {
            var explicitQuery = MetadataHelpers.GetString(meta, "sourceQuery");
            if (!string.IsNullOrEmpty(explicitQuery))
            {
                return explicitQuery;
            }
            var src = MetadataHelpers.GetDict(meta, "source", required: true);
            string schema = MetadataHelpers.GetString(src, "schema", required: true);
            string table  = MetadataHelpers.GetString(src, "table",  required: true);
            var columns = MetadataHelpers.GetArray(meta, "columns", required: true);
            if (columns.Count == 0)
            {
                throw new System.ArgumentException(
                    "fact metadata: 'columns' must list at least one {source,target} mapping when sourceQuery is omitted.");
            }
            var sb = new StringBuilder("SELECT ");
            for (int i = 0; i < columns.Count; i++)
            {
                var col = (IDictionary<string, object>)columns[i];
                string s = MetadataHelpers.GetString(col, "source", required: true);
                if (i > 0) sb.Append(", ");
                sb.Append('[').Append(s).Append(']');
            }
            sb.Append(" FROM [").Append(schema).Append("].[").Append(table).Append("];");
            return sb.ToString();
        }
    }
}
