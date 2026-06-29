// Type-2 (SCD-2) dimension load.
//
// Flow:
//   OLE_SRC ──► LKP Dim Current (bk → bk, WHERE IsCurrent = 1, return sk + payload)
//                  ├─ No Match Output ──► DC Insert Audit ──► OLE_DST Insert New
//                  └─ Match    Output ──► CS Changed?
//                                            ├─ Unchanged → drop
//                                            └─ Changed   → MC Changed Fanout
//                                                              ├─ Expire ──► DC Expire Audit ──► CMD Expire Old
//                                                              └─ Insert ──► DC Insert Audit  ──► OLE_DST Insert New (changed)
//
// SCD-2 columns on dim:
//   IsCurrent      bit          NOT NULL
//   EffectiveFrom  datetime2(3) NOT NULL
//   EffectiveTo    datetime2(3)     NULL
//   LoadedAt       datetime2(3) NOT NULL
//
// Change-detection expression: compares each payload column to its lookup-returned
// counterpart. After the Lookup adds matching-name return columns to the output, the
// SSIS engine renames the duplicates by suffixing them — so the upstream copy keeps
// its name and the lookup copy is exposed as "<col>_existing" in this generator. We
// achieve that by renaming the return columns in the Lookup setup before reading
// them back here.

using System.Collections.Generic;
using System.Text;
using Microsoft.SqlServer.Dts.Runtime;
using Microsoft.SqlServer.Dts.Pipeline.Wrapper;

namespace SsisOmHost.Patterns
{
    internal static class Type2Dimension
    {
        public static void Build(IDictionary<string, object> meta, string outputPath)
        {
            string packageName    = MetadataHelpers.GetString(meta, "packageName",      required: true);
            string sourceConnName = MetadataHelpers.GetString(meta, "sourceConnection", required: true);
            string targetConnName = MetadataHelpers.GetString(meta, "targetConnection", required: true);
            string targetTable    = MetadataHelpers.GetString(meta, "targetTable",      required: true);
            string bk             = MetadataHelpers.GetString(meta, "businessKey",      required: true);
            string sk             = MetadataHelpers.GetString(meta, "surrogateKey",     required: true);

            if (bk == sk)
            {
                throw new System.ArgumentException(
                    "type2-dim metadata: businessKey and surrogateKey must differ.");
            }
            if (!targetTable.StartsWith("dim.") && !targetTable.StartsWith("[dim]."))
            {
                throw new System.ArgumentException(
                    "type2-dim metadata: targetTable '" + targetTable + "' must be in the 'dim' schema.");
            }

            string currentCol = MetadataHelpers.GetString(meta, "currentFlagColumn",   defaultValue: "IsCurrent");
            string fromCol    = MetadataHelpers.GetString(meta, "effectiveFromColumn", defaultValue: "EffectiveFrom");
            string toCol      = MetadataHelpers.GetString(meta, "effectiveToColumn",   defaultValue: "EffectiveTo");

            var payloadArr = MetadataHelpers.GetArray(meta, "payloadColumns", required: true);
            if (payloadArr.Count == 0)
            {
                throw new System.ArgumentException(
                    "type2-dim metadata: payloadColumns required.");
            }
            var payload = new List<string>(payloadArr.Count);
            foreach (var p in payloadArr) payload.Add(System.Convert.ToString(p));

            string sourceQuery = ResolveSourceQuery(meta);
            var srcConn = MetadataHelpers.ResolveConnection(meta, "source");
            var tgtConn = MetadataHelpers.ResolveConnection(meta, "target");

            var pkg = PackageBuilder.NewPackage(packageName);
            var src = PackageBuilder.AddOleDbConnection(pkg, sourceConnName, srcConn.Server, srcConn.Database);
            var tgt = string.Equals(sourceConnName, targetConnName, System.StringComparison.OrdinalIgnoreCase)
                ? src
                : PackageBuilder.AddOleDbConnection(pkg, targetConnName, tgtConn.Server, tgtConn.Database);

            var df = PackageBuilder.AddDataFlowTask(pkg, "DFT SCD2");

            var oleSrc = PackageBuilder.AddOleDbSource(df, "OLE_SRC Stg", src, sourceQuery);

            // Lookup current rows — return sk + each payload column (aliased _existing for change detection).
            var lookupSb = new StringBuilder("SELECT [").Append(sk).Append("], [").Append(bk).Append("]");
            foreach (var col in payload)
            {
                lookupSb.Append(", [").Append(col).Append("] AS [").Append(col).Append("_existing]");
            }
            lookupSb.Append(" FROM ").Append(targetTable)
                    .Append(" WHERE [").Append(currentCol).Append("] = 1;");
            string lookupSql = lookupSb.ToString();

            var joinCols = new Dictionary<string, string> { { bk, bk } };
            var returnCols = new List<string> { sk };
            foreach (var col in payload) returnCols.Add(col + "_existing");

            // NoMatchBehavior=1 = SendRowsWithNoMatchingEntriesToNoMatchOutput.
            // The Type-2 pattern wires "Lookup No Match Output" to the
            // insert-new branch; behavior must be 1, not 2 (IgnoreFailure)
            // which would route NULL surrogate keys through Match Output.
            var lkp = PackageBuilder.AddLookup(df, "LKP Dim Current", tgt, lookupSql,
                joinCols, returnCols, noMatchBehavior: 1,
                upstream: oleSrc);

            // ---------- No-match → DC Insert Audit → OLE_DST Insert New ----------
            var noMatchAudit = BuildInsertAuditSpecs(currentCol, fromCol, toCol);
            var dcInsertNew = PackageBuilder.AddDerivedColumn(df, "DC Insert Audit (New)", noMatchAudit);
            PackageBuilder.ConnectComponents(df, lkp, dcInsertNew, fromOutputName: "Lookup No Match Output");

            var dstInsertNew = PackageBuilder.AddOleDbDestination(df, "OLE_DST Insert New", tgt, targetTable);
            PackageBuilder.ConnectComponents(df, dcInsertNew, dstInsertNew);
            PackageBuilder.InitializeOleDbDestinationMapping(dstInsertNew);

            // ---------- Match → Conditional Split: Changed vs Unchanged ----------
            var changeExpr = BuildChangeExpression(payload);
            var splitCases = new List<KeyValuePair<string, string>>
            {
                new KeyValuePair<string, string>("Changed", changeExpr)
            };
            var split = PackageBuilder.AddConditionalSplit(df, "CS Changed?", splitCases, defaultOutputName: "Unchanged");
            PackageBuilder.ConnectComponents(df, lkp, split, fromOutputName: "Lookup Match Output");
            // CS expressions reference [col] and [col_existing] by name — those
            // columns must be in the CS input column collection or Validate
            // reports "input column was not found". Only mark referenced columns
            // (not every upstream column) to avoid "READONLY but not referenced
            // by an expression" warnings.
            var csReferenced = new List<string>();
            foreach (var col in payload) { csReferenced.Add(col); csReferenced.Add(col + "_existing"); }
            PackageBuilder.MarkAllInputColumnsReadOnly(split, csReferenced);

            // ---------- Changed → Multicast → (Expire | Insert New Version) ----------
            var mc = PackageBuilder.AddMulticast(df, "MC Changed Fanout",
                new List<string> { "Expire", "InsertChanged" });
            PackageBuilder.ConnectComponents(df, split, mc, fromOutputName: "Changed");

            // Expire branch: DC adds EffectiveTo timestamp, then OLE DB Command UPDATE.
            var expireAudit = new List<DerivedColumnSpec>
            {
                DerivedColumnSpec.Timestamp("EffectiveToValue", "@[System::StartTime]")
            };
            var dcExpire = PackageBuilder.AddDerivedColumn(df, "DC Expire Audit", expireAudit);
            PackageBuilder.ConnectComponents(df, mc, dcExpire, fromOutputName: "Expire");

            string expireSql =
                "UPDATE " + targetTable +
                " SET [" + currentCol + "] = 0, [" + toCol + "] = ? WHERE [" + sk + "] = ?;";
            var cmdExpire = PackageBuilder.AddOleDbCommand(df, "CMD Expire Old", tgt, expireSql);
            PackageBuilder.ConnectComponents(df, dcExpire, cmdExpire);
            PackageBuilder.BindOleDbCommandParameters(cmdExpire,
                new List<string> { "EffectiveToValue", sk });

            // Insert-changed branch: same audit shape as no-match insert, then OLE_DST.
            var changedAudit = BuildInsertAuditSpecs(currentCol, fromCol, toCol);
            var dcInsertChanged = PackageBuilder.AddDerivedColumn(df, "DC Insert Audit (Changed)", changedAudit);
            PackageBuilder.ConnectComponents(df, mc, dcInsertChanged, fromOutputName: "InsertChanged");

            var dstInsertChanged = PackageBuilder.AddOleDbDestination(df, "OLE_DST Insert Changed", tgt, targetTable);
            PackageBuilder.ConnectComponents(df, dcInsertChanged, dstInsertChanged);
            // Exclude the surrogate key (IDENTITY) and the lookup-returned
            // _existing columns — the destination must let SQL Server assign a
            // new surrogate key, and the _existing columns aren't real table
            // columns.
            var excludeFromInsert = new List<string> { sk };
            foreach (var col in payload) excludeFromInsert.Add(col + "_existing");
            PackageBuilder.InitializeOleDbDestinationMapping(dstInsertChanged, excludeFromInsert);

            PackageBuilder.SavePackage(pkg, outputPath);
        }

