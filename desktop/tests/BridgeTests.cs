using System;
using System.Collections.Generic;
using System.Data.SqlClient;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;

namespace Lineboard {
 // Exercises the bridge contract against a new SQL sandbox.  It intentionally
 // calls DesktopBridge.Process directly; browser rendering is covered only by
 // --render-web-preview, which uses WebView2 CapturePreviewAsync.
 static class BridgeTests {
  static readonly List<string> passed=new List<string>();
  static void Check(string name,bool value){if(!value)throw new Exception("BRIDGE_TEST_FAILED: "+name);passed.Add(name);}
  static Dictionary<string,object> Response(DesktopBridge bridge,string source,string id,string action,object payload) {
   var value=Json.Read<Dictionary<string,object>>(bridge.Process(source,Json.Write(new{id,action,payload})));
   if(value.ContainsKey("ok")&&!Convert.ToBoolean(value["ok"]))throw new Exception("Bridge action failed: "+action+" / "+Convert.ToString(((Dictionary<string,object>)value["error"])["code"]));
   return value;
  }
  static Dictionary<string,object> Error(DesktopBridge bridge,string source,string id,string action,object payload) {
   var value=Json.Read<Dictionary<string,object>>(bridge.Process(source,Json.Write(new{id,action,payload})));
   if(value.ContainsKey("ok")&&Convert.ToBoolean(value["ok"]))throw new Exception("Bridge action unexpectedly succeeded: "+action);
   return (Dictionary<string,object>)value["error"];
  }
  static List<Dictionary<string,object>> Units(Dictionary<string,object> data) { return Json.Read<List<Dictionary<string,object>>>(Json.Write(data["units"])); }
  static int FreePort() { var listener=new TcpListener(IPAddress.Loopback,0);listener.Start();var port=((IPEndPoint)listener.LocalEndpoint).Port;listener.Stop();return port; }
  static object Count(SicStore store,string table){using(var c=store.Open())return SicStore.Scalar(c,null,"SELECT COUNT(*) FROM "+table);}
  public static int Main(string[] args) {
   try {
    if(args.Length<2)throw new Exception("Usage: BridgeTests.exe <workspace> <database>");
    var workspace=Path.GetFullPath(args[0]);var database=args[1];
    if(!database.StartsWith("LINEBOARD_LAB_BRIDGE",StringComparison.Ordinal))throw new Exception("A dedicated bridge sandbox is required.");
    Environment.SetEnvironmentVariable("LINEBOARD_SYNC_URL",null);Environment.SetEnvironmentVariable("LINEBOARD_SYNC_TOKEN",null);
    var store=new SicStore(@"(localdb)\MSSQLLocalDB",database,workspace);
    if(Convert.ToInt64(Count(store,"lineboard.Units"))!=0)throw new Exception("Bridge tests require an empty sandbox.");
    var original=Json.Write(Program.Probe(@"(localdb)\MSSQLLocalDB"));
    var api=new LocalApi(store,"localhost",FreePort());var sync=new CloudSync(store,(Func<Dictionary<string,object>,Dictionary<string,object>>)null);using(var background=new BackgroundSync(sync)) {
     string exported=null;var bridge=new DesktopBridge(store,api,sync,background,html=>{exported=html;return true;});
     var origin=DesktopBridge.Origin;
     var refused=Error(bridge,"https://lineboard.local.evil/","bad-origin","bootstrap",new{});
     Check("untrusted origin is refused",Convert.ToString(refused["code"])=="ORIGIN_REFUSED");
     var unknown=Error(bridge,origin,"unknown","does.not.exist",new{});
     Check("unknown action is refused",Convert.ToString(unknown["code"])=="UNKNOWN_ACTION");
     var empty=Response(bridge,origin,"boot","bootstrap",new{});
     var emptyData=(Dictionary<string,object>)empty["data"];Check("bootstrap starts without demonstration units",Json.Read<List<Dictionary<string,object>>>(Json.Write(emptyData["catalog"])).Count==0);
     var requestId=Guid.NewGuid().ToString();
     var draft=new ProductDraft{request_id=requestId,name="Produto ponte",brand="Laboratorio",cost=10,price=25,location="A1",notes="Fixture isolada da ponte",internal_code="BRIDGE",variants=new List<VariantDraft>{
      new VariantDraft{color="Preta",size="P",quantity=1},new VariantDraft{color="Azul",size="M",quantity=2},new VariantDraft{color="Areia",size="G",quantity=1}}};
     var extraProductPayload=Json.Map(draft);extraProductPayload["unexpected"]="rejected";
     var rejectedProduct=Error(bridge,origin,"extra-product","product.create",extraProductPayload);
     Check("product payload rejects unknown fields",Convert.ToString(rejectedProduct["code"])=="INVALID_PAYLOAD");
     var extraVariantPayload=Json.Map(draft);var variantItems=Json.Read<List<Dictionary<string,object>>>(Json.Write(extraVariantPayload["variants"]));variantItems[0]["unexpected"]="rejected";extraVariantPayload["variants"]=variantItems;
     var rejectedVariant=Error(bridge,origin,"extra-variant","product.create",extraVariantPayload);
     Check("variant payload rejects unknown fields",Convert.ToString(rejectedVariant["code"])=="INVALID_PAYLOAD");
     var created=Response(bridge,origin,"create","product.create",draft);var units=Units((Dictionary<string,object>)created["data"]);var codes=units.Select(x=>Convert.ToString(x["barcode"])).ToList();
     Check("three variants create four independently coded pieces",units.Count==4&&codes.Distinct().Count()==4);
     var replay=Response(bridge,origin,"create-retry","product.create",draft);Check("product retry is idempotent",Convert.ToBoolean(((Dictionary<string,object>)replay["data"])["replayed"]));
     Check("idempotent product retry does not duplicate SIC rows",Convert.ToInt64(Count(store,"dbo.TABEST1"))==4);
     var found=Response(bridge,origin,"lookup","unit.get",new{barcode=codes[0]});Check("unit lookup returns the requested physical code",Convert.ToString(((Dictionary<string,object>)found["data"])["barcode"])==codes[0]);
     var current=(Dictionary<string,object>)found["data"];var editDraft=new EditDraft{request_id=Guid.NewGuid().ToString(),revision=Convert.ToInt64(current["revision"]),name="Produto ponte editado",brand="Laboratorio",color="Preta",size="P",cost=10,price=26,location="A2",notes="Edição pela ponte",internal_code="BRIDGE"};
     var edited=Response(bridge,origin,"edit","unit.edit",new{barcode=codes[0],draft=editDraft});Check("unit edit uses the nested contract and preserves barcode",Convert.ToString(((Dictionary<string,object>)edited["data"])["barcode"])==codes[0]&&Convert.ToString(((Dictionary<string,object>)edited["data"])["name"])=="Produto ponte editado");
     var addPayload=new CartDraft{request_id=Guid.NewGuid().ToString(),barcode=codes[0]};Response(bridge,origin,"add","cart.add",addPayload);Response(bridge,origin,"add-retry","cart.add",addPayload);
     var retryCartData=(Dictionary<string,object>)Response(bridge,origin,"cart","bootstrap",new{})["data"];var retryCart=(Dictionary<string,object>)retryCartData["cart"];
     Check("cart retry remains one item",Convert.ToInt64(Count(store,"lineboard.Cart"))==1&&Json.Read<List<Dictionary<string,object>>>(Json.Write(retryCart["items"])).Count==1);
     Response(bridge,origin,"add-two","cart.add",new CartDraft{request_id=Guid.NewGuid().ToString(),barcode=codes[1]});
     var cart=(Dictionary<string,object>)((Dictionary<string,object>)Response(bridge,origin,"cart-two","bootstrap",new{})["data"])["cart"];var version=Convert.ToInt64(cart["version"]);
     var salePayload=new ConfirmDraft{request_id=Guid.NewGuid().ToString(),version=version,payment="cash",fiscal_document="nfce"};var sale=Response(bridge,origin,"sale","cart.confirm",salePayload);var saleData=(Dictionary<string,object>)sale["data"];
     Check("sale requests NFC-e in the new interface",Convert.ToString(saleData["fiscal_document"])=="nfce"&&Convert.ToString(saleData["fiscal_status"])=="pending_adapter");
     var saleRetry=Response(bridge,origin,"sale-retry","cart.confirm",salePayload);Check("sale confirmation is idempotent",Convert.ToBoolean(((Dictionary<string,object>)saleRetry["data"])["replayed"]));
     var report=(Dictionary<string,object>)Response(bridge,origin,"sales-report","sales.report",new{from="2026-01-01T00:00:00.0000000Z",to="2027-01-01T00:00:00.0000000Z",brand="",category="",payment="",query=""})["data"];
     var reportSummary=(Dictionary<string,object>)report["summary"];
     Check("sales report returns the confirmed sale",Convert.ToInt32(reportSummary["sales"])==1&&Convert.ToDecimal(reportSummary["items"])==2&&Json.Read<List<Dictionary<string,object>>>(Json.Write(report["rows"])).Count==2);
     Check("sale leaves one SIC header and clears cart",Convert.ToInt64(Count(store,"dbo.TABEST3A"))==1&&Convert.ToInt64(Count(store,"lineboard.Cart"))==0);
      var mobileCreated=store.CreateProduct(new ProductDraft{request_id=Guid.NewGuid().ToString(),name="Venda mobile atomica",brand="Laboratorio",category="Camiseta",cost=8,price=19,location="A3",variants=new List<VariantDraft>{new VariantDraft{color="Verde",size="M",quantity=2}}});
      var mobileCodes=Units(mobileCreated).Select(x=>Convert.ToString(x["barcode"])).ToList();
      var mobileSale=store.ConfirmLines(new ConfirmLinesDraft{request_id=Guid.NewGuid().ToString(),payment="pix",lines=mobileCodes.Select(code=>new SaleLineDraft{barcode=code,quantity=1}).ToList()});
      Check("mobile sale writes all SIC and Lineboard rows in one operation",Convert.ToInt64(Count(store,"dbo.TABEST3A"))==2&&Convert.ToInt64(Count(store,"dbo.TABEST3B"))==4&&Convert.ToInt64(Count(store,"lineboard.Sales"))==2&&Convert.ToInt32(mobileSale["sic_sale_id"])>0);
      var salesBeforeRollback=Convert.ToInt64(Count(store,"dbo.TABEST3A"));try{store.ConfirmLines(new ConfirmLinesDraft{request_id=Guid.NewGuid().ToString(),payment="pix",lines=new List<SaleLineDraft>{new SaleLineDraft{barcode=mobileCodes[0],quantity=1},new SaleLineDraft{barcode="SLB-900999999999",quantity=1}}});throw new Exception("expected mobile sale rollback");}catch(DomainError error){if(error.Code!="BARCODE_NOT_FOUND")throw;}
      Check("mobile sale failure rolls back every native row",Convert.ToInt64(Count(store,"dbo.TABEST3A"))==salesBeforeRollback&&Convert.ToInt64(store.Lookup(mobileCodes[0])["quantity"])==0);
     var labelPreview=Response(bridge,origin,"labels","labels.preview",new{});Check("labels preview is generated by the existing label renderer",Convert.ToString(((Dictionary<string,object>)labelPreview["data"])["html"]).Contains(codes[2]));
     var labelExport=Response(bridge,origin,"labels-export","labels.export",new{});Check("labels export uses the host callback",Convert.ToBoolean(((Dictionary<string,object>)labelExport["data"])["saved"])&&exported!=null);
     var history=Response(bridge,origin,"history","history.list",new{});Check("history is read through SicStore",Json.Read<List<Dictionary<string,object>>>(Json.Write(((Dictionary<string,object>)history["data"])["items"])).Count>0);
     using(var c=store.Open())SicStore.NonQuery(c,null,"UPDATE lineboard.Outbox SET state='sent'");
     var outboxBefore=store.Outbox().Count;
     Check("shared store snapshot adds the scanned item to the desktop cart",store.ImportSharedCart(Json.Map(new{version=1,barcodes=new[]{codes[2]}}))&&Convert.ToInt64(Count(store,"lineboard.Cart"))==1);
     Check("shared cart replay neither duplicates items nor creates echo events",!store.ImportSharedCart(Json.Map(new{version=1,barcodes=new[]{codes[2]}}))&&store.Outbox().Count==outboxBefore);
     store.AddCart(new CartDraft{request_id=Guid.NewGuid().ToString(),barcode=codes[3]});
     Check("pending local cart events prevent a stale cloud snapshot erasing an edit",!store.ImportSharedCart(Json.Map(new{version=2,barcodes=new string[0]}))&&Convert.ToInt64(Count(store,"lineboard.Cart"))==2);
     using(var c=store.Open())SicStore.NonQuery(c,null,"UPDATE lineboard.Outbox SET state='sent'");
     var soldRemote=store.Lookup(codes[2]);soldRemote["revision"]=Convert.ToInt64(soldRemote["revision"])+1;soldRemote["quantity"]=0;soldRemote["expected_quantity"]=0;
     var importedRemote=store.ImportCloudSnapshot(Json.Map(new{units=new[]{soldRemote}}));
     Check("a sale on another desktop updates existing native SIC stock",Convert.ToInt32(importedRemote["updated"])==1&&Convert.ToInt32(store.Lookup(codes[2])["quantity"])==0);
     store.ImportSharedCart(Json.Map(new{version=3,barcodes=new string[0]}));
     Check("the sold item disappears from every shared desktop cart",Convert.ToInt64(Count(store,"lineboard.Cart"))==0);
     Check("an older shared snapshot cannot restore a removed cart item",!store.ImportSharedCart(Json.Map(new{version=2,barcodes=new[]{codes[3]}}))&&Convert.ToInt64(Count(store,"lineboard.Cart"))==0);
     store.AddCart(new CartDraft{request_id=Guid.NewGuid().ToString(),barcode=codes[3]});
     var guardedSale=new ConfirmDraft{request_id=Guid.NewGuid().ToString(),version=Convert.ToInt64(store.Cart()["version"]),payment="pix"};
     var claims=0;var releases=0;store.ClaimCheckout=(request,items)=>{claims++;};store.ReleaseCheckout=request=>releases++;
     using(var c=store.Open())SicStore.NonQuery(c,null,"CREATE TRIGGER lineboard.TestCheckoutFailure ON lineboard.Sales AFTER INSERT AS THROW 51001,'TEST_CHECKOUT_FAILURE',1;");
     try{store.Confirm(guardedSale);throw new Exception("expected checkout failure");}catch(SqlException error){if(!error.Message.Contains("TEST_CHECKOUT_FAILURE"))throw;}finally{using(var c=store.Open())SicStore.NonQuery(c,null,"DROP TRIGGER lineboard.TestCheckoutFailure");}
     Check("native rollback releases the cloud checkout without selling a piece",claims==1&&releases==1&&Convert.ToInt32(store.Lookup(codes[3])["quantity"])==1);
     var guardedReceipt=store.Confirm(guardedSale);
     Check("a successful checkout persists its claim identity for delivery",Convert.ToString(guardedReceipt["checkout_request_id"])==guardedSale.request_id&&claims==2&&releases==1);
     guardedSale.version++;
     try{store.Confirm(guardedSale);throw new Exception("expected idempotency conflict");}catch(DomainError error){if(error.Code!="IDEMPOTENCY_CONFLICT")throw;}
     Check("a changed retry cannot release the claim of an already committed sale",releases==1);
     var settings=Response(bridge,origin,"settings","settings.info",new{});Check("settings do not expose cloud credentials",!Json.Write(settings).Contains("LINEBOARD_SYNC_TOKEN"));
     Check("original SIC database remains unchanged",original==Json.Write(Program.Probe(@"(localdb)\MSSQLLocalDB")));
    }
    Console.WriteLine(Json.Write(new{passed=passed.Count,tests=passed,database,source_unchanged=true,mode="sandbox"}));return 0;
   }catch(Exception error){Console.Error.WriteLine(error.ToString());return 1;}
  }
 }
}
