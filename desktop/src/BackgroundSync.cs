using System;
using System.Collections.Generic;
using System.Threading;

namespace Lineboard {
 // One background worker; a request is caused by a local/cloud event. Failed
 // deliveries get a bounded retry timer, but there is no periodic pull loop.
 internal sealed class BackgroundSync : IDisposable {
  readonly bool configured;readonly Func<Dictionary<string,object>> push;readonly int retryDelay;
  readonly SicStore store;
  readonly object lifecycle=new object();Timer retryTimer;int running;int requested;bool started;bool disposed;
  public volatile string State;
  public BackgroundSync(CloudSync sync):this(null,sync){}
  public BackgroundSync(SicStore store,CloudSync sync):this(sync.Configured,()=>sync.Reconcile(),1000){this.store=store;if(this.store!=null)this.store.Changed+=Request;}
  internal BackgroundSync(bool configured,Func<Dictionary<string,object>> push,int retryDelay){this.configured=configured;this.push=push;this.retryDelay=retryDelay;State=configured?"waiting":"not_configured";}
  public void Start(){lock(lifecycle){if(disposed||!configured||started)return;started=true;}Request();}
  public void Request(){
   bool queue=false;
   lock(lifecycle){
    if(disposed||!configured)return;
    requested=1;
    if(retryTimer!=null){retryTimer.Dispose();retryTimer=null;}
    if(running==0){running=1;queue=true;}
   }
   if(queue)ThreadPool.QueueUserWorkItem(s=>Attempt());
  }
  void Attempt(){
   Interlocked.Exchange(ref requested,0);
   var failed=false;
   try{var result=push();State=Convert.ToString(result["state"]);}
   catch(Exception){State="pending";failed=true;}
   bool queue=false;
   lock(lifecycle){
    if(disposed){running=0;return;}
    if(requested==1){requested=0;queue=true;}
    else {running=0;if(failed)retryTimer=new Timer(s=>Request(),null,retryDelay,Timeout.Infinite);}
   }
   if(queue)ThreadPool.QueueUserWorkItem(s=>Attempt());
  }
  public void Dispose(){lock(lifecycle){disposed=true;if(store!=null)store.Changed-=Request;if(retryTimer!=null){retryTimer.Dispose();retryTimer=null;}}}
 }
}
