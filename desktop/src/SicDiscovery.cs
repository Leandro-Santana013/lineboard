using System;
using System.Collections.Generic;
using System.Data.SqlClient;
using System.Diagnostics;
using System.Text.RegularExpressions;
using Microsoft.Win32;

namespace Lineboard {
 internal static class SicDiscovery {
  const string DefaultServer = @"(localdb)\MSSQLLocalDB";

  public static string ResolveServer(string configured, string database) {
   var preferred = String.IsNullOrWhiteSpace(configured) || String.Equals(configured.Trim(), "auto", StringComparison.OrdinalIgnoreCase)
    ? null : configured.Trim();
   if(preferred!=null && CanUse(preferred,database))return preferred;
   foreach(var candidate in Candidates(preferred))if(CanUse(candidate,database))return candidate;
   return preferred??DefaultServer;
  }

  static List<string> Candidates(string preferred) {
   var result=new List<string>();var seen=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
   Add(result,seen,preferred);
   Add(result,seen,DefaultServer);
   Add(result,seen,@"(localdb)\ProjectsV13");
   Add(result,seen,@"(localdb)\ProjectsV12");
   Add(result,seen,@"(localdb)\v11.0");
   Add(result,seen,@".\SQLEXPRESS");
   Add(result,seen,@"localhost\SQLEXPRESS");
   Add(result,seen,".");
   Add(result,seen,"localhost");
   AddRegistryInstances(result,seen);
   AddLocalDbInstances(result,seen);
   return result;
  }

  static void Add(List<string> result,HashSet<string> seen,string value) {
   if(String.IsNullOrWhiteSpace(value)||!seen.Add(value.Trim()))return;
   result.Add(value.Trim());
  }

  static void AddRegistryInstances(List<string> result,HashSet<string> seen) {
   foreach(var path in new[]{
    @"SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL",
    @"SOFTWARE\WOW6432Node\Microsoft\Microsoft SQL Server\Instance Names\SQL"}) {
    try {
     using(var key=Registry.LocalMachine.OpenSubKey(path)) {
      if(key==null)continue;
      foreach(var name in key.GetValueNames())Add(result,seen,String.Equals(name,"MSSQLSERVER",StringComparison.OrdinalIgnoreCase)?".":@".\"+name);
     }
    } catch { }
   }
  }

  static void AddLocalDbInstances(List<string> result,HashSet<string> seen) {
   foreach(var executable in new[]{"SqlLocalDB.exe","sqllocaldb.exe"}) {
    try {
     var start=new ProcessStartInfo {FileName=executable,Arguments="i",UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=false};
     using(var process=Process.Start(start)) {
      if(process==null)continue;
      var output=process.StandardOutput.ReadToEnd();process.WaitForExit(3000);
      foreach(var line in output.Split(new[]{'\r','\n'},StringSplitOptions.RemoveEmptyEntries)) {
       var name=line.Trim();
       if(Regex.IsMatch(name,@"^[A-Za-z0-9_.-]{1,128}$"))Add(result,seen,@"(localdb)\"+name);
      }
     }
     return;
    } catch { }
   }
  }

  static bool CanUse(string server,string database) {
   try {
    var builder=new SqlConnectionStringBuilder {DataSource=server,InitialCatalog=database,IntegratedSecurity=true,ConnectTimeout=2,ApplicationName="Lineboard SIC discovery"};
    using(var connection=new SqlConnection(builder.ConnectionString)) {
     connection.Open();
     using(var command=new SqlCommand("SELECT CASE WHEN OBJECT_ID(N'dbo.TABEST1',N'U') IS NOT NULL AND OBJECT_ID(N'dbo.TABEST3A',N'U') IS NOT NULL THEN 1 ELSE 0 END",connection)) {
      command.CommandTimeout=2;return Convert.ToInt32(command.ExecuteScalar())==1;
     }
    }
   } catch { return false; }
  }
 }
}
