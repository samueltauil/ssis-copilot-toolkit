using System;
using System.Collections.Generic;

namespace SsisOmHost
{
    internal static class MetadataHelpers
    {
        public static string GetString(IDictionary<string, object> d, string key, bool required = false, string defaultValue = null)
        {
            object v;
            if (d.TryGetValue(key, out v) && v != null)
            {
                return Convert.ToString(v);
            }
            if (required)
            {
                throw new ArgumentException("metadata: missing required field '" + key + "'.");
            }
            return defaultValue;
        }

        public static bool GetBool(IDictionary<string, object> d, string key, bool defaultValue)
        {
            object v;
            if (d.TryGetValue(key, out v) && v != null)
            {
                return Convert.ToBoolean(v);
            }
            return defaultValue;
        }

        public static IDictionary<string, object> GetDict(IDictionary<string, object> d, string key, bool required = false)
        {
            object v;
            if (d.TryGetValue(key, out v) && v is IDictionary<string, object>)
            {
                return (IDictionary<string, object>)v;
            }
            if (required)
            {
                throw new ArgumentException("metadata: missing required object '" + key + "'.");
            }
            return null;
        }

        public static IList<object> GetArray(IDictionary<string, object> d, string key, bool required = false)
        {
            object v;
            if (d.TryGetValue(key, out v) && v != null)
            {
                if (v is object[]) return new List<object>((object[])v);
                if (v is IList<object>) return (IList<object>)v;
                // JavaScriptSerializer.Deserialize<Dictionary<string,object>> hands JSON
                // arrays back as System.Collections.ArrayList — accept any non-generic IList too.
                var nonGeneric = v as System.Collections.IList;
                if (nonGeneric != null)
                {
                    var list = new List<object>(nonGeneric.Count);
                    foreach (var item in nonGeneric) list.Add(item);
                    return list;
                }
            }
            if (required)
            {
                throw new ArgumentException("metadata: missing required array '" + key + "'.");
            }
            return new List<object>();
        }

        public static ConnectionInfo ResolveConnection(IDictionary<string, object> meta, string role)
        {
            // 1. explicit connections.{role}.{server,database}
            var conns = GetDict(meta, "connections");
            if (conns != null && conns.ContainsKey(role))
            {
                var c = conns[role] as IDictionary<string, object>;
                if (c != null)
                {
                    return new ConnectionInfo
                    {
                        Server   = RequireConnectionValue(c, "server",   role),
                        Database = RequireConnectionValue(c, "database", role)
                    };
                }
            }
            // 2. inferred from the source/target block
            var block = GetDict(meta, role);
            if (block != null)
            {
                return new ConnectionInfo
                {
                    Server   = RequireConnectionValue(block, "server",   role),
                    Database = RequireConnectionValue(block, "database", role)
                };
            }
            throw new ArgumentException(
                "metadata: cannot resolve the '" + role + "' connection. Add \"" + role +
                "\": { \"server\": \"...\", \"database\": \"...\" } (or \"connections\"." + role +
                ") to the metadata JSON.");
        }

        // No environment default is safe here: guessing a server or database silently
        // produces a package pointed at something the author never named.
        private static string RequireConnectionValue(IDictionary<string, object> d, string key, string role)
        {
            var value = GetString(d, key);
            if (string.IsNullOrWhiteSpace(value))
            {
                throw new ArgumentException(
                    "metadata: '" + role + "." + key + "' is required and has no default. " +
                    "Set it in the metadata JSON to match your environment.");
            }
            return value;
        }

        /// <summary>
        /// Warehouse schema name for a pattern role ("staging", "dimension", "fact").
        /// Defaults to the Kimball-conventional stg/dim/fact, overridable per package
        /// via a "schemas" block in the metadata JSON.
        /// </summary>
        public static string GetSchemaName(IDictionary<string, object> meta, string role, string defaultValue)
        {
            var schemas = GetDict(meta, "schemas");
            if (schemas != null)
            {
                var configured = GetString(schemas, role);
                if (!string.IsNullOrWhiteSpace(configured)) { return configured; }
            }
            return defaultValue;
        }

        public static void EnsureTargetSchema(string patternName, string role, string targetTable, string schemaName)
        {
            if (targetTable.StartsWith(schemaName + ".") ||
                targetTable.StartsWith("[" + schemaName + "]."))
            {
                return;
            }
            throw new ArgumentException(
                patternName + " metadata: targetTable '" + targetTable + "' must be in the '" +
                schemaName + "' schema. Override the schema name with \"schemas\": { \"" + role +
                "\": \"...\" } in the metadata JSON.");
        }
    }

    internal class ConnectionInfo
    {
        public string Server { get; set; }
        public string Database { get; set; }
    }
}
