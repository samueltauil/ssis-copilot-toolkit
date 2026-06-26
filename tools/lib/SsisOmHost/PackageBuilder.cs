// PackageBuilder — thin wrappers over the SSIS managed object model used by pattern classes.
// Mirrors the helpers in tools/lib/SsisOm.psm1 so the pattern logic is a 1:1 translation.

using System;
using System.Collections.Generic;
using Microsoft.SqlServer.Dts.Runtime;
using Microsoft.SqlServer.Dts.Pipeline.Wrapper;
using DataType = Microsoft.SqlServer.Dts.Runtime.Wrapper.DataType;

namespace SsisOmHost
{
    internal static class PackageBuilder
    {
        public static Package NewPackage(string name, DTSProtectionLevel protection = DTSProtectionLevel.DontSaveSensitive)
        {
            return new Package { Name = name, ProtectionLevel = protection };
        }

        public static ConnectionManager AddOleDbConnection(Package pkg, string name, string serverName, string initialCatalog, bool integratedSecurity = true)
        {
            var cm = pkg.Connections.Add("OLEDB");
            cm.Name = name;
            var sec = integratedSecurity ? "SSPI" : "False";
            // TrustServerCertificate=True so MSOLEDBSQL 18+ accepts the SQL Server dev cert
            // (same reason sqlcmd needs -C in this environment).
            cm.ConnectionString = "Data Source=" + serverName +
                                  ";Initial Catalog=" + initialCatalog +
                                  ";Provider=MSOLEDBSQL;Integrated Security=" + sec +
                                  ";Trust Server Certificate=True" +
                                  ";Auto Translate=False;";
            return cm;
        }

        public static Executable AddExecuteSqlTask(Package pkg, string name, ConnectionManager conn, string sql)
        {
            var exec = pkg.Executables.Add("Microsoft.ExecuteSQLTask");
            ((TaskHost)exec).Name = name;
            dynamic task = ((TaskHost)exec).InnerObject;
            task.Connection = conn.Name;
            task.SqlStatementSource = sql;
            return exec;
        }

        public static DataFlow AddDataFlowTask(Package pkg, string name)
        {
            var exec = (TaskHost)pkg.Executables.Add("Microsoft.Pipeline");
            exec.Name = name;
            return new DataFlow { TaskHost = exec, MainPipe = (MainPipe)exec.InnerObject };
        }

        public static void SetComponentConnection(IDTSComponentMetaData100 component, ConnectionManager conn)
        {
            component.RuntimeConnectionCollection[0].ConnectionManagerID = conn.ID;
            component.RuntimeConnectionCollection[0].ConnectionManager =
                DtsConvert.GetExtendedInterface(conn);
        }

        public static IDTSComponentMetaData100 AddOleDbSource(DataFlow df, string name, ConnectionManager conn, string sqlCommand)
        {
            var comp = df.MainPipe.ComponentMetaDataCollection.New();
            comp.ComponentClassID = "Microsoft.OLEDBSource";
            var inst = comp.Instantiate();
            inst.ProvideComponentProperties();
            comp.Name = name; // set AFTER ProvideComponentProperties so the framework default doesn't overwrite
            SetComponentConnection(comp, conn);
            comp.CustomPropertyCollection["AccessMode"].Value = 2;
            comp.CustomPropertyCollection["SqlCommand"].Value = sqlCommand;
            inst.AcquireConnections(null);
            inst.ReinitializeMetaData();
            inst.ReleaseConnections();
            return comp;
        }

        public static IDTSComponentMetaData100 AddOleDbDestination(DataFlow df, string name, ConnectionManager conn, string table, bool fastLoad = true, int rowsPerBatch = 10000)
        {
            var comp = df.MainPipe.ComponentMetaDataCollection.New();
            comp.ComponentClassID = "Microsoft.OLEDBDestination";
            var inst = comp.Instantiate();
            inst.ProvideComponentProperties();
            comp.Name = name;
            SetComponentConnection(comp, conn);
            comp.CustomPropertyCollection["AccessMode"].Value = fastLoad ? 3 : 0;
            comp.CustomPropertyCollection["OpenRowset"].Value = table;
            if (fastLoad)
            {
                comp.CustomPropertyCollection["FastLoadOptions"].Value = "TABLOCK,CHECK_CONSTRAINTS";
                comp.CustomPropertyCollection["FastLoadMaxInsertCommitSize"].Value = rowsPerBatch;
            }
            return comp;
        }

