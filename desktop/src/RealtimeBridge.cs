using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Lineboard {
 // Supabase Realtime is an optional cloud-to-desktop lane. The key is read
 // only from the Windows environment; it is never sent to the React surface.
 public sealed class RealtimeBridge : IDisposable {
  readonly SicStore store;
  readonly string socketAddress;
  readonly string restAddress;
  readonly string realtimeKey;
  readonly string instanceId;
  readonly string ackAddress;
  readonly string integrationToken;
  readonly CancellationTokenSource stop=new CancellationTokenSource();
  readonly object lifecycle=new object();
  readonly object commandGate=new object();
  readonly HashSet<string> activeCommands=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
  Task worker;
  public string State { get; private set; }
  public bool Configured { get; private set; }

  public RealtimeBridge(SicStore store) {
   if(store==null)throw new ArgumentNullException("store");
   this.store=store;instanceId=store.InstanceId;
   socketAddress=Environment.GetEnvironmentVariable("LINEBOARD_REALTIME_URL");
   realtimeKey=Environment.GetEnvironmentVariable("LINEBOARD_REALTIME_KEY");
   integrationToken=Environment.GetEnvironmentVariable("LINEBOARD_SYNC_TOKEN");
   var supabase=Environment.GetEnvironmentVariable("SUPABASE_URL");
   Uri supabaseUri;
   restAddress=Uri.TryCreate(supabase,UriKind.Absolute,out supabaseUri)&&supabaseUri.Scheme=="https"?new Uri(supabaseUri,"rest/v1/sic_commands").ToString():null;
   var ack=Environment.GetEnvironmentVariable("LINEBOARD_REALTIME_ACK_URL");
   if(String.IsNullOrWhiteSpace(ack)) {
    Uri baseUri;
    if(Uri.TryCreate(supabase,UriKind.Absolute,out baseUri))ack=new Uri(baseUri,"functions/v1/sic-command-ack").ToString();
   }
   ackAddress=ack;
   Configured=IsSocket(socketAddress)&&!String.IsNullOrWhiteSpace(realtimeKey)&&RegexToken(integrationToken)&&IsAckAddress(ackAddress);
   State=Configured?"waiting":"not_configured";
  }

  static bool IsSocket(string value){Uri uri;return Uri.TryCreate(value,UriKind.Absolute,out uri)&&(uri.Scheme=="wss"||uri.Scheme=="ws")&&uri.AbsolutePath=="/realtime/v1/websocket"&&String.IsNullOrEmpty(uri.UserInfo)&&String.IsNullOrEmpty(uri.Query)&&String.IsNullOrEmpty(uri.Fragment);}
  static bool IsAckAddress(string value){Uri uri;return Uri.TryCreate(value,UriKind.Absolute,out uri)&&uri.Scheme=="https"&&uri.Host.EndsWith(".supabase.co",StringComparison.OrdinalIgnoreCase)&&uri.AbsolutePath=="/functions/v1/sic-command-ack"&&String.IsNullOrEmpty(uri.UserInfo)&&String.IsNullOrEmpty(uri.Query)&&String.IsNullOrEmpty(uri.Fragment);}
  static bool RegexToken(string value){return !String.IsNullOrWhiteSpace(value)&&System.Text.RegularExpressions.Regex.IsMatch(value,@"^slb_live_[a-f0-9]{64}$");}
  public void Start(){lock(lifecycle){if(worker!=null||!Configured)return;worker=Task.Run(new Func<Task>(RunAsync));}}

  async Task RunAsync(){
   while(!stop.IsCancellationRequested){
    var retry=false;
    try{State="connecting";using(var socket=new ClientWebSocket()){socket.Options.KeepAliveInterval=TimeSpan.FromSeconds(20);await socket.ConnectAsync(JoinUrl(),stop.Token);await Join(socket);State="listening";await Receive(socket);}}
    catch(OperationCanceledException){break;}
    catch(Exception){State="retrying";retry=true;}
    if(retry){
     try{await Task.Delay(TimeSpan.FromSeconds(10),stop.Token);}
     catch(OperationCanceledException){break;}
    }
   }
   State="stopped";
  }
  Uri JoinUrl(){var separator=socketAddress.Contains("?")?"&":"?";return new Uri(socketAddress+separator+"apikey="+Uri.EscapeDataString(realtimeKey)+"&vsn=1.0.0");}
  async Task Join(ClientWebSocket socket){
   var config=new Dictionary<string,object> {
    {"broadcast",new Dictionary<string,object> {{"ack",false},{"self",false}}},
    {"presence",new Dictionary<string,object> {{"key",""}}},
    {"postgres_changes",new[]{new Dictionary<string,object> {{"event","INSERT"},{"schema","public"},{"table","sic_commands"},{"filter","instance_id=eq."+instanceId}}}}
   };
   var payload=new Dictionary<string,object> {{"config",config},{"access_token",realtimeKey}};
   await Send(socket,new Dictionary<string,object> {{"topic","realtime:public:sic_commands"},{"event","phx_join"},{"payload",payload},{"ref","1"}});
   Observe(Heartbeat(socket));
   CatchUp();
  }
  async Task Heartbeat(ClientWebSocket socket){
   while(socket.State==WebSocketState.Open&&!stop.IsCancellationRequested){
    try{
     await Task.Delay(TimeSpan.FromSeconds(15),stop.Token);
     if(socket.State!=WebSocketState.Open||stop.IsCancellationRequested)return;
     await Send(socket,new Dictionary<string,object>{{"topic","phoenix"},{"event","heartbeat"},{"payload",new Dictionary<string,object>()},{"ref",Guid.NewGuid().ToString("N")}});
    }catch{ return; }
   }
  }
  void CatchUp(){
   if(String.IsNullOrWhiteSpace(restAddress))return;
   try{
     var request=(HttpWebRequest)WebRequest.Create(restAddress+"?select=*&instance_id=eq."+Uri.EscapeDataString(instanceId)+"&status=in.(pending,processing)&order=created_at.asc");
    request.Method="GET";request.AllowAutoRedirect=false;request.Timeout=15000;request.Headers["apikey"]=realtimeKey;request.Headers["Authorization"]="Bearer "+realtimeKey;
    using(var response=(HttpWebResponse)request.GetResponse())using(var reader=new StreamReader(response.GetResponseStream())){
     var rows=Json.Read<List<Dictionary<string,object>>>(reader.ReadToEnd());
     foreach(var row in rows)Observe(ProcessAsync(row));
    }
   }catch{ State="listening"; }
  }
  async Task Receive(ClientWebSocket socket){
   var buffer=new byte[128*1024];var builder=new MemoryStream();
   while(socket.State==WebSocketState.Open&&!stop.IsCancellationRequested){
    builder.SetLength(0);WebSocketReceiveResult part;
    do{part=await socket.ReceiveAsync(new ArraySegment<byte>(buffer),stop.Token);if(part.MessageType==WebSocketMessageType.Close)return;builder.Write(buffer,0,part.Count);}while(!part.EndOfMessage);
    var message=Json.Read<Dictionary<string,object>>(Encoding.UTF8.GetString(builder.ToArray()));
    if(String.Equals(Convert.ToString(message.ContainsKey("event")?message["event"]:null),"postgres_changes",StringComparison.Ordinal)) {
     var payload=message["payload"] as Dictionary<string,object>;var data=payload==null?null:payload["data"] as Dictionary<string,object>;var record=data==null?null:data["record"] as Dictionary<string,object>;
      if(record!=null)Observe(ProcessAsync(record));
    }
   }
  }
  async Task Send(ClientWebSocket socket,object value){var bytes=Encoding.UTF8.GetBytes(Json.Write(value));await socket.SendAsync(new ArraySegment<byte>(bytes),WebSocketMessageType.Text,true,stop.Token);}
  static Guid StableRequest(string command,int index){using(var md5=MD5.Create())return new Guid(md5.ComputeHash(Encoding.UTF8.GetBytes(command+":"+index)));}
   async Task ProcessAsync(Dictionary<string,object> row){
    var rowStatus=row==null||!row.ContainsKey("status")?null:Convert.ToString(row["status"]);
    if(row==null||!row.ContainsKey("instance_id")||!String.Equals(Convert.ToString(row["instance_id"]),instanceId,StringComparison.OrdinalIgnoreCase)||(rowStatus!="pending"&&rowStatus!="processing"))return;
   var commandId=row.ContainsKey("command_id")?Convert.ToString(row["command_id"]):null;var org=row.ContainsKey("organization_id")?Convert.ToString(row["organization_id"]):null;var requestId=row.ContainsKey("request_id")?Convert.ToString(row["request_id"]):null;var kind=row.ContainsKey("kind")?Convert.ToString(row["kind"]):null;var payload=row.ContainsKey("payload")?row["payload"] as Dictionary<string,object>:null;
   if(String.IsNullOrWhiteSpace(commandId))return;
   lock(commandGate){if(activeCommands.Contains(commandId))return;activeCommands.Add(commandId);}
   if(payload==null||String.IsNullOrWhiteSpace(org)||String.IsNullOrWhiteSpace(requestId)){Observe(Ack(org,commandId,"failed",null,"INVALID_COMMAND"));Release(commandId);return;}
   var finalStatus="completed";var finalError=(string)null;Dictionary<string,object> result=null;
   try{
    await Ack(org,commandId,"processing",null,null);
    switch(kind){
     case "product.create": result=store.CreateProduct(ProductFromCommand(requestId,payload));break;
     case "cart.add": payload["request_id"]=requestId;result=store.AddCart(Json.Read<CartDraft>(Json.Write(payload)));break;
     case "cart.remove": payload["request_id"]=requestId;result=store.RemoveCart(Json.Read<CartDraft>(Json.Write(payload)));break;
     case "stock.adjust": payload["request_id"]=requestId;result=store.Adjust(Json.Read<AdjustmentDraft>(Json.Write(payload)));break;
     case "cart.confirm": result=ApplySale(requestId,payload);break;
     default:throw new DomainError("INVALID_COMMAND");
    }
   }catch(DomainError error){finalStatus=error.Code=="SIC_STOCK_CONFLICT"?"conflict":"failed";finalError=error.Code;}
   catch(Exception){finalStatus="failed";finalError="LOCAL_OPERATION_FAILED";}
   await Ack(org,commandId,finalStatus,result,finalError);
   if(finalStatus=="completed")State="listening";
   Release(commandId);
  }
  void Release(string commandId){lock(commandGate)activeCommands.Remove(commandId);}
  internal static ProductDraft ProductFromCommand(string requestId,Dictionary<string,object> payload){
   var normalized=new Dictionary<string,object>(payload);normalized["request_id"]=requestId;
   object photo;if(normalized.TryGetValue("photo_path",out photo))normalized["photo"]=photo;
   return Json.Read<ProductDraft>(Json.Write(normalized));
  }
  static void Observe(Task task){if(task==null)return;task.ContinueWith(t=>{var ignored=t.Exception;},TaskContinuationOptions.OnlyOnFaulted);}
  Dictionary<string,object> ApplySale(string requestId,Dictionary<string,object> payload){
   var lines=payload.ContainsKey("lines")?payload["lines"] as IEnumerable<object>:null;if(lines==null)throw new DomainError("INVALID_LINES");var drafts=new List<SaleLineDraft>();
   foreach(var raw in lines){var line=raw as Dictionary<string,object>;if(line==null||!line.ContainsKey("barcode")||!line.ContainsKey("quantity"))throw new DomainError("INVALID_LINES");drafts.Add(new SaleLineDraft{barcode=Convert.ToString(line["barcode"]),quantity=Convert.ToInt32(line["quantity"])});}
   return store.ConfirmLines(new ConfirmLinesDraft{request_id=requestId,lines=drafts,payment=payload.ContainsKey("payment")?Convert.ToString(payload["payment"]):"pix",fiscal_document=payload.ContainsKey("fiscal_document")?Convert.ToString(payload["fiscal_document"]):null,reference=payload.ContainsKey("reference")?Convert.ToString(payload["reference"]):null});
  }
  async Task Ack(string org,string command,string status,Dictionary<string,object> result,string error){
   if(!Configured||String.IsNullOrWhiteSpace(ackAddress)||String.IsNullOrWhiteSpace(org)||String.IsNullOrWhiteSpace(command))return;
   try{var request=(HttpWebRequest)WebRequest.Create(ackAddress);request.Method="POST";request.AllowAutoRedirect=false;request.Timeout=15000;request.ContentType="application/json";request.Headers["Authorization"]="Bearer "+integrationToken;var bytes=Encoding.UTF8.GetBytes(Json.Write(new Dictionary<string,object>{{"organization_id",org},{"command_id",command},{"instance_id",instanceId},{"status",status},{"result",result},{"error_code",error}}));request.ContentLength=bytes.Length;using(var stream=request.GetRequestStream())await stream.WriteAsync(bytes,0,bytes.Length);using(var response=(HttpWebResponse)await request.GetResponseAsync())using(var reader=new StreamReader(response.GetResponseStream()))await reader.ReadToEndAsync();}
   catch{State="ack_pending";}
  }
   public void Dispose(){stop.Cancel();try{if(worker!=null)worker.Wait(TimeSpan.FromSeconds(2));}catch{}stop.Dispose();}
 }
}
