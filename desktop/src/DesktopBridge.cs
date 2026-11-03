using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;

namespace Lineboard {
 // The only message surface exposed to the React application.  Keep this class
 // independent from WebView2 so that the contract can be exercised against a
 // real SIC sandbox without pretending that a mock browser is an integration
 // test.
 public sealed class DesktopBridge {
  public const string Origin = "https://lineboard.local/";
  static readonly HashSet<string> Actions = new HashSet<string>(StringComparer.Ordinal) {
   "bootstrap", "product.create", "photo.upload", "photo.url", "unit.get", "unit.edit", "stock.adjust",
   "cart.add", "cart.remove", "cart.confirm", "sales.report", "history.list", "labels.preview",
   "labels.export", "settings.info", "pair.open", "support.outbox"
  };
  readonly SicStore store;
  readonly LocalApi api;
  readonly CloudSync sync;
  readonly BackgroundSync backgroundSync;
  readonly RealtimeBridge realtime;
  readonly Func<string, bool> saveLabels;
  public bool BootstrapServed { get; private set; }

  internal DesktopBridge(SicStore store, LocalApi api, CloudSync sync, BackgroundSync backgroundSync, Func<string, bool> saveLabels, RealtimeBridge realtime = null) {
   if(store==null||api==null||sync==null||backgroundSync==null)throw new ArgumentNullException();
   this.store=store;this.api=api;this.sync=sync;this.backgroundSync=backgroundSync;this.saveLabels=saveLabels;this.realtime=realtime;
  }

  public string Process(string source, string message) {
   if(!IsTrustedSource(source)) return Error(null, "ORIGIN_REFUSED", "A interface só pode ser usada pelo aplicativo Lineboard.");
   string id=null;
   try {
    if(message==null||message.Length>8*1024*1024)throw new DomainError("REQUEST_TOO_LARGE");
    var envelope=Json.Read<Dictionary<string,object>>(message);
    if(envelope==null)throw new DomainError("INVALID_MESSAGE");
    foreach(var key in envelope.Keys)if(key!="id"&&key!="action"&&key!="payload")throw new DomainError("INVALID_MESSAGE");
    id=RequiredString(envelope,"id",128);
    var action=RequiredString(envelope,"action",64);
    object rawPayload=envelope.ContainsKey("payload")?envelope["payload"]:null;
    var payload=AsObject(rawPayload);
    if(!Actions.Contains(action))throw new DomainError("UNKNOWN_ACTION");
    var data=Dispatch(action,payload);
    return Json.Write(new {id,ok=true,data});
   }catch(DomainError error){return Error(id,error.Code,Friendly(error.Code));}
   catch(ArgumentException){return Error(id,"INVALID_MESSAGE","A mensagem da interface não é válida.");}
   catch(InvalidOperationException){return Error(id,"INVALID_MESSAGE","A mensagem da interface não é válida.");}
   catch(Exception){return Error(id,"BRIDGE_OPERATION_FAILED","Não foi possível concluir a operação local.");}
  }

  static string Error(string id,string code,string message) { return Json.Write(new {id,ok=false,error=new {code,message}}); }

  static bool IsTrustedSource(string source) {
   Uri uri;if(!Uri.TryCreate(source,UriKind.Absolute,out uri))return false;
   return uri.Scheme==Uri.UriSchemeHttps&&String.Equals(uri.Host,"lineboard.local",StringComparison.OrdinalIgnoreCase)&&
    (uri.Port==-1||uri.Port==443)&&String.IsNullOrEmpty(uri.UserInfo);
  }

  static string RequiredString(Dictionary<string,object> map,string key,int max) {
   if(!map.ContainsKey(key)||!(map[key] is string))throw new DomainError("INVALID_MESSAGE");
   var value=((string)map[key]).Trim();
   if(value.Length==0||value.Length>max||value.Any(Char.IsControl))throw new DomainError("INVALID_MESSAGE");
   return value;
  }

  static Dictionary<string,object> AsObject(object value) {
   if(value==null)return new Dictionary<string,object>();
   var map=value as Dictionary<string,object>;
   if(map==null)throw new DomainError("INVALID_PAYLOAD");
   return map;
  }

