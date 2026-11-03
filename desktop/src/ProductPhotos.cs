using System;
using System.Text;
using System.Text.RegularExpressions;

namespace Lineboard {
 // Only stable private Storage references cross the product persistence boundary.
 public static class ProductPhotos {
  public const int MaximumBytes=5*1024*1024;
  public static string Path(string path) {
   if(path==null||!Regex.IsMatch(path,@"^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}/[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\.(jpg|jpeg|png|webp)$"))throw new DomainError("INVALID_PHOTO");
   return path;
  }
  public static void Validate(string type,string data) {
   if(data==null||data.Length==0)throw new DomainError("INVALID_PHOTO_TYPE");
   if(data.Length>4*((MaximumBytes+2)/3))throw new DomainError("PHOTO_TOO_LARGE");
   byte[] bytes;try{bytes=Convert.FromBase64String(data);}catch(FormatException){throw new DomainError("INVALID_PHOTO_TYPE");}
   if(bytes.Length>MaximumBytes)throw new DomainError("PHOTO_TOO_LARGE");
   var png=bytes.Length>=8&&bytes[0]==137&&bytes[1]==80&&bytes[2]==78&&bytes[3]==71&&bytes[4]==13&&bytes[5]==10&&bytes[6]==26&&bytes[7]==10;
   var jpeg=bytes.Length>=3&&bytes[0]==255&&bytes[1]==216&&bytes[2]==255;
   var webp=bytes.Length>=12&&Encoding.ASCII.GetString(bytes,0,4)=="RIFF"&&Encoding.ASCII.GetString(bytes,8,4)=="WEBP";
   if(!((type=="image/png"&&png)||(type=="image/jpeg"&&jpeg)||(type=="image/webp"&&webp)))throw new DomainError("INVALID_PHOTO_TYPE");
  }
 }
}