        public static IDTSComponentMetaData100 AddDerivedColumn(DataFlow df, string name, IList<DerivedColumnSpec> expressions)
        {
            var comp = df.MainPipe.ComponentMetaDataCollection.New();
            comp.ComponentClassID = "Microsoft.DerivedColumn";
            var inst = comp.Instantiate();
            inst.ProvideComponentProperties();
            comp.Name = name;
            var output = comp.OutputCollection[0];
            foreach (var spec in expressions)
            {
                var newCol = output.OutputColumnCollection.New();
                newCol.Name = spec.Name;
                newCol.SetDataTypeProperties(spec.DataType, spec.Length, spec.Precision, spec.Scale, spec.CodePage);
                newCol.ErrorRowDisposition      = DTSRowDisposition.RD_FailComponent;
                newCol.TruncationRowDisposition = DTSRowDisposition.RD_FailComponent;

                // Derived Column requires explicit creation of Expression / FriendlyExpression
                // custom properties on each new output column (they are not auto-created).
                var expr = newCol.CustomPropertyCollection.New();
                expr.Name = "Expression";
                expr.Value = spec.Expression;

                var friendly = newCol.CustomPropertyCollection.New();
                friendly.Name = "FriendlyExpression";
                friendly.Value = spec.Expression;
            }
            return comp;
        }

        public static void ConnectComponents(DataFlow df, IDTSComponentMetaData100 from, IDTSComponentMetaData100 to, string fromOutputName = null, string toInputName = null)
        {
            IDTSOutput100 output = null;
            if (!string.IsNullOrEmpty(fromOutputName))
            {
                foreach (IDTSOutput100 o in from.OutputCollection)
                {
                    if (o.Name == fromOutputName) { output = o; break; }
                }
            }
            else
            {
                foreach (IDTSOutput100 o in from.OutputCollection)
                {
                    if (!o.IsErrorOut) { output = o; break; }
                }
            }
            if (output == null) throw new InvalidOperationException("Connect: output '" + fromOutputName + "' not found on '" + from.Name + "'.");

            IDTSInput100 input = null;
            if (!string.IsNullOrEmpty(toInputName))
            {
                foreach (IDTSInput100 i in to.InputCollection)
                {
                    if (i.Name == toInputName) { input = i; break; }
                }
            }
            else
            {
                input = to.InputCollection[0];
            }
            if (input == null) throw new InvalidOperationException("Connect: input '" + toInputName + "' not found on '" + to.Name + "'.");

            var path = df.MainPipe.PathCollection.New();
            path.AttachPathAndPropagateNotifications(output, input);
        }

        public static void InitializeOleDbDestinationMapping(
            IDTSComponentMetaData100 destination,
            IList<string> excludeColumns = null)
        {
            var inst = destination.Instantiate();
            inst.AcquireConnections(null);
            inst.ReinitializeMetaData();
            inst.ReleaseConnections();
            var input = destination.InputCollection[0];
            var virtualInput = input.GetVirtualInput();
            foreach (IDTSVirtualInputColumn100 vCol in virtualInput.VirtualInputColumnCollection)
            {
                // Skip caller-supplied columns (typically surrogate-key / IDENTITY
                // columns that arrive via a Lookup but must NOT be inserted).
                if (excludeColumns != null)
                {
                    bool skip = false;
                    foreach (var ex in excludeColumns)
                    {
                        if (string.Equals(ex, vCol.Name, StringComparison.OrdinalIgnoreCase)) { skip = true; break; }
                    }
                    if (skip) continue;
                }
                IDTSExternalMetadataColumn100 external = null;
                foreach (IDTSExternalMetadataColumn100 ec in input.ExternalMetadataColumnCollection)
                {
                    if (ec.Name == vCol.Name) { external = ec; break; }
                }
                if (external == null) continue;
                inst.SetUsageType(input.ID, virtualInput, vCol.LineageID, DTSUsageType.UT_READONLY);
                IDTSInputColumn100 matched = null;
                foreach (IDTSInputColumn100 ic in input.InputColumnCollection)
                {
                    if (ic.LineageID == vCol.LineageID) { matched = ic; break; }
                }
                if (matched != null) matched.ExternalMetadataColumnID = external.ID;
            }
        }

