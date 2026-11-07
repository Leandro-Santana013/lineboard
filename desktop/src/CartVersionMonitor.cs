using System;
using System.IO;

namespace Lineboard {
 // Read only a version marker between full reconciliations. A reconnect or a
 // missing WebSocket credential must not leave the checkout stale indefinitely.
 internal sealed class CartVersionMonitor {
  readonly Func<string> readVersion;
  readonly Action changed;
  string observed;
  public CartVersionMonitor(Func<string> readVersion,Action changed){this.readVersion=readVersion;this.changed=changed;}
  public void Check(){
   var version=readVersion();
   if(String.IsNullOrWhiteSpace(version))throw new InvalidDataException("CART_VERSION_INVALID");
   if(String.Equals(version,observed,StringComparison.Ordinal))return;
   changed();
   observed=version;
  }
 }
}
