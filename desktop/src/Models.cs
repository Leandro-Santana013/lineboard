using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Web.Script.Serialization;

namespace Lineboard {
 public static class Json {
  public static JavaScriptSerializer Serializer() { return new JavaScriptSerializer { MaxJsonLength=4*1024*1024, RecursionLimit=64 }; }
  public static string Write(object value) { return Serializer().Serialize(value); }
  public static T Read<T>(string value) { return Serializer().Deserialize<T>(value); }
  public static string Hash(string value) { using(var sha=SHA256.Create()) return BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(value))).Replace("-","").ToLowerInvariant(); }
  public static string Canonical(object value) {
   var map=value as IDictionary<string,object>;
   if(map!=null) return "{"+String.Join(",",map.Keys.OrderBy(k=>k,StringComparer.Ordinal).Select(k=>Write(k)+":"+Canonical(map[k])))+"}";
   var array=value as IEnumerable;
   if(array!=null && !(value is string)) return "["+String.Join(",",array.Cast<object>().Select(Canonical))+"]";
   return Write(value);
  }
  public static Dictionary<string,object> Map(object value) { return Read<Dictionary<string,object>>(Write(value)); }
 }
 public class DomainError : Exception { public string Code; public DomainError(string code):base(code){Code=code;} }
 public class UnitFields {
  public string name {get;set;} public string brand {get;set;} public string category {get;set;} public string color {get;set;} public string size {get;set;}
  public decimal cost {get;set;} public decimal price {get;set;} public string location {get;set;} public string photo {get;set;}
  public string notes {get;set;} public string internal_code {get;set;}
  public Dictionary<string,object> fiscal {get;set;}
 }
 public class VariantDraft { public string color {get;set;} public string size {get;set;} public int quantity {get;set;} }
 public class ProductDraft : UnitFields { public string request_id {get;set;} public List<VariantDraft> variants {get;set;} }
 public class EditDraft : UnitFields { public string request_id {get;set;} public long revision {get;set;} }
 public class CartDraft { public string request_id {get;set;} public string barcode {get;set;} }
 public class ConfirmDraft { public string request_id {get;set;} public long version {get;set;} public string payment {get;set;} public string fiscal_document {get;set;} }
 public class SaleLineDraft { public string barcode {get;set;} public int quantity {get;set;} }
 public class ConfirmLinesDraft { public string request_id {get;set;} public List<SaleLineDraft> lines {get;set;} public string payment {get;set;} public string fiscal_document {get;set;} public string reference {get;set;} }
 public class AdjustmentDraft { public string request_id {get;set;} public string barcode {get;set;} public int quantity {get;set;} public string reason {get;set;} }
 public class SalesReportFilter { public string from {get;set;} public string to {get;set;} public string brand {get;set;} public string category {get;set;} public string payment {get;set;} public string query {get;set;} }
 public static class Validation {
  public static string Text(string value,int maximum,bool required) {
   value=(value??"").Trim();
   if(value.Length>maximum || (required && value.Length==0) || value.Any(c=>Char.IsControl(c) && c!='\n' && c!='\r')) throw new DomainError("INVALID_FIELD");
   return value;
  }
  public static string Barcode(string value) {
   value=(value??"").Trim().ToUpperInvariant();
   if(!System.Text.RegularExpressions.Regex.IsMatch(value,@"^SLB-\d{12}$")) throw new DomainError("INVALID_BARCODE");
   return value;
  }
  public static Guid Id(string value) { Guid id; if(!Guid.TryParse(value,out id)||id==Guid.Empty) throw new DomainError("INVALID_REQUEST_ID");return id; }
  public static UnitFields Fields(UnitFields f) {
   f.name=Text(f.name,50,true);f.brand=Text(f.brand,20,false);f.category=Text(f.category,40,false);f.color=Text(f.color,40,false);f.size=Text(f.size,40,false);
   f.location=Text(f.location,80,false);f.photo=Text(f.photo,1000,false);f.notes=Text(f.notes,4000,false);f.internal_code=Text(f.internal_code,20,false);
   if(f.cost<0||f.price<0||f.cost>1000000000m||f.price>1000000000m||Decimal.Round(f.cost,4)!=f.cost||Decimal.Round(f.price,4)!=f.price) throw new DomainError("INVALID_PRICE");
   f.fiscal=Fiscal.Normalize(f.fiscal);return f;
  }
 }
 public static class Fiscal {
  // These are data fields only. No tax calculation, default classification or issuance is inferred.
  public static readonly Dictionary<string,int> TextFields=new Dictionary<string,int>{{"codipi",12},{"cst",3},{"ipi_cst",2},{"cean",14},{"ceantrib",14},{"cest",7},{"cst_pis",2},{"cst_cofins",2},{"cbenef",10},{"cst_ibscbs",3},{"cclasstrib",6}};
  public static readonly string[] Numbers={"ipi","icms","basecalculo","pesobruto","pesoliq","ipi_basecalc","fcp","origem","cprodanp"};
  public static Dictionary<string,object> Normalize(Dictionary<string,object> source) {
   var result=new Dictionary<string,object>();
   foreach(var entry in source??new Dictionary<string,object>()) {
    if(TextFields.ContainsKey(entry.Key)) result[entry.Key]=Validation.Text(Convert.ToString(entry.Value,CultureInfo.InvariantCulture),TextFields[entry.Key],false);
    else if(Numbers.Contains(entry.Key)) {
     decimal number; if(!Decimal.TryParse(Convert.ToString(entry.Value,CultureInfo.InvariantCulture),NumberStyles.Number,CultureInfo.InvariantCulture,out number)||number<0||number>1000000000m)throw new DomainError("INVALID_FISCAL_FIELD");
     if((entry.Key=="origem"||entry.Key=="cprodanp")&&Decimal.Truncate(number)!=number)throw new DomainError("INVALID_FISCAL_FIELD");
     if(entry.Key=="origem"&&number>8)throw new DomainError("INVALID_FISCAL_FIELD");result[entry.Key]=number;
    } else throw new DomainError("UNKNOWN_FISCAL_FIELD");
   } return result;
  }
 }
}
