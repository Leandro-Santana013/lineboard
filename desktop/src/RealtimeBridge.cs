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
  readonly string syncAddress;
  readonly string realtimeKey;
  readonly string instanceId;
  readonly string ackAddress;
  readonly string integrationToken;
  readonly CancellationTokenSource stop=new CancellationTokenSource();
  readonly object lifecycle=new object();
  readonly object commandGate=new object();
  readonly HashSet<string> activeCommands=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
  Task worker;int connected;
  public string State { get; private set; }
  public string LastError { get; private set; }
  public bool Configured { get; private set; }
  public bool CommandsConfigured { get; private set; }
  public event Action SharedCartChanged;

  public RealtimeBridge(SicStore store) {
   if(store==null)throw new ArgumentNullException("store");
   this.store=store;instanceId=store.InstanceId;
   socketAddress=Env("LINEBOARD_REALTIME_URL");
   realtimeKey=Env("LINEBOARD_REALTIME_KEY");
   integrationToken=Env("LINEBOARD_SYNC_TOKEN");
   var supabase=Env("SUPABASE_URL");
   Uri supabaseUri;
   var sync=Env("LINEBOARD_SYNC_URL");
   Uri syncUri;
   syncAddress=Uri.TryCreate(sync,UriKind.Absolute,out syncUri)&&syncUri.Scheme=="https"?syncUri.ToString():null;
   if(Uri.TryCreate(supabase,UriKind.Absolute,out supabaseUri)&&supabaseUri.Scheme=="https"){
    restAddress=new Uri(supabaseUri,"rest/v1/sic_commands").ToString();
   } else {restAddress=null;}
   var ack=Env("LINEBOARD_REALTIME_ACK_URL");
   if(String.IsNullOrWhiteSpace(ack)) {
    Uri baseUri;
    if(Uri.TryCreate(supabase,UriKind.Absolute,out baseUri))ack=new Uri(baseUri,"functions/v1/sic-command-ack").ToString();
   }
   ackAddress=ack;
   Configured=IsSocket(socketAddress)&&!String.IsNullOrWhiteSpace(realtimeKey);
   CommandsConfigured=Configured&&RegexToken(integrationToken)&&IsAckAddress(ackAddress);
   State=Configured?"waiting":"not_configured";
  }

  static string Env(string name){
   var value=Environment.GetEnvironmentVariable(name);
   if(!String.IsNullOrWhiteSpace(value))return value;
   value=Environment.GetEnvironmentVariable(name,EnvironmentVariableTarget.User);
   if(!String.IsNullOrWhiteSpace(value))return value;
   return Environment.GetEnvironmentVariable(name,EnvironmentVariableTarget.Machine);
  }

  static bool IsSocket(string value){Uri uri;return Uri.TryCreate(value,UriKind.Absolute,out uri)&&(uri.Scheme=="wss"||uri.Scheme=="ws")&&uri.AbsolutePath=="/realtime/v1/websocket"&&String.IsNullOrEmpty(uri.UserInfo)&&String.IsNullOrEmpty(uri.Query)&&String.IsNullOrEmpty(uri.Fragment);}
  static bool IsAckAddress(string value){Uri uri;return Uri.TryCreate(value,UriKind.Absolute,out uri)&&uri.Scheme=="https"&&uri.Host.EndsWith(".supabase.co",StringComparison.OrdinalIgnoreCase)&&uri.AbsolutePath=="/functions/v1/sic-command-ack"&&String.IsNullOrEmpty(uri.UserInfo)&&String.IsNullOrEmpty(uri.Query)&&String.IsNullOrEmpty(uri.Fragment);}
  static bool RegexToken(string value){return !String.IsNullOrWhiteSpace(value)&&System.Text.RegularExpressions.Regex.IsMatch(value,@"^slb_live_[a-f0-9]{64}$");}
  public void Start(){lock(lifecycle){if(worker!=null||!Configured)return;worker=Task.Run(new Func<Task>(RunAsync));}}

  async Task RunAsync(){
   while(!stop.IsCancellationRequested){
    var retry=false;var phase="connecting";
    try{ServicePointManager.SecurityProtocol|=SecurityProtocolType.Tls12;State=phase;using(var socket=new ClientWebSocket()){socket.Options.KeepAliveInterval=TimeSpan.FromSeconds(20);await socket.ConnectAsync(JoinUrl(),stop.Token);phase="joining";State=phase;await Join(socket);phase="listening";State=phase;await Receive(socket);}}
    catch(OperationCanceledException){if(stop.IsCancellationRequested)break;LastError="REALTIME_JOIN_TIMEOUT";State="retrying";retry=true;}
    catch(Exception error){LastError=phase+": "+SafeError(error);State="retrying";retry=true;}
    if(retry){
     try{await Task.Delay(TimeSpan.FromSeconds(10),stop.Token);}
     catch(OperationCanceledException){break;}
    }
   }
   State="stopped";
  }
  string SafeError(Exception error){
   var details=new StringBuilder();for(var current=error;current!=null;current=current.InnerException){if(details.Length>0)details.Append(" <- ");details.Append(current.GetType().Name).Append(": ").Append(current.Message);}
   return SafeErrorText(details.ToString());
  }
  string SafeErrorText(string message){
   if(!String.IsNullOrEmpty(realtimeKey)){message=message.Replace(realtimeKey,"[redacted]").Replace(Uri.EscapeDataString(realtimeKey),"[redacted]");}
   if(!String.IsNullOrEmpty(integrationToken))message=message.Replace(integrationToken,"[redacted]");
   if(message.Length>512)message=message.Substring(0,512);
   return message;
  }
  string SystemError(Dictionary<string,object> systemPayload,string topic){
   var detail=new StringBuilder("REALTIME_SUBSCRIPTION_REJECTED channel=").Append(topic);
   if(systemPayload!=null){foreach(var field in new[]{"message","code","details","hint"}){object value;if(systemPayload.TryGetValue(field,out value)&&value!=null)detail.Append(" ").Append(field).Append("=").Append(Convert.ToString(value));}}
   return SafeErrorText(detail.ToString());
  }
  Uri JoinUrl(){var separator=socketAddress.Contains("?")?"&":"?";return new Uri(socketAddress+separator+"apikey="+Uri.EscapeDataString(realtimeKey)+"&vsn=1.0.0");}
  async Task Join(ClientWebSocket socket){
   if(CommandsConfigured){
    var config=ChannelConfig(new[]{new Dictionary<string,object> {{"event","INSERT"},{"schema","public"},{"table","sic_commands"},{"filter","instance_id=eq."+instanceId}}});
    try{await JoinChannel(socket,"realtime:public:sic_commands",config,"1",1);}
    catch(DomainError){/* Command delivery is optional; the shared cart must still subscribe. */}
   }
   var organization=ResolveOrganization();
   if(String.IsNullOrWhiteSpace(organization))throw new DomainError("SIC_ORGANIZATION_UNRESOLVED");
   var cartConfig=ChannelConfig(new[]{
    new Dictionary<string,object> {{"event","INSERT"},{"schema","public"},{"table","sic_shared_carts"},{"filter","organization_id=eq."+organization}},
    new Dictionary<string,object> {{"event","UPDATE"},{"schema","public"},{"table","sic_shared_carts"},{"filter","organization_id=eq."+organization}}
   });
   await JoinChannel(socket,"realtime:public:sic_shared_carts",cartConfig,"2",2);
   Observe(Heartbeat(socket));
   if(CommandsConfigured)CatchUp();
   // Start() performs the initial snapshot. Later joins are reconnects and
   // must reconcile once because events may have been missed while offline.
   // Reconcile on the first successful join as well as on reconnects. The
   // initial desktop snapshot can finish before this socket is ready, so a
   // first-join notification closes that race without introducing polling.
   Interlocked.Exchange(ref connected,1);
   LastError=null;
   NotifySharedCartChanged();
  }
  async Task JoinChannel(ClientWebSocket socket,string topic,Dictionary<string,object> config,string reference,int expectedBindings){
   await Send(socket,JoinMessage(topic,config,reference));
   using(var timeout=CancellationTokenSource.CreateLinkedTokenSource(stop.Token)){
    timeout.CancelAfter(TimeSpan.FromSeconds(15));
    while(!timeout.IsCancellationRequested){
     var message=await ReceiveMessage(socket,timeout.Token);
     var eventName=Convert.ToString(message.ContainsKey("event")?message["event"]:null);
     if(eventName=="system"){
      var systemPayload=message.ContainsKey("payload")?message["payload"] as Dictionary<string,object>:null;
      if(systemPayload!=null&&String.Equals(Convert.ToString(systemPayload.ContainsKey("status")?systemPayload["status"]:null),"error",StringComparison.OrdinalIgnoreCase))throw new DomainError(SystemError(systemPayload,topic));
      continue;
     }
     if(eventName!="phx_reply"||!String.Equals(Convert.ToString(message.ContainsKey("ref")?message["ref"]:null),reference,StringComparison.Ordinal))continue;
     var payload=message.ContainsKey("payload")?message["payload"] as Dictionary<string,object>:null;
     if(payload==null||!String.Equals(Convert.ToString(payload.ContainsKey("status")?payload["status"]:null),"ok",StringComparison.OrdinalIgnoreCase))throw new DomainError("REALTIME_JOIN_REJECTED");
     var response=payload.ContainsKey("response")?payload["response"] as Dictionary<string,object>:null;
     var bindings=response!=null&&response.ContainsKey("postgres_changes")?response["postgres_changes"] as System.Collections.IList:null;
     if(bindings==null||bindings.Count!=expectedBindings)throw new DomainError("REALTIME_BINDING_MISMATCH");
     return;
    }
   }
   throw new DomainError("REALTIME_JOIN_TIMEOUT");
  }
  static Dictionary<string,object> ChannelConfig(IEnumerable<Dictionary<string,object>> changes){
   return new Dictionary<string,object> {
    {"broadcast",new Dictionary<string,object> {{"ack",false},{"self",false}}},
    {"presence",new Dictionary<string,object> {{"key",""}}},
    {"postgres_changes",changes}
   };
  }
  Dictionary<string,object> JoinMessage(string topic,Dictionary<string,object> config,string reference){
   // New Supabase sb_secret_* keys authenticate through the apikey query
   // parameter. They are not JWT access tokens and must not be sent as
   // access_token in the Realtime payload. A session JWT can be supplied by
   // a user-facing client, but this desktop adapter intentionally uses the
   // server key only.
   var payload=new Dictionary<string,object> {{"config",config}};
   return new Dictionary<string,object> {{"topic",topic},{"event","phx_join"},{"payload",payload},{"ref",reference}};
  }
  string ResolveOrganization(){
   if(String.IsNullOrWhiteSpace(syncAddress)||!RegexToken(integrationToken))return null;
   try{
    var request=(HttpWebRequest)WebRequest.Create(syncAddress+"?instance_id="+Uri.EscapeDataString(instanceId));
    request.Method="GET";request.AllowAutoRedirect=false;request.Timeout=15000;request.Headers["Authorization"]="Bearer "+integrationToken;
    using(var response=(HttpWebResponse)request.GetResponse())using(var reader=new StreamReader(response.GetResponseStream())){
     var snapshot=Json.Read<Dictionary<string,object>>(reader.ReadToEnd());
     return snapshot.ContainsKey("organization_id")?Convert.ToString(snapshot["organization_id"]):null;
    }
   }catch{return null;}
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
   while(socket.State==WebSocketState.Open&&!stop.IsCancellationRequested){
    var message=await ReceiveMessage(socket,stop.Token);var eventName=Convert.ToString(message.ContainsKey("event")?message["event"]:null);
    if(eventName=="system"){
     var systemPayload=message.ContainsKey("payload")?message["payload"] as Dictionary<string,object>:null;
     if(systemPayload!=null&&String.Equals(Convert.ToString(systemPayload.ContainsKey("status")?systemPayload["status"]:null),"error",StringComparison.OrdinalIgnoreCase))throw new DomainError(SystemError(systemPayload,Convert.ToString(message.ContainsKey("topic")?message["topic"]:null)));
     continue;
    }
    if(String.Equals(eventName,"postgres_changes",StringComparison.Ordinal)) {
     var payload=message["payload"] as Dictionary<string,object>;var data=payload==null?null:payload["data"] as Dictionary<string,object>;var record=data==null?null:data["record"] as Dictionary<string,object>;
      var table=data==null?null:Convert.ToString(data.ContainsKey("table")?data["table"]:null);
      if(table=="sic_shared_carts"){NotifySharedCartChanged();continue;}
      if(table=="sic_commands"&&record!=null&&CommandsConfigured)Observe(ProcessAsync(record));
    }
   }
  }
  async Task<Dictionary<string,object>> ReceiveMessage(ClientWebSocket socket,CancellationToken token){
   var buffer=new byte[128*1024];using(var builder=new MemoryStream()){
    WebSocketReceiveResult part;
    do{part=await socket.ReceiveAsync(new ArraySegment<byte>(buffer),token);if(part.MessageType==WebSocketMessageType.Close)throw new IOException("REALTIME_SOCKET_CLOSED");builder.Write(buffer,0,part.Count);}while(!part.EndOfMessage);
    return Json.Read<Dictionary<string,object>>(Encoding.UTF8.GetString(builder.ToArray()));
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
   if(!CommandsConfigured||String.IsNullOrWhiteSpace(org)||String.IsNullOrWhiteSpace(command))return;
   try{var request=(HttpWebRequest)WebRequest.Create(ackAddress);request.Method="POST";request.AllowAutoRedirect=false;request.Timeout=15000;request.ContentType="application/json";request.Headers["Authorization"]="Bearer "+integrationToken;var bytes=Encoding.UTF8.GetBytes(Json.Write(new Dictionary<string,object>{{"organization_id",org},{"command_id",command},{"instance_id",instanceId},{"status",status},{"result",result},{"error_code",error}}));request.ContentLength=bytes.Length;using(var stream=request.GetRequestStream())await stream.WriteAsync(bytes,0,bytes.Length);using(var response=(HttpWebResponse)await request.GetResponseAsync())using(var reader=new StreamReader(response.GetResponseStream()))await reader.ReadToEndAsync();}
   catch{State="ack_pending";}
  }
  void NotifySharedCartChanged(){try{var handler=SharedCartChanged;if(handler!=null)handler();}catch{State="sync_pending";}}
   public void Dispose(){stop.Cancel();try{if(worker!=null)worker.Wait(TimeSpan.FromSeconds(2));}catch{}stop.Dispose();}
 }
}
