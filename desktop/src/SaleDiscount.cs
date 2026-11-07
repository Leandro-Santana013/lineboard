using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;

namespace Lineboard {
 public sealed class SaleDiscount {
  public decimal Subtotal, Amount, Total, Value;
  public string Type;
  public Dictionary<string,decimal> LineTotals=new Dictionary<string,decimal>();
  public static decimal Money(decimal value){return Decimal.Round(value,2,MidpointRounding.AwayFromZero);}
  public static SaleDiscount Calculate(List<Dictionary<string,object>> items,string type,decimal value){
   type=String.IsNullOrEmpty(type)?"percent":type;
   if((type!="percent"&&type!="amount")||value<0||Money(value)!=value||(type=="percent"&&value>100))throw new DomainError("INVALID_DISCOUNT");
   var ordered=items.OrderBy(x=>(string)x["barcode"],StringComparer.Ordinal).ToList();
   var prices=ordered.Select(x=>Money(Convert.ToDecimal(x["price"]??0))).ToList();
   if(prices.Any(x=>x<0))throw new DomainError("INVALID_PRICE");
   var result=new SaleDiscount{Type=type,Value=value,Subtotal=prices.Sum()};
   if(result.Subtotal<=0)throw new DomainError("PRICE_REQUIRED");
   if(type=="amount"&&value>result.Subtotal)throw new DomainError("INVALID_DISCOUNT");
   result.Amount=type=="percent"?Money(result.Subtotal*value/100):value;
   result.Total=result.Subtotal-result.Amount;
   // Cumulative proportional allocation preserves every cent, including 100% discounts.
   decimal cumulative=0,allocated=0;
   for(int i=0;i<ordered.Count;i++){
    cumulative+=prices[i];
    decimal target=Money(result.Amount*cumulative/result.Subtotal);
    result.LineTotals[(string)ordered[i]["barcode"]]=prices[i]-(target-allocated);
    allocated=target;
   }
   return result;
  }
  public string Note {get{return " | Subtotal R$ "+Subtotal.ToString("F2",CultureInfo.GetCultureInfo("pt-BR"))+"; desconto "+Value.ToString("0.##",CultureInfo.GetCultureInfo("pt-BR"))+(Type=="percent"?"%":" BRL")+" (R$ "+Amount.ToString("F2",CultureInfo.GetCultureInfo("pt-BR"))+")";}}
  public void Include(Dictionary<string,object> result){
   result["subtotal"]=Subtotal;result["discount_type"]=Type;result["discount_value"]=Value;
   result["discount_total"]=Amount;result["line_totals"]=LineTotals;
  }
 }
}