        public static void SavePackage(Package pkg, string path)
        {
            var dir = System.IO.Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(dir) && !System.IO.Directory.Exists(dir))
            {
                System.IO.Directory.CreateDirectory(dir);
            }
            var app = new Application();
            app.SaveToXml(path, pkg, null);
        }

        // -- Lookup ----------------------------------------------------------
        //
        // JoinColumns maps upstream input column name -> reference column name on
        // the lookup table. ReturnColumns is the list of reference columns to add
        // to the Lookup Match Output for downstream consumption. NoMatchBehavior:
        // 0 = FailComponent, 1 = IgnoreFailure, 2 = RedirectRow.
        //
        // Reference-column resolution: we query the lookup SQL with
        // CommandBehavior.SchemaOnly via SqlClient to learn the available column
        // names + SSIS data types up front. We keep that snapshot in a local
        // dictionary and:
        //
        //   - validate that every join target and every requested return column
        //     actually exists on the reference table at generation time;
        //   - set the output column data types from the reference schema (so
        //     downstream components see the correct types);
        //   - skip populating ExternalMetadataColumnCollection entirely. The
        //     designer fills it for offline-validation convenience, but the
        //     runtime resolves JoinToReferenceColumn / CopyFromReferenceColumn
        //     by *name* against the live reference query, and our prior attempts
        //     to seed it manually triggered DTS_E_VALIDATEEXTERNALMETADATA at
        //     runtime (0x8000FFFF). Leaving it empty is harmless — the package
        //     loads, designs, and executes.
        public static IDTSComponentMetaData100 AddLookup(
            DataFlow df,
            string name,
            ConnectionManager conn,
            string sqlCommand,
            IDictionary<string, string> joinColumns,
            IList<string> returnColumns = null,
            int noMatchBehavior = 2,
            IDTSComponentMetaData100 upstream = null,
            string fromOutputName = null)
        {
            var comp = df.MainPipe.ComponentMetaDataCollection.New();
            comp.ComponentClassID = "DTSTransform.Lookup";
            var inst = comp.Instantiate();
            inst.ProvideComponentProperties();
            comp.Name = name;
            SetComponentConnection(comp, conn);
            comp.CustomPropertyCollection["SqlCommand"].Value = sqlCommand;
            comp.CustomPropertyCollection["CacheType"].Value = 0; // Full Cache
            comp.CustomPropertyCollection["NoMatchBehavior"].Value = noMatchBehavior;

            if (upstream != null)
            {
                ConnectComponents(df, upstream, comp, fromOutputName);
            }

            inst.AcquireConnections(null);
            inst.ReinitializeMetaData();
            inst.ReleaseConnections();

            // Build a name -> SSIS-type dictionary by introspecting the reference SQL.
            // Used to (a) validate join/return column names exist and (b) type the
            // output columns we add to "Lookup Match Output".
            var refSchema = QueryReferenceSchema(conn, sqlCommand);

            var input = comp.InputCollection[0];
            var virtualInput = input.GetVirtualInput();

            // CRITICAL: Lookup is DIFFERENT from OLE DB / dest components.
            // Designer-built Lookup XML has EMPTY <externalMetadataColumns />
            // on input AND output, with NO externalMetadataColumnId attribute
            // on inputColumn or outputColumn. The Lookup framework uses
            // ReferenceMetadataXml (the property) as its sole source of
            // reference-column metadata. Populating ExternalMetadataColumnCollection
            // makes the native Lookup Validate throw E_UNEXPECTED (0x8000FFFF)
            // at dtexec /Validate time. Do NOT set IsUsed or add columns here.

            foreach (var kv in joinColumns)
            {
                string inputColName = kv.Key;
                string lookupColName = kv.Value;

                if (!refSchema.ContainsKey(lookupColName))
                    throw new InvalidOperationException(
                        "Lookup '" + name + "': lookup column '" + lookupColName + "' not found in reference SQL result.");

                IDTSVirtualInputColumn100 vCol = null;
                foreach (IDTSVirtualInputColumn100 v in virtualInput.VirtualInputColumnCollection)
                {
                    if (v.Name == inputColName) { vCol = v; break; }
                }
                if (vCol == null) throw new InvalidOperationException(
                    "Lookup '" + name + "': input column '" + inputColName + "' not found upstream.");

                inst.SetUsageType(input.ID, virtualInput, vCol.LineageID, DTSUsageType.UT_READONLY);

                IDTSInputColumn100 matched = null;
                foreach (IDTSInputColumn100 ic in input.InputColumnCollection)
                {
                    if (ic.LineageID == vCol.LineageID) { matched = ic; break; }
                }
                if (matched == null) throw new InvalidOperationException(
                    "Lookup '" + name + "': failed to bind input column '" + inputColName + "'.");

                SetOrCreateCustomProperty(matched.CustomPropertyCollection, "JoinToReferenceColumn", lookupColName);
                SetOrCreateCustomProperty(matched.CustomPropertyCollection, "CopyFromReferenceColumn", null);
            }

            if (returnColumns != null && returnColumns.Count > 0)
            {
                IDTSOutput100 matchOutput = null;
                foreach (IDTSOutput100 o in comp.OutputCollection)
                {
                    if (o.Name == "Lookup Match Output") { matchOutput = o; break; }
                }
                if (matchOutput == null) throw new InvalidOperationException(
                    "Lookup '" + name + "': 'Lookup Match Output' missing.");

                // Match Output disposition rules differ by NoMatchBehavior:
                //  - behavior=0 (FailComponent): leave framework default
                //    (RD_FailComponent) — the Lookup native validator rejects
                //    RD_NotUsed when no-match failures must propagate.
                //  - behavior=1 (SendToNoMatch) and 2 (IgnoreFailure): set
                //    RD_NotUsed because matches never produce row-level errors
                //    on the Match Output path.
                if (noMatchBehavior != 0)
                {
                    matchOutput.ErrorRowDisposition      = DTSRowDisposition.RD_NotUsed;
                    matchOutput.TruncationRowDisposition = DTSRowDisposition.RD_NotUsed;
                }

                foreach (var returnName in returnColumns)
                {
                    ReferenceColumnInfo info;
                    if (!refSchema.TryGetValue(returnName, out info))
                        throw new InvalidOperationException(
                            "Lookup '" + name + "': return column '" + returnName + "' not found in reference SQL result.");

                    var newOutCol = matchOutput.OutputColumnCollection.New();
                    newOutCol.Name = returnName;
                    newOutCol.SetDataTypeProperties(info.DataType, info.Length, info.Precision, info.Scale, info.CodePage);
                    // Designer-built Lookup output columns: errorRowDisposition is
                    // omitted (= NotUsed), truncationRowDisposition is FailComponent,
                    // errorOrTruncationOperation is "Copy Column". The Match Output
                    // never produces errors at the row level (failures route to
                    // Error Output) so RD_NotUsed is correct for errorRowDisposition.
                    newOutCol.ErrorRowDisposition       = DTSRowDisposition.RD_NotUsed;
                    newOutCol.TruncationRowDisposition  = DTSRowDisposition.RD_FailComponent;
                    newOutCol.ErrorOrTruncationOperation = "Copy Column";
                    SetOrCreateCustomProperty(newOutCol.CustomPropertyCollection, "CopyFromReferenceColumn", returnName);
                }
            }

            return comp;
        }

