using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading.Tasks;

namespace Lineboard {
 static class SelfTests {
  static readonly List<string> passed=new List<string>();
  static void Check(string name,bool condition){if(!condition)throw new Exception("TEST_FAILED: "+name);passed.Add(name);}
  static void Reject(string name,string code,Action action){try{action();}catch(DomainError e){Check(name,e.Code==code);return;}throw new Exception("TEST_FAILED: "+name+" (accepted)");}
  static long Count(SicStore store,string table){using(var c=store.Open())return Convert.ToInt64(SicStore.Scalar(c,null,"SELECT COUNT(*) FROM "+table));}
  static List<Dictionary<string,object>> Units(Dictionary<string,object> result){return Json.Read<List<Dictionary<string,object>>>(Json.Write(result["units"]));}
  static object Request(string address,string method,string path,object body,string token,int expected){
   var request=(HttpWebRequest)WebRequest.Create(address+path.TrimStart('/'));request.Method=method;request.Timeout=10000;
   if(token!=null)request.Headers["Authorization"]="Bearer "+token;
   if(body!=null){var bytes=Encoding.UTF8.GetBytes(Json.Write(body));request.ContentType="application/json";request.ContentLength=bytes.Length;using(var stream=request.GetRequestStream())stream.Write(bytes,0,bytes.Length);}
   HttpWebResponse response;try{response=(HttpWebResponse)request.GetResponse();}catch(WebException e){response=e.Response as HttpWebResponse;if(response==null)throw;}
   using(response){if((int)response.StatusCode!=expected)throw new Exception("HTTP_TEST_FAILED: "+path+" "+response.StatusCode);using(var reader=new StreamReader(response.GetResponseStream()))return Json.Read<Dictionary<string,object>>(reader.ReadToEnd());}
  }
  public static object Run(SicStore store,string server,string workspace){
   if(Count(store,"lineboard.Units")!=0)throw new Exception("Self-tests require a NEW empty sandbox. Existing data was left unchanged.");
   string sourceBefore=Json.Write(Program.Probe(server));
   Reject("production database refused","SANDBOX_ONLY",()=>new SicStore(server,"SICNET",workspace));
   var draft=new ProductDraft {request_id=Guid.NewGuid().ToString(),name="TESTE Lineboard Camiseta",brand="Laboratorio",cost=40m,price=89.90m,notes="Dado sintético de validação",location="A1",variants=new List<VariantDraft>{new VariantDraft{color="Preta",size="M",quantity=5}}};
   var created=store.CreateProduct(draft);var units=Units(created);var codes=units.Select(x=>(string)x["barcode"]).ToList();
   Check("five units have five unique codes",units.Count==5&&codes.Distinct().Count()==5);
   Check("Code128 includes quiet zones checksum and optimized numeric suffix",Labels.Modules("SLB-900000000001").Length==176&&Labels.Codewords("SLB-900000000001")[12]==1&&Labels.Modules(codes[0]).StartsWith("0000000000")&&Labels.Modules(codes[0]).EndsWith("0000000000"));
   var sampleLabel=new[]{new Dictionary<string,object>{{"barcode",codes[0]},{"name","<script>"},{"color","Preta"},{"size","M"}}};
   Check("label export escapes product text",Labels.HtmlWithQr(sampleLabel,50,30).Contains("&lt;script&gt;"));
   Check("QR SVG uses a quiet zone around its 21-module symbol",Labels.QrSvg(codes[0]).Contains("viewBox=\"0 0 29 29\"")&&Labels.QrModules(codes[0]).GetLength(0)==21);
   Check("legacy product labels keep Code128 only",Labels.HtmlWithQr(sampleLabel,50,30).Contains("class=\"barcode\"")&&!Labels.HtmlWithQr(sampleLabel,50,30).Contains("class=\"qr\""));
   var qrLabel=new[]{new Dictionary<string,object>{{"barcode",codes[0]},{"name","Produto QR"},{"color","Verde"},{"size","M"},{"qr_only",true}}};var qrHtml=Labels.HtmlWithQr(qrLabel,50,30);
   Check("QR-only product labels contain QR and no Code128",qrHtml.Contains("viewBox=\"0 0 29 29\"")&&qrHtml.Contains("class=\"qr\"")&&!qrHtml.Contains("class=\"barcode\""));
   Check("QR-only product labels center and enlarge the QR within the label",qrHtml.Contains(".qr-label .qr{left:50%;right:auto;top:50%;width:min(20mm,calc(100% - 12mm));height:min(20mm,calc(100% - 12mm));transform:translate(-50%,-25%)}"));
   Check("label barcode adapts to narrow sizes",!Labels.HtmlWithQr(sampleLabel,40,30).Contains("width:47mm"));
   Check("barcode test fixtures use a reserved internal code",SicStore.IsQrTestFixture(new Dictionary<string,object>{{"internal_code","LB-QR-TEST-01"}})&&!SicStore.IsQrTestFixture(new Dictionary<string,object>{{"internal_code","NORMAL-01"}}));
   Reject("test and regular products stay in separate carts","QR_TEST_MIXED_CART",()=>SicStore.EnsureSingleFixtureGroup(new List<Dictionary<string,object>>{new Dictionary<string,object>{{"internal_code","LB-QR-TEST-01"}},new Dictionary<string,object>{{"internal_code","NORMAL-01"}}}));
   Check("five independent SIC product records",Count(store,"dbo.TABEST1")==5&&units.Select(x=>x["sic_id"]).Distinct().Count()==5);
   Check("initial receipt and five movement rows",Count(store,"dbo.TABEST2A")==1&&Count(store,"dbo.TABEST2B")==5&&Count(store,"lineboard.Movements")==5);
   Check("initial quantities are one",store.Catalog().All(x=>Convert.ToInt32(x["quantity"])==1));
   var replay=store.CreateProduct(draft);Check("product retry returns same units",(bool)replay["replayed"]&&Units(replay).Select(x=>x["barcode"]).SequenceEqual(codes)&&Count(store,"dbo.TABEST1")==5);
   draft.price=90;Reject("changed retry payload rejected","IDEMPOTENCY_CONFLICT",()=>store.CreateProduct(draft));draft.price=89.90m;
   var edit=new EditDraft {request_id=Guid.NewGuid().ToString(),revision=1,name="TESTE Peça individual",brand="Laboratorio",color="Azul",size="G",cost=45,price=99.50m,notes="Ficha individual",location="B2",fiscal=new Dictionary<string,object>{{"codipi","61091000"},{"cean",""}}};
   store.Edit(codes[0],edit);Check("only one unit edited",Convert.ToDecimal(store.Lookup(codes[0])["price"])==99.50m&&store.Catalog().Count(x=>Convert.ToDecimal(x["price"])==89.90m)==4);
   edit.request_id=Guid.NewGuid().ToString();Reject("stale unit edit rejected","REVISION_CONFLICT",()=>store.Edit(codes[0],edit));
   Check("edit audit retained",Count(store,"lineboard.UnitEdits")==1);
   var scan=new CartDraft{request_id=Guid.NewGuid().ToString(),barcode=codes[0]};store.AddCart(scan);
   Check("scanning does not decrement stock",Convert.ToInt32(store.Lookup(codes[0])["quantity"])==1&&Count(store,"dbo.TABEST3A")==0);
   store.AddCart(scan);Check("scan retry is idempotent",Count(store,"lineboard.Cart")==1);
   Reject("same physical unit cannot repeat in cart","ALREADY_IN_CART",()=>store.AddCart(new CartDraft{request_id=Guid.NewGuid().ToString(),barcode=codes[0]}));
   var reopened=new SicStore(server,store.Database,workspace);Check("cart survives connector restart",((List<Dictionary<string,object>>)reopened.Cart()["items"]).Count==1);
   var staleVersion=Convert.ToInt64(store.Cart()["version"]);store.AddCart(new CartDraft{request_id=Guid.NewGuid().ToString(),barcode=codes[1]});
   Reject("changed cart requires renewed confirmation","CART_CHANGED",()=>store.Confirm(new ConfirmDraft{request_id=Guid.NewGuid().ToString(),version=staleVersion,payment="pix"}));
   var confirm=new ConfirmDraft{request_id=Guid.NewGuid().ToString(),version=Convert.ToInt64(store.Cart()["version"]),payment="pix"};
   using(var c=store.Open())SicStore.NonQuery(c,null,"CREATE TRIGGER dbo.LineboardTestFailure ON dbo.TABEST3B AFTER INSERT AS BEGIN IF EXISTS(SELECT 1 FROM inserted WHERE lkproduto="+Convert.ToInt32(units[1]["sic_id"]).ToString(CultureInfo.InvariantCulture)+") THROW 51001,'SIMULATED_LINE_FAILURE',1; END");
   bool failed=false;try{store.Confirm(confirm);}catch(System.Data.SqlClient.SqlException){failed=true;}finally{using(var c=store.Open())SicStore.NonQuery(c,null,"DROP TRIGGER dbo.LineboardTestFailure");}
   Check("forced mid-sale failure rolls back all rows",failed&&Count(store,"dbo.TABEST3A")==0&&Count(store,"dbo.TABEST3B")==0&&Count(store,"dbo.TABEST3R")==0&&Count(store,"lineboard.Cart")==2&&Convert.ToInt32(store.Lookup(codes[0])["quantity"])==1&&Count(store,"lineboard.Outbox")==6);
   var first=Task.Run(()=>store.Confirm(confirm));var second=Task.Run(()=>store.Confirm(confirm));Task.WaitAll(first,second);
   Check("parallel retries produce one sale",first.Result["sale_id"].Equals(second.Result["sale_id"])&&(bool)first.Result["replayed"]!=(bool)second.Result["replayed"]&&Count(store,"dbo.TABEST3A")==1);
   Check("sale recorded in SIC header lines and payment",Count(store,"dbo.TABEST3B")==2&&Count(store,"dbo.TABEST3R")==1);
   Check("sold units are zero and cart cleared",Convert.ToInt32(store.Lookup(codes[0])["quantity"])==0&&Convert.ToInt32(store.Lookup(codes[1])["quantity"])==0&&Count(store,"lineboard.Cart")==0);
   Check("sale does not pretend to process payment or issue tax invoice",(string)first.Result["fiscal_status"]=="not_requested"&&!(bool)first.Result["payment_processed"]);
   Reject("sold code cannot be sold again","INSUFFICIENT_STOCK",()=>store.AddCart(new CartDraft{request_id=Guid.NewGuid().ToString(),barcode=codes[0]}));
   Reject("boleto excluded from first version","INVALID_PAYMENT",()=>store.Confirm(new ConfirmDraft{request_id=Guid.NewGuid().ToString(),version=0,payment="boleto"}));
   store.Adjust(new AdjustmentDraft{request_id=Guid.NewGuid().ToString(),barcode=codes[0],quantity=1,reason="Retorno físico de teste, sem estorno financeiro"});
   Check("stock input preserves original unit barcode",Convert.ToInt32(store.Lookup(codes[0])["quantity"])==1&&Count(store,"dbo.TABINV")==1&&Count(store,"dbo.TABEST1")==5);
   using(var c=store.Open())SicStore.NonQuery(c,null,"UPDATE dbo.TABEST1 SET quantidade=0 WHERE controle=@id","@id",units[2]["sic_id"]);
   Check("external SIC stock modification detected",(bool)store.Lookup(codes[2])["conflict"]);
   Reject("external conflict never silently overwritten","SIC_STOCK_CONFLICT",()=>store.AddCart(new CartDraft{request_id=Guid.NewGuid().ToString(),barcode=codes[2]}));
   Check("outbox persists and remains unsent without cloud credentials",new SicStore(server,store.Database,workspace).Outbox().Count==8&&store.Outbox().All(x=>(string)x["state"]=="pending"));
   var tcp=new TcpListener(IPAddress.Loopback,0);tcp.Start();int port=((IPEndPoint)tcp.LocalEndpoint).Port;tcp.Stop();
   using(var api=new LocalApi(store,"localhost",port)){
    api.Start();Request(api.Address,"GET","api/health",null,null,200);Request(api.Address,"GET","api/catalog",null,null,401);Check("LAN API requires authentication",true);
    var pin=api.OpenPairing();var paired=(Dictionary<string,object>)Request(api.Address,"POST","api/pair",new{pin,name="TESTE Scanner"},null,200);string token=(string)paired["token"];
    Request(api.Address,"POST","api/pair",new{pin,name="Reuse"},null,403);Check("pairing code is one-time",true);
    Request(api.Address,"GET","api/catalog",null,token,200);Check("paired scanner can read real catalog",true);
    Request(api.Address,"POST","api/cart/items",new{request_id=Guid.NewGuid().ToString(),barcode=codes[3]},token,200);
    Check("scanner API adds to desktop cart without sale",Count(store,"lineboard.Cart")==1&&Convert.ToInt32(store.Lookup(codes[3])["quantity"])==1&&Count(store,"dbo.TABEST3A")==1);
    Request(api.Address,"POST","api/cart/confirm",new{},token,404);Check("scanner cannot confirm sale remotely",true);
    using(var c=store.Open())Check("device credential stored as hash",Convert.ToInt32(SicStore.Scalar(c,null,"SELECT COUNT(*) FROM lineboard.Devices WHERE token_hash=@hash","@hash",Json.Hash(token)))==1&&Convert.ToInt32(SicStore.Scalar(c,null,"SELECT COUNT(*) FROM lineboard.Devices WHERE token_hash=@token","@token",token))==0);
   }
   var offlineSync=new CloudSync(store,payload=>{throw new DomainError("SIMULATED_OFFLINE");});
   Reject("cloud transport failure preserves pending events","SIMULATED_OFFLINE",()=>offlineSync.Push());
   Check("no event marked sent without cloud acknowledgement",store.Outbox().All(x=>(string)x["state"]=="pending"));
   var wrongAck=new CloudSync(store,payload=>new Dictionary<string,object>{{"event_id",Guid.NewGuid().ToString()},{"state","applied"}});
   Reject("wrong cloud acknowledgement is rejected","INVALID_CLOUD_ACK",()=>wrongAck.Push());
   var acceptedSync=new CloudSync(store,payload=>new Dictionary<string,object>{{"event_id",payload["event_id"]},{"state","applied"}});
   Check("only matching acknowledgements mark events sent",Convert.ToInt32(acceptedSync.Push()["sent"])==8&&store.Outbox().All(x=>(string)x["state"]=="sent"));
   var previousSalePrice=first.Result["total"];
   store.Edit(codes[0],new EditDraft{request_id=Guid.NewGuid().ToString(),revision=4,name="TESTE ficha corrigida",brand="Laboratorio",color="Azul",size="G",price=15,cost=10});
   using(var c=store.Open())Check("fiscal fields can be cleared without rewriting old sale totals",SicStore.Scalar(c,null,"SELECT codipi FROM dbo.TABEST1 WHERE controle=@id","@id",units[0]["sic_id"])==null&&Convert.ToDecimal(SicStore.Scalar(c,null,"SELECT total FROM lineboard.Sales"))==Convert.ToDecimal(previousSalePrice));
   var conflictSync=new CloudSync(store,payload=>new Dictionary<string,object>{{"event_id",payload["event_id"]},{"state","conflict"},{"reason","CLOUD_STOCK_CONFLICT"}});
   Check("cloud stock conflict is retained for review",Convert.ToString(conflictSync.Push()["state"])=="conflict"&&store.Outbox().Count(x=>(string)x["state"]=="conflict")==1);
   Check("original SIC database unchanged",sourceBefore==Json.Write(Program.Probe(server)));
   return new{passed=passed.Count,tests=passed,database=store.Database,source_unchanged=true,mode="sandbox",native_sic_ui_verified=false,fiscal_issuance_verified=false,cloud_sync_verified=false};
  }
 }
}
