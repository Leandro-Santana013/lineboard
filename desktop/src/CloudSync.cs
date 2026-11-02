using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Text;

namespace Lineboard {
 public sealed class CloudSync {
  readonly SicStore store;readonly Func<Dictionary<string,object>,Dictionary<string,object>> send;readonly Func<Dictionary<string,object>> pull;readonly object gate=new object();
  public readonly bool Configured;
  public CloudSync(SicStore store):this(store,CreateSender(),CreatePuller(store)){}
  internal CloudSync(SicStore store,Func<Dictionary<string,object>,Dictionary<string,object>> sender){this.store=store;send=sender;pull=null;Configured=sender!=null;}
  CloudSync(SicStore store,Func<Dictionary<string,object>,Dictionary<string,object>> sender,Func<Dictionary<string,object>> receiver){this.store=store;send=sender;pull=receiver;Configured=sender!=null;}
  static string Env(string name){var value=Environment.GetEnvironmentVariable(name);if(!String.IsNullOrEmpty(value))return value;value=Environment.GetEnvironmentVariable(name,EnvironmentVariableTarget.User);if(!String.IsNullOrEmpty(value))return value;return Environment.GetEnvironmentVariable(name,EnvironmentVariableTarget.Machine);}
  static Func<Dictionary<string,object>,Dictionary<string,object>> CreateSender(){
   var address=Env("LINEBOARD_SYNC_URL");var token=Env("LINEBOARD_SYNC_TOKEN");
   if(String.IsNullOrEmpty(address)||String.IsNullOrEmpty(token))return null;
   Uri uri;if(!Uri.TryCreate(address,UriKind.Absolute,out uri)||uri.Scheme!="https"||!uri.Host.EndsWith(".supabase.co",StringComparison.OrdinalIgnoreCase)||uri.AbsolutePath!="/functions/v1/sic-sync"||uri.UserInfo!=""||uri.Query!=""||uri.Fragment!="")throw new DomainError("INVALID_CLOUD_ADDRESS");
   if(!System.Text.RegularExpressions.Regex.IsMatch(token,@"^slb_live_[a-f0-9]{64}$"))throw new DomainError("INVALID_CLOUD_CREDENTIAL");
   return payload=>{
    ServicePointManager.SecurityProtocol=SecurityProtocolType.Tls12;
    var request=(HttpWebRequest)WebRequest.Create(uri);request.Method="POST";request.AllowAutoRedirect=false;request.Timeout=15000;request.ContentType="application/json";request.Headers["Authorization"]="Bearer "+token;
    var bytes=Encoding.UTF8.GetBytes(Json.Write(payload));request.ContentLength=bytes.Length;using(var stream=request.GetRequestStream())stream.Write(bytes,0,bytes.Length);
    try{using(var response=(HttpWebResponse)request.GetResponse())using(var reader=new StreamReader(response.GetResponseStream()))return Json.Read<Dictionary<string,object>>(reader.ReadToEnd());}
    catch(WebException error){if(error.Response!=null)error.Response.Dispose();throw new DomainError("CLOUD_NOT_ACKNOWLEDGED");}
   };
  }
  static Func<Dictionary<string,object>> CreatePuller(SicStore store){
   var address=Env("LINEBOARD_SYNC_URL");var token=Env("LINEBOARD_SYNC_TOKEN");
   if(String.IsNullOrEmpty(address)||String.IsNullOrEmpty(token))return null;
   Uri uri;if(!Uri.TryCreate(address,UriKind.Absolute,out uri)||uri.Scheme!="https"||!uri.Host.EndsWith(".supabase.co",StringComparison.OrdinalIgnoreCase)||uri.AbsolutePath!="/functions/v1/sic-sync"||uri.UserInfo!=""||uri.Query!=""||uri.Fragment!="")throw new DomainError("INVALID_CLOUD_ADDRESS");
   if(!System.Text.RegularExpressions.Regex.IsMatch(token,@"^slb_live_[a-f0-9]{64}$"))throw new DomainError("INVALID_CLOUD_CREDENTIAL");
   return ()=>{
    ServicePointManager.SecurityProtocol=SecurityProtocolType.Tls12;
    var target=new Uri(uri.AbsoluteUri+"?instance_id="+Uri.EscapeDataString(store.InstanceId));
    var request=(HttpWebRequest)WebRequest.Create(target);request.Method="GET";request.AllowAutoRedirect=false;request.Timeout=15000;request.Headers["Authorization"]="Bearer "+token;
    try{using(var response=(HttpWebResponse)request.GetResponse())using(var reader=new StreamReader(response.GetResponseStream()))return Json.Read<Dictionary<string,object>>(reader.ReadToEnd());}
    catch(WebException error){if(error.Response!=null)error.Response.Dispose();throw new DomainError("CLOUD_NOT_ACKNOWLEDGED");}
   };
  }
  public Dictionary<string,object> Reconcile(){
   if(!Configured)throw new DomainError("CLOUD_NOT_CONFIGURED");int imported=0;
   if(pull!=null){var snapshot=pull();if(!snapshot.ContainsKey("state")||Convert.ToString(snapshot["state"])!="snapshot")throw new DomainError("INVALID_CLOUD_SNAPSHOT");if(!String.Equals(Convert.ToString(snapshot["instance_id"]),store.InstanceId,StringComparison.OrdinalIgnoreCase))throw new DomainError("INVALID_CLOUD_SNAPSHOT");var result=store.ImportCloudSnapshot(snapshot);imported=Convert.ToInt32(result["imported"]);object raw;var cloudUnits=snapshot.TryGetValue("units",out raw)?Json.Read<List<Dictionary<string,object>>>(Json.Write(raw)):new List<Dictionary<string,object>>();store.QueueCatalogMissing(cloudUnits);}
   var pushed=Push();pushed["imported"]=imported;return pushed;
  }
  public Dictionary<string,object> Push(){lock(gate){
   if(!Configured)throw new DomainError("CLOUD_NOT_CONFIGURED");int sent=0;
   foreach(var row in store.Outbox()){
    if((string)row["state"]=="sent")continue;if((string)row["state"]=="conflict")return new Dictionary<string,object>{{"sent",sent},{"state","conflict"}};
    var eventId=Convert.ToString(row["event_id"]);Dictionary<string,object> result;
    try{
     var payload=new Dictionary<string,object>{{"instance_id",store.InstanceId},{"mode",store.Production?"production":"sandbox"},{"event_id",eventId},{"kind",row["kind"]},{"payload",Json.Read<Dictionary<string,object>>((string)row["payload"])}};
     result=send(payload);
     if(!result.ContainsKey("event_id")||!String.Equals(Convert.ToString(result["event_id"]),eventId,StringComparison.OrdinalIgnoreCase)||!result.ContainsKey("state"))throw new DomainError("INVALID_CLOUD_ACK");
     string state=Convert.ToString(result["state"]);if(state!="applied"&&state!="ignored"&&state!="conflict")throw new DomainError("INVALID_CLOUD_ACK");
     using(var c=store.Open())SicStore.NonQuery(c,null,"UPDATE lineboard.Outbox SET state=@state,attempts=attempts+1,last_error=@error,sent_at=CASE WHEN @state='sent' THEN SYSUTCDATETIME() ELSE NULL END WHERE id=@id AND state='pending'","@state",state=="conflict"?"conflict":"sent","@error",state=="conflict"?(result.ContainsKey("reason")?Convert.ToString(result["reason"]):"CLOUD_CONFLICT"):null,"@id",row["id"]);
     if(state=="conflict")return new Dictionary<string,object>{{"sent",sent},{"state","conflict"}};sent++;
    }catch(Exception){using(var c=store.Open())SicStore.NonQuery(c,null,"UPDATE lineboard.Outbox SET attempts=attempts+1,last_error='CLOUD_NOT_ACKNOWLEDGED' WHERE id=@id AND state='pending'","@id",row["id"]);throw;}
   }
   return new Dictionary<string,object>{{"sent",sent},{"state","up_to_date"}};
  }}
 }
}