        // Indexer get on CustomPropertyCollection throws DTS_E_PROPERTYNOTFOUND when the
        // named property doesn't exist yet. For Lookup input/output columns the
        // JoinToReferenceColumn / CopyFromReferenceColumn props are not auto-created —
        // call .New() the first time, then set Value.
        private static void SetOrCreateCustomProperty(IDTSCustomPropertyCollection100 props, string propName, object value)
        {
            IDTSCustomProperty100 prop = null;
            try { prop = props[propName]; } catch { /* not present yet */ }
            if (prop == null)
            {
                prop = props.New();
                prop.Name = propName;
            }
            prop.Value = value;
        }

        // Reference-column schema introspection ---------------------------------
        //
        // Per-column metadata captured from CommandBehavior.SchemaOnly on the
        // Lookup's reference SQL — used to set output column data types and to
        // validate join/return column names at generation time.
        private struct ReferenceColumnInfo
        {
            public DataType DataType;
            public int Length;
            public int Precision;
            public int Scale;
            public int CodePage;
        }

        private static IDictionary<string, ReferenceColumnInfo> QueryReferenceSchema(ConnectionManager cm, string sqlCommand)
        {
            string server, database;
            ParseServerAndDatabase(cm.ConnectionString, out server, out database);

            var sqlConnString = "Server=" + server +
                                ";Database=" + database +
                                ";Integrated Security=True" +
                                ";TrustServerCertificate=True" +
                                ";Encrypt=False;";

            var result = new Dictionary<string, ReferenceColumnInfo>(StringComparer.OrdinalIgnoreCase);
            using (var sqlConn = new System.Data.SqlClient.SqlConnection(sqlConnString))
            {
                sqlConn.Open();
                using (var cmd = new System.Data.SqlClient.SqlCommand(sqlCommand, sqlConn))
                using (var reader = cmd.ExecuteReader(System.Data.CommandBehavior.SchemaOnly | System.Data.CommandBehavior.KeyInfo))
                {
                    var schema = reader.GetSchemaTable();
                    if (schema == null) return result;

                    foreach (System.Data.DataRow row in schema.Rows)
                    {
                        var colName  = System.Convert.ToString(row["ColumnName"]);
                        var dotnetTy = (System.Type)row["DataType"];
                        int colSize  = row["ColumnSize"]      is System.DBNull ? 0 : System.Convert.ToInt32(row["ColumnSize"]);
                        int prec     = row["NumericPrecision"] is System.DBNull ? 0 : System.Convert.ToInt32(row["NumericPrecision"]);
                        int scale    = row["NumericScale"]    is System.DBNull ? 0 : System.Convert.ToInt32(row["NumericScale"]);
                        string provTy = row.Table.Columns.Contains("DataTypeName") && !(row["DataTypeName"] is System.DBNull)
                            ? System.Convert.ToString(row["DataTypeName"]).ToLowerInvariant()
                            : null;

                        ReferenceColumnInfo info;
                        MapSqlTypeToSsis(provTy, dotnetTy, colSize, prec, scale,
                            out info.DataType, out info.Length, out info.Precision, out info.Scale, out info.CodePage);
                        result[colName] = info;
                    }
                }
            }
            return result;
        }

