using System;
using System.IO;
using Lineboard;

static class CartVersionMonitorTests {
 static void Equal(int actual,int expected){if(actual!=expected)throw new Exception("Expected "+expected+", got "+actual);}
 static int Main(){
  var version="store:0";var changes=0;var offline=false;var notifyFailed=false;
  var monitor=new CartVersionMonitor(()=>{if(offline)throw new IOException("Offline");return version;},()=>{if(notifyFailed)throw new Exception("Not ready");changes++;});
  monitor.Check();Equal(changes,1);
  monitor.Check();Equal(changes,1);
  version="store:1";monitor.Check();Equal(changes,2);
  offline=true;version="store:3";
  try{monitor.Check();throw new Exception("Offline accepted");}catch(IOException){}
  Equal(changes,2);offline=false;monitor.Check();Equal(changes,3);
  monitor.Check();Equal(changes,3);
  version="store:4";notifyFailed=true;
  try{monitor.Check();}catch(Exception){}
  Equal(changes,3);notifyFailed=false;monitor.Check();Equal(changes,4);
  version="store:5";monitor.Check();Equal(changes,5);
  version=null;
  try{monitor.Check();throw new Exception("Empty version accepted");}catch(InvalidDataException){}
  version="other-store:5";monitor.Check();Equal(changes,6);
  Console.WriteLine("PASS: initial refresh, scan/removal updates, unchanged versions, offline recovery, notification retry and invalid responses.");
  return 0;
 }
}
