using System;
using System.IO;
using System.Security;
using System.Text;

namespace Lineboard {
 internal static class ConfigurationFile {
  public static void Save(string content,string commonPath,string localPath){
   // The user file has priority when loading. Once a user has one, keep
   // updating it so an older local file cannot hide a fresh machine config.
   if(!String.IsNullOrEmpty(localPath)&&File.Exists(localPath)){Write(localPath,content);return;}
   try{Write(commonPath,content);}
   catch(UnauthorizedAccessException){Fallback(content,commonPath,localPath);}
   catch(SecurityException){Fallback(content,commonPath,localPath);}
   catch(IOException){Fallback(content,commonPath,localPath);}
  }
  static void Fallback(string content,string commonPath,string localPath){
   if(String.IsNullOrEmpty(localPath)||String.Equals(commonPath,localPath,StringComparison.OrdinalIgnoreCase))throw new IOException("CONFIGURATION_NOT_WRITABLE");
   Write(localPath,content);
  }
  static void Write(string path,string content){
   var parent=Path.GetDirectoryName(path);Directory.CreateDirectory(parent);
   var temporary=Path.Combine(parent,".config-"+Guid.NewGuid().ToString("N")+".tmp");
   try{
    File.WriteAllText(temporary,content,new UTF8Encoding(false));
    if(File.Exists(path))File.Replace(temporary,path,null);
    else File.Move(temporary,path);
   }finally{try{if(File.Exists(temporary))File.Delete(temporary);}catch{}}
  }
 }
}
