using System;
using System.Collections.Generic;
using System.IO;

namespace Lineboard {
 internal static class Configuration {
  static readonly object gate=new object();
  static Dictionary<string,object> fileValues;

  // Environment variables remain supported for backwards compatibility. A
  // config file is the preferred distribution mechanism because an installed
  // desktop should not require a PowerShell session or a user profile setup.
  public static string Get(string name) {
   var value=Environment.GetEnvironmentVariable(name);
   if(!String.IsNullOrWhiteSpace(value))return value;
   value=Environment.GetEnvironmentVariable(name,EnvironmentVariableTarget.User);
   if(!String.IsNullOrWhiteSpace(value))return value;
   value=Environment.GetEnvironmentVariable(name,EnvironmentVariableTarget.Machine);
   if(!String.IsNullOrWhiteSpace(value))return value;
   EnsureLoaded();
   object configured;
   if(fileValues!=null&&fileValues.TryGetValue(name,out configured)&&configured!=null) {
    value=Convert.ToString(configured);
    if(!String.IsNullOrWhiteSpace(value))return value.Trim();
   }
   return null;
  }

  static void EnsureLoaded() {
   if(fileValues!=null)return;
   lock(gate) {
    if(fileValues!=null)return;
    fileValues=new Dictionary<string,object>(StringComparer.OrdinalIgnoreCase);
    foreach(var path in CandidatePaths()) {
     if(!File.Exists(path))continue;
     try {
      var parsed=Json.Read<Dictionary<string,object>>(File.ReadAllText(path));
      if(parsed==null)continue;
      foreach(var entry in parsed)if(entry.Value!=null)fileValues[entry.Key]=entry.Value;
     } catch(Exception error) {
      // An invalid optional config must not prevent the desktop from opening
      // when a valid legacy environment configuration is available.
      System.Diagnostics.Trace.WriteLine("Lineboard config ignored: "+error.Message);
     }
    }
   }
  }

  static IEnumerable<string> CandidatePaths() {
   yield return Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"config.json");
   var common=Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
   if(!String.IsNullOrWhiteSpace(common))yield return Path.Combine(common,"Lineboard","config.json");
   var local=Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
   if(!String.IsNullOrWhiteSpace(local))yield return Path.Combine(local,"Lineboard","config.json");
  }
 }
}
