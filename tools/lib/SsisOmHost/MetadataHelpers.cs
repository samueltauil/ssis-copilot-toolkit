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
                var c = (IDictionary<string, object>)conns[role];
                return new ConnectionInfo
                {
                    Server   = GetString(c, "server",   required: true),
                    Database = GetString(c, "database", required: true)
                };
            }
            // 2. inferred from source/target block
            var block = GetDict(meta, role);
            if (block != null)
            {
                var defaultDb = role == "source" ? "AdventureWorks2025" : "CopilotSSIS_Warehouse";
                return new ConnectionInfo
                {
                    Server   = GetString(block, "server",   defaultValue: @".\SQL2025"),
                    Database = GetString(block, "database", defaultValue: defaultDb)
                };
            }
            throw new ArgumentException("Cannot resolve '" + role + "' connection. Provide connections." + role + ".{server,database} or " + role + ".{database}.");
        }
    }

    internal class ConnectionInfo
    {
        public string Server { get; set; }
        public string Database { get; set; }
    }
}
