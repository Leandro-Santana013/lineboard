using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Lineboard {
 public sealed class LocalApi : IDisposable {
  readonly SicStore store; readonly HttpListener listener=new HttpListener(); readonly object pairingLock=new object();
  string pin; DateTime pinExpires; int attempts; public readonly string Address;
  public LocalApi(SicStore store,string host,int port){
   IPAddress ip;if(host!="localhost"&&(!IPAddress.TryParse(host,out ip)||!Private(ip)))throw new DomainError("LOCAL_NETWORK_ONLY");
   this.store=store;Address="http://"+host+":"+port+"/";listener.Prefixes.Add(Address);
  }
  static bool Private(IPAddress ip){if(IPAddress.IsLoopback(ip))return true;var b=ip.GetAddressBytes();return b.Length==4&&(b[0]==10||(b[0]==172&&b[1]>=16&&b[1]<=31)||(b[0]==192&&b[1]==168));}
  static string Secret(){var bytes=new byte[32];using(var rng=RandomNumberGenerator.Create())rng.GetBytes(bytes);return BitConverter.ToString(bytes).Replace("-","").ToLowerInvariant();}
  public string OpenPairing(){lock(pairingLock){var bytes=new byte[4];using(var rng=RandomNumberGenerator.Create())rng.GetBytes(bytes);pin=(BitConverter.ToUInt32(bytes,0)%1000000).ToString("D6");pinExpires=DateTime.UtcNow.AddMinutes(3);attempts=0;return pin;}}
  public void Start(){listener.Start();Task.Run(async()=>{while(listener.IsListening){try{var context=await listener.GetContextAsync();ThreadPool.QueueUserWorkItem(_=>Handle(context));}catch(HttpListenerException){break;}catch(ObjectDisposedException){break;}}});}
  static string Body(HttpListenerRequest request,int maximum=1024*1024){
   if(request.ContentLength64>maximum)throw new DomainError("REQUEST_TOO_LARGE");
   using(var stream=request.InputStream)using(var output=new MemoryStream()){
    var buffer=new byte[8192];int n;while((n=stream.Read(buffer,0,buffer.Length))>0){if(output.Length+n>maximum)throw new DomainError("REQUEST_TOO_LARGE");output.Write(buffer,0,n);}return Encoding.UTF8.GetString(output.ToArray());
   }
  }
  object Pair(Dictionary<string,object> body){lock(pairingLock){
   attempts++;if(pin==null||DateTime.UtcNow>pinExpires||attempts>10||!body.ContainsKey("pin")||!String.Equals(pin,Convert.ToString(body["pin"]),StringComparison.Ordinal))throw new DomainError("PAIRING_REFUSED");
   var name=Validation.Text(body.ContainsKey("name")?Convert.ToString(body["name"]):"Celular",80,true);var token=Secret();store.RegisterDevice(token,name);pin=null;
   return new{token,instance_id=store.InstanceId,mode=store.Production?"production":"sandbox"};
  }}
  void Handle(HttpListenerContext context){
   int status=200;object result;
   try{
    var request=context.Request;var path=request.Url.AbsolutePath.TrimEnd('/');var method=request.HttpMethod;
    if(!Private(request.RemoteEndPoint.Address)||request.Headers["Origin"]!=null)throw new DomainError("REQUEST_ORIGIN_REFUSED");
    if(path=="/api/health"&&method=="GET")result=store.Health();
    else if(path=="/api/pair"&&method=="POST")result=Pair(Json.Read<Dictionary<string,object>>(Body(request)));
    else{
     var auth=request.Headers["Authorization"]??"";if(!auth.StartsWith("Bearer ",StringComparison.Ordinal)||!store.Authorized(auth.Substring(7)))throw new DomainError("UNAUTHORIZED");
     if(path=="/api/catalog"&&method=="GET")result=new{items=store.Catalog()};
     else if(path=="/api/photos"&&method=="POST"){
      var photo=Json.Read<Dictionary<string,string>>(Body(request,8*1024*1024));if(photo==null||photo.Count!=2||!photo.ContainsKey("content_type")||!photo.ContainsKey("data"))throw new DomainError("INVALID_PAYLOAD");
      result=new CloudSync(store,false).UploadPhoto(photo["content_type"],photo["data"]);
     }
     else if(path=="/api/photos/url"&&method=="POST"){
      var photo=Json.Read<Dictionary<string,string>>(Body(request));if(photo==null||photo.Count!=1||!photo.ContainsKey("photo_path"))throw new DomainError("INVALID_PAYLOAD");result=new CloudSync(store,false).PhotoUrl(photo["photo_path"]);
     }
     else if(path.StartsWith("/api/units/",StringComparison.Ordinal)&&method=="GET")result=store.Lookup(Uri.UnescapeDataString(path.Substring(11)));
     else if(path.StartsWith("/api/units/",StringComparison.Ordinal)&&method=="PUT")result=store.Edit(Uri.UnescapeDataString(path.Substring(11)),Json.Read<EditDraft>(Body(request)));
     else if(path=="/api/products"&&method=="POST")result=store.CreateProduct(Json.Read<ProductDraft>(Body(request)));
     else if(path=="/api/cart"&&method=="GET")result=store.Cart();
     else if(path=="/api/cart/items"&&method=="POST")result=store.AddCart(Json.Read<CartDraft>(Body(request)));
     else if(path=="/api/cart/items"&&method=="DELETE")result=store.RemoveCart(Json.Read<CartDraft>(Body(request)));
     // Closing a sale is intentionally a desktop operation, never a scanner endpoint.
     else{status=404;result=new{error="NOT_FOUND"};}
    }
   }catch(DomainError error){status=error.Code=="UNAUTHORIZED"?401:(error.Code=="PAIRING_REFUSED"||error.Code=="REQUEST_ORIGIN_REFUSED"?403:409);result=new{error=error.Code};}
   catch(ArgumentException){status=400;result=new{error="INVALID_REQUEST"};}
   catch(InvalidOperationException){status=400;result=new{error="INVALID_REQUEST"};}
   catch(Exception){status=500;result=new{error="LOCAL_OPERATION_FAILED"};}
   try{var bytes=Encoding.UTF8.GetBytes(Json.Write(result));context.Response.StatusCode=status;context.Response.ContentType="application/json; charset=utf-8";context.Response.Headers["Cache-Control"]="no-store";context.Response.Headers["X-Lineboard-Instance"]=store.InstanceId;context.Response.ContentLength64=bytes.Length;context.Response.OutputStream.Write(bytes,0,bytes.Length);}catch(HttpListenerException){}finally{context.Response.Close();}
  }
  public void Dispose(){listener.Close();}
 }
}
