using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace Lineboard {
 // A single native window around the local React application.  No local HTTP
 // endpoint is exposed to the page: the only application API is DesktopBridge.
 public sealed class WebDesktopForm : Form {
  readonly SicStore store;
  readonly LocalApi api;
  readonly string workspace;
  readonly string uiRoot;
  readonly string previewPath;
  readonly bool preview;
  readonly bool webSelfTest;
  readonly bool webCapture;
  readonly bool largeCapture;
  readonly CloudSync sync;
  readonly BackgroundSync backgroundSync;
  readonly RealtimeBridge realtime;
  readonly WebView2 webView=new WebView2 {Dock=DockStyle.Fill,Margin=Padding.Empty};
  readonly SemaphoreSlim bridgeGate=new SemaphoreSlim(1,1);
  readonly SemaphoreSlim photoGate=new SemaphoreSlim(3,3);
  readonly SemaphoreSlim exportGate=new SemaphoreSlim(1,1);
  DesktopBridge bridge;
  bool initialized;
  public bool PreviewSucceeded { get; private set; }
  public bool SelfTestSucceeded { get; private set; }
  public string SelfTestResult { get; private set; }
  public string PreviewError { get; private set; }
  public WebView2 Browser { get { return webView; } }

  public WebDesktopForm(SicStore store,LocalApi api,string workspace,bool preview=false,string previewPath=null,bool webSelfTest=false,bool webCapture=false,bool largeCapture=false,RealtimeBridge realtime=null) {
   if(store==null||api==null)throw new ArgumentNullException();
   this.store=store;this.api=api;this.realtime=realtime;this.workspace=Path.GetFullPath(workspace);this.preview=preview;this.previewPath=previewPath;this.webSelfTest=webSelfTest;this.webCapture=webCapture;this.largeCapture=largeCapture;
   uiRoot=Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"ui");
   if(!Directory.Exists(uiRoot)||!File.Exists(Path.Combine(uiRoot,"index.html")))throw new DomainError("UI_ASSETS_MISSING");
   sync=new CloudSync(store);backgroundSync=new BackgroundSync(store,sync);
   if(this.realtime!=null)this.realtime.SharedCartChanged+=backgroundSync.Request;
   backgroundSync.Completed+=OnBackgroundSyncCompleted;
   Text="Linesboard • Loja e estoque";Icon=System.Drawing.Icon.ExtractAssociatedIcon(Application.ExecutablePath);StartPosition=FormStartPosition.CenterScreen;ClientSize=new Size(1224,794);MinimumSize=new Size(1180,740);if(largeCapture)ClientSize=new Size(1400,960);
   if(preview){ShowInTaskbar=false;WindowState=FormWindowState.Normal;}
   Controls.Add(webView);
   Shown+=OnShown;FormClosed+=OnClosed;
  }

  async void OnShown(object sender,EventArgs args) {
   try {
    await InitializeAsync();
    if(preview) {
     await WaitForPreviewReadyAsync();
     await CapturePreviewAsync(previewPath);
     PreviewSucceeded=true;Close();
    } else if(webSelfTest) {
     await WaitForPreviewReadyAsync();
     SelfTestResult=await RunWebSelfTestAsync(previewPath);
     SelfTestSucceeded=true;Close();
    } else if(webCapture) {
     await WaitForPreviewReadyAsync();
     SelfTestResult=await RunWebCaptureAsync(previewPath);
     SelfTestSucceeded=true;Close();
    } else backgroundSync.Start();
   } catch(Exception error) {
    PreviewError=error.Message;
    if(preview||webSelfTest||webCapture) { Close();return; }
    MessageBox.Show(this,"Não foi possível carregar a interface local.\n\n"+error.Message+"\n\nConfira a dependência WebView2 e os arquivos em desktop/bin/ui.","Lineboard",MessageBoxButtons.OK,MessageBoxIcon.Error);
    Close();
   }
  }

  async Task InitializeAsync() {
   if(initialized)return;
   var userData=Path.Combine(workspace,".local","webview2-user-data");Directory.CreateDirectory(userData);
   var environment=await CoreWebView2Environment.CreateAsync(null,userData,null);
   await webView.EnsureCoreWebView2Async(environment);
   var core=webView.CoreWebView2;
   Configure(core);
   core.SetVirtualHostNameToFolderMapping("lineboard.local",uiRoot,CoreWebView2HostResourceAccessKind.DenyCors);
   bridge=new DesktopBridge(store,api,sync,backgroundSync,SaveLabels,realtime);
   core.WebMessageReceived+=OnWebMessageReceived;
   initialized=true;
   await NavigateAndWaitAsync(new Uri(DesktopBridge.Origin+"index.html"));
  }

  void Configure(CoreWebView2 core) {
   var settings=core.Settings;
   settings.AreDefaultContextMenusEnabled=false;settings.AreDefaultScriptDialogsEnabled=false;settings.AreDevToolsEnabled=false;
   settings.AreHostObjectsAllowed=false;settings.IsBuiltInErrorPageEnabled=false;settings.IsGeneralAutofillEnabled=false;
   settings.IsPasswordAutosaveEnabled=false;settings.IsStatusBarEnabled=false;settings.IsWebMessageEnabled=true;
   settings.IsZoomControlEnabled=false;settings.AreBrowserAcceleratorKeysEnabled=false;
   core.NavigationStarting+=OnNavigationStarting;core.FrameNavigationStarting+=OnFrameNavigationStarting;
   core.NewWindowRequested+=OnNewWindowRequested;core.PermissionRequested+=OnPermissionRequested;
   core.DownloadStarting+=OnDownloadStarting;
  }

  static bool IsTrustedUri(string value) {
   Uri uri;if(!Uri.TryCreate(value,UriKind.Absolute,out uri))return false;
   return uri.Scheme==Uri.UriSchemeHttps&&String.Equals(uri.Host,"lineboard.local",StringComparison.OrdinalIgnoreCase)&&
    (uri.Port==-1||uri.Port==443)&&String.IsNullOrEmpty(uri.UserInfo);
  }
  static void OnNavigationStarting(object sender,CoreWebView2NavigationStartingEventArgs args) { if(!IsTrustedUri(args.Uri))args.Cancel=true; }
  static void OnFrameNavigationStarting(object sender,CoreWebView2NavigationStartingEventArgs args) {
   // Label previews may use an about:srcdoc iframe owned by the trusted page.
   // The same URI is never accepted by the top-level navigation handler.
   if(String.Equals(args.Uri,"about:blank",StringComparison.OrdinalIgnoreCase)||String.Equals(args.Uri,"about:srcdoc",StringComparison.OrdinalIgnoreCase))return;
   if(!IsTrustedUri(args.Uri))args.Cancel=true;
  }
  static void OnNewWindowRequested(object sender,CoreWebView2NewWindowRequestedEventArgs args) { args.Handled=true; }
  static void OnPermissionRequested(object sender,CoreWebView2PermissionRequestedEventArgs args) { args.State=CoreWebView2PermissionState.Deny;args.Handled=true; }
  static void OnDownloadStarting(object sender,CoreWebView2DownloadStartingEventArgs args) { args.Cancel=true;args.Handled=true; }

  async Task NavigateAndWaitAsync(Uri target) {
   var core=webView.CoreWebView2;var completed=new TaskCompletionSource<bool>();
   EventHandler<CoreWebView2NavigationCompletedEventArgs> handler=null;
   handler=(sender,args)=>{core.NavigationCompleted-=handler;completed.TrySetResult(args.IsSuccess);};core.NavigationCompleted+=handler;
   core.Navigate(target.ToString());
   var winner=await Task.WhenAny(completed.Task,Task.Delay(15000));
   if(winner!=completed.Task)throw new DomainError("UI_NAVIGATION_TIMEOUT");
   if(!await completed.Task)throw new DomainError("UI_NAVIGATION_FAILED");
  }

  async Task WaitForPreviewReadyAsync() {
   for(var attempt=0;attempt<75;attempt++) {
    if(bridge!=null&&bridge.BootstrapServed) {
     var result=await webView.CoreWebView2.ExecuteScriptAsync("(function(){var logo=document.querySelector('.brand-logo');return document.readyState==='complete' && !!document.querySelector('.inventory-card') && !!logo && logo.complete && logo.naturalWidth>0;})()");
     if(String.Equals(result,"true",StringComparison.OrdinalIgnoreCase))return;
    }
    await Task.Delay(200);
   }
   throw new DomainError("UI_NOT_READY");
  }

  async Task<string> ExecuteScriptAsync(string script) { return await webView.CoreWebView2.ExecuteScriptAsync(script); }
  async Task<bool> WaitForDomTextAsync(string text) {
   var needle=Json.Write(text);
   for(var attempt=0;attempt<75;attempt++) {
    var result=await ExecuteScriptAsync("(function(){return !!(document.body && (document.body.innerText||'').indexOf("+needle+")>=0);})()");
    if(String.Equals(result,"true",StringComparison.OrdinalIgnoreCase))return true;
    await Task.Delay(200);
   }
   return false;
  }
  async Task<bool> ClickTextAsync(string text) {
   var needle=Json.Write(text);
   var result=await ExecuteScriptAsync("(function(){var n=Array.prototype.slice.call(document.querySelectorAll('button,a,[role=button]')).find(function(x){return (x.innerText||x.textContent||'').indexOf("+needle+")>=0;});if(!n)return false;n.click();return true;})()");
   return String.Equals(result,"true",StringComparison.OrdinalIgnoreCase);
  }
  async Task<bool> FillProductDraftAsync() {
   var result=await ExecuteScriptAsync("(function(){function setValue(input,value){if(!input)return false;var setter=Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,'value').set;setter.call(input,value);input.dispatchEvent(new Event('input',{bubbles:true}));input.dispatchEvent(new Event('change',{bubbles:true}));return true;}function byLabel(needle){var label=Array.prototype.slice.call(document.querySelectorAll('label')).find(function(x){return (x.innerText||x.textContent||'').indexOf(needle)>=0;});if(!label)return null;return document.getElementById(label.htmlFor)||label.parentElement.querySelector('input,textarea');}function byAria(prefix,index){return Array.prototype.slice.call(document.querySelectorAll('input[aria-label^=\"'+prefix+'\"]'))[index]||null;}var values=[['Nome do produto','Produto ponte UI'],['Marca','Laboratorio'],['interno','WEBUI'],['custo','10'],['venda','25']];for(var i=0;i<values.length;i++)if(!setValue(byLabel(values[i][0]),values[i][1]))return false;var colors=['Preta','Azul','Areia'],sizes=['P','M','G'],quantities=['1','2','1'];for(var row=0;row<3;row++){if(!setValue(byAria('Cor da varia',row),colors[row])||!setValue(byAria('Tamanho da varia',row),sizes[row])||!setValue(byAria('Quantidade da varia',row),quantities[row]))return false;}return true;})() ");
   return String.Equals(result,"true",StringComparison.OrdinalIgnoreCase);
  }
  async Task<Dictionary<string,object>> PostAndWaitAsync(string id,string action,object payload) {
   var request=Json.Write(new {id,action,payload});var idLiteral=Json.Write(id);
   await ExecuteScriptAsync("(function(){window.__lineboardHostResponses=[];window.chrome.webview.addEventListener('message',function(e){window.__lineboardHostResponses.push(e.data);});window.chrome.webview.postMessage("+request+");})()");
   for(var attempt=0;attempt<75;attempt++) {
    var raw=await ExecuteScriptAsync("JSON.stringify((window.__lineboardHostResponses||[]).find(function(x){return x&&x.id==="+idLiteral+";})||null)");
    if(!String.Equals(raw,"null",StringComparison.OrdinalIgnoreCase)) {
     var serialized=Json.Read<string>(raw);if(serialized!="null")return Json.Read<Dictionary<string,object>>(serialized);
    }
    await Task.Delay(200);
   }
   throw new DomainError("WEBVIEW_MESSAGE_TIMEOUT");
  }
  static Dictionary<string,object> RequireOk(Dictionary<string,object> response) {
   if(response==null||!response.ContainsKey("ok")||!Convert.ToBoolean(response["ok"]))throw new DomainError("WEBVIEW_BRIDGE_FAILED");
   return (Dictionary<string,object>)response["data"];
  }
  async Task<string> CaptureProductAndStockAsync(string capturePath) {
   var captureFullPath=Path.GetFullPath(capturePath);var captureDirectory=Path.GetDirectoryName(captureFullPath);var captureName=Path.GetFileNameWithoutExtension(captureFullPath);
   string productCapturePath=Path.Combine(captureDirectory,captureName+"-product.png");
   var pages=new[]{"Novo produto","Histórico","Loja e estoque"};
   var markers=new[]{"Cores, tamanhos e quantidades","Operações registradas no histórico.","Suas peças e o caixa em um só lugar."};
   for(var index=0;index<pages.Length;index++) {
    if(!await ClickTextAsync(pages[index])||!await WaitForDomTextAsync(markers[index]))throw new DomainError("WEBVIEW_NAVIGATION_FAILED");
    if(index==0) {
     if(!await ClickTextAsync("Adicionar variação"))throw new DomainError("WEBVIEW_PRODUCT_FORM_FAILED");
     await Task.Delay(150);
     if(!await ClickTextAsync("Adicionar variação"))throw new DomainError("WEBVIEW_PRODUCT_FORM_FAILED");
     await Task.Delay(250);
     if(!await FillProductDraftAsync()||!await WaitForDomTextAsync("4 peças no total"))throw new DomainError("WEBVIEW_PRODUCT_DRAFT_FAILED");
     await ExecuteScriptAsync("(function(){if(document.activeElement)document.activeElement.blur();var target=document.querySelector('h1')||document.body;['pointerdown','mousedown','mouseup','click'].forEach(function(type){target.dispatchEvent(new MouseEvent(type,{bubbles:true,view:window}));});return true;})()");
     await Task.Delay(250);
     await CapturePreviewAsync(productCapturePath);
    }
    if(Application.OpenForms.Count!=1)throw new DomainError("WEBVIEW_OPEN_FORMS_FAILED");
   }
   await CapturePreviewAsync(capturePath);
   return productCapturePath;
  }
  async Task<string> RunWebSelfTestAsync(string capturePath) {
   if(String.IsNullOrWhiteSpace(capturePath))capturePath=Path.Combine(workspace,".local","desktop-web-self-test.png");
   var bootstrap=RequireOk(await PostAndWaitAsync("web-self-bootstrap","bootstrap",new{}));
   if(Json.Read<List<Dictionary<string,object>>>(Json.Write(bootstrap["catalog"])).Count!=0)throw new DomainError("WEBVIEW_FIXTURE_NOT_EMPTY");
   var draft=new ProductDraft{request_id=Guid.NewGuid().ToString(),name="Produto ponte WebView",brand="Laboratorio",cost=10,price=25,location="A1",notes="Fixture real do WebView2",internal_code="WEBVIEW",variants=new List<VariantDraft>{
    new VariantDraft{color="Preta",size="P",quantity=1},new VariantDraft{color="Azul",size="M",quantity=2},new VariantDraft{color="Areia",size="G",quantity=1}}};
   var created=RequireOk(await PostAndWaitAsync("web-self-create","product.create",draft));
   var units=Json.Read<List<Dictionary<string,object>>>(Json.Write(created["units"]));if(units.Count!=4)throw new DomainError("WEBVIEW_CREATE_FAILED");
   var refreshed=RequireOk(await PostAndWaitAsync("web-self-refresh","bootstrap",new{}));if(Json.Read<List<Dictionary<string,object>>>(Json.Write(refreshed["catalog"])).Count!=4)throw new DomainError("WEBVIEW_REFRESH_FAILED");
   if(!await WaitForDomTextAsync("Produto ponte WebView"))throw new DomainError("WEBVIEW_UI_NOT_UPDATED");
   var unknown=RequireError(await PostAndWaitAsync("web-self-unknown","bridge.unknown",new{}));if(Convert.ToString(unknown["code"])!="UNKNOWN_ACTION")throw new DomainError("WEBVIEW_ERROR_CONTRACT_FAILED");
   var productCapturePath=await CaptureProductAndStockAsync(capturePath);
   var salesReport=RequireOk(await PostAndWaitAsync("web-self-sales","sales.report",new{from="2026-01-01T00:00:00.0000000Z",to="2027-01-01T00:00:00.0000000Z",brand="",category="",payment="",query=""}));
   if(!await ClickTextAsync("Vendas e saídas")||!await WaitForDomTextAsync("Faturamento"))throw new DomainError("WEBVIEW_SALES_REPORT_FAILED");
   return Json.Write(new {passed=11,checks=new[]{"real WebMessageReceived bootstrap","real product.create through WebView2","real catalog refresh without reload","React UI updated after bridge response","unknown action error response","Novo produto draft filled in the real UI","CapturePreviewAsync produced product PNG","internal navigation keeps one Form","CapturePreviewAsync produced stock PNG","sales.report returned through WebView2","Vendas e saídas opened inside the same window"},preview=Path.GetFullPath(capturePath),product_preview=Path.GetFullPath(productCapturePath),units=units.Count,sales=Convert.ToInt32(((Dictionary<string,object>)salesReport["summary"])["sales"]),open_forms=Application.OpenForms.Count});
  }
  async Task<string> RunWebCaptureAsync(string capturePath) {
   if(String.IsNullOrWhiteSpace(capturePath))capturePath=Path.Combine(workspace,".local","desktop-web-capture.png");
   var bootstrap=RequireOk(await PostAndWaitAsync("web-capture-bootstrap","bootstrap",new{}));
   var units=Json.Read<List<Dictionary<string,object>>>(Json.Write(bootstrap["catalog"]));
   if(units.Count==0)throw new DomainError("WEBVIEW_CAPTURE_FIXTURE_EMPTY");
   var productCapturePath=await CaptureProductAndStockAsync(capturePath);
   return Json.Write(new {passed=4,checks=new[]{"existing sandbox catalog loaded through WebView2","Novo produto draft filled in the real UI","CapturePreviewAsync produced product PNG","internal navigation keeps one Form and produced stock PNG"},preview=Path.GetFullPath(capturePath),product_preview=Path.GetFullPath(productCapturePath),units=units.Count,open_forms=Application.OpenForms.Count});
  }
  static Dictionary<string,object> RequireError(Dictionary<string,object> response) {
   if(response==null||!response.ContainsKey("ok")||Convert.ToBoolean(response["ok"])||!response.ContainsKey("error"))throw new DomainError("WEBVIEW_ERROR_CONTRACT_FAILED");
   return (Dictionary<string,object>)response["error"];
  }

  static string BridgeAction(string message) {
   try {
    var envelope=Json.Read<Dictionary<string,object>>(message);object action;
    return envelope!=null&&envelope.TryGetValue("action",out action)?action as string:null;
   } catch { return null; }
  }
  async void OnWebMessageReceived(object sender,CoreWebView2WebMessageReceivedEventArgs args) {
   if(bridge==null||webView.CoreWebView2==null)return;
   var source=args.Source;var message=args.WebMessageAsJson;var action=BridgeAction(message);string response;
   if(action=="labels.export") {
    // SaveFileDialog must stay on the WinForms STA, but it must not hold the
    // SQL gate while its modal loop lets bootstrap polling continue.
    await exportGate.WaitAsync();
    try { response=bridge.Process(source,message); }
    finally { exportGate.Release(); }
   } else if(action=="photo.url"||action=="photo.upload") {
    // Optional network images must not queue stock/sale operations behind them.
    await photoGate.WaitAsync();
    try { response=await Task.Run(()=>bridge.Process(source,message)); }
    finally { photoGate.Release(); }
   } else {
    await bridgeGate.WaitAsync();
    try { response=await Task.Run(()=>bridge.Process(source,message)); }
    finally { bridgeGate.Release(); }
   }
   if(IsDisposed||Disposing||webView.CoreWebView2==null)return;
   webView.CoreWebView2.PostWebMessageAsJson(response);
  }

  bool SaveLabels(string html) {
   using(var dialog=new SaveFileDialog {Filter="Etiquetas imprimíveis (*.html)|*.html",FileName="etiquetas-lineboard.html",Title="Exportar etiquetas"}) {
    if(dialog.ShowDialog(this)!=DialogResult.OK)return false;
    File.WriteAllText(dialog.FileName,html,System.Text.Encoding.UTF8);return true;
   }
  }

  public async Task CapturePreviewAsync(string path) {
   if(!initialized||webView.CoreWebView2==null)throw new DomainError("WEBVIEW_NOT_READY");
   if(String.IsNullOrWhiteSpace(path))throw new DomainError("MISSING_ARGUMENT");
   var full=Path.GetFullPath(path);var parent=Path.GetDirectoryName(full);if(!String.IsNullOrEmpty(parent))Directory.CreateDirectory(parent);
   using(var stream=new FileStream(full,FileMode.Create,FileAccess.Write,FileShare.Read))
    await webView.CoreWebView2.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png,stream);
  }

  void OnBackgroundSyncCompleted() {
   if(IsDisposed||Disposing)return;
   try {
    if(InvokeRequired) { BeginInvoke(new Action(OnBackgroundSyncCompleted)); return; }
    if(webView.CoreWebView2!=null)webView.CoreWebView2.PostWebMessageAsJson("{\"type\":\"lineboard_sync_completed\"}");
   } catch(InvalidOperationException) {}
  }

  void OnClosed(object sender,FormClosedEventArgs args) { if(realtime!=null)realtime.SharedCartChanged-=backgroundSync.Request;backgroundSync.Completed-=OnBackgroundSyncCompleted;backgroundSync.Dispose();api.Dispose(); }
 }
}
