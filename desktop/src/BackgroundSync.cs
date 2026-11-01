using System;
using System.Collections.Generic;
using System.Threading;

namespace Lineboard {
 // One background worker; failed deliveries remain in the persisted outbox for the next retry.
 internal sealed class BackgroundSync : IDisposable {
  readonly bool configured;readonly Func<Dictionary<string,object>> push;readonly int interval;
  readonly object lifecycle=new object();Timer timer;int running;bool disposed;
  public volatile string State;
  public BackgroundSync(CloudSync sync):this(sync.Configured,()=>sync.Push(),30000){}
  internal BackgroundSync(bool configured,Func<Dictionary<string,object>> push,int interval){this.configured=configured;this.push=push;this.interval=interval;State=configured?"waiting":"not_configured";}
  public void Start(){lock(lifecycle){if(disposed||!configured||timer!=null)return;timer=new Timer(s=>Attempt(),null,0,interval);}}
  public void Request(){lock(lifecycle){if(disposed||!configured)return;ThreadPool.QueueUserWorkItem(s=>Attempt());}}
  void Attempt(){
   lock(lifecycle){if(disposed||Interlocked.CompareExchange(ref running,1,0)!=0)return;}
   try{var result=push();State=Convert.ToString(result["state"]);}catch(Exception){State="pending";}finally{Interlocked.Exchange(ref running,0);}
  }
  public void Dispose(){lock(lifecycle){disposed=true;if(timer!=null){timer.Dispose();timer=null;}}}
 }
}
