// StagingLoad — 1:1 port of tools/lib/patterns/StagingLoad.psm1.
// Source → Derived Column (audit) → OLE DB Destination (FastLoad).

using System.Collections.Generic;
using System.Text;

namespace SsisOmHost.Patterns
{
    internal static class StagingLoad
    {
        public static void Build(IDictionary<string, object> meta, string outputPath)
        {
            string packageName     = MetadataHelpers.GetString(meta, "packageName",     required: true);
            string sourceConnName  = MetadataHelpers.GetString(meta, "sourceConnection", required: true);
            string targetConnName  = MetadataHelpers.GetString(meta, "targetConnection", required: true);
            string targetTable     = MetadataHelpers.GetString(meta, "targetTable",      required: true);
            bool   truncate        = MetadataHelpers.GetBool  (meta, "truncateBeforeLoad", true);

            if (!targetTable.StartsWith("stg.") && !targetTable.StartsWith("[stg]."))
            {
                throw new System.ArgumentException(
                    "staging metadata: targetTable '" + targetTable + "' must be in the 'stg' schema.");
            }

            string sourceQuery = ResolveSourceQuery(meta);
            var srcConn = MetadataHelpers.ResolveConnection(meta, "source");
            var tgtConn = MetadataHelpers.ResolveConnection(meta, "target");

            var pkg = PackageBuilder.NewPackage(packageName);
            var src = PackageBuilder.AddOleDbConnection(pkg, sourceConnName, srcConn.Server, srcConn.Database);
            var tgt = PackageBuilder.AddOleDbConnection(pkg, targetConnName, tgtConn.Server, tgtConn.Database);

            if (truncate)
            {
                PackageBuilder.AddExecuteSqlTask(pkg, "SQL Truncate Target", tgt,
                    "TRUNCATE TABLE " + targetTable + ";");
            }

            var df = PackageBuilder.AddDataFlowTask(pkg, "DFT Load Stg");

            var oleSrc = PackageBuilder.AddOleDbSource(df, "OLE_SRC Source", src, sourceQuery);

            // Use built-in System variables so the package validates standalone.
            // When wrapped in a project (tools/New-SsisProject.ps1) with @[$Project::RunDate]
            // and @[$Project::LoadedByPackageRunId], swap these to the project-scope refs.
            var auditExpressions = new List<DerivedColumnSpec>
            {
                DerivedColumnSpec.Timestamp("LoadedAt",             "@[System::StartTime]"),
                DerivedColumnSpec.Guid     ("LoadedByPackageRunId", "@[System::ExecutionInstanceGUID]")
            };
            var derived = PackageBuilder.AddDerivedColumn(df, "DC Audit", auditExpressions);

            var oleDst = PackageBuilder.AddOleDbDestination(df, "OLE_DST Stg", tgt, targetTable);

            PackageBuilder.ConnectComponents(df, oleSrc, derived);
            PackageBuilder.ConnectComponents(df, derived, oleDst);
            PackageBuilder.InitializeOleDbDestinationMapping(oleDst);

            var runSql = new StringBuilder()
                .Append("INSERT INTO etl.PackageRun (PackageName, StartedAt, FinishedAt, Status, RowsLoaded) ")
                .Append("VALUES (N'").Append(packageName).Append("', SYSUTCDATETIME(), SYSUTCDATETIME(), N'Succeeded', NULL);")
                .ToString();
            PackageBuilder.AddExecuteSqlTask(pkg, "SQL Insert PackageRun", tgt, runSql);

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
                throw new System.ArgumentException("staging metadata: 'columns' must list at least one {source,target} mapping when sourceQuery is omitted.");
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