        private static void ParseServerAndDatabase(string oleDbConnectionString, out string server, out string database)
        {
            server   = null;
            database = null;
            foreach (var raw in oleDbConnectionString.Split(';'))
            {
                var part = raw.Trim();
                if (part.Length == 0) continue;
                var eq = part.IndexOf('=');
                if (eq <= 0) continue;
                var key = part.Substring(0, eq).Trim().ToLowerInvariant();
                var val = part.Substring(eq + 1).Trim();
                if (key == "data source" || key == "server")          server   = val;
                if (key == "initial catalog" || key == "database")    database = val;
            }
            if (string.IsNullOrEmpty(server) || string.IsNullOrEmpty(database))
                throw new InvalidOperationException(
                    "Cannot parse server/database from connection string: " + oleDbConnectionString);
        }

        private static void MapSqlTypeToSsis(
            string providerTypeName, System.Type dotnetType,
            int columnSize, int precision, int scale,
            out DataType ssisType, out int outLen, out int outPrec, out int outScale, out int outCodePage)
        {
            outLen = 0; outPrec = 0; outScale = 0; outCodePage = 0;

            // Prefer explicit SQL type name when available.
            var t = providerTypeName ?? "";
            switch (t)
            {
                case "int":              ssisType = DataType.DT_I4;          return;
                case "bigint":           ssisType = DataType.DT_I8;          return;
                case "smallint":         ssisType = DataType.DT_I2;          return;
                case "tinyint":          ssisType = DataType.DT_UI1;         return;
                case "bit":              ssisType = DataType.DT_BOOL;        return;
                case "uniqueidentifier": ssisType = DataType.DT_GUID;        return;
                case "date":             ssisType = DataType.DT_DBDATE;      return;
                case "time":             ssisType = DataType.DT_DBTIME2;     outScale = scale; return;
                case "datetime":         ssisType = DataType.DT_DBTIMESTAMP; return;
                case "smalldatetime":    ssisType = DataType.DT_DBTIMESTAMP; return;
                case "datetime2":        ssisType = DataType.DT_DBTIMESTAMP2; outScale = scale; return;
                case "datetimeoffset":   ssisType = DataType.DT_DBTIMESTAMPOFFSET; outScale = scale; return;
                case "real":             ssisType = DataType.DT_R4;          return;
                case "float":            ssisType = DataType.DT_R8;          return;
                case "money":            ssisType = DataType.DT_CY;          return;
                case "smallmoney":       ssisType = DataType.DT_CY;          return;
                case "decimal":
                case "numeric":          ssisType = DataType.DT_NUMERIC; outPrec = precision == 0 ? 18 : precision; outScale = scale; return;
                case "char":             ssisType = DataType.DT_STR;  outLen = columnSize > 0 ? columnSize : 1; outCodePage = 1252; return;
                case "varchar":          ssisType = DataType.DT_STR;  outLen = columnSize > 0 ? columnSize : 50; outCodePage = 1252; return;
                case "text":             ssisType = DataType.DT_TEXT; outCodePage = 1252; return;
                case "nchar":            ssisType = DataType.DT_WSTR; outLen = columnSize > 0 ? columnSize : 1; return;
                case "nvarchar":         ssisType = DataType.DT_WSTR; outLen = columnSize > 0 ? columnSize : 50; return;
                case "ntext":            ssisType = DataType.DT_NTEXT; return;
                case "binary":           ssisType = DataType.DT_BYTES; outLen = columnSize > 0 ? columnSize : 1; return;
                case "varbinary":        ssisType = DataType.DT_BYTES; outLen = columnSize > 0 ? columnSize : 50; return;
                case "image":            ssisType = DataType.DT_IMAGE; return;
                case "xml":              ssisType = DataType.DT_NTEXT; return;
            }

            // Fall back to .NET type when SQL type name is missing.
            if (dotnetType == typeof(int))       { ssisType = DataType.DT_I4;          return; }
            if (dotnetType == typeof(long))      { ssisType = DataType.DT_I8;          return; }
            if (dotnetType == typeof(short))     { ssisType = DataType.DT_I2;          return; }
            if (dotnetType == typeof(byte))      { ssisType = DataType.DT_UI1;         return; }
            if (dotnetType == typeof(bool))      { ssisType = DataType.DT_BOOL;        return; }
            if (dotnetType == typeof(System.Guid))   { ssisType = DataType.DT_GUID;    return; }
            if (dotnetType == typeof(System.DateTime)) { ssisType = DataType.DT_DBTIMESTAMP; return; }
            if (dotnetType == typeof(decimal))   { ssisType = DataType.DT_NUMERIC; outPrec = precision == 0 ? 18 : precision; outScale = scale; return; }
            if (dotnetType == typeof(float))     { ssisType = DataType.DT_R4;          return; }
            if (dotnetType == typeof(double))    { ssisType = DataType.DT_R8;          return; }
            if (dotnetType == typeof(string))    { ssisType = DataType.DT_WSTR; outLen = columnSize > 0 ? columnSize : 4000; return; }

            // Last-resort sane default — wide string.
            ssisType = DataType.DT_WSTR;
            outLen = columnSize > 0 ? columnSize : 4000;
        }

