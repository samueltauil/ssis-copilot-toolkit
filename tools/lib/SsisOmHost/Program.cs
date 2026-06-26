// SsisOmHost — .NET Framework 4.8 console app that performs SSIS managed-OM authoring on
// behalf of PowerShell. PowerShell cannot activate SSIS pipeline design-time components
// (ProvideComponentProperties fails with TYPE_E_ELEMENTNOTFOUND), so all OM work happens
// inside this exe.
//
// Usage:
//   SsisOmHost.exe build  --metadata <file.json> --output <file.dtsx>
//   SsisOmHost.exe verify --package  <file.dtsx>
//
// `verify` does an Application.LoadPackage + SaveToXml round-trip — the same code path
// VS's SSIS designer uses on open. It is used by Test-SsisDesignerLoad.ps1.

using System;
using System.IO;
using System.Web.Script.Serialization;
using Microsoft.SqlServer.Dts.Runtime;

namespace SsisOmHost
{
    internal static class Program
    {
        public static int Main(string[] args)
        {
            try
            {
                if (args.Length == 0)
                {
                    return Usage();
                }

                switch (args[0])
                {
                    case "build":  return RunBuild(args);
                    case "verify": return RunVerify(args);
                    default:       return Usage();
                }
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("FAIL: " + ex.GetType().FullName + " :: " + ex.Message);
                if (ex.InnerException != null)
                {
                    Console.Error.WriteLine("Inner: " + ex.InnerException.Message);
                }
                Console.Error.WriteLine(ex.StackTrace);
                return 1;
            }
        }

        private static int RunBuild(string[] args)
        {
            string metadataPath = null;
            string outputPath = null;
            for (int i = 1; i < args.Length; i++)
            {
                switch (args[i])
                {
                    case "--metadata": metadataPath = args[++i]; break;
                    case "--output":   outputPath   = args[++i]; break;
                    default: return Usage();
                }
            }
            if (string.IsNullOrEmpty(metadataPath) || string.IsNullOrEmpty(outputPath))
            {
                return Usage();
            }
            if (!File.Exists(metadataPath))
            {
                Console.Error.WriteLine("ERROR: metadata not found: " + metadataPath);
                return 2;
            }

            var json = File.ReadAllText(metadataPath);
            var serializer = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };
            var meta = serializer.Deserialize<System.Collections.Generic.Dictionary<string, object>>(json);

            string pattern = MetadataHelpers.GetString(meta, "pattern", required: true);
            Console.WriteLine("Pattern: " + pattern);
            Console.WriteLine("Output:  " + outputPath);

            switch (pattern.ToLowerInvariant())
            {
                case "staging":
                    Patterns.StagingLoad.Build(meta, outputPath);
                    break;
                case "type1":
                case "type1dimension":
                case "type1-dim":
                case "dim-type1":
                    Patterns.Type1Dimension.Build(meta, outputPath);
                    break;
                case "type2":
                case "type2dimension":
                case "type2-dim":
                case "dim-type2":
                case "scd2":
                    Patterns.Type2Dimension.Build(meta, outputPath);
                    break;
                case "fact":
                case "factload":
                    Patterns.FactLoad.Build(meta, outputPath);
                    break;
                default:
                    Console.Error.WriteLine("ERROR: unknown pattern '" + pattern + "'.");
                    return 3;
            }

            Console.WriteLine("OK: " + outputPath);
            return 0;
        }

        private static int RunVerify(string[] args)
        {
            string packagePath = null;
            for (int i = 1; i < args.Length; i++)
            {
                switch (args[i])
                {
                    case "--package": packagePath = args[++i]; break;
                    default: return Usage();
                }
            }
            if (string.IsNullOrEmpty(packagePath))
            {
                return Usage();
            }
            if (!File.Exists(packagePath))
            {
                Console.Error.WriteLine("ERROR: package not found: " + packagePath);
                return 2;
            }

            var app = new Application();
            Package pkg = app.LoadPackage(packagePath, null);

            string temp = Path.Combine(Path.GetTempPath(),
                "ssis-roundtrip-" + Guid.NewGuid().ToString("N") + ".dtsx");
            try
            {
                app.SaveToXml(temp, pkg, null);
                // Sanity-check the resaved file parses as XML.
                var doc = new System.Xml.XmlDocument();
                doc.Load(temp);
            }
            finally
            {
                if (File.Exists(temp))
                {
                    try { File.Delete(temp); } catch { /* best-effort */ }
                }
            }

            Console.WriteLine("OK: Application.LoadPackage + SaveToXml round-trip succeeded.");
            return 0;
        }

        private static int Usage()
        {
            Console.Error.WriteLine("Usage:");
            Console.Error.WriteLine("  SsisOmHost.exe build  --metadata <file.json> --output <file.dtsx>");
            Console.Error.WriteLine("  SsisOmHost.exe verify --package  <file.dtsx>");
            return 64;
        }
    }
}
