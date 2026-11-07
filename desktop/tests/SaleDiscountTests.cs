using System;
using System.Collections.Generic;
using System.Linq;
using Lineboard;

static class SaleDiscountTests {
 static List<Dictionary<string,object>> Items(params decimal[] prices){return prices.Select((price,index)=>new Dictionary<string,object>{{"barcode","SLB-"+index.ToString("D12")},{"price",price}}).ToList();}
 static void Equal(decimal actual,decimal expected){if(actual!=expected)throw new Exception("Expected "+expected+", got "+actual);}
 static void Invalid(string type,decimal value){try{SaleDiscount.Calculate(Items(109),type,value);}catch(DomainError e){if(e.Code=="INVALID_DISCOUNT")return;throw;}throw new Exception("Invalid discount accepted");}
 static int Main(){
  var items=Items(109,109,109,109);var result=SaleDiscount.Calculate(items,"percent",10);
  Equal(result.Subtotal,436);Equal(result.Amount,43.60m);Equal(result.Total,392.40m);
  Equal(result.LineTotals.Values.Sum(),result.Total);Equal(Convert.ToDecimal(items[0]["price"]),109);
  result=SaleDiscount.Calculate(items,"amount",20.50m);Equal(result.Total,415.50m);Equal(result.LineTotals.Values.Sum(),result.Total);
  result=SaleDiscount.Calculate(Items(0.05m),"percent",10);Equal(result.Amount,0.01m);
  result=SaleDiscount.Calculate(Items(69.9m),"percent",12.34m);Equal(result.Total,61.27m);
  result=SaleDiscount.Calculate(Items(0.01m,0.01m,0.01m),"amount",0.01m);Equal(result.LineTotals.Values.Sum(),0.02m);
  result=SaleDiscount.Calculate(items,"percent",100);Equal(result.Total,0);Equal(result.LineTotals.Values.Sum(),0);
  result=SaleDiscount.Calculate(items,null,0);Equal(result.Total,436);
  Invalid("percent",-1);Invalid("percent",101);Invalid("amount",110);Invalid("amount",0.001m);Invalid("other",0);
  var random=new Random(8127);
  for(int n=0;n<1000;n++){
   var values=Enumerable.Range(0,random.Next(1,40)).Select(_=>random.Next(0,50000)/100m).ToArray();
   if(values.Sum()==0)continue;
   result=SaleDiscount.Calculate(Items(values),"percent",random.Next(0,10001)/100m);
   Equal(result.LineTotals.Values.Sum(),result.Total);
   if(result.LineTotals.Values.Any(x=>x<0))throw new Exception("Negative line total");
  }
  Console.WriteLine("PASS: discount validation, cents, proportional allocation and 1000 randomized carts; no database writes.");return 0;
 }
}
