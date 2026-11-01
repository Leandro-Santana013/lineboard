using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Security;
using System.Text;

namespace Lineboard {
 public static class Labels {
  // Standard ISO/IEC 15417 Code 128 symbol patterns (least-significant module first).
  // The SLB prefix uses code set B and its 12 digits use code set C.
  static readonly int[] Patterns={0x19b,0x1b3,0x333,0xc9,0x189,0x191,0x99,0x119,0x131,0x93,0x113,0x123,0x1cd,0x1d9,0x399,0x19d,0x1b9,0x339,0x273,0x1d3,0x393,0x13b,0x173,0x3b7,0x197,0x1a7,0x327,0x137,0x167,0x267,0xdb,0x31b,0x363,0xc5,0xd1,0x311,0x8d,0xb1,0x231,0x8b,0xa3,0x223,0xed,0x38d,0x3b1,0xdd,0x31d,0x371,0x377,0x38b,0x3a3,0xbb,0x23b,0x3bb,0xd7,0x317,0x347,0xb7,0x237,0x2c7,0x2f7,0x213,0x28f,0x65,0x185,0x69,0x309,0x1a1,0x321,0x4d,0x10d,0x59,0x219,0x161,0x261,0x243,0x53,0x2ef,0x143,0x2f1,0x1e5,0x1e9,0x3c9,0x13d,0x179,0x279,0x12f,0x14f,0x24f,0x3db,0x37b,0x36f,0xf5,0x3c5,0x3d1,0xbd,0x23d,0xaf,0x22f,0x3dd,0x3bd,0x3d7,0x3af,0x10b,0x4b,0x1cb,0x2e3};
  public static List<int> Codewords(string code){
   code=Validation.Barcode(code);var result=new List<int>{104,51,44,34,13,99};for(int i=4;i<code.Length;i+=2)result.Add(Int32.Parse(code.Substring(i,2),CultureInfo.InvariantCulture));
   int checksum=result[0];for(int i=1;i<result.Count;i++)checksum+=result[i]*i;result.Add(checksum%103);result.Add(106);return result;
  }
  public static string Modules(string code){var bits=new StringBuilder("0000000000");foreach(int word in Codewords(code)){for(int i=0;i<11;i++)bits.Append((Patterns[word]&(1<<i))!=0?'1':'0');if(word==106)bits.Append("11");}bits.Append("0000000000");return bits.ToString();}
  static string Escape(object value){return SecurityElement.Escape(Convert.ToString(value))??"";}
  public static string Html(IEnumerable<Dictionary<string,object>> units,double widthMm,double heightMm){
   if(widthMm<40||widthMm>120||heightMm<20||heightMm>120)throw new DomainError("INVALID_LABEL_SIZE");
   var html=new StringBuilder("<!doctype html><html lang=\"pt-BR\"><meta charset=\"utf-8\"><title>Etiquetas Lineboard</title><style>body{font:12px Arial;background:white;display:flex;flex-wrap:wrap;gap:3mm}.label{box-sizing:border-box;padding:2mm;border:1px dashed #aaa;overflow:hidden;width:");
   html.Append(widthMm.ToString(CultureInfo.InvariantCulture)).Append("mm;height:").Append(heightMm.ToString(CultureInfo.InvariantCulture)).Append("mm;break-inside:avoid}.name{white-space:nowrap;text-overflow:ellipsis;overflow:hidden;font-weight:bold}svg{width:100%;height:65%;display:block}@media print{body{margin:0}.label{border:0}} </style><body>");
   foreach(var unit in units){string code=Validation.Barcode((string)unit["barcode"]),bits=Modules(code);html.Append("<article class=\"label\"><div class=\"name\">").Append(Escape(unit["name"])).Append("</div><div>").Append(Escape(unit["color"])).Append(" · ").Append(Escape(unit["size"])).Append("</div><svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 ").Append(bits.Length).Append(" 75\" role=\"img\" aria-label=\"").Append(code).Append("\" shape-rendering=\"crispEdges\"><rect width=\"100%\" height=\"100%\" fill=\"white\"/>");
    for(int x=0;x<bits.Length;x++)if(bits[x]=='1')html.Append("<rect x=\"").Append(x).Append("\" y=\"2\" width=\"1\" height=\"55\" fill=\"black\"/>");
    html.Append("<text x=\"").Append(bits.Length/2).Append("\" y=\"70\" font-size=\"9\" text-anchor=\"middle\" font-family=\"monospace\">").Append(code).Append("</text></svg></article>");
   }return html.Append("</body></html>").ToString();
  }
 }
}
