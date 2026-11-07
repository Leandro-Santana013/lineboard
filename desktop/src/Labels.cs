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
  static void AppendBits(List<bool> bits,int value,int length){for(int i=length-1;i>=0;i--)bits.Add(((value>>i)&1)!=0);}
  static int GaloisMultiply(int x,int y){int product=0;for(int i=0;i<8;i++){if((y&1)!=0)product^=x;bool high=(x&0x80)!=0;x=(x<<1)&0xff;if(high)x^=0x1d;y>>=1;}return product;}
  static List<int> ErrorCorrection(List<int> data,int degree){
   var generator=new List<int>{1};int root=1;
   for(int i=0;i<degree;i++){var next=new int[generator.Count+1];for(int j=0;j<generator.Count;j++){next[j]^=generator[j];next[j+1]^=GaloisMultiply(generator[j],root);}generator=new List<int>(next);root=GaloisMultiply(root,2);}
   var remainder=new int[degree];foreach(int value in data){int factor=value^remainder[0];for(int i=0;i<degree-1;i++)remainder[i]=remainder[i+1];remainder[degree-1]=0;for(int i=0;i<degree;i++)remainder[i]^=GaloisMultiply(generator[i+1],factor);}
   return new List<int>(remainder);
  }
  static void SetFunction(bool[,] modules,bool[,] reserved,int x,int y,bool dark){modules[y,x]=dark;reserved[y,x]=true;}
  static void DrawFinder(bool[,] modules,bool[,] reserved,int left,int top){
   for(int dy=-1;dy<=7;dy++)for(int dx=-1;dx<=7;dx++){int x=left+dx,y=top+dy;if(x<0||x>=21||y<0||y>=21)continue;bool inside=dx>=0&&dx<=6&&dy>=0&&dy<=6;int distance=Math.Max(Math.Abs(dx-3),Math.Abs(dy-3));SetFunction(modules,reserved,x,y,inside&&(distance==3||distance<=1));}
  }
  static void DrawFormat(bool[,] modules,bool[,] reserved,int mask){
   int data=(1<<3)|mask,remainder=data;for(int i=0;i<10;i++)remainder=(remainder<<1)^(((remainder>>9)&1)*0x537);int bits=((data<<10)|remainder)^0x5412;
   for(int i=0;i<=5;i++)SetFunction(modules,reserved,8,i,((bits>>i)&1)!=0);
   SetFunction(modules,reserved,8,7,((bits>>6)&1)!=0);SetFunction(modules,reserved,8,8,((bits>>7)&1)!=0);SetFunction(modules,reserved,7,8,((bits>>8)&1)!=0);
   for(int i=9;i<15;i++)SetFunction(modules,reserved,14-i,8,((bits>>i)&1)!=0);
   for(int i=0;i<8;i++)SetFunction(modules,reserved,20-i,8,((bits>>i)&1)!=0);
   for(int i=8;i<15;i++)SetFunction(modules,reserved,8,21-15+i,((bits>>i)&1)!=0);
   SetFunction(modules,reserved,8,13,true);
  }
  public static bool[,] QrModules(string value){
   string code=Validation.Barcode(value);byte[] payload=Encoding.ASCII.GetBytes(code);if(payload.Length>17)throw new DomainError("QR_PAYLOAD_TOO_LONG");
   var bits=new List<bool>();AppendBits(bits,4,4);AppendBits(bits,payload.Length,8);foreach(byte valueByte in payload)AppendBits(bits,valueByte,8);
   int capacity=19*8;for(int i=0;i<4&&bits.Count<capacity;i++)bits.Add(false);while(bits.Count%8!=0)bits.Add(false);
   var data=new List<int>();for(int i=0;i<bits.Count;i+=8){int valueByte=0;for(int j=0;j<8;j++)valueByte=(valueByte<<1)|(bits[i+j]?1:0);data.Add(valueByte);}
   for(int pad=0;data.Count<19;pad++)data.Add(pad%2==0?0xec:0x11);
   var codewords=new List<int>(data);codewords.AddRange(ErrorCorrection(data,7));var dataBits=new List<bool>();foreach(int valueByte in codewords)AppendBits(dataBits,valueByte,8);
   var modules=new bool[21,21];var reserved=new bool[21,21];DrawFinder(modules,reserved,0,0);DrawFinder(modules,reserved,14,0);DrawFinder(modules,reserved,0,14);
   for(int i=8;i<13;i++){SetFunction(modules,reserved,i,6,i%2==0);SetFunction(modules,reserved,6,i,i%2==0);}DrawFormat(modules,reserved,0);
   int bitIndex=0;bool upward=true;for(int right=20;right>=1;right-=2){if(right==6)right=5;for(int step=0;step<21;step++){int y=upward?20-step:step;for(int offset=0;offset<2;offset++){int x=right-offset;if(reserved[y,x])continue;bool dark=bitIndex<dataBits.Count&&dataBits[bitIndex];if((x+y)%2==0)dark=!dark;modules[y,x]=dark;bitIndex++;}}upward=!upward;}
   return modules;
  }
  public static string QrSvg(string value){
   string code=Validation.Barcode(value);var modules=QrModules(code);var svg=new StringBuilder("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 29 29\" role=\"img\" aria-label=\"QR ");svg.Append(code).Append("\" shape-rendering=\"crispEdges\"><rect width=\"29\" height=\"29\" fill=\"white\"/>");
   for(int y=0;y<21;y++)for(int x=0;x<21;x++)if(modules[y,x])svg.Append("<rect x=\"").Append(x+4).Append("\" y=\"").Append(y+4).Append("\" width=\"1\" height=\"1\" fill=\"black\"/>");
   return svg.Append("</svg>").ToString();
  }
  static string Escape(object value){return SecurityElement.Escape(Convert.ToString(value))??"";}
  public static string Html(IEnumerable<Dictionary<string,object>> units,double widthMm,double heightMm){return HtmlWithQr(units,widthMm,heightMm);}
  public static string HtmlWithQr(IEnumerable<Dictionary<string,object>> units,double widthMm,double heightMm){
   if(widthMm<40||widthMm>120||heightMm<20||heightMm>120)throw new DomainError("INVALID_LABEL_SIZE");
   var html=new StringBuilder("<!doctype html><html lang=\"pt-BR\"><meta charset=\"utf-8\"><title>Etiquetas Lineboard</title><style>body{font:12px Arial;background:white;display:flex;flex-wrap:wrap;gap:3mm}.label{box-sizing:border-box;position:relative;padding:1mm;border:1px dashed #aaa;overflow:hidden;width:");
   html.Append(widthMm.ToString(CultureInfo.InvariantCulture)).Append("mm;height:").Append(heightMm.ToString(CultureInfo.InvariantCulture)).Append("mm;break-inside:avoid}.label-header{position:absolute;left:1.5mm;top:1.3mm;right:1.5mm;height:11mm}.name{white-space:nowrap;text-overflow:ellipsis;overflow:hidden;font-size:7pt;font-weight:bold}.variant{white-space:nowrap;text-overflow:ellipsis;overflow:hidden;font-size:6pt}.barcode{position:absolute;left:1.5mm;right:1.5mm;bottom:1mm;height:14mm}.barcode svg{width:100%;height:100%;display:block}.qr{position:absolute;right:1.5mm;top:1.5mm;width:12mm;height:12mm}.qr svg{width:100%;height:100%;display:block}.qr-label .qr{left:50%;right:auto;top:50%;width:min(20mm,calc(100% - 12mm));height:min(20mm,calc(100% - 12mm));transform:translate(-50%,-25%)}@media print{body{margin:0}.label{border:0}} </style><body>");
   foreach(var unit in units){string code=Validation.Barcode(Convert.ToString(unit["barcode"])),bits=Modules(code);bool qrOnly=unit.ContainsKey("qr_only")&&Convert.ToBoolean(unit["qr_only"]);html.Append("<article class=\"label").Append(qrOnly?" qr-label":"").Append("\"><div class=\"label-header\"><div class=\"name\">").Append(Escape(unit["name"])).Append("</div><div class=\"variant\">").Append(Escape(unit["color"])).Append(" &middot; ").Append(Escape(unit["size"])).Append("</div></div>");
    if(qrOnly)html.Append("<div class=\"qr\">").Append(QrSvg(code)).Append("</div>");
    else {html.Append("<svg class=\"barcode\" xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 ").Append(bits.Length).Append(" 75\" preserveAspectRatio=\"none\" role=\"img\" aria-label=\"Codigo de barras ").Append(code).Append("\" shape-rendering=\"crispEdges\"><rect width=\"100%\" height=\"100%\" fill=\"white\"/>");
     for(int x=0;x<bits.Length;x++)if(bits[x]=='1')html.Append("<rect x=\"").Append(x).Append("\" y=\"2\" width=\"1\" height=\"55\" fill=\"black\"/>");
     html.Append("<text x=\"").Append(bits.Length/2).Append("\" y=\"70\" font-size=\"9\" text-anchor=\"middle\" font-family=\"monospace\">").Append(code).Append("</text></svg>");}
    html.Append("</article>");
   }return html.Append("</body></html>").ToString();
  }
 }
}
