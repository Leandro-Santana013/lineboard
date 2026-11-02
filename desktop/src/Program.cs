using System;
using System.Collections.Generic;
using System.Data.SqlClient;
using System.IO;
using System.Threading;
using System.Windows.Forms;

namespace Lineboard {
 static class Program {
  [STAThread] static int Main(string[] args){
   try{
     string workspace=Option(args,"--workspace",Path.GetFullPath(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"..","..")));
      string server=Option(args,"--server",ConfiguredServer());
     bool explicitDatabase=Array.IndexOf(args,"--database")>=0;
     string database=Option(args,"--database",explicitDatabase?"LINEBOARD_LAB":"SICNET");
    if(Array.IndexOf(args,"--probe")>=0){Emit(args,Json.Write(Probe(server)));return 0;}
    var explicitProduction=Array.IndexOf(args,"--production")>=0;
    var production=explicitProduction||!explicitDatabase;
    if(explicitProduction&&Array.IndexOf(args,"--confirm-production")<0)throw new DomainError("PRODUCTION_CONFIRM_REQUIRED");
    var store=new SicStore(server,database,workspace,production);
    if(Array.IndexOf(args,"--sync-now")>=0){try{var sync=new CloudSync(store);Emit(args,Json.Write(sync.Reconcile()));return 0;}catch(Exception error){ErrorFile(args,error.Message);throw;}}
    if(Array.IndexOf(args,"--self-test")>=0){Emit(args,Json.Write(SelfTests.Run(store,server,workspace)));return 0;}
    if(Array.IndexOf(args,"--health")>=0){Emit(args,Json.Write(store.Health()));return 0;}
    if(Array.IndexOf(args,"--export-outbox")>=0){Emit(args,Json.Write(store.Outbox()));return 0;}
    if(Array.IndexOf(args,"--render-legacy-preview")>=0){Application.EnableVisualStyles();using(var previewApi=new LocalApi(store,"localhost",47831))using(var preview=new DesktopForm(store,previewApi)){preview.RenderPreview(Option(args,"--output",Path.Combine(workspace,".local","desktop-preview.png")));}return 0;}
    var legacyUi=Array.IndexOf(args,"--legacy-ui")>=0;
    var webSelfTest=Array.IndexOf(args,"--web-self-test")>=0;
    var webPreview=Array.IndexOf(args,"--render-web-preview")>=0||Array.IndexOf(args,"--render-preview")>=0;
    var webCaptureLarge=Array.IndexOf(args,"--web-capture-large")>=0;
    var webCapture=Array.IndexOf(args,"--web-capture")>=0||webCaptureLarge;
    if((webSelfTest&&webPreview)||(webSelfTest&&webCapture)||(webPreview&&webCapture))throw new DomainError("CONFLICTING_MODE");
    var serve=Array.IndexOf(args,"--serve")>=0;
    if(webPreview&&!HasWebUi())throw new DomainError("UI_ASSETS_MISSING");
    if(!webPreview&&!webSelfTest&&!webCapture&&!legacyUi&&!serve&&!HasWebUi())throw new DomainError("UI_ASSETS_MISSING");
    var api=new LocalApi(store,Option(args,"--host","localhost"),Int32.Parse(Option(args,"--port","47831")));
    using(var realtime=new RealtimeBridge(store)) {
     realtime.Start();
    if(webPreview||webSelfTest||webCapture){
     Application.EnableVisualStyles();Application.SetCompatibleTextRenderingDefault(false);
     var outputName=webCaptureLarge?"desktop-web-capture-large.png":(webSelfTest?"desktop-web-self-test.png":(webCapture?"desktop-web-capture.png":"desktop-web-preview.png"));
     var preview=new WebDesktopForm(store,api,workspace,webPreview,Option(args,"--output",Path.Combine(workspace,".local",outputName)),webSelfTest,webCapture,webCaptureLarge,realtime);
    using(preview){Application.Run(preview);if(webSelfTest||webCapture)Emit(args,preview.SelfTestResult??Json.Write(new{ok=false,error=preview.PreviewError??"WEBVIEW_CAPTURE_FAILED"}));return (webSelfTest||webCapture)?(preview.SelfTestSucceeded?0:1):(preview.PreviewSucceeded?0:1);}
    }
    api.Start();
    if(serve){Emit(args,Json.Write(new{address=api.Address,mode=production?"production":"sandbox",database}));new ManualResetEvent(false).WaitOne();return 0;}
    Application.EnableVisualStyles();Application.SetCompatibleTextRenderingDefault(false);
    if(legacyUi){using(var form=new DesktopForm(store,api)){Application.Run(form);}}
    else {using(var form=new WebDesktopForm(store,api,workspace,false,null,false,false,false,realtime)){Application.Run(form);}}
    return 0;
    }
   }catch(Exception error){Console.Error.WriteLine(error.Message);bool command=Array.Exists(args,a=>a=="--serve"||a=="--self-test"||a=="--health"||a=="--probe"||a=="--export-outbox"||a=="--render-preview"||a=="--render-web-preview"||a=="--render-legacy-preview"||a=="--web-self-test"||a=="--web-capture"||a=="--web-capture-large"||a=="--production"||a=="--confirm-production");if(!command)MessageBox.Show("Não foi possível iniciar o Lineboard.\n\n"+error.Message+"\n\nConfira a base isolada e a permissão da API local. Consulte desktop/README.md. Para usar apenas neste computador, inicie com --host localhost.","Lineboard",MessageBoxButtons.OK,MessageBoxIcon.Error);return 1;}
  }
   static string ConfiguredServer(){
    var server=Environment.GetEnvironmentVariable("LINEBOARD_SIC_SERVER");
    return String.IsNullOrWhiteSpace(server)?@"(localdb)\MSSQLLocalDB":server.Trim();
   }
   internal static bool HasWebUi(){return File.Exists(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"ui","index.html"));}
  static string Option(string[] args,string name,string fallback){int index=Array.IndexOf(args,name);if(index<0)return fallback;if(index+1==args.Length||args[index+1].StartsWith("--"))throw new DomainError("MISSING_ARGUMENT");return args[index+1];}
  static void Emit(string[] args,string value){Console.WriteLine(value);var path=Option(args,"--result-file",null);if(String.IsNullOrWhiteSpace(path))return;var full=Path.GetFullPath(path);var parent=Path.GetDirectoryName(full);if(!String.IsNullOrEmpty(parent))Directory.CreateDirectory(parent);File.WriteAllText(full,value,new System.Text.UTF8Encoding(false));}
  static void ErrorFile(string[] args,string message){var path=Option(args,"--result-file",null);if(String.IsNullOrWhiteSpace(path))return;var full=Path.GetFullPath(path);var parent=Path.GetDirectoryName(full);if(!String.IsNullOrEmpty(parent))Directory.CreateDirectory(parent);File.WriteAllText(full,Json.Write(new{ok=false,error=message}),new System.Text.UTF8Encoding(false));}
  public static object Probe(string server){
   var builder=new SqlConnectionStringBuilder{DataSource=server,InitialCatalog="SICNET",IntegratedSecurity=true,ConnectTimeout=5,ApplicationName="Lineboard Readonly Probe"};
   using(var c=new SqlConnection(builder.ConnectionString)){c.Open();return new{
    database="SICNET",mode="read_only_probe",
    products=SicStore.Scalar(c,null,"SELECT COUNT(*) FROM dbo.TABEST1"),
    sale_headers=SicStore.Scalar(c,null,"SELECT COUNT(*) FROM dbo.TABEST3A"),
    sale_lines=SicStore.Scalar(c,null,"SELECT COUNT(*) FROM dbo.TABEST3B"),
    files=SicStore.Rows(c,null,"SELECT type_desc,physical_name FROM sys.database_files"),
    custom_schema_exists=SicStore.Scalar(c,null,"SELECT SCHEMA_ID('lineboard')")!=null,
    fiscal_automation="not_validated"
   };}
  }
 }
}