        // -- Conditional Split ----------------------------------------------
        //
        // cases: ordered map of output name -> SSIS expression returning bool.
        // The default output is renamed to defaultOutputName (whatever rows match
        // no case land there).
        public static IDTSComponentMetaData100 AddConditionalSplit(
            DataFlow df,
            string name,
            IList<KeyValuePair<string, string>> cases,
            string defaultOutputName = "Default")
        {
            var comp = df.MainPipe.ComponentMetaDataCollection.New();
            comp.ComponentClassID = "Microsoft.ConditionalSplit";
            var inst = comp.Instantiate();
            inst.ProvideComponentProperties();
            comp.Name = name;

            int order = 0;
            foreach (var kv in cases)
            {
                var newOut = comp.OutputCollection.New();
                newOut.Name = kv.Key;
                newOut.IsErrorOut = false;
                newOut.SynchronousInputID = comp.InputCollection[0].ID;
                // All ConditionalSplit case outputs (and the default) must
                // share ExclusionGroup=1 so the framework knows each row
                // routes to exactly one output.
                newOut.ExclusionGroup = 1;
                // Case outputs need explicit row dispositions — framework
                // default RD_NotUsed fails Validate with "invalid error or
                // truncation row disposition". Designer-built CS outputs use
                // FailComponent for both.
                newOut.ErrorRowDisposition      = DTSRowDisposition.RD_FailComponent;
                newOut.TruncationRowDisposition = DTSRowDisposition.RD_FailComponent;
                // ConditionalSplit outputs added via OutputCollection.New() do
                // NOT have the Expression/FriendlyExpression/EvaluationOrder
                // custom properties pre-created — we have to add them.
                SetOrCreateCustomProperty(newOut.CustomPropertyCollection, "Expression", kv.Value);
                SetOrCreateCustomProperty(newOut.CustomPropertyCollection, "FriendlyExpression", kv.Value);
                SetOrCreateCustomProperty(newOut.CustomPropertyCollection, "EvaluationOrder", order++);
            }

            // ConditionalSplit's first output is the default (unmatched-rows) output.
            comp.OutputCollection[0].Name = defaultOutputName;
            comp.OutputCollection[0].ExclusionGroup = 1;
            return comp;
        }

