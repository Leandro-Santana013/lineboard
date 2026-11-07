using System;
using System.IO;
using Lineboard;

static class ConfigurationFileTests {
 static void Check(bool condition,string name){if(!condition)throw new Exception(name);}
 static int Main(){
  var root=Path.Combine(Path.GetTempPath(),"lineboard-config-test-"+Guid.NewGuid().ToString("N"));
  var common=Path.Combine(root,"machine","config.json");var local=Path.Combine(root,"user","config.json");
  try{
   ConfigurationFile.Save("initial",common,local);
   Check(File.ReadAllText(common)=="initial"&&!File.Exists(local),"Initial machine config");
   File.SetAttributes(common,FileAttributes.ReadOnly);
   bool previousFailed=false;
   try{File.WriteAllText(common,"old activation behavior");}catch(UnauthorizedAccessException){previousFailed=true;}
   Check(previousFailed,"Reproduce activation failure with a protected machine config");
   ConfigurationFile.Save("activated",common,local);
   Check(File.ReadAllText(local)=="activated"&&File.ReadAllText(common)=="initial","User fallback preserves machine config");
   File.SetAttributes(common,FileAttributes.Normal);
   ConfigurationFile.Save("renewed",common,local);
   Check(File.ReadAllText(local)=="renewed"&&File.ReadAllText(common)=="initial","Existing user config keeps load priority");
   File.Delete(local);ConfigurationFile.Save("machine renewal",common,local);
   Check(File.ReadAllText(common)=="machine renewal","Atomic replacement of machine config");
   var blocked=Path.Combine(root,"blocked");File.WriteAllText(blocked,"directory blocker");
   bool rejected=false;
   try{ConfigurationFile.Save("must fail",Path.Combine(blocked,"common.json"),Path.Combine(blocked,"local.json"));}catch(IOException){rejected=true;}
   Check(rejected,"Both targets unavailable must report a failure");
   Check(Directory.GetFiles(root,"*.tmp",SearchOption.AllDirectories).Length==0,"No temporary credential files left");
   Console.WriteLine("PASS: protected machine config reproduces the activation error; user fallback, renewal, atomic writes and cleanup work.");
   return 0;
  }finally{
   if(File.Exists(common))File.SetAttributes(common,FileAttributes.Normal);
   if(Directory.Exists(root))Directory.Delete(root,true);
  }
 }
}
