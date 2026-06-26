// Type-1 (overwrite) dimension load.
// 1:1 port of tools/lib/patterns/Type1Dimension.psm1, with parameter binding
// completed so the package actually validates.
//
// Flow:
//   OLE_SRC  ──► LKP Dim (bk → bk, return sk)
//                  ├─ No Match Output  ──► DC Insert Audit ──► OLE_DST Insert
//                  └─ Match    Output  ──► DC Update Audit ──► CMD Update Payload
//
// Update SQL:
//   UPDATE <dim> SET [c1] = ?, [c2] = ?, ..., LoadedAt = ? WHERE <sk> = ?
//
// Param bindings (positional, mapped by BindOleDbCommandParameters):
//   [payload columns in order from metadata]  →  ?, ?, ...
//   LoadedAt (DC-added)                       →  ?
//   <sk>     (from Lookup return)             →  ?

using System.Collections.Generic;
using System.Text;

namespace SsisOmHost.Patterns
{
    internal static class Type1Dimension
    {
        public static void Build(IDictionary<string, object> meta, string outputPath)
        {
            string packageName    = MetadataHelpers.GetString(meta, "packageName",     required: true);
            string sourceConnName = MetadataHelpers.GetString(meta, "sourceConnection", required: true);
            string targetConnName = MetadataHelpers.GetString(meta, "targetConnection", required: true);
            string targetTable    = MetadataHelpers.GetString(meta, "targetTable",      required: true);
            string bk             = MetadataHelpers.GetString(meta, "businessKey",      required: true);
            string sk             = MetadataHelpers.GetString(meta, "surrogateKey",     required: true);

            if (bk == sk)
            {
                throw new System.ArgumentException(
                    "type1-dim metadata: businessKey and surrogateKey must differ.");
            }
            if (!targetTable.StartsWith("dim.") && !targetTable.StartsWith("[dim]."))
            {
                throw new System.ArgumentException(
                    "type1-dim metadata: targetTable '" + targetTable + "' must be in the 'dim' schema.");
            }

            var payloadArr = MetadataHelpers.GetArray(meta, "payloadColumns", required: true);
            if (payloadArr.Count == 0)
            {
                throw new System.ArgumentException(
                    "type1-dim metadata: payloadColumns must list at least one column.");
            }
            var payload = new List<string>(payloadArr.Count);
            foreach (var p in payloadArr) payload.Add(System.Convert.ToString(p));

            string sourceQuery = ResolveSourceQuery(meta);
            var srcConn = MetadataHelpers.ResolveConnection(meta, "source");
            var tgtConn = MetadataHelpers.ResolveConnection(meta, "target");

            var pkg = PackageBuilder.NewPackage(packageName);
            var src = PackageBuilder.AddOleDbConnection(pkg, sourceConnName, srcConn.Server, srcConn.Database);
            // When the user reuses the same connection name for source and target (very common
            // when staging and dim live in the same warehouse), reuse the same ConnectionManager.
            var tgt = string.Equals(sourceConnName, targetConnName, System.StringComparison.OrdinalIgnoreCase)
                ? src
                : PackageBuilder.AddOleDbConnection(pkg, targetConnName, tgtConn.Server, tgtConn.Database);

            var df = PackageBuilder.AddDataFlowTask(pkg, "DFT Merge Dim");

            var oleSrc = PackageBuilder.AddOleDbSource(df, "OLE_SRC Stg", src, sourceQuery);

            string lookupSql = "SELECT [" + sk + "], [" + bk + "] FROM " + targetTable + ";";
            var joinCols = new Dictionary<string, string> { { bk, bk } };
            var returnCols = new List<string> { sk };
            // NoMatchBehavior=1 = SendRowsWithNoMatchingEntriesToNoMatchOutput.
            // The pattern wires the "Lookup No Match Output" branch to the
            // insert chain; using 2 (IgnoreFailure) would leave that path
            // unrouted and the package would fail Validate.
            var lkp = PackageBuilder.AddLookup(df, "LKP Dim", tgt, lookupSql,
                joinCols, returnCols, noMatchBehavior: 1,
                upstream: oleSrc);

            // ---------- No-match branch: insert new dim row ----------
            //
            // The dim table has LoadedAt — add a DC to populate it from the
            // package start time (matches the staging pattern convention).
            var insertAudit = new List<DerivedColumnSpec>
            {
                DerivedColumnSpec.Timestamp("LoadedAt", "@[System::StartTime]")
            };
            var dcInsert = PackageBuilder.AddDerivedColumn(df, "DC Insert Audit", insertAudit);
            PackageBuilder.ConnectComponents(df, lkp, dcInsert, fromOutputName: "Lookup No Match Output");

            var dstInsert = PackageBuilder.AddOleDbDestination(df, "OLE_DST Insert", tgt, targetTable);
            PackageBuilder.ConnectComponents(df, dcInsert, dstInsert);
            PackageBuilder.InitializeOleDbDestinationMapping(dstInsert);

            // ---------- Match branch: UPDATE payload + LoadedAt ----------
            var updateAudit = new List<DerivedColumnSpec>
            {
                DerivedColumnSpec.Timestamp("LoadedAt", "@[System::StartTime]")
            };
            var dcUpdate = PackageBuilder.AddDerivedColumn(df, "DC Update Audit", updateAudit);
            PackageBuilder.ConnectComponents(df, lkp, dcUpdate, fromOutputName: "Lookup Match Output");

            var setClause = new StringBuilder();
            for (int i = 0; i < payload.Count; i++)
            {
                if (i > 0) setClause.Append(", ");
                setClause.Append('[').Append(payload[i]).Append("] = ?");
            }
            string updateSql = "UPDATE " + targetTable +
                               " SET " + setClause +
                               ", [LoadedAt] = ? WHERE [" + sk + "] = ?;";
            var cmd = PackageBuilder.AddOleDbCommand(df, "CMD Update Payload", tgt, updateSql);
            PackageBuilder.ConnectComponents(df, dcUpdate, cmd);

            // Param binding order matches the ? order in the SQL above.
            var paramOrder = new List<string>(payload);
            paramOrder.Add("LoadedAt");
            paramOrder.Add(sk);
            PackageBuilder.BindOleDbCommandParameters(cmd, paramOrder);

            PackageBuilder.SavePackage(pkg, outputPath);
        }

        // Identical to the staging pattern's helper, kept local so each pattern is self-contained.
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
                    "type1-dim metadata: 'columns' must list at least one {source,target} mapping when sourceQuery is omitted.");
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
