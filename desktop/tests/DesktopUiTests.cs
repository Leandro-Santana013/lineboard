using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;

namespace Lineboard {
 // Runs the real WinForms views against a new guarded SQL sandbox, never the working catalog.
 static class DesktopUiTests {
  static readonly List<string> passed=new List<string>();
  static void Check(string name,bool value){if(!value)throw new Exception("UI_TEST_FAILED: "+name);passed.Add(name);}
  static T Field<T>(object view,string name){return (T)view.GetType().GetField(name,BindingFlags.Instance|BindingFlags.NonPublic).GetValue(view);}
  static void Refresh(DesktopForm view){view.GetType().GetMethod("RefreshData",BindingFlags.Instance|BindingFlags.NonPublic).Invoke(view,null);Application.DoEvents();}
  static void Capture(Form view,string path){view.PerformLayout();Application.DoEvents();using(var image=new Bitmap(view.ClientSize.Width,view.ClientSize.Height)){view.Controls[0].DrawToBitmap(image,new Rectangle(Point.Empty,view.ClientSize));image.Save(path,System.Drawing.Imaging.ImageFormat.Png);}}
  static void ShowForTest(Form view){view.StartPosition=FormStartPosition.Manual;view.Location=new Point(-20000,-20000);view.ShowInTaskbar=false;view.Show();Application.DoEvents();}
  static void Select(DataGridView grid,string code){foreach(DataGridViewRow row in grid.Rows)if(Convert.ToString(row.Cells["barcode"].Value)==code){grid.CurrentCell=row.Cells[0];return;}throw new Exception("Missing fixture row");}
  [STAThread] static int Main(string[] args){
   try{
    string workspace=Path.GetFullPath(args[0]),database=args[1],output=Path.Combine(workspace,".local","ui-verification");Directory.CreateDirectory(output);
    if(!database.StartsWith("LINEBOARD_LAB_UITEST",StringComparison.Ordinal))throw new Exception("A dedicated UI test sandbox is required.");
    // No live integration credentials are used by the test process.
    Environment.SetEnvironmentVariable("LINEBOARD_SYNC_URL",null);Environment.SetEnvironmentVariable("LINEBOARD_SYNC_TOKEN",null);
    Application.EnableVisualStyles();Application.SetCompatibleTextRenderingDefault(false);
    var store=new SicStore(@"(localdb)\MSSQLLocalDB",database,workspace);if(store.Catalog().Count!=0)throw new Exception("UI tests require an empty sandbox.");
    using(var api=new LocalApi(store,"localhost",47839))using(var view=new DesktopForm(store,api)){
     ShowForTest(view);Refresh(view);
     var grid=Field<DataGridView>(view,"inventory");var search=Field<TextBox>(view,"search");var filter=Field<ComboBox>(view,"stockFilter");var add=Field<ActionButton>(view,"addButton");var checkout=Field<ActionButton>(view,"confirmButton");var total=Field<Label>(view,"total");
     Check("empty inventory and cart explain the next step",Field<EmptyState>(view,"inventoryEmpty").Visible&&Field<EmptyState>(view,"cartEmpty").Visible&&!add.Enabled&&!checkout.Enabled);
     Check("daily navigation contains no connection or manual cloud controls",!Descendants(view).OfType<Button>().Any(x=>x.Text=="Sincronizar nuvem"||x.Text=="Fila de sincronização"||x.Text=="Parear celular")&&Descendants(view).OfType<Button>().Any(x=>x.Text=="Configurações"));
     Capture(view,Path.Combine(output,"empty.png"));
     string[] names={"Camiseta básica","Calça jeans reta","Camisa de linho","Vestido midi","Blusa canelada","Bermuda sarja"},colors={"Preta","Azul","Areia","Verde","Branca","Bege"},sizes={"M","40","G","M","P","42"};decimal[] prices={69.90m,129.90m,159.90m,189.90m,59.90m,89.90m};
     var codes=new List<string>();
     for(int i=0;i<names.Length;i++){
      var result=store.CreateProduct(new ProductDraft{request_id=Guid.NewGuid().ToString(),name=names[i],brand="Laboratório",cost=30,price=prices[i],internal_code="UI"+i,notes="Fixture isolada da verificação visual",variants=new List<VariantDraft>{new VariantDraft{color=colors[i],size=sizes[i],quantity=1}}});
      codes.Add(Convert.ToString(Json.Read<List<Dictionary<string,object>>>(Json.Write(result["units"]))[0]["barcode"]));
     }
     Refresh(view);Check("catalog displays six individually tracked pieces",grid.Rows.Count==6&&!Field<EmptyState>(view,"inventoryEmpty").Visible);
     search.Text="BASICA";Check("search ignores case and Portuguese accents",grid.Rows.Count==1&&Convert.ToString(grid.Rows[0].Cells["barcode"].Value)==codes[0]);
     search.Text=codes[2];Check("barcode search identifies the physical piece",grid.Rows.Count==1&&Convert.ToString(grid.Rows[0].Cells["name"].Value)==names[2]);
     search.Text="UI4";Check("internal reference is searchable",grid.Rows.Count==1&&Convert.ToString(grid.Rows[0].Cells["barcode"].Value)==codes[4]);
     search.Text="sem-correspondencia";Check("no-result search preserves catalog and disables selected actions",Field<EmptyState>(view,"inventoryEmpty").Visible&&!add.Enabled&&!Field<ActionButton>(view,"editButton").Enabled&&store.Catalog().Count==6);
     search.Clear();Select(grid,codes[0]);Check("available piece enables add-to-cart",add.Enabled);add.PerformClick();
     Check("add button persists the selected piece without lowering stock",((List<Dictionary<string,object>>)store.Cart()["items"]).Count==1&&Convert.ToDecimal(store.Lookup(codes[0])["quantity"])==1);
     Check("piece in cart is marked and cannot be added twice",Convert.ToString(grid.CurrentRow.Cells["state"].Value)=="No caixa"&&!add.Enabled);
     Select(grid,codes[1]);add.PerformClick();Check("cart total uses Brazilian currency and item count",total.Text==199.80m.ToString("C",CultureInfo.GetCultureInfo("pt-BR"))&&Field<Label>(view,"cartCount").Text=="2 itens"&&checkout.Enabled);
     Capture(view,Path.Combine(output,"stock-and-checkout.png"));
     var before=store.Cart();var unit=store.Lookup(codes[1]);store.Edit(codes[1],new EditDraft{request_id=Guid.NewGuid().ToString(),revision=Convert.ToInt64(unit["revision"]),name=names[1],brand="Laboratório",color=colors[1],size=sizes[1],cost=30,price=139.90m,internal_code="UI1",fiscal=new Dictionary<string,object>()});Refresh(view);
     Check("editing an in-cart price refreshes total and invalidates older confirmations",Convert.ToInt64(before["version"])<Convert.ToInt64(store.Cart()["version"])&&total.Text==209.80m.ToString("C",CultureInfo.GetCultureInfo("pt-BR")));
     var cards=Field<FlowLayoutPanel>(view,"cartItems");Check("cart card displays the revised price",cards.Controls[1].AccessibleName.Contains("139,90"));
     before=store.Cart();using(var connection=store.Open())SicStore.NonQuery(connection,null,"UPDATE dbo.TABEST1 SET precovenda=149.90 WHERE controle=@id","@id",unit["sic_id"]);Refresh(view);
     Check("external SIC price changes refresh cards even without a cart version change",Convert.ToInt64(before["version"])==Convert.ToInt64(store.Cart()["version"])&&total.Text==219.80m.ToString("C",CultureInfo.GetCultureInfo("pt-BR"))&&cards.Controls[1].AccessibleName.Contains("149,90"));
     using(var connection=store.Open())SicStore.NonQuery(connection,null,"UPDATE dbo.TABEST1 SET precovenda=139.90 WHERE controle=@id","@id",unit["sic_id"]);Refresh(view);
     ((Button)cards.Controls[0].Controls[0]).PerformClick();Check("per-item remove button persists removal and updates total",((List<Dictionary<string,object>>)store.Cart()["items"]).Count==1&&total.Text==139.90m.ToString("C",CultureInfo.GetCultureInfo("pt-BR")));
     filter.SelectedIndex=2;Check("cart filter shows only the remaining cart piece",grid.Rows.Count==1&&Convert.ToString(grid.Rows[0].Cells["barcode"].Value)==codes[1]);
     store.Adjust(new AdjustmentDraft{request_id=Guid.NewGuid().ToString(),barcode=codes[4],quantity=0,reason="Cenário sintético sem saldo"});
     using(var connection=store.Open())SicStore.NonQuery(connection,null,"UPDATE dbo.TABEST1 SET quantidade=0 WHERE controle=@id","@id",store.Lookup(codes[5])["sic_id"]);
     Refresh(view);filter.SelectedIndex=3;Check("zero stock disables add-to-cart",grid.Rows.Count==1&&Convert.ToString(grid.Rows[0].Cells["state"].Value)=="Sem saldo"&&!add.Enabled);
     filter.SelectedIndex=4;Check("stock conflicts remain visible and cannot be added",grid.Rows.Count==1&&Convert.ToString(grid.Rows[0].Cells["state"].Value)=="Em conflito"&&!add.Enabled);
     filter.SelectedIndex=1;Check("available filter excludes cart, zero stock and conflicts",grid.Rows.Count==3);
     filter.SelectedIndex=0;Select(grid,codes[2]);Refresh(view);Check("periodic refresh preserves selected physical piece",Convert.ToString(grid.CurrentRow.Cells["barcode"].Value)==codes[2]);
     view.Size=view.MinimumSize;Application.DoEvents();Check("checkout action and inventory actions fit minimum window",checkout.RectangleToScreen(checkout.ClientRectangle).Bottom<=view.RectangleToScreen(view.ClientRectangle).Bottom&&add.Width>140&&checkout.Width>260);
     Check("inventory columns fit minimum window without horizontal scrolling",!grid.Controls.OfType<HScrollBar>().Any(x=>x.Visible));
     Check("compact window keeps product and barcode together instead of truncating columns",!grid.Columns["barcode"].Visible&&grid.Columns["name"].Width>150);
     Capture(view,Path.Combine(output,"minimum-size.png"));
     view.Size=new Size(1360,880);filter.SelectedIndex=2;search.Text="linho";Check("search and situation filter combine",grid.Rows.Count==0);search.Clear();filter.SelectedIndex=0;
     // More items than the card viewport verifies real scrolling and item width calculation.
     foreach(int index in new[]{0,2,3})store.AddCart(new CartDraft{request_id=Guid.NewGuid().ToString(),barcode=codes[index]});Refresh(view);view.Size=view.MinimumSize;Application.DoEvents();
     Check("long cart scrolls vertically without a horizontal scrollbar",cards.VerticalScroll.Visible&&!cards.HorizontalScroll.Visible&&cards.Controls.Cast<Control>().All(x=>x.Width<=cards.ClientSize.Width));
     Capture(view,Path.Combine(output,"scrolling-cart.png"));view.Close();
    }
    using(var product=new FieldsDialog(null,true)){
     ShowForTest(product);Capture(product,Path.Combine(output,"new-product.png"));var tabs=product.Controls[0].Controls.OfType<TabControl>().Single();
     Check("product form exposes ficha, grade and fiscal tabs in workflow order",tabs.TabPages.Count==3&&tabs.TabPages[1].Text=="Grade e quantidades");tabs.SelectedIndex=1;Application.DoEvents();Capture(product,Path.Combine(output,"product-variants.png"));
     var grade=Field<DataGridView>(product,"variants");grade.CurrentCell=grade.Rows[0].Cells[2];grade.BeginEdit(false);((TextBox)grade.EditingControl).Text="3";grade.EndEdit();Check("edited variant quantity is committed",product.Variants()[0].quantity==3);
     tabs.SelectedIndex=2;Application.DoEvents();Capture(product,Path.Combine(output,"product-tax.png"));product.Close();
    }
    using(var adjust=new AdjustmentDialog()){
     ShowForTest(adjust);var save=(Button)adjust.AcceptButton;Check("stock adjustment requires a reason",!save.Enabled);Field<TextBox>(adjust,"reason").Text="Contagem física no laboratório";Check("reason enables stock adjustment",save.Enabled);Capture(adjust,Path.Combine(output,"adjustment.png"));adjust.Close();
    }
    int calls=0,active=0,peak=0;
    using(var automatic=new BackgroundSync(true,()=>{
     int current=Interlocked.Increment(ref active);int seen;do{seen=peak;if(current<=seen)break;}while(Interlocked.CompareExchange(ref peak,current,seen)!=seen);
     try{int attempt=Interlocked.Increment(ref calls);Thread.Sleep(25);if(attempt==1)throw new Exception("Synthetic offline transport");return new Dictionary<string,object>{{"state","up_to_date"}};}finally{Interlocked.Decrement(ref active);}
    },10)){
     automatic.Start();bool recovered=SpinWait.SpinUntil(()=>automatic.State=="up_to_date",2000);
     Check("background updates start and retry an offline attempt without operator action",recovered&&calls>=2);Check("background updates never overlap",peak==1);
    }
    int disabledCalls=0;using(var disabled=new BackgroundSync(false,()=>{Interlocked.Increment(ref disabledCalls);return new Dictionary<string,object>{{"state","up_to_date"}};},10)){disabled.Start();disabled.Request();Thread.Sleep(30);Check("unconfigured integration does not attempt a network operation",disabledCalls==0&&disabled.State=="not_configured");}
    Console.WriteLine(Json.Write(new{passed=passed.Count,checks=passed,database,previews=output}));return 0;
   }catch(Exception error){Console.Error.WriteLine(error.ToString());return 1;}
  }
  static IEnumerable<Control> Descendants(Control parent){foreach(Control child in parent.Controls){yield return child;foreach(var nested in Descendants(child))yield return nested;}}
 }
}