        private static List<DerivedColumnSpec> BuildInsertAuditSpecs(string currentCol, string fromCol, string toCol)
        {
            return new List<DerivedColumnSpec>
            {
                new DerivedColumnSpec
                {
                    Name       = currentCol,
                    Expression = "(DT_BOOL)1",
                    DataType   = Microsoft.SqlServer.Dts.Runtime.Wrapper.DataType.DT_BOOL
                },
                DerivedColumnSpec.Timestamp(fromCol, "@[System::StartTime]"),
                new DerivedColumnSpec
                {
                    Name       = toCol,
                    Expression = "NULL(DT_DBTIMESTAMP)",
                    DataType   = Microsoft.SqlServer.Dts.Runtime.Wrapper.DataType.DT_DBTIMESTAMP
                },
                DerivedColumnSpec.Timestamp("LoadedAt", "@[System::StartTime]")
            };
        }

        private static string BuildChangeExpression(List<string> payload)
        {
            // Designer-built SCD2 change-detection idiom: NULL-safe compare via
            // ISNULL flag XOR plus direct compare. When either side is NULL
            // ISNULL differs and triggers "changed"; when both NULL ISNULL
            // agrees and the direct compare evaluates NULL (treated as false),
            // so the row is "unchanged". REPLACENULL+"" was rejected by the
            // SSIS expression parser at Validate time.
            var sb = new StringBuilder();
            for (int i = 0; i < payload.Count; i++)
            {
                if (i > 0) sb.Append(" || ");
                string col = payload[i];
                sb.Append("((ISNULL([").Append(col).Append("]) != ISNULL([")
                  .Append(col).Append("_existing])) || ([")
                  .Append(col).Append("] != [").Append(col).Append("_existing]))");
            }
            return sb.ToString();
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
                    "type2-dim metadata: 'columns' must list at least one {source,target} mapping when sourceQuery is omitted.");
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