  static void ExactKeys(Dictionary<string,object> payload,params string[] allowed) {
   var accepted=new HashSet<string>(allowed,StringComparer.Ordinal);
   foreach(var key in payload.Keys)if(!accepted.Contains(key))throw new DomainError("INVALID_PAYLOAD");
  }
  static void RequiredKeys(Dictionary<string,object> payload,params string[] required) {
   foreach(var key in required)if(!payload.ContainsKey(key))throw new DomainError("INVALID_PAYLOAD");
  }
  static Dictionary<string,object> NestedObject(Dictionary<string,object> parent,string key) {
   if(!parent.ContainsKey(key)||!(parent[key] is Dictionary<string,object>))throw new DomainError("INVALID_PAYLOAD");
   return (Dictionary<string,object>)parent[key];
  }
  static T Model<T>(Dictionary<string,object> payload,params string[] keys) {
   ExactKeys(payload,keys);return Json.Read<T>(Json.Write(payload));
  }

  object Dispatch(string action,Dictionary<string,object> payload) {
   switch(action) {
    case "photo.upload":ExactKeys(payload,"content_type","data");return sync.UploadPhoto(RequiredString(payload,"content_type",40),RequiredString(payload,"data",7*1024*1024));
    case "photo.url":ExactKeys(payload,"photo_path");return sync.PhotoUrl(RequiredString(payload,"photo_path",1000));
    case "bootstrap":
     ExactKeys(payload);var bootstrap=new {catalog=store.Catalog(),cart=store.Cart(),mode=store.Production?"production":"sandbox",sync_state=backgroundSync.State};BootstrapServed=true;return bootstrap;
    case "product.create": {
     var draft=Model<ProductDraft>(payload,"request_id","name","brand","category","color","size","cost","price","location","photo","notes","internal_code","fiscal","variants");
     ValidateVariantPayload(payload);ValidateVariants(draft.variants);var result=store.CreateProduct(draft);backgroundSync.Request();return result;
    }
    case "unit.get": {
     ExactKeys(payload,"barcode");RequiredKeys(payload,"barcode");return store.Lookup(StringValue(payload,"barcode"));
    }
    case "unit.edit": {
     ExactKeys(payload,"barcode","draft");RequiredKeys(payload,"barcode","draft");
     var draftPayload=NestedObject(payload,"draft");
     var draft=Model<EditDraft>(draftPayload,"request_id","revision","name","brand","category","color","size","cost","price","location","photo","notes","internal_code","fiscal");
     var result=store.Edit(StringValue(payload,"barcode"),draft);backgroundSync.Request();return result;
    }
    case "stock.adjust": {
     var draft=Model<AdjustmentDraft>(payload,"request_id","barcode","quantity","reason");var result=store.Adjust(draft);backgroundSync.Request();return result;
    }
    case "cart.add": {
     var draft=Model<CartDraft>(payload,"request_id","barcode");var result=store.AddCart(draft);backgroundSync.Request();return result;
    }
    case "cart.remove": {
     var draft=Model<CartDraft>(payload,"request_id","barcode");var result=store.RemoveCart(draft);backgroundSync.Request();return result;
    }
    case "cart.confirm": {
     var draft=Model<ConfirmDraft>(payload,"request_id","version","payment","fiscal_document");var result=store.Confirm(draft);backgroundSync.Request();return result;
    }
    case "sales.report": {
     var filter=Model<SalesReportFilter>(payload,"from","to","brand","category","payment","query");return store.SalesReport(filter);
    }
    case "history.list":ExactKeys(payload);return new {items=store.History()};
    case "labels.preview": {
     ExactKeys(payload);return new {html=Labels.Html(LabelUnits(),50,30)};
    }
    case "labels.export": {
     ExactKeys(payload);if(saveLabels==null)throw new DomainError("LABEL_EXPORT_UNAVAILABLE");return new {saved=saveLabels(Labels.Html(LabelUnits(),50,30))};
    }
    case "settings.info":ExactKeys(payload);return new {address=api.Address,sync_configured=sync.Configured,sync_state=backgroundSync.State,realtime_configured=realtime!=null&&realtime.Configured,realtime_state=realtime==null?"not_configured":realtime.State,mode=store.Production?"production":"sandbox"};
    case "pair.open":ExactKeys(payload);return new {address=api.Address,pin=api.OpenPairing(),expires_in_seconds=180};
    case "support.outbox":ExactKeys(payload);return new {items=store.Outbox()};
    default:throw new DomainError("UNKNOWN_ACTION");
   }
  }

