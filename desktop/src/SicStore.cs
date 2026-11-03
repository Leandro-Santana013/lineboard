using System;
using System.Collections.Generic;
using System.Data;
using System.Data.SqlClient;
using System.Globalization;
using System.IO;
using System.Linq;

namespace Lineboard {
 public sealed class SicStore {
  readonly string connectionString; readonly bool production; public readonly string Database; public readonly string InstanceId; public bool Production { get { return production; } }
  public event Action Changed;
  internal Action PrepareCheckout;
  internal Action<string,List<Dictionary<string,object>>> ClaimCheckout;
  internal Action<string> ReleaseCheckout;
  public SicStore(string server,string database,string workspace,bool allowProduction=false) {
   var lab=System.Text.RegularExpressions.Regex.IsMatch(database,@"^LINEBOARD_LAB(_[A-Za-z0-9]+)?$");
   production=!lab;
   if((!lab&&(!allowProduction||!String.Equals(database,"SICNET",StringComparison.OrdinalIgnoreCase)))||
      (allowProduction&&!String.Equals(database,"SICNET",StringComparison.OrdinalIgnoreCase)))throw new DomainError("SANDBOX_ONLY");
   var builder=new SqlConnectionStringBuilder {DataSource=server,InitialCatalog=database,IntegratedSecurity=true,ConnectTimeout=8,ApplicationName="Lineboard Sandbox Connector"};
   connectionString=builder.ConnectionString;Database=database;
   using(var c=Open()) {
    if(lab){
     var root=Path.GetFullPath(Path.Combine(workspace,".local","sic-lab"))+Path.DirectorySeparatorChar;
     foreach(var file in Rows(c,null,"SELECT physical_name FROM sys.database_files"))
      if(!Path.GetFullPath((string)file["physical_name"]).StartsWith(root,StringComparison.OrdinalIgnoreCase))throw new DomainError("SANDBOX_PATH_REQUIRED");
     if(Scalar(c,null,"SELECT OBJECT_ID('dbo.LineboardSandboxMarker')")==null)throw new DomainError("SANDBOX_MARKER_REQUIRED");
     InstanceId=Convert.ToString(Scalar(c,null,"SELECT instance_id FROM dbo.LineboardSandboxMarker WHERE id=1"));
     if(String.IsNullOrEmpty(InstanceId))throw new DomainError("SANDBOX_MARKER_REQUIRED");
    } else {
     NonQuery(c,null,"IF OBJECT_ID('dbo.LineboardProductionMarker') IS NULL BEGIN CREATE TABLE dbo.LineboardProductionMarker (id int PRIMARY KEY CHECK(id=1),instance_id uniqueidentifier NOT NULL,created_at datetime2 NOT NULL DEFAULT SYSUTCDATETIME()); INSERT dbo.LineboardProductionMarker(id,instance_id) VALUES(1,NEWID()); END");
     InstanceId=Convert.ToString(Scalar(c,null,"SELECT instance_id FROM dbo.LineboardProductionMarker WHERE id=1"));
     if(String.IsNullOrEmpty(InstanceId))throw new DomainError("PRODUCTION_MARKER_REQUIRED");
    }
    foreach(var table in new[]{"TABEST1","TABEST2A","TABEST2B","TABEST3A","TABEST3B","TABEST3R","TABEST6","TABEST7","TABINV"})
     if(Scalar(c,null,"SELECT OBJECT_ID(@table)","@table","dbo."+table)==null)throw new DomainError("SIC_SCHEMA_UNSUPPORTED");
    NonQuery(c,null,File.ReadAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"schema.sql")));
   }
  }
  internal SqlConnection Open(){var c=new SqlConnection(connectionString);c.Open();return c;}
  internal static SqlCommand Command(SqlConnection c,SqlTransaction tx,string sql,params object[] args){
   var cmd=new SqlCommand(sql,c,tx){CommandTimeout=15};
   for(int i=0;i<args.Length;i+=2)cmd.Parameters.AddWithValue((string)args[i],args[i+1]??DBNull.Value);return cmd;
  }
  internal static object Scalar(SqlConnection c,SqlTransaction tx,string sql,params object[] args){using(var cmd=Command(c,tx,sql,args)){var v=cmd.ExecuteScalar();return v==DBNull.Value?null:v;}}
  internal static int NonQuery(SqlConnection c,SqlTransaction tx,string sql,params object[] args){using(var cmd=Command(c,tx,sql,args))return cmd.ExecuteNonQuery();}
  internal static List<Dictionary<string,object>> Rows(SqlConnection c,SqlTransaction tx,string sql,params object[] args){
   using(var cmd=Command(c,tx,sql,args))using(var r=cmd.ExecuteReader()){
    var rows=new List<Dictionary<string,object>>();while(r.Read()){var row=new Dictionary<string,object>();for(int i=0;i<r.FieldCount;i++){
     var value=r.IsDBNull(i)?null:r.GetValue(i);if(value is DateTime)value=((DateTime)value).ToString("o");if(value is Guid)value=value.ToString();row[r.GetName(i)]=value;
    }rows.Add(row);}return rows;
   }
  }
  Dictionary<string,object> Execute(string kind,string requestId,object input,Func<SqlConnection,SqlTransaction,Guid,Dictionary<string,object>> action){
   var id=Validation.Id(requestId);var hash=Json.Hash(Json.Canonical(Json.Map(input)));
   using(var c=Open())using(var tx=c.BeginTransaction(IsolationLevel.Serializable)){
    bool commitAttempted=false;
    try{
     NonQuery(c,tx,"DECLARE @result int; EXEC @result=sys.sp_getapplock @Resource=N'lineboard:writer',@LockMode='Exclusive',@LockOwner='Transaction',@LockTimeout=10000; IF @result<0 THROW 51000,'WRITER_BUSY',1;");
     var previous=Rows(c,tx,"SELECT kind,request_hash,response FROM lineboard.Operations WHERE id=@id","@id",id).SingleOrDefault();
     if(previous!=null){
      if((string)previous["kind"]!=kind||(string)previous["request_hash"]!=hash)throw new DomainError("IDEMPOTENCY_CONFLICT");
       var replay=Json.Read<Dictionary<string,object>>((string)previous["response"]);replay["replayed"]=true;commitAttempted=true;tx.Commit();return replay;
     }
     var result=action(c,tx,id);result["replayed"]=false;
     NonQuery(c,tx,"INSERT lineboard.Operations(id,kind,request_hash,response) VALUES(@id,@kind,@hash,@response)","@id",id,"@kind",kind,"@hash",hash,"@response",Json.Write(result));
     commitAttempted=true;tx.Commit();
     try{var changed=Changed;if(changed!=null)changed();}catch{}
     return result;
     }catch{bool rolledBack=false;try{if(tx.Connection!=null){tx.Rollback();rolledBack=true;}else rolledBack=!commitAttempted;}catch{}if(rolledBack&&kind=="sale.confirm"&&ReleaseCheckout!=null){try{if(Convert.ToInt32(Scalar(c,null,"SELECT COUNT(*) FROM lineboard.Operations WHERE id=@id","@id",id))==0)ReleaseCheckout(requestId);}catch{}}throw;}
   }
  }
  static void Event(SqlConnection c,SqlTransaction tx,string kind,object payload){
   NonQuery(c,tx,"INSERT lineboard.Outbox(event_id,kind,payload) VALUES(@id,@kind,@payload)","@id",Guid.NewGuid(),"@kind",kind,"@payload",Json.Write(payload));
  }
  public Dictionary<string,object> Health(){using(var c=Open())return new Dictionary<string,object>{{"mode",production?"production":"sandbox"},{"database",Database},{"instance_id",InstanceId},{"pending",Scalar(c,null,"SELECT COUNT(*) FROM lineboard.Outbox WHERE state='pending'")},{"fiscal_issuance","unavailable"},{"production_writes",production},{"sicnet_write_mode",production?"atomic":"sandbox"}};}
  const string CatalogSql=@"SELECT u.id AS stock_item_id,u.product_id,u.variant_id,u.sic_id,u.barcode,u.category,u.color,u.size,u.location,u.photo AS photo_path,u.revision,u.expected_quantity,
   p.produto AS name,p.fabricante AS brand,p.precocusto AS cost,p.precovenda AS price,p.quantidade AS quantity,p.obs AS notes,p.codinterno AS internal_code,
   p.codipi,p.cst,p.ipi,p.icms,p.basecalculo,p.pesobruto,p.pesoliq,p.ipi_cst,p.ipi_basecalc,p.cean,p.ceantrib,p.cprodanp,p.cest,p.origem,p.cst_pis,p.cst_cofins,p.cbenef,p.fcp,p.cst_ibscbs,p.cclasstrib
   FROM lineboard.Units u JOIN dbo.TABEST1 p ON p.controle=u.sic_id";
  Dictionary<string,object> Enrich(Dictionary<string,object> row){row["organization_id"]=InstanceId;row["tracking"]="individual";row["category"]=Convert.ToString(row["category"]??"");row["model"]="";row["conflict"]=Convert.ToDecimal(row["quantity"]??0)!=Convert.ToDecimal(row["expected_quantity"]);return row;}
  public List<Dictionary<string,object>> Catalog(){using(var c=Open())return Rows(c,null,CatalogSql+" ORDER BY u.barcode").Select(Enrich).ToList();}
  Dictionary<string,object> Unit(SqlConnection c,SqlTransaction tx,string barcode){
   var row=Rows(c,tx,CatalogSql+" WHERE u.barcode=@barcode","@barcode",barcode).SingleOrDefault();if(row==null)throw new DomainError("BARCODE_NOT_FOUND");return Enrich(row);
  }
  public Dictionary<string,object> Lookup(string barcode){using(var c=Open())return Unit(c,null,Validation.Barcode(barcode));}
  static UnitFields FieldsFrom(Dictionary<string,object> row){
   var f=new UnitFields{name=(string)row["name"],brand=(string)row["brand"],category=Convert.ToString(row["category"]),color=(string)row["color"],size=(string)row["size"],location=(string)row["location"],photo=(string)row["photo_path"],notes=Convert.ToString(row["notes"]),internal_code=Convert.ToString(row["internal_code"]),cost=Convert.ToDecimal(row["cost"]??0),price=Convert.ToDecimal(row["price"]??0),fiscal=new Dictionary<string,object>()};
   foreach(var name in Fiscal.TextFields.Keys.Concat(Fiscal.Numbers))if(row.ContainsKey(name)&&row[name]!=null)f.fiscal[name]=row[name];return f;
  }
  static void WriteFields(SqlConnection c,SqlTransaction tx,int sicId,UnitFields f){
   NonQuery(c,tx,"UPDATE dbo.TABEST1 SET produto=@name,fabricante=@brand,precocusto=@cost,customedio=@cost,precovenda=@price,obs=@notes,codinterno=@internal WHERE controle=@id", "@name",f.name,"@brand",f.brand,"@cost",f.cost,"@price",f.price,"@notes",f.notes,"@internal",f.internal_code,"@id",sicId);
   NonQuery(c,tx,"UPDATE lineboard.Units SET category=@category WHERE sic_id=@id","@category",f.category,"@id",sicId);
   foreach(var name in Fiscal.TextFields.Keys.Concat(Fiscal.Numbers))NonQuery(c,tx,"UPDATE dbo.TABEST1 SET ["+name+"]=@value WHERE controle=@id","@value",f.fiscal.ContainsKey(name)?f.fiscal[name]:null,"@id",sicId);
  }
  static void CheckQuantity(Dictionary<string,object> unit){if((bool)unit["conflict"])throw new DomainError("SIC_STOCK_CONFLICT");}
  public Dictionary<string,object> CreateProduct(ProductDraft draft){
   Validation.Fields(draft);if(draft.variants==null||draft.variants.Count==0||draft.variants.Count>100)throw new DomainError("INVALID_VARIANTS");
   var variants=new HashSet<string>();int total=0;
   foreach(var v in draft.variants){v.color=Validation.Text(v.color,40,false);v.size=Validation.Text(v.size,40,false);if(v.quantity<1||v.quantity>500||!variants.Add(v.color+"\0"+v.size))throw new DomainError("INVALID_VARIANTS");total+=v.quantity;}
   if(total>1000)throw new DomainError("TOO_MANY_UNITS");
   return Execute("product.create",draft.request_id,draft,(c,tx,operation)=>{
    var product=Guid.NewGuid();var created=new List<object>();
    int receipt=Convert.ToInt32(Scalar(c,tx,"INSERT dbo.TABEST2A(data,nota,obs,frete,tipo) OUTPUT inserted.controle VALUES(CONVERT(date,GETDATE()),0,@note,0,'E')","@note","Lineboard: cadastro inicial "+operation));
    foreach(var variant in draft.variants){var variantId=Guid.NewGuid();for(int n=0;n<variant.quantity;n++){
     var code="SLB-"+Convert.ToInt64(Scalar(c,tx,"SELECT NEXT VALUE FOR lineboard.BarcodeNumber")).ToString("D12");
     if(Convert.ToInt32(Scalar(c,tx,"SELECT COUNT(*) FROM dbo.TABEST1 WHERE codigo=@code","@code",code))!=0)throw new DomainError("BARCODE_COLLISION");
     int sicId=Convert.ToInt32(Scalar(c,tx,@"INSERT dbo.TABEST1(codigo,codinterno,produto,fabricante,precocusto,customedio,precovenda,quantidade,estminimo,unidade,lucro,comissao,moeda,obs,inativo,naosaitabela,datainc,qntembalagem)
       OUTPUT inserted.controle VALUES(@code,@internal,@name,@brand,@cost,@cost,@price,1,0,'UN',0,0,'R$',@notes,0,0,GETDATE(),1)","@code",code,"@internal",draft.internal_code,"@name",draft.name,"@brand",draft.brand,"@cost",draft.cost,"@price",draft.price,"@notes",draft.notes));
     WriteFields(c,tx,sicId,draft);var unitId=Guid.NewGuid();
     NonQuery(c,tx,"INSERT lineboard.Units(id,product_id,variant_id,sic_id,barcode,category,color,size,location,photo,expected_quantity) VALUES(@id,@product,@variant,@sic,@code,@category,@color,@size,@location,@photo,1)","@id",unitId,"@product",product,"@variant",variantId,"@sic",sicId,"@code",code,"@category",draft.category,"@color",variant.color,"@size",variant.size,"@location",draft.location,"@photo",draft.photo);
     NonQuery(c,tx,"INSERT dbo.TABEST2B(lkest2a,lkproduto,quantidade,total,icms,valoripi,datainc,saiu) VALUES(@receipt,@sic,1,@cost,0,0,CONVERT(date,GETDATE()),0)","@receipt",receipt,"@sic",sicId,"@cost",draft.cost);
     NonQuery(c,tx,"INSERT lineboard.Movements(operation_id,unit_id,delta,reason,sic_document_id) VALUES(@operation,@unit,1,'initial',@receipt)","@operation",operation,"@unit",unitId,"@receipt",receipt);
     var item=Unit(c,tx,code);created.Add(item);Event(c,tx,"unit.upsert",item);
    }}return new Dictionary<string,object>{{"product_id",product.ToString()},{"units",created},{"sic_receipt_id",receipt}};
   });
  }
  public Dictionary<string,object> Edit(string barcode,EditDraft draft){
   barcode=Validation.Barcode(barcode);Validation.Fields(draft);
   return Execute("unit.edit",draft.request_id,new{barcode,draft},(c,tx,operation)=>{
    var before=Unit(c,tx,barcode);CheckQuantity(before);if(Convert.ToInt64(before["revision"])!=draft.revision)throw new DomainError("REVISION_CONFLICT");
    WriteFields(c,tx,Convert.ToInt32(before["sic_id"]),draft);
    var variant=Scalar(c,tx,"SELECT TOP(1) variant_id FROM lineboard.Units WHERE product_id=@product AND color=@color AND size=@size","@product",Validation.Id((string)before["product_id"]),"@color",draft.color,"@size",draft.size)??(object)Guid.NewGuid();
    NonQuery(c,tx,"UPDATE lineboard.Units SET variant_id=@variant,category=@category,color=@color,size=@size,location=@location,photo=@photo,revision=revision+1,updated_at=SYSUTCDATETIME() WHERE barcode=@code","@variant",variant,"@category",draft.category,"@color",draft.color,"@size",draft.size,"@location",draft.location,"@photo",draft.photo,"@code",barcode);
    var after=Unit(c,tx,barcode);NonQuery(c,tx,"INSERT lineboard.UnitEdits(operation_id,unit_id,before_json,after_json) VALUES(@operation,@unit,@before,@after)","@operation",operation,"@unit",Validation.Id((string)before["stock_item_id"]),"@before",Json.Write(before),"@after",Json.Write(after));
    if(!String.Equals(Convert.ToString(before["photo_path"]),draft.photo,StringComparison.Ordinal)){
     var siblings=Rows(c,tx,"SELECT barcode FROM lineboard.Units WHERE product_id=@product AND barcode<>@code ORDER BY barcode","@product",Validation.Id((string)before["product_id"]),"@code",barcode);
     foreach(var sibling in siblings){
      var code=Convert.ToString(sibling["barcode"]);var siblingBefore=Unit(c,tx,code);
      NonQuery(c,tx,"UPDATE lineboard.Units SET photo=@photo,revision=revision+1,updated_at=SYSUTCDATETIME() WHERE barcode=@code","@photo",draft.photo,"@code",code);
      var siblingAfter=Unit(c,tx,code);NonQuery(c,tx,"INSERT lineboard.UnitEdits(operation_id,unit_id,before_json,after_json) VALUES(@operation,@unit,@before,@after)","@operation",operation,"@unit",Validation.Id((string)siblingBefore["stock_item_id"]),"@before",Json.Write(siblingBefore),"@after",Json.Write(siblingAfter));
      Event(c,tx,"unit.upsert",siblingAfter);
     }
    }
    NonQuery(c,tx,"UPDATE lineboard.Settings SET cart_version=cart_version+1 WHERE id=1");Event(c,tx,"unit.upsert",after);return after;
   });
  }
  public Dictionary<string,object> Cart(){using(var c=Open())using(var tx=c.BeginTransaction(IsolationLevel.RepeatableRead)){
   var version=Convert.ToInt64(Scalar(c,tx,"SELECT cart_version FROM lineboard.Settings WHERE id=1"));
   var items=Rows(c,tx,CatalogSql+" JOIN lineboard.Cart cart ON cart.unit_id=u.id ORDER BY u.barcode").Select(Enrich).ToList();
   tx.Commit();return new Dictionary<string,object>{{"version",version},{"items",items},{"total",items.Sum(x=>Convert.ToDecimal(x["price"]??0))}};
  }}
  public Dictionary<string,object> AddCart(CartDraft draft){
   draft.barcode=Validation.Barcode(draft.barcode);
   return Execute("cart.add",draft.request_id,draft,(c,tx,op)=>{
    var unit=Unit(c,tx,draft.barcode);CheckQuantity(unit);if(Convert.ToDecimal(unit["quantity"])!=1)throw new DomainError("INSUFFICIENT_STOCK");
    if(Convert.ToInt32(Scalar(c,tx,"SELECT COUNT(*) FROM lineboard.Cart WHERE unit_id=@id","@id",Validation.Id((string)unit["stock_item_id"])))>0)throw new DomainError("ALREADY_IN_CART");
    NonQuery(c,tx,"INSERT lineboard.Cart(unit_id) VALUES(@id)","@id",Validation.Id((string)unit["stock_item_id"]));NonQuery(c,tx,"UPDATE lineboard.Settings SET cart_version=cart_version+1 WHERE id=1");
    Event(c,tx,"cart.added",new{barcode=draft.barcode});
    return new Dictionary<string,object>{{"added",draft.barcode},{"version",Scalar(c,tx,"SELECT cart_version FROM lineboard.Settings WHERE id=1")}};
   });
  }
  public Dictionary<string,object> RemoveCart(CartDraft draft){
   draft.barcode=Validation.Barcode(draft.barcode);return Execute("cart.remove",draft.request_id,draft,(c,tx,op)=>{
    NonQuery(c,tx,"DELETE cart FROM lineboard.Cart cart JOIN lineboard.Units u ON u.id=cart.unit_id WHERE u.barcode=@code","@code",draft.barcode);NonQuery(c,tx,"UPDATE lineboard.Settings SET cart_version=cart_version+1 WHERE id=1");Event(c,tx,"cart.removed",new{barcode=draft.barcode});return new Dictionary<string,object>{{"removed",draft.barcode}};
   });
  }
  public Dictionary<string,object> Confirm(ConfirmDraft draft){
   var paymentNames=new Dictionary<string,string>{{"pix","PIX"},{"cash","Dinheiro"},{"credit","Cartão de crédito"},{"debit","Cartão de débito"},{"google_pay","Cartão de crédito"}};
   if(draft.payment==null||!paymentNames.ContainsKey(draft.payment))throw new DomainError("INVALID_PAYMENT");
   var fiscalDocument=String.IsNullOrWhiteSpace(draft.fiscal_document)?null:draft.fiscal_document;
   if(fiscalDocument!=null&&fiscalDocument!="nfce"&&fiscalDocument!="nfe")throw new DomainError("INVALID_FISCAL_DOCUMENT");
   var fiscalStatus=fiscalDocument==null?"not_requested":"pending_adapter";
   if(PrepareCheckout!=null)PrepareCheckout();
   return Execute("sale.confirm",draft.request_id,draft,(c,tx,operation)=>{
    if(Convert.ToInt64(Scalar(c,tx,"SELECT cart_version FROM lineboard.Settings WHERE id=1"))!=draft.version)throw new DomainError("CART_CHANGED");
    var items=Rows(c,tx,CatalogSql+" JOIN lineboard.Cart cart ON cart.unit_id=u.id ORDER BY u.barcode").Select(Enrich).ToList();if(items.Count==0)throw new DomainError("EMPTY_CART");
    foreach(var item in items){CheckQuantity(item);if(Convert.ToDecimal(item["quantity"])!=1)throw new DomainError("INSUFFICIENT_STOCK");}
    var total=items.Sum(x=>Convert.ToDecimal(x["price"]??0));if(total<=0)throw new DomainError("PRICE_REQUIRED");
    object paymentId=Scalar(c,tx,"SELECT controle FROM dbo.TABEST7 WHERE recebimento=@name","@name",paymentNames[draft.payment]);
    object typeId=Scalar(c,tx,"SELECT controle FROM dbo.TABEST6 WHERE tipo=@name","@name",draft.payment=="pix"||draft.payment=="cash"?"Venda a vista":"Venda com cartão");
    if(paymentId==null||typeId==null)throw new DomainError("SIC_LOOKUP_MISSING");
    if(ClaimCheckout!=null)ClaimCheckout(draft.request_id,items);
    int saleId=Convert.ToInt32(Scalar(c,tx,@"INSERT dbo.TABEST3A(data,hora,lktipo,nota,pedido,lkreceb,obs,venda,cancelada,valorfrete,cgi,tagcliente,comissao,comissaovend)
     OUTPUT inserted.controle VALUES(CONVERT(date,GETDATE()),CONVERT(time,GETDATE()),@type,0,0,@payment,@note,1,0,0,0,0,0,0)","@type",typeId,"@payment",paymentId,"@note","Lineboard "+operation));
    var id=Guid.NewGuid();
    foreach(var item in items){
     int changed=NonQuery(c,tx,"UPDATE dbo.TABEST1 SET quantidade=quantidade-1 WHERE controle=@id AND quantidade=1","@id",item["sic_id"]);if(changed!=1)throw new DomainError("INSUFFICIENT_STOCK");
     NonQuery(c,tx,"INSERT dbo.TABEST3B(lkest3a,quantidade,lkproduto,total,totvenda,lucro,acrescimo,datainc,icms,quantcanc,valorcanc,comissaoprod) VALUES(@sale,1,@sic,@price,@price,@profit,0,GETDATE(),0,0,0,0)","@sale",saleId,"@sic",item["sic_id"],"@price",item["price"],"@profit",Convert.ToDecimal(item["price"])-Convert.ToDecimal(item["cost"]));
     NonQuery(c,tx,"UPDATE lineboard.Units SET expected_quantity=0,revision=revision+1,updated_at=SYSUTCDATETIME() WHERE id=@unit; INSERT lineboard.Movements(operation_id,unit_id,delta,reason,sic_document_id) VALUES(@op,@unit,-1,'sale',@sale)","@unit",Validation.Id((string)item["stock_item_id"]),"@op",operation,"@sale",saleId);
    }
    NonQuery(c,tx,"INSERT dbo.TABEST3R(lkest3a,lkest7,valor,pgtroco) VALUES(@sale,@payment,@total,0)","@sale",saleId,"@payment",paymentId,"@total",total);
    NonQuery(c,tx,"INSERT lineboard.Sales(id,operation_id,sic_id,payment,total,fiscal_status) VALUES(@id,@op,@sale,@payment,@total,@fiscal_status); DELETE FROM lineboard.Cart; UPDATE lineboard.Settings SET cart_version=cart_version+1 WHERE id=1;","@id",id,"@op",operation,"@sale",saleId,"@payment",draft.payment,"@total",total,"@fiscal_status",fiscalStatus);
    var result=new Dictionary<string,object>{{"sale_id",id.ToString()},{"sic_sale_id",saleId},{"total",total},{"items",items},{"fiscal_document",fiscalDocument},{"fiscal_status",fiscalStatus},{"payment_recorded",true},{"payment_processed",false},{"native_sic_validation","pending"}};
    if(ClaimCheckout!=null)result["checkout_request_id"]=draft.request_id;
    Event(c,tx,"sale.confirmed",result);return result;
   });
  }
  // Mobile commands arrive as one sale payload. Keep line resolution, native
  // SIC rows, Lineboard audit rows, and the outbox event in one SQL transaction
  // instead of adding the cart one item at a time.
  public Dictionary<string,object> ConfirmLines(ConfirmLinesDraft draft){
   if(draft==null||draft.lines==null||draft.lines.Count==0||draft.lines.Count>200)throw new DomainError("INVALID_LINES");
   var paymentNames=new Dictionary<string,string>{{"pix","PIX"},{"cash","Dinheiro"},{"credit","Cart\u00e3o de cr\u00e9dito"},{"debit","Cart\u00e3o de d\u00e9bito"},{"google_pay","Cart\u00e3o de cr\u00e9dito"}};
   if(draft.payment==null||!paymentNames.ContainsKey(draft.payment))throw new DomainError("INVALID_PAYMENT");
   var fiscalDocument=String.IsNullOrWhiteSpace(draft.fiscal_document)?null:draft.fiscal_document;
   if(fiscalDocument!=null&&fiscalDocument!="nfce"&&fiscalDocument!="nfe")throw new DomainError("INVALID_FISCAL_DOCUMENT");
   var fiscalStatus=fiscalDocument==null?"not_requested":"pending_adapter";
   draft.reference=Validation.Text(draft.reference,120,false);
   if(PrepareCheckout!=null)PrepareCheckout();
   return Execute("sale.confirm",draft.request_id,draft,(c,tx,operation)=>{
    var seen=new HashSet<string>(StringComparer.OrdinalIgnoreCase);var items=new List<Dictionary<string,object>>();
    foreach(var line in draft.lines){
     if(line==null||line.quantity!=1)throw new DomainError("INVALID_LINES");
     var barcode=Validation.Barcode(line.barcode);if(!seen.Add(barcode))throw new DomainError("INVALID_LINES");
     var item=Unit(c,tx,barcode);CheckQuantity(item);items.Add(item);
    }
    var total=items.Sum(x=>Convert.ToDecimal(x["price"]??0));if(total<=0)throw new DomainError("PRICE_REQUIRED");
    object paymentId=Scalar(c,tx,"SELECT controle FROM dbo.TABEST7 WHERE recebimento=@name","@name",paymentNames[draft.payment]);
    object typeId=Scalar(c,tx,"SELECT controle FROM dbo.TABEST6 WHERE tipo=@name","@name",draft.payment=="pix"||draft.payment=="cash"?"Venda a vista":"Venda com cartão");
    if(paymentId==null||typeId==null)throw new DomainError("SIC_LOOKUP_MISSING");
    if(ClaimCheckout!=null)ClaimCheckout(draft.request_id,items);
    var note="Lineboard "+operation+(String.IsNullOrWhiteSpace(draft.reference)?"":" "+draft.reference);
    int saleId=Convert.ToInt32(Scalar(c,tx,@"INSERT dbo.TABEST3A(data,hora,lktipo,nota,pedido,lkreceb,obs,venda,cancelada,valorfrete,cgi,tagcliente,comissao,comissaovend)
     OUTPUT inserted.controle VALUES(CONVERT(date,GETDATE()),CONVERT(time,GETDATE()),@type,0,0,@payment,@note,1,0,0,0,0,0,0)","@type",typeId,"@payment",paymentId,"@note",note));
    var id=Guid.NewGuid();
    foreach(var item in items){
     int changed=NonQuery(c,tx,"UPDATE dbo.TABEST1 SET quantidade=quantidade-1 WHERE controle=@id AND quantidade=1","@id",item["sic_id"]);if(changed!=1)throw new DomainError("INSUFFICIENT_STOCK");
     NonQuery(c,tx,"INSERT dbo.TABEST3B(lkest3a,quantidade,lkproduto,total,totvenda,lucro,acrescimo,datainc,icms,quantcanc,valorcanc,comissaoprod) VALUES(@sale,1,@sic,@price,@price,@profit,0,GETDATE(),0,0,0,0)","@sale",saleId,"@sic",item["sic_id"],"@price",item["price"],"@profit",Convert.ToDecimal(item["price"])-Convert.ToDecimal(item["cost"]));
     NonQuery(c,tx,"UPDATE lineboard.Units SET expected_quantity=0,revision=revision+1,updated_at=SYSUTCDATETIME() WHERE id=@unit; INSERT lineboard.Movements(operation_id,unit_id,delta,reason,sic_document_id) VALUES(@op,@unit,-1,'sale',@sale)","@unit",Validation.Id((string)item["stock_item_id"]),"@op",operation,"@sale",saleId);
    }
    NonQuery(c,tx,"INSERT dbo.TABEST3R(lkest3a,lkest7,valor,pgtroco) VALUES(@sale,@payment,@total,0)","@sale",saleId,"@payment",paymentId,"@total",total);
    NonQuery(c,tx,"INSERT lineboard.Sales(id,operation_id,sic_id,payment,total,fiscal_status) VALUES(@id,@op,@sale,@payment,@total,@fiscal_status)","@id",id,"@op",operation,"@sale",saleId,"@payment",draft.payment,"@total",total,"@fiscal_status",fiscalStatus);
    var result=new Dictionary<string,object>{{"sale_id",id.ToString()},{"sic_sale_id",saleId},{"total",total},{"items",items},{"fiscal_document",fiscalDocument},{"fiscal_status",fiscalStatus},{"payment_recorded",true},{"payment_processed",false},{"native_sic_validation","pending"}};
    if(ClaimCheckout!=null)result["checkout_request_id"]=draft.request_id;
    Event(c,tx,"sale.confirmed",result);return result;
   });
  }
  public Dictionary<string,object> Adjust(AdjustmentDraft draft){
   draft.barcode=Validation.Barcode(draft.barcode);draft.reason=Validation.Text(draft.reason,200,true);if(draft.quantity!=0&&draft.quantity!=1)throw new DomainError("INVALID_QUANTITY");
   return Execute("stock.adjust",draft.request_id,draft,(c,tx,operation)=>{
    var item=Unit(c,tx,draft.barcode);CheckQuantity(item);int before=Convert.ToInt32(item["quantity"]);int delta=draft.quantity-before;if(delta==0)throw new DomainError("NO_STOCK_CHANGE");
    if(Convert.ToInt32(Scalar(c,tx,"SELECT COUNT(*) FROM lineboard.Cart WHERE unit_id=@id","@id",Validation.Id((string)item["stock_item_id"])))>0)throw new DomainError("UNIT_IN_CART");
    NonQuery(c,tx,"UPDATE dbo.TABEST1 SET quantidade=@quantity WHERE controle=@sic; INSERT dbo.TABINV(data,lkproduto,quantidade,acerto) VALUES(CONVERT(date,GETDATE()),@sic,@quantity,1)","@quantity",draft.quantity,"@sic",item["sic_id"]);
    NonQuery(c,tx,"UPDATE lineboard.Units SET expected_quantity=@quantity,revision=revision+1,updated_at=SYSUTCDATETIME() WHERE id=@id; INSERT lineboard.Movements(operation_id,unit_id,delta,reason) VALUES(@op,@id,@delta,'adjustment')","@id",Validation.Id((string)item["stock_item_id"]),"@quantity",draft.quantity,"@op",operation,"@delta",delta);
    var after=Unit(c,tx,draft.barcode);Event(c,tx,"stock.adjusted",new{unit=after,reason=draft.reason,delta});return after;
   });
  }
  public List<Dictionary<string,object>> History(){using(var c=Open())return Rows(c,null,"SELECT TOP(200) m.id,u.barcode,m.delta,m.reason,m.sic_document_id,m.created_at FROM lineboard.Movements m JOIN lineboard.Units u ON u.id=m.unit_id ORDER BY m.id DESC");}
  public List<Dictionary<string,object>> Outbox(){using(var c=Open())return Rows(c,null,"SELECT id,event_id,kind,payload,state,attempts,last_error,created_at FROM lineboard.Outbox ORDER BY id");}
  public void QueueInitialSharedCart(){using(var c=Open())using(var tx=c.BeginTransaction(IsolationLevel.Serializable)){
   NonQuery(c,tx,"DECLARE @r int; EXEC @r=sys.sp_getapplock @Resource=N'lineboard:writer',@LockMode='Exclusive',@LockOwner='Transaction',@LockTimeout=10000; IF @r<0 THROW 51000,'WRITER_BUSY',1;");
   if(Convert.ToInt64(Scalar(c,tx,"SELECT cloud_cart_version FROM lineboard.Settings WHERE id=1"))<0&&Convert.ToInt32(Scalar(c,tx,"SELECT COUNT(*) FROM lineboard.Outbox WHERE kind IN ('cart.added','cart.removed')"))==0)
    foreach(var row in Rows(c,tx,"SELECT u.barcode FROM lineboard.Cart c JOIN lineboard.Units u ON u.id=c.unit_id"))Event(c,tx,"cart.added",new{barcode=Convert.ToString(row["barcode"])});
   tx.Commit();
  }}
  public bool ImportSharedCart(Dictionary<string,object> cart){
   if(cart==null||!cart.ContainsKey("version")||!cart.ContainsKey("barcodes"))throw new DomainError("INVALID_CLOUD_CART");
   var version=Convert.ToInt64(cart["version"]);var codes=Json.Read<List<string>>(Json.Write(cart["barcodes"])).Select(Validation.Barcode).OrderBy(x=>x,StringComparer.Ordinal).ToList();
   using(var c=Open())using(var tx=c.BeginTransaction(IsolationLevel.Serializable)){
    NonQuery(c,tx,"DECLARE @r int; EXEC @r=sys.sp_getapplock @Resource=N'lineboard:writer',@LockMode='Exclusive',@LockOwner='Transaction',@LockTimeout=10000; IF @r<0 THROW 51000,'WRITER_BUSY',1;");
    if(Convert.ToInt32(Scalar(c,tx,"SELECT COUNT(*) FROM lineboard.Outbox WHERE state<>'sent'"))>0){tx.Commit();return false;}
    var last=Convert.ToInt64(Scalar(c,tx,"SELECT cloud_cart_version FROM lineboard.Settings WHERE id=1"));if(version<last){tx.Commit();return false;}
    var current=Rows(c,tx,"SELECT u.barcode FROM lineboard.Cart c JOIN lineboard.Units u ON u.id=c.unit_id ORDER BY u.barcode").Select(x=>Convert.ToString(x["barcode"])).ToList();
    var changed=!current.SequenceEqual(codes);if(changed){
     NonQuery(c,tx,"DELETE FROM lineboard.Cart");
     foreach(var code in codes){var unit=Unit(c,tx,code);CheckQuantity(unit);if(Convert.ToInt32(unit["quantity"])!=1)throw new DomainError("CLOUD_LOCAL_CONFLICT");NonQuery(c,tx,"INSERT lineboard.Cart(unit_id) VALUES(@unit)","@unit",Validation.Id(Convert.ToString(unit["stock_item_id"])));}
     NonQuery(c,tx,"UPDATE lineboard.Settings SET cart_version=cart_version+1 WHERE id=1");
    }
    NonQuery(c,tx,"UPDATE lineboard.Settings SET cloud_cart_version=@version WHERE id=1","@version",version);tx.Commit();return changed;
   }
  }
  public int QueueCatalogMissing(List<Dictionary<string,object>> cloudUnits){var remote=new HashSet<string>((cloudUnits??new List<Dictionary<string,object>>()).Select(x=>CloudText(x,"barcode")),StringComparer.OrdinalIgnoreCase);using(var c=Open())using(var tx=c.BeginTransaction(IsolationLevel.Serializable)){
   if(Convert.ToInt32(Scalar(c,tx,"SELECT COUNT(*) FROM lineboard.Outbox WHERE state='pending'"))>0){tx.Commit();return 0;}
   var rows=Rows(c,tx,CatalogSql+" ORDER BY u.barcode").Where(x=>!remote.Contains(CloudText(x,"barcode"))).ToList();foreach(var row in rows)Event(c,tx,"unit.upsert",row);tx.Commit();return rows.Count;
  }}
  static string CloudText(Dictionary<string,object> row,string key){object value;return row!=null&&row.TryGetValue(key,out value)&&value!=null?Convert.ToString(value,CultureInfo.InvariantCulture):"";}
  static decimal CloudDecimal(Dictionary<string,object> row,string key){object value;return row!=null&&row.TryGetValue(key,out value)&&value!=null?Convert.ToDecimal(value,CultureInfo.InvariantCulture):0m;}
  static int CloudInt(Dictionary<string,object> row,string key){object value;return row!=null&&row.TryGetValue(key,out value)&&value!=null?Convert.ToInt32(value,CultureInfo.InvariantCulture):0;}
  static long CloudLong(Dictionary<string,object> row,string key){object value;return row!=null&&row.TryGetValue(key,out value)&&value!=null?Convert.ToInt64(value,CultureInfo.InvariantCulture):0L;}
  static void AddPendingBarcode(HashSet<string> barcodes,object raw){
   if(raw==null)return;var unit=Json.Read<Dictionary<string,object>>(Json.Write(raw));var barcode=CloudText(unit,"barcode");if(!String.IsNullOrWhiteSpace(barcode))barcodes.Add(barcode);
  }
  static HashSet<string> PendingBarcodes(SqlConnection c,SqlTransaction tx){
   var barcodes=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
   foreach(var row in Rows(c,tx,"SELECT kind,payload FROM lineboard.Outbox WHERE state<>'sent'")){
    try{
     var kind=Convert.ToString(row["kind"]);var payload=Json.Read<Dictionary<string,object>>(Convert.ToString(row["payload"]));object raw;
     if(kind=="unit.upsert")AddPendingBarcode(barcodes,payload);
     else if(kind=="stock.adjusted"&&payload.TryGetValue("unit",out raw))AddPendingBarcode(barcodes,raw);
     else if(kind=="sale.confirmed"&&payload.TryGetValue("items",out raw))foreach(var item in Json.Read<List<Dictionary<string,object>>>(Json.Write(raw)))AddPendingBarcode(barcodes,item);
    }catch{}
   }
   return barcodes;
  }
  public Dictionary<string,object> ImportCloudSnapshot(Dictionary<string,object> snapshot){
   object raw;if(snapshot==null||!snapshot.TryGetValue("units",out raw)||raw==null)throw new DomainError("INVALID_CLOUD_SNAPSHOT");
   var units=Json.Read<List<Dictionary<string,object>>>(Json.Write(raw));int imported=0;int updated=0;int existing=0;int receipt=0;long maximumBarcode=0;
   using(var c=Open())using(var tx=c.BeginTransaction(IsolationLevel.Serializable)){
    NonQuery(c,tx,"DECLARE @r int; EXEC @r=sys.sp_getapplock @Resource=N'lineboard:writer',@LockMode='Exclusive',@LockOwner='Transaction',@LockTimeout=10000; IF @r<0 THROW 51000,'WRITER_BUSY',1;");
    var pending=PendingBarcodes(c,tx);
    foreach(var remote in units){
     var barcode=Validation.Barcode(CloudText(remote,"barcode"));var unitId=Validation.Id(CloudText(remote,"stock_item_id"));var productId=Validation.Id(CloudText(remote,"product_id"));var variantId=Validation.Id(CloudText(remote,"variant_id"));
     var fields=new UnitFields{name=CloudText(remote,"name"),brand=CloudText(remote,"brand"),category=CloudText(remote,"category"),color=CloudText(remote,"color"),size=CloudText(remote,"size"),cost=CloudDecimal(remote,"cost"),price=CloudDecimal(remote,"price"),location=CloudText(remote,"location"),photo=CloudText(remote,"photo_path"),notes=CloudText(remote,"notes"),internal_code=CloudText(remote,"internal_code"),fiscal=new Dictionary<string,object>()};
     foreach(var name in Fiscal.TextFields.Keys.Concat(Fiscal.Numbers)){object value;if(remote.TryGetValue(name,out value)&&value!=null)fields.fiscal[name]=value;}
     Validation.Fields(fields);var quantity=CloudInt(remote,"quantity");var revision=CloudLong(remote,"revision");if((quantity!=0&&quantity!=1)||revision<1)throw new DomainError("INVALID_CLOUD_SNAPSHOT");
     var local=Rows(c,tx,"SELECT u.id,u.sic_id,u.revision,u.expected_quantity,p.quantidade AS current_quantity FROM lineboard.Units u JOIN dbo.TABEST1 p ON p.controle=u.sic_id WHERE u.barcode=@barcode","@barcode",barcode).SingleOrDefault();
     if(local!=null){
      if(!String.Equals(Convert.ToString(local["id"]),unitId.ToString(),StringComparison.OrdinalIgnoreCase))throw new DomainError("CLOUD_LOCAL_CONFLICT");
      existing++;if(pending.Contains(barcode))continue;
      var localRevision=Convert.ToInt64(local["revision"]);var currentQuantity=Convert.ToInt32(local["current_quantity"]);var expectedQuantity=Convert.ToInt32(local["expected_quantity"]);
      if(currentQuantity!=expectedQuantity)throw new DomainError("CLOUD_LOCAL_CONFLICT");
      if(revision<localRevision)continue;
      if(revision==localRevision){if(currentQuantity!=quantity)throw new DomainError("CLOUD_LOCAL_CONFLICT");continue;}
      var existingSicId=Convert.ToInt32(local["sic_id"]);WriteFields(c,tx,existingSicId,fields);
      if(currentQuantity!=quantity){
       NonQuery(c,tx,"UPDATE dbo.TABEST1 SET quantidade=@quantity WHERE controle=@sic; INSERT dbo.TABINV(data,lkproduto,quantidade,acerto) VALUES(CONVERT(date,GETDATE()),@sic,@quantity,1)","@quantity",quantity,"@sic",existingSicId);
       NonQuery(c,tx,"INSERT lineboard.Movements(operation_id,unit_id,delta,reason) VALUES(@operation,@unit,@delta,'cloud_sync')","@operation",Guid.NewGuid(),"@unit",unitId,"@delta",quantity-currentQuantity);
      }
      NonQuery(c,tx,"UPDATE lineboard.Units SET variant_id=@variant,category=@category,color=@color,size=@size,location=@location,photo=@photo,expected_quantity=@quantity,revision=@revision,updated_at=SYSUTCDATETIME() WHERE id=@id","@variant",variantId,"@category",fields.category,"@color",fields.color,"@size",fields.size,"@location",fields.location,"@photo",fields.photo,"@quantity",quantity,"@revision",revision,"@id",unitId);
      updated++;continue;
     }
     if(Convert.ToInt32(Scalar(c,tx,"SELECT COUNT(*) FROM dbo.TABEST1 WHERE codigo=@barcode","@barcode",barcode))!=0)throw new DomainError("CLOUD_LOCAL_CONFLICT");
     if(receipt==0)receipt=Convert.ToInt32(Scalar(c,tx,"INSERT dbo.TABEST2A(data,nota,obs,frete,tipo) OUTPUT inserted.controle VALUES(CONVERT(date,GETDATE()),0,@note,0,'E')","@note","Lineboard cloud bootstrap"));
     int sicId=Convert.ToInt32(Scalar(c,tx, @"INSERT dbo.TABEST1(codigo,codinterno,produto,fabricante,precocusto,customedio,precovenda,quantidade,estminimo,unidade,lucro,comissao,moeda,obs,inativo,naosaitabela,datainc,qntembalagem)
       OUTPUT inserted.controle VALUES(@code,@internal,@name,@brand,@cost,@cost,@price,@quantity,0,'UN',0,0,'R$',@notes,0,0,GETDATE(),1)","@code",barcode,"@internal",fields.internal_code,"@name",fields.name,"@brand",fields.brand,"@cost",fields.cost,"@price",fields.price,"@quantity",quantity,"@notes",fields.notes));
     WriteFields(c,tx,sicId,fields);
     NonQuery(c,tx,"INSERT lineboard.Units(id,product_id,variant_id,sic_id,barcode,category,color,size,location,photo,expected_quantity,revision) VALUES(@id,@product,@variant,@sic,@code,@category,@color,@size,@location,@photo,@quantity,@revision)","@id",unitId,"@product",productId,"@variant",variantId,"@sic",sicId,"@code",barcode,"@category",fields.category,"@color",fields.color,"@size",fields.size,"@location",fields.location,"@photo",fields.photo,"@quantity",quantity,"@revision",revision);
     NonQuery(c,tx,"INSERT dbo.TABEST2B(lkest2a,lkproduto,quantidade,total,icms,valoripi,datainc,saiu) VALUES(@receipt,@sic,1,@cost,0,0,CONVERT(date,GETDATE()),@saiu)","@receipt",receipt,"@sic",sicId,"@cost",fields.cost,"@saiu",quantity==0?1:0);
     if(quantity==1)NonQuery(c,tx,"INSERT lineboard.Movements(operation_id,unit_id,delta,reason,sic_document_id) VALUES(@operation,@unit,1,'initial',@receipt)","@operation",Guid.NewGuid(),"@unit",unitId,"@receipt",receipt);
     imported++;long numeric;if(Int64.TryParse(barcode.Substring(4),NumberStyles.None,CultureInfo.InvariantCulture,out numeric)&&numeric>maximumBarcode)maximumBarcode=numeric;
    }
    if(imported>0&&maximumBarcode>0){var current=Convert.ToInt64(Scalar(c,tx,"SELECT ISNULL(CAST(current_value AS bigint),0) FROM sys.sequences WHERE name='BarcodeNumber' AND schema_id=SCHEMA_ID('lineboard')"));var next=maximumBarcode+1;if(next>999999999999L)throw new DomainError("BARCODE_RANGE_EXHAUSTED");if(next>current)NonQuery(c,tx,"ALTER SEQUENCE lineboard.BarcodeNumber RESTART WITH "+next.ToString(CultureInfo.InvariantCulture));}
    tx.Commit();
   }
   return new Dictionary<string,object>{{"state",imported==0&&updated==0?"up_to_date":"imported"},{"imported",imported},{"updated",updated},{"existing",existing},{"total",units.Count}};
  }
  public List<Dictionary<string,object>> Sales(){using(var c=Open())return Rows(c,null,"SELECT TOP(100) id,sic_id,payment,total,fiscal_status,created_at FROM lineboard.Sales ORDER BY created_at DESC");}
  static object ReportDate(string value){
   if(String.IsNullOrWhiteSpace(value))return null;
   DateTime date;if(!DateTime.TryParse(value,CultureInfo.InvariantCulture,DateTimeStyles.RoundtripKind,out date))throw new DomainError("INVALID_REPORT_PERIOD");
   return date.ToUniversalTime();
  }
  static decimal ReportDecimal(Dictionary<string,object> row,string key){return row[key]==null?0m:Convert.ToDecimal(row[key],CultureInfo.InvariantCulture);}
  public Dictionary<string,object> SalesReport(SalesReportFilter filter){
   filter=filter??new SalesReportFilter();
   var from=ReportDate(filter.from);var to=ReportDate(filter.to);
   var brand=String.IsNullOrWhiteSpace(filter.brand)?null:Validation.Text(filter.brand,40,false);
   var category=String.IsNullOrWhiteSpace(filter.category)?null:Validation.Text(filter.category,40,false);
   var payment=String.IsNullOrWhiteSpace(filter.payment)?null:Validation.Text(filter.payment,20,false);
   var query=String.IsNullOrWhiteSpace(filter.query)?null:"%"+Validation.Text(filter.query,80,false)+"%";
   using(var c=Open()){
    var rows=Rows(c,null,@"SELECT TOP(5000) s.id AS sale_id,s.created_at,s.payment,s.total AS sale_total,s.fiscal_status,
      l.quantidade AS quantity,l.total AS line_total,p.produto AS name,p.fabricante AS brand,p.codinterno AS internal_code,
      u.barcode,u.category,u.color,u.size
      FROM lineboard.Sales s
      JOIN dbo.TABEST3A h ON h.controle=s.sic_id
      JOIN dbo.TABEST3B l ON l.lkest3a=h.controle
      JOIN dbo.TABEST1 p ON p.controle=l.lkproduto
      LEFT JOIN lineboard.Units u ON u.sic_id=l.lkproduto
      WHERE (@from IS NULL OR s.created_at>=@from) AND (@to IS NULL OR s.created_at<@to)
        AND (@brand IS NULL OR p.fabricante=@brand) AND (@category IS NULL OR u.category=@category)
        AND (@payment IS NULL OR s.payment=@payment)
        AND (@query IS NULL OR p.produto LIKE @query OR p.codinterno LIKE @query OR u.barcode LIKE @query)
      ORDER BY s.created_at DESC","@from",from,"@to",to,"@brand",brand,"@category",category,"@payment",payment,"@query",query);
    var sales=rows.GroupBy(x=>Convert.ToString(x["sale_id"])).Select(g=>g.First()).ToList();
    var revenue=sales.Sum(x=>ReportDecimal(x,"sale_total"));
    var items=rows.Sum(x=>ReportDecimal(x,"quantity"));
    var categories=rows.GroupBy(x=>String.IsNullOrWhiteSpace(Convert.ToString(x["category"]))?"Sem tipo":Convert.ToString(x["category"]))
      .Select(g=>new{label=g.Key,items=g.Sum(x=>ReportDecimal(x,"quantity")),revenue=g.Sum(x=>ReportDecimal(x,"line_total"))}).OrderByDescending(x=>x.revenue).ToList();
    var brands=rows.GroupBy(x=>String.IsNullOrWhiteSpace(Convert.ToString(x["brand"]))?"Sem marca":Convert.ToString(x["brand"]))
      .Select(g=>new{label=g.Key,items=g.Sum(x=>ReportDecimal(x,"quantity")),revenue=g.Sum(x=>ReportDecimal(x,"line_total"))}).OrderByDescending(x=>x.revenue).ToList();
    var filterRows=Rows(c,null,"SELECT DISTINCT p.fabricante AS brand,u.category FROM dbo.TABEST1 p LEFT JOIN lineboard.Units u ON u.sic_id=p.controle");
    var filterOptions=new Dictionary<string,object> {
     {"brands",filterRows.Select(x=>Convert.ToString(x["brand"])).Where(x=>!String.IsNullOrWhiteSpace(x)).Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(x=>x).ToList()},
     {"categories",filterRows.Select(x=>Convert.ToString(x["category"])).Where(x=>!String.IsNullOrWhiteSpace(x)).Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(x=>x).ToList()}
    };
    var summary=new Dictionary<string,object> {{"sales",sales.Count},{"revenue",revenue},{"items",items},{"average_ticket",sales.Count==0?0m:revenue/sales.Count}};
    return new Dictionary<string,object> {{"summary",summary},{"by_category",categories},{"by_brand",brands},{"rows",rows},{"filters",filterOptions}};
   }
  }
  public void RegisterDevice(string token,string name){using(var c=Open())NonQuery(c,null,"INSERT lineboard.Devices(token_hash,name) VALUES(@hash,@name)","@hash",Json.Hash(token),"@name",Validation.Text(name,80,true));}
  public bool Authorized(string token){if(String.IsNullOrEmpty(token)||token.Length>200)return false;using(var c=Open())return Convert.ToInt32(Scalar(c,null,"SELECT COUNT(*) FROM lineboard.Devices WHERE token_hash=@hash AND revoked=0","@hash",Json.Hash(token)))==1;}
 }
}