        // Mark every upstream column on the component's input as UT_READONLY so
        // SSIS expressions that reference [col] resolve. Required for Conditional
        // Split (and other expression-evaluating components) after the upstream
        // path is connected — without this the expression parser reports
        // 0xC0010009 "input column was not found in the input column collection".
        // If columnNames is null, marks ALL upstream columns; otherwise marks only
        // the named columns (preferred for CS to avoid "READONLY but not
        // referenced by an expression" warnings).
        public static void MarkAllInputColumnsReadOnly(
            IDTSComponentMetaData100 comp,
            IList<string> columnNames = null)
        {
            var inst = comp.Instantiate();
            var input = comp.InputCollection[0];
            var vInput = input.GetVirtualInput();
            foreach (IDTSVirtualInputColumn100 v in vInput.VirtualInputColumnCollection)
            {
                if (columnNames != null)
                {
                    bool include = false;
                    foreach (var n in columnNames)
                    {
                        if (string.Equals(n, v.Name, StringComparison.OrdinalIgnoreCase)) { include = true; break; }
                    }
                    if (!include) continue;
                }
                inst.SetUsageType(input.ID, vInput, v.LineageID, DTSUsageType.UT_READONLY);
            }
        }

        // -- OLE DB Command --------------------------------------------------
        //
        // sqlCommand may contain `?` placeholders bound positionally to input
        // columns named "Param_0", "Param_1", ... as parameter mappings. After
        // ReinitializeMetaData, the component exposes a Param_N external column
        // for each `?` in the SQL — the caller can wire input columns to them
        // by name with the regular SetUsageType + ExternalMetadataColumnID dance.
        public static IDTSComponentMetaData100 AddOleDbCommand(
            DataFlow df,
            string name,
            ConnectionManager conn,
            string sqlCommand)
        {
            var comp = df.MainPipe.ComponentMetaDataCollection.New();
            comp.ComponentClassID = "Microsoft.OleDbCommand";
            var inst = comp.Instantiate();
            inst.ProvideComponentProperties();
            comp.Name = name;
            SetComponentConnection(comp, conn);
            comp.CustomPropertyCollection["SqlCommand"].Value = sqlCommand;
            inst.AcquireConnections(null);
            inst.ReinitializeMetaData();
            inst.ReleaseConnections();
            return comp;
        }

