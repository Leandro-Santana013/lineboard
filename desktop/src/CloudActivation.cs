using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace Lineboard {
 public sealed class CloudActivation {
  // Public project URL, not a secret. It lets a fresh public installer reach
  // the activation function before any cloud configuration exists locally.
  const string DefaultSupabaseUrl="https://isktnezzanqpcrkkqldw.supabase.co";
  readonly SicStore store;

  public CloudActivation(SicStore store) { this.store=store??throw new ArgumentNullException("store"); }

  public Dictionary<string,object> Activate(string code,string deviceName=null) {
   code=NormalizeCode(code);if(!Regex.IsMatch(code,@"^LB-[A-Z0-9]{4}(?:-[A-Z0-9]{4}){2}$"))throw new DomainError("ACTIVATION_INVALID");
   deviceName=String.IsNullOrWhiteSpace(deviceName)?Environment.MachineName:deviceName.Trim();if(deviceName.Length>120)deviceName=deviceName.Substring(0,120);
   var endpoint=ActivationEndpoint();var body=Json.Write(new{code,instance_id=store.InstanceId,device_name=deviceName});
   try {
    ServicePointManager.SecurityProtocol|=SecurityProtocolType.Tls12;
    var request=(HttpWebRequest)WebRequest.Create(endpoint);request.Method="POST";request.AllowAutoRedirect=false;request.Timeout=15000;request.ContentType="application/json";
    var bytes=Encoding.UTF8.GetBytes(body);request.ContentLength=bytes.Length;using(var stream=request.GetRequestStream())stream.Write(bytes,0,bytes.Length);
    using(var response=(HttpWebResponse)request.GetResponse())using(var reader=new StreamReader(response.GetResponseStream()))return SaveConfiguration(Json.Read<Dictionary<string,object>>(reader.ReadToEnd()));
   } catch(WebException error) {
    if(error.Response!=null)using(var response=error.Response)using(var reader=new StreamReader(response.GetResponseStream())) {
     try { var result=Json.Read<Dictionary<string,object>>(reader.ReadToEnd());object raw;if(result!=null&&result.TryGetValue("error",out raw)&&!String.IsNullOrWhiteSpace(Convert.ToString(raw)))throw new DomainError(Convert.ToString(raw)); }
     catch(DomainError){throw;}
     catch{}
    }
    throw new DomainError("ACTIVATION_NETWORK_ERROR");
   } catch(DomainError){throw;} catch(Exception){throw new DomainError("ACTIVATION_CONFIG_INVALID");}
  }

  static string NormalizeCode(string value) { return (value??"").Trim().ToUpperInvariant().Replace(" ",""); }
  static Uri ActivationEndpoint() {
   var configured=Configuration.Get("SUPABASE_URL");var value=String.IsNullOrWhiteSpace(configured)?DefaultSupabaseUrl:configured.Trim();Uri baseUri;
   if(!Uri.TryCreate(value,UriKind.Absolute,out baseUri)||baseUri.Scheme!="https"||!baseUri.Host.EndsWith(".supabase.co",StringComparison.OrdinalIgnoreCase)||!String.IsNullOrEmpty(baseUri.UserInfo)||baseUri.Query!=""||baseUri.Fragment!="")throw new DomainError("ACTIVATION_CONFIG_INVALID");
   return new Uri(baseUri,"functions/v1/activate-desktop");
  }

  static Dictionary<string,object> SaveConfiguration(Dictionary<string,object> response) {
   if(response==null||!response.ContainsKey("activated")||!Convert.ToBoolean(response["activated"])||!response.ContainsKey("config"))throw new DomainError("ACTIVATION_CONFIG_INVALID");
   var config=Json.Map(response["config"]);var token=StringValue(config,"LINEBOARD_SYNC_TOKEN");var sync=StringValue(config,"LINEBOARD_SYNC_URL");var supabase=StringValue(config,"SUPABASE_URL");
   if(!Regex.IsMatch(token,@"^slb_live_[a-f0-9]{64}$")||!ValidHttps(sync,"/functions/v1/sic-sync")||!ValidSupabase(supabase))throw new DomainError("ACTIVATION_CONFIG_INVALID");
   var updates=new Dictionary<string,object>();foreach(var entry in config)updates[entry.Key]=entry.Value;Configuration.Merge(updates);
   return new Dictionary<string,object>{{"activated",true},{"restart_required",true},{"organization_id",response.ContainsKey("organization_id")?response["organization_id"]:null},{"instance_id",response.ContainsKey("instance_id")?response["instance_id"]:null}};
  }

  static string StringValue(Dictionary<string,object> map,string key) { object value;if(!map.TryGetValue(key,out value)||String.IsNullOrWhiteSpace(Convert.ToString(value)))throw new DomainError("ACTIVATION_CONFIG_INVALID");return Convert.ToString(value).Trim(); }
  static bool ValidSupabase(string value) { Uri uri;return Uri.TryCreate(value,UriKind.Absolute,out uri)&&uri.Scheme=="https"&&uri.Host.EndsWith(".supabase.co",StringComparison.OrdinalIgnoreCase)&&String.IsNullOrEmpty(uri.UserInfo)&&String.IsNullOrEmpty(uri.Query)&&String.IsNullOrEmpty(uri.Fragment); }
  static bool ValidHttps(string value,string path) { Uri uri;return Uri.TryCreate(value,UriKind.Absolute,out uri)&&uri.Scheme=="https"&&uri.Host.EndsWith(".supabase.co",StringComparison.OrdinalIgnoreCase)&&uri.AbsolutePath==path&&String.IsNullOrEmpty(uri.UserInfo)&&String.IsNullOrEmpty(uri.Query)&&String.IsNullOrEmpty(uri.Fragment); }
 }
}