  string StringValue(Dictionary<string,object> payload,string key) {
   if(!payload.ContainsKey(key)||!(payload[key] is string))throw new DomainError("INVALID_PAYLOAD");
   return (string)payload[key];
  }

  static void ValidateVariants(List<VariantDraft> variants) {
   if(variants==null)throw new DomainError("INVALID_PAYLOAD");
   foreach(var variant in variants??new List<VariantDraft>()) {
    if(variant==null)throw new DomainError("INVALID_PAYLOAD");
   }
  }

  static void ValidateVariantPayload(Dictionary<string,object> payload) {
   if(!payload.ContainsKey("variants")||!(payload["variants"] is IList))throw new DomainError("INVALID_PAYLOAD");
   foreach(var item in (IList)payload["variants"]) {
    var variant=item as Dictionary<string,object>;if(variant==null)throw new DomainError("INVALID_PAYLOAD");
    ExactKeys(variant,"color","size","quantity");RequiredKeys(variant,"color","size","quantity");
   }
  }

  List<Dictionary<string,object>> LabelUnits() {
   return store.Catalog().Where(x=>Convert.ToDecimal(x["quantity"]??0,CultureInfo.InvariantCulture)==1).ToList();
  }

  static string Friendly(string code) {
   var messages=new Dictionary<string,string>(StringComparer.Ordinal) {
    {"PHOTO_TOO_LARGE","Escolha uma imagem de até 5 MB."},
    {"INVALID_PHOTO_TYPE","Escolha uma imagem JPG/JPEG, PNG ou WebP válida."},
    {"INVALID_PHOTO","Não foi possível abrir esta foto. Escolha a imagem novamente."},
    {"PHOTO_UPLOAD_FAILED","Não foi possível enviar a foto. Confira a conexão e tente novamente."},
    {"CLOUD_NOT_CONFIGURED","Configure a conexão da loja para enviar fotos."},
    {"ORIGIN_REFUSED","A interface só pode ser usada pelo aplicativo Lineboard."},
    {"INVALID_MESSAGE","A mensagem da interface não é válida."},
    {"INVALID_PAYLOAD","Confira os dados enviados pela interface."},
    {"UNKNOWN_ACTION","A ação solicitada não está disponível."},
    {"LABEL_EXPORT_UNAVAILABLE","Não foi possível abrir o seletor de arquivo."},
    {"CART_CHANGED","O carrinho mudou. Confira os itens e confirme novamente."},
    {"CHECKOUT_IN_PROGRESS","Outro computador está confirmando esta compra. Aguarde a conclusão."},
    {"CLOUD_STOCK_CONFLICT","O estoque central mudou. Atualize o carrinho antes de confirmar."},
    {"CLOUD_NOT_ACKNOWLEDGED","Não foi possível confirmar com a loja. Confira a conexão e tente novamente."},
    {"SIC_STOCK_CONFLICT","O saldo foi alterado fora do Lineboard. Confira a peça no SIC."},
    {"ALREADY_IN_CART","Essa peça já está no carrinho."},
    {"INSUFFICIENT_STOCK","A peça não está disponível."},
    {"PRICE_REQUIRED","Informe um preço de venda antes de concluir."},
    {"REVISION_CONFLICT","A ficha mudou em outra sessão. Reabra e confira as informações."},
    {"EMPTY_CART","Adicione uma peça ao carrinho."},
    {"INVALID_FISCAL_DOCUMENT","Escolha NFC-e ou NF-e para continuar."},
    {"UNIT_IN_CART","Remova a peça do carrinho antes de ajustar o estoque."},
    {"INVALID_FIELD","Confira os campos do produto."},
    {"INVALID_PRICE","Informe valores válidos de custo e venda."}
   };
   return messages.ContainsKey(code)?messages[code]:"Não foi possível concluir a operação local.";
  }
 }
}