        // -- Multicast -------------------------------------------------------
        //
        // Fan-out: a Multicast forwards every input row to every output,
        // unchanged. Pass the desired output names; one synchronous output is
        // created for each. Used by Type-2 (SCD-2) to split the "changed"
        // branch into expire-old + insert-new.
        public static IDTSComponentMetaData100 AddMulticast(
            DataFlow df,
            string name,
            IList<string> outputNames)
        {
            var comp = df.MainPipe.ComponentMetaDataCollection.New();
            comp.ComponentClassID = "Microsoft.Multicast";
            var inst = comp.Instantiate();
            inst.ProvideComponentProperties();
            comp.Name = name;

            // Multicast starts with zero outputs; we create one per requested name.
            int inputId = comp.InputCollection[0].ID;
            foreach (var outName in outputNames)
            {
                var newOut = comp.OutputCollection.New();
                newOut.Name = outName;
                newOut.SynchronousInputID = inputId;
            }
            return comp;
        }

        // Map upstream input columns by name onto the OLE DB Command's Param_N
        // external metadata columns produced after ReinitializeMetaData. Pass
        // the input column names in the order they should bind to ?-parameters.
        public static void BindOleDbCommandParameters(
            IDTSComponentMetaData100 oleDbCommand,
            IList<string> inputColumnNames)
        {
            var input = oleDbCommand.InputCollection[0];
            var virtualInput = input.GetVirtualInput();
            var inst = oleDbCommand.Instantiate();

            for (int i = 0; i < inputColumnNames.Count; i++)
            {
                string colName = inputColumnNames[i];
                string paramName = "Param_" + i;

                IDTSVirtualInputColumn100 vCol = null;
                foreach (IDTSVirtualInputColumn100 v in virtualInput.VirtualInputColumnCollection)
                {
                    if (v.Name == colName) { vCol = v; break; }
                }
                if (vCol == null) throw new InvalidOperationException(
                    "OLE DB Command '" + oleDbCommand.Name + "': input column '" + colName + "' not found upstream.");

                inst.SetUsageType(input.ID, virtualInput, vCol.LineageID, DTSUsageType.UT_READONLY);

                IDTSInputColumn100 matched = null;
                foreach (IDTSInputColumn100 ic in input.InputColumnCollection)
                {
                    if (ic.LineageID == vCol.LineageID) { matched = ic; break; }
                }
                if (matched == null) throw new InvalidOperationException(
                    "OLE DB Command '" + oleDbCommand.Name + "': failed to bind input column '" + colName + "'.");

                IDTSExternalMetadataColumn100 paramCol = null;
                foreach (IDTSExternalMetadataColumn100 ec in input.ExternalMetadataColumnCollection)
                {
                    if (ec.Name == paramName) { paramCol = ec; break; }
                }
                if (paramCol == null) throw new InvalidOperationException(
                    "OLE DB Command '" + oleDbCommand.Name + "': expected parameter '" + paramName +
                    "' not exposed - check the ? count in the SQL.");

                matched.ExternalMetadataColumnID = paramCol.ID;
            }
        }
    }

    internal class DataFlow
    {
        public TaskHost TaskHost { get; set; }
        public MainPipe MainPipe { get; set; }
    }

    internal class DerivedColumnSpec
    {
        public string Name;
        public string Expression;
        public DataType DataType;
        public int Length;
        public int Precision;
        public int Scale;
        public int CodePage;

        public static DerivedColumnSpec Timestamp(string name, string expression)
        {
            return new DerivedColumnSpec { Name = name, Expression = expression, DataType = DataType.DT_DBTIMESTAMP };
        }

        public static DerivedColumnSpec Guid(string name, string expression)
        {
            return new DerivedColumnSpec { Name = name, Expression = expression, DataType = DataType.DT_GUID };
        }
    }
}
