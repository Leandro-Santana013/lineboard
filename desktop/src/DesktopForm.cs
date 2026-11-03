using System;
using System.Collections.Generic;
using System.Data;
using System.Drawing;
using System.Globalization;
using System.Linq;
using System.Windows.Forms;

namespace Lineboard {
 public sealed class DesktopForm : Form {
  readonly SicStore store; readonly LocalApi api; readonly CloudSync sync;readonly BackgroundSync backgroundSync;readonly RealtimeBridge realtime; readonly DataGridView inventory=Grid();
  readonly Label status=DesktopTheme.Label("Operação local",8.5f,DesktopTheme.Muted),catalogCount=DesktopTheme.Label(""),cartCount=DesktopTheme.Label(""),total=DesktopTheme.Label("R$ 0,00",23,DesktopTheme.Ink,FontStyle.Bold),pieceCount=DesktopTheme.Label("0 peças",9,DesktopTheme.Muted),selection=DesktopTheme.Label("Selecione uma peça",8.5f,DesktopTheme.Muted);
  readonly ComboBox payment=new ComboBox {DropDownStyle=ComboBoxStyle.DropDownList,Dock=DockStyle.Fill};
  readonly ComboBox stockFilter=new ComboBox{DropDownStyle=ComboBoxStyle.DropDownList,Dock=DockStyle.Fill};
  readonly TextBox search=new TextBox{BorderStyle=BorderStyle.None,Dock=DockStyle.Fill,Font=DesktopTheme.TextFont(10),AccessibleName="Buscar produto ou código"};
  readonly FlowLayoutPanel cartItems=new FlowLayoutPanel{Dock=DockStyle.Fill,AutoScroll=true,FlowDirection=FlowDirection.TopDown,WrapContents=false,BackColor=Color.White,Margin=Padding.Empty};
  readonly EmptyState inventoryEmpty=new EmptyState(),cartEmpty=new EmptyState{Heading="Seu caixa está vazio",Description="Selecione uma peça no estoque\ne adicione ao caixa.",Glyph="cart"};
  ActionButton editButton,adjustButton,addButton,confirmButton;
  List<Dictionary<string,object>> catalogRows=new List<Dictionary<string,object>>();
  HashSet<string> cartCodes=new HashSet<string>();
  readonly System.Windows.Forms.Timer refreshTimer=new System.Windows.Forms.Timer {Interval=1800};
  long cartVersion=-1; string pendingConfirmation; ConfirmDraft pendingDraft; string inventorySignature="";bool renderingPreview;
  public DesktopForm(SicStore store,LocalApi api,RealtimeBridge realtime=null){
   this.store=store;this.api=api;this.realtime=realtime;sync=new CloudSync(store);backgroundSync=new BackgroundSync(store,sync);if(this.realtime!=null)this.realtime.SharedCartChanged+=backgroundSync.Request;DesktopTheme.Form(this);Text="Lineboard • Loja e estoque • Laboratório";
   Size=new Size(1360,880);MinimumSize=new Size(1180,740);StartPosition=FormStartPosition.CenterScreen;KeyPreview=true;DoubleBuffered=true;
   var area=Screen.FromControl(this).WorkingArea;Size=new Size(Math.Min(Width,area.Width),Math.Min(Height,area.Height));
   var shell=new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=2,RowCount=1,Margin=Padding.Empty};shell.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute,204));shell.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100));shell.RowStyles.Add(new RowStyle(SizeType.Percent,100));Controls.Add(shell);
   shell.Controls.Add(BuildSidebar(),0,0);
   var main=DesktopTheme.Rows(86,58,-1,30);main.Padding=new Padding(22,10,22,8);shell.Controls.Add(main,1,0);
   var header=new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=2,RowCount=1,Margin=Padding.Empty};header.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100));header.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute,164));header.RowStyles.Add(new RowStyle(SizeType.Percent,100));
   var heading=DesktopTheme.Rows(44,30);heading.Controls.Add(DesktopTheme.Label("Loja e estoque",25,DesktopTheme.Ink,FontStyle.Bold),0,0);heading.Controls.Add(DesktopTheme.Label("Suas peças e o caixa em um só lugar.",10.5f,DesktopTheme.Muted),0,1);header.Controls.Add(heading,0,0);
   var createButton=Button("Novo produto",()=>Create(),true,"plus");createButton.Dock=DockStyle.Top;createButton.Margin=new Padding(0,14,0,0);header.Controls.Add(createButton,1,0);main.Controls.Add(header,0,0);
   var notice=new Surface{Fill=Color.FromArgb(255,248,231),Edge=Color.FromArgb(244,214,161),Padding=new Padding(14,0,12,0),Dock=DockStyle.Fill,Margin=new Padding(0,0,0,14)};
   var noticeText=DesktopTheme.Label("Ambiente de teste • Emissão fiscal indisponível",9.5f,Color.FromArgb(136,79,14));noticeText.Padding=new Padding(32,0,0,0);notice.Controls.Add(noticeText);noticeText.Paint+=(s,e)=>DesktopTheme.Icon(e.Graphics,"info",new Rectangle(0,(noticeText.Height-21)/2,21,21),Color.FromArgb(180,112,18));main.Controls.Add(notice,0,1);
   var workspace=new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=3,RowCount=1,Margin=Padding.Empty};workspace.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100));workspace.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute,18));workspace.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute,326));workspace.RowStyles.Add(new RowStyle(SizeType.Percent,100));
   workspace.Controls.Add(BuildInventory(),0,0);workspace.Controls.Add(BuildCheckout(),2,0);main.Controls.Add(workspace,0,2);
   status.Text="Alterações salvas";main.Controls.Add(status,0,3);
   inventory.CurrentCellChanged+=(s,e)=>UpdateSelection();inventory.CellPainting+=PaintInventoryCell;inventory.SizeChanged+=(s,e)=>FitInventoryColumns();
   search.TextChanged+=(s,e)=>BindInventory();stockFilter.SelectedIndexChanged+=(s,e)=>BindInventory();
   KeyDown+=(s,e)=>{if(e.Control&&e.KeyCode==Keys.F){search.Focus();search.SelectAll();e.SuppressKeyPress=true;}};
   refreshTimer.Tick+=(s,e)=>{try{RefreshData();}catch(Exception){status.Text="Não foi possível atualizar a tela. Tente novamente.";}};
   Shown+=(s,e)=>{RefreshData();refreshTimer.Start();if(!renderingPreview)backgroundSync.Start();};FormClosed+=(s,e)=>{refreshTimer.Stop();refreshTimer.Dispose();if(realtime!=null)realtime.SharedCartChanged-=backgroundSync.Request;backgroundSync.Dispose();api.Dispose();};
  }
  Control BuildSidebar(){
   var sidebar=DesktopTheme.Rows(106,34,46,46,46,-1,46,44);sidebar.BackColor=DesktopTheme.Navy;sidebar.Padding=new Padding(12,14,12,4);
   var brand=DesktopTheme.Rows(44,24);var wordmark=DesktopTheme.Label("LINEBOARD",16.5f,Color.White,FontStyle.Bold);wordmark.Padding=new Padding(29,0,0,0);wordmark.Paint+=(s,e)=>{using(var a=new SolidBrush(DesktopTheme.Teal))using(var b=new SolidBrush(Color.FromArgb(30,194,198))){e.Graphics.FillRectangle(a,2,11,18,24);e.Graphics.FillRectangle(b,2,11,9,14);}};brand.Controls.Add(wordmark,0,0);brand.Controls.Add(DesktopTheme.Label("     Gestão da loja",10,Color.FromArgb(159,186,204)),0,1);sidebar.Controls.Add(brand,0,0);
   sidebar.Controls.Add(DesktopTheme.Label("  OPERAÇÃO",8,Color.FromArgb(145,172,192),FontStyle.Bold),0,1);
   var home=Nav("Loja e estoque",()=>inventory.Focus(),"store");home.Active=true;sidebar.Controls.Add(home,0,2);
   sidebar.Controls.Add(Nav("Histórico",()=>ShowRows("Histórico de estoque",store.History()),"history"),0,3);
   sidebar.Controls.Add(Nav("Etiquetas",()=>ExportLabels(),"tag"),0,4);
   sidebar.Controls.Add(Nav("Configurações",()=>ShowSettings(),"settings"),0,6);
   sidebar.Controls.Add(DesktopTheme.Label("  ●  Modo laboratório",9,Color.FromArgb(255,195,87)),0,7);return sidebar;
  }
  ActionButton Nav(string title,Action action,string glyph){var button=Button(title,action,false,glyph);button.Navigation=true;button.Dock=DockStyle.Fill;button.Font=DesktopTheme.TextFont(9.5f);button.Margin=new Padding(0,2,0,2);return button;}
  Control BuildInventory(){
   var card=new Surface{Dock=DockStyle.Fill};var rows=DesktopTheme.Rows(56,70,-1,76);card.Controls.Add(rows);
   var heading=DesktopTheme.Rows(30,24);heading.Controls.Add(DesktopTheme.Label("Estoque",17,DesktopTheme.Ink,FontStyle.Bold),0,0);catalogCount.Font=DesktopTheme.TextFont(9);catalogCount.ForeColor=DesktopTheme.Muted;heading.Controls.Add(catalogCount,0,1);rows.Controls.Add(heading,0,0);
   var find=DesktopTheme.Rows(23,38);find.Controls.Add(DesktopTheme.Label("Buscar produto ou código",9,DesktopTheme.Muted),0,0);
   var filters=new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=3,RowCount=1,Margin=Padding.Empty};filters.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100));filters.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute,10));filters.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute,150));filters.RowStyles.Add(new RowStyle(SizeType.Percent,100));
   var box=new Surface{Dock=DockStyle.Fill,Padding=new Padding(34,9,8,6)};box.Paint+=(s,e)=>DesktopTheme.Icon(e.Graphics,"search",new Rectangle(9,10,18,18),DesktopTheme.Muted);box.Controls.Add(search);filters.Controls.Add(box,0,0);
   stockFilter.Items.AddRange(new object[]{"Todas as peças","Disponíveis","No caixa","Sem saldo","Em conflito"});stockFilter.SelectedIndex=0;stockFilter.Font=DesktopTheme.TextFont(9);stockFilter.Margin=new Padding(0,5,0,0);filters.Controls.Add(stockFilter,2,0);find.Controls.Add(filters,0,1);rows.Controls.Add(find,0,1);
   var gridHost=new Panel{Dock=DockStyle.Fill,Margin=Padding.Empty,BackColor=Color.White};gridHost.Controls.Add(inventory);gridHost.Controls.Add(inventoryEmpty);rows.Controls.Add(gridHost,0,2);
   var footer=DesktopTheme.Rows(28,42);footer.Padding=new Padding(0,5,0,0);footer.Controls.Add(selection,0,0);
   var actions=new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=3,RowCount=1,Margin=Padding.Empty};actions.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,27));actions.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,33));actions.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,40));actions.RowStyles.Add(new RowStyle(SizeType.Percent,100));
   editButton=Button("Editar peça",()=>Edit(),false,"edit");adjustButton=Button("Entrada / ajuste",()=>Adjust(),false,"box");addButton=Button("Adicionar ao caixa",()=>AddSelected(),true,"cart");
   var buttons=new[]{editButton,adjustButton,addButton};for(int i=0;i<buttons.Length;i++){buttons[i].Dock=DockStyle.Fill;buttons[i].Margin=new Padding(i==0?0:6,0,0,0);actions.Controls.Add(buttons[i],i,0);}footer.Controls.Add(actions,0,1);rows.Controls.Add(footer,0,3);return card;
  }
  Control BuildCheckout(){
   var card=new Surface{Dock=DockStyle.Fill};var rows=DesktopTheme.Rows(34,36,-1,68,84,46,54);card.Controls.Add(rows);
   var heading=new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=2,RowCount=1,Margin=Padding.Empty};heading.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100));heading.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute,62));heading.RowStyles.Add(new RowStyle(SizeType.Percent,100));
   var title=DesktopTheme.Label("     Caixa",17,DesktopTheme.Ink,FontStyle.Bold);title.Paint+=(s,e)=>DesktopTheme.Icon(e.Graphics,"cart",new Rectangle(0,5,26,26),DesktopTheme.Ink);heading.Controls.Add(title,0,0);cartCount.TextAlign=ContentAlignment.MiddleRight;cartCount.Font=DesktopTheme.TextFont(9);cartCount.ForeColor=DesktopTheme.Muted;heading.Controls.Add(cartCount,1,0);rows.Controls.Add(heading,0,0);
   rows.Controls.Add(DesktopTheme.Label("Confira os itens antes de concluir.",9,DesktopTheme.Muted),0,1);
   var listHost=new Panel{Dock=DockStyle.Fill,Margin=Padding.Empty,BackColor=Color.White};listHost.Controls.Add(cartItems);listHost.Controls.Add(cartEmpty);rows.Controls.Add(listHost,0,2);cartItems.ClientSizeChanged+=(s,e)=>SizeCartItems();
   var paymentRows=DesktopTheme.Rows(28,34);paymentRows.Paint+=(s,e)=>{using(var pen=new Pen(DesktopTheme.Border))e.Graphics.DrawLine(pen,0,0,paymentRows.Width,0);};paymentRows.Controls.Add(DesktopTheme.Label("Forma de pagamento",9),0,0);
   payment.Items.AddRange(new object[]{"Pix","Dinheiro","Cartão de crédito","Cartão de débito","Google Pay"});payment.SelectedIndex=0;payment.Font=DesktopTheme.TextFont(10);payment.Margin=new Padding(0,3,0,0);paymentRows.Controls.Add(payment,0,1);rows.Controls.Add(paymentRows,0,3);
   var summary=DesktopTheme.Rows(28,48);summary.Controls.Add(pieceCount,0,0);var totalRow=new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=2,RowCount=1,Margin=Padding.Empty};totalRow.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute,76));totalRow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100));totalRow.RowStyles.Add(new RowStyle(SizeType.Percent,100));totalRow.Controls.Add(DesktopTheme.Label("Total",16,DesktopTheme.Ink,FontStyle.Bold),0,0);total.TextAlign=ContentAlignment.MiddleRight;totalRow.Controls.Add(total,1,0);summary.Controls.Add(totalRow,0,1);rows.Controls.Add(summary,0,4);
   confirmButton=Button("Confirmar venda de teste",()=>Confirm(),true);confirmButton.Dock=DockStyle.Fill;confirmButton.Font=DesktopTheme.TextFont(10,FontStyle.Bold);rows.Controls.Add(confirmButton,0,5);
   var note=DesktopTheme.Label("Registra no laboratório, sem cobrança\nou emissão de nota.",8,DesktopTheme.Muted);note.TextAlign=ContentAlignment.MiddleCenter;rows.Controls.Add(note,0,6);return card;
  }
  static DataGridView Grid(){var grid=new DataGridView{Dock=DockStyle.Fill,ReadOnly=true,AllowUserToAddRows=false,AllowUserToDeleteRows=false,SelectionMode=DataGridViewSelectionMode.FullRowSelect,MultiSelect=false,Margin=Padding.Empty};DesktopTheme.Grid(grid);return grid;}
  ActionButton Button(string title,Action action,bool primary=false,string glyph=null){var b=new ActionButton{Text=title,Primary=primary,Glyph=glyph};b.Click+=(s,e)=>Run(action);return b;}
  void Run(Action action){try{action();RefreshData();backgroundSync.Request();}catch(Exception ex){MessageBox.Show(this,Friendly(ex),"Operação não concluída",MessageBoxButtons.OK,MessageBoxIcon.Warning);}}
  void ShowSettings(){
   using(var form=new Form{Text="Configurações",Size=new Size(580,400),MinimizeBox=false,MaximizeBox=false,ShowInTaskbar=false}){
    DesktopTheme.Form(form);var root=DesktopTheme.Rows(48,68,54,-1,52);root.Padding=new Padding(24,16,24,16);form.Controls.Add(root);
    root.Controls.Add(DesktopTheme.Label("Configurações",22,DesktopTheme.Ink,FontStyle.Bold),0,0);root.Controls.Add(DesktopTheme.Label("O sistema cuida da atualização dos dados em segundo plano.\nVocê pode continuar cadastrando e vendendo normalmente.",10,DesktopTheme.Muted),0,1);
    var phone=Button("Usar celular",()=>PairPhone(),false,"phone");phone.Dock=DockStyle.Top;phone.Width=180;root.Controls.Add(phone,0,2);
    var details=Button("Informações de suporte",()=>ShowRows("Informações de suporte — operações salvas",store.Outbox()),false,"info");details.Dock=DockStyle.Top;root.Controls.Add(details,0,3);
    var close=new ActionButton{Text="Fechar",Width=110,Dock=DockStyle.Right,DialogResult=DialogResult.Cancel};root.Controls.Add(close,0,4);form.CancelButton=close;form.ShowDialog(this);
   }
  }
  void PairPhone(){MessageBox.Show(this,"Endereço: "+api.Address+"\nCódigo: "+api.OpenPairing()+"\nVálido por 3 minutos e um pareamento.\n\nPara Wi-Fi, inicie com --host IP_DO_COMPUTADOR.\nO computador deve permanecer ligado.","Parear celular",MessageBoxButtons.OK,MessageBoxIcon.Information);}
  static string Friendly(Exception ex){var errors=new Dictionary<string,string>{{"CART_CHANGED","O carrinho mudou. Confira os itens e confirme novamente."},{"SIC_STOCK_CONFLICT","O saldo foi alterado fora do Lineboard. Confira a peça no SIC antes de continuar."},{"ALREADY_IN_CART","Essa peça já está no carrinho."},{"INSUFFICIENT_STOCK","A peça não está disponível."},{"PRICE_REQUIRED","Informe um preço de venda antes de concluir."},{"REVISION_CONFLICT","A ficha mudou em outra sessão. Reabra e confira as informações."},{"EMPTY_CART","Adicione uma peça ao carrinho."},{"UNIT_IN_CART","Remova a peça do carrinho antes de ajustar o estoque."},{"INVALID_FIELD","Confira os campos. Nome: até 50 caracteres; marca: até 20."},{"INVALID_PRICE","Informe valores positivos com até quatro casas decimais."}};return errors.ContainsKey(ex.Message)?errors[ex.Message]:ex.Message;}
  static DataTable Table(IEnumerable<Dictionary<string,object>> rows,params string[] columns){var t=new DataTable();foreach(var col in columns)t.Columns.Add(col);foreach(var row in rows)t.Rows.Add(columns.Select(col=>row.ContainsKey(col)?Convert.ToString(row[col],CultureInfo.GetCultureInfo("pt-BR")):"").ToArray());return t;}
  static void Headers(DataGridView grid){
   var labels=new Dictionary<string,string>{{"name","PRODUTO"},{"barcode","CÓDIGO"},{"variant","COR / TAM."},{"price","PREÇO"},{"state","SITUAÇÃO"}};
   foreach(DataGridViewColumn col in grid.Columns){col.HeaderText=labels.ContainsKey(col.Name)?labels[col.Name]:col.Name;col.SortMode=DataGridViewColumnSortMode.NotSortable;}
   if(!grid.Columns.Contains("state"))return;
   grid.Columns["name"].FillWeight=29;grid.Columns["name"].MinimumWidth=112;
   grid.Columns["barcode"].FillWeight=26;grid.Columns["barcode"].MinimumWidth=124;grid.Columns["barcode"].DefaultCellStyle.Font=DesktopTheme.TextFont(8);
   grid.Columns["variant"].FillWeight=16;grid.Columns["variant"].MinimumWidth=86;
   grid.Columns["price"].FillWeight=14;grid.Columns["price"].MinimumWidth=82;grid.Columns["price"].DefaultCellStyle.Format="C2";grid.Columns["price"].DefaultCellStyle.FormatProvider=CultureInfo.GetCultureInfo("pt-BR");grid.Columns["price"].DefaultCellStyle.Alignment=DataGridViewContentAlignment.MiddleRight;grid.Columns["price"].HeaderCell.Style.Alignment=DataGridViewContentAlignment.MiddleRight;
   grid.Columns["state"].FillWeight=17;grid.Columns["state"].MinimumWidth=100;
  }
  string Selected(DataGridView grid){if(grid.CurrentRow==null)throw new DomainError("Selecione uma peça.");return Convert.ToString(grid.CurrentRow.Cells["barcode"].Value);}
  void RefreshData(){
   var catalog=store.Catalog();var current=store.Cart();var items=(List<Dictionary<string,object>>)current["items"];
   string signature=Json.Hash(Json.Write(catalog));bool changed=signature!=inventorySignature;
   cartCodes=new HashSet<string>(items.Select(x=>Convert.ToString(x["barcode"])));
   if(changed){catalogRows=catalog;inventorySignature=signature;}
   // A change in the SIC catalog can affect a cart price without advancing the local cart version.
   var version=Convert.ToInt64(current["version"]);if(changed||version!=cartVersion){BindInventory();BindCart(items);cartVersion=version;}
   total.Text=Convert.ToDecimal(current["total"]).ToString("C",CultureInfo.GetCultureInfo("pt-BR"));
   float totalSize=total.Text.Length>13?17:23;if(total.Font.Size!=totalSize)total.Font=DesktopTheme.TextFont(totalSize,FontStyle.Bold);
   cartCount.Text=items.Count+(items.Count==1?" item":" itens");pieceCount.Text=items.Count+(items.Count==1?" peça":" peças");payment.Enabled=items.Count>0;confirmButton.Enabled=items.Count>0;
   status.Text=backgroundSync.State=="conflict"?"Uma peça precisa de conferência. Abra Configurações.":"Alterações salvas";UpdateSelection();
  }
  static string Variant(Dictionary<string,object> row){var values=new[]{Convert.ToString(row["color"]),Convert.ToString(row["size"])}.Where(x=>!String.IsNullOrWhiteSpace(x));var text=String.Join(" · ",values);return text.Length==0?"—":text;}
  string State(Dictionary<string,object> row){if(Convert.ToBoolean(row["conflict"]))return "Em conflito";if(Convert.ToDecimal(row["quantity"]??0)!=1)return "Sem saldo";return cartCodes.Contains(Convert.ToString(row["barcode"]))?"No caixa":"Disponível";}
  void BindInventory(){
   if(addButton==null)return;
   string selected=inventory.CurrentRow==null?null:Convert.ToString(inventory.CurrentRow.Cells["barcode"].Value),query=search.Text.Trim();
   var visible=catalogRows.Where(row=>{
    bool matches=query.Length==0||new[]{"name","barcode","brand","color","size","internal_code"}.Any(key=>CultureInfo.GetCultureInfo("pt-BR").CompareInfo.IndexOf(Convert.ToString(row[key]),query,CompareOptions.IgnoreCase|CompareOptions.IgnoreNonSpace)>=0);
    string state=State(row);int filter=stockFilter.SelectedIndex;
    return matches&&(filter<1||filter==1&&state=="Disponível"||filter==2&&state=="No caixa"||filter==3&&state=="Sem saldo"||filter==4&&state=="Em conflito");
   }).ToList();
   var table=new DataTable();table.Columns.Add("name");table.Columns.Add("barcode");table.Columns.Add("variant");table.Columns.Add("price",typeof(decimal));table.Columns.Add("state");
   foreach(var row in visible)table.Rows.Add(row["name"],row["barcode"],Variant(row),Convert.ToDecimal(row["price"]??0),State(row));
   inventory.DataSource=table;Headers(inventory);FitInventoryColumns();
   if(selected!=null)foreach(DataGridViewRow row in inventory.Rows)if(Convert.ToString(row.Cells["barcode"].Value)==selected){inventory.CurrentCell=row.Cells[0];break;}
   catalogCount.Text=(visible.Count==catalogRows.Count?catalogRows.Count+" peças cadastradas":visible.Count+" de "+catalogRows.Count+" peças");
   inventoryEmpty.Heading=catalogRows.Count==0?"Nenhuma peça cadastrada":"Nenhuma peça encontrada";inventoryEmpty.Description=catalogRows.Count==0?"Use Novo produto para cadastrar suas primeiras peças.":"Tente outro termo ou altere o filtro de situação.";
   inventory.Visible=visible.Count>0;inventoryEmpty.Visible=visible.Count==0;inventoryEmpty.Invalidate();if(inventoryEmpty.Visible)inventoryEmpty.BringToFront();UpdateSelection();
  }
  void FitInventoryColumns(){
   if(inventory.Columns.Count!=5)return;
   // Reserve the scrollbar gutter before distributing space; WinForms Fill can otherwise
   // introduce a horizontal scrollbar when the vertical one appears in a smaller window.
   inventory.AutoSizeColumnsMode=DataGridViewAutoSizeColumnsMode.None;
   inventory.Columns["barcode"].Visible=inventory.ClientSize.Width>=650;
   var columns=inventory.Columns.Cast<DataGridViewColumn>().Where(x=>x.Visible).ToList();
   int available=Math.Max(0,inventory.ClientSize.Width-SystemInformation.VerticalScrollBarWidth-2),minimum=columns.Sum(x=>x.MinimumWidth);
   int extra=Math.Max(0,available-minimum),assigned=0;float weight=columns.Sum(x=>x.FillWeight);
   for(int i=0;i<columns.Count;i++){var column=columns[i];int width=column.MinimumWidth+(int)(extra*column.FillWeight/weight);if(i==columns.Count-1)width=Math.Max(column.MinimumWidth,available-assigned);column.Width=width;assigned+=width;}inventory.Invalidate();
  }
  void BindCart(List<Dictionary<string,object>> items){
   int scroll=-cartItems.AutoScrollPosition.Y;cartItems.SuspendLayout();
   while(cartItems.Controls.Count>0){var old=cartItems.Controls[0];cartItems.Controls.Remove(old);old.Dispose();}
   foreach(var item in items){string barcode=Convert.ToString(item["barcode"]);var card=new CartItem(Convert.ToString(item["name"]),Variant(item),barcode,Convert.ToDecimal(item["price"]??0).ToString("C",CultureInfo.GetCultureInfo("pt-BR")),()=>Run(()=>RemoveItem(barcode)));cartItems.Controls.Add(card);}
   SizeCartItems();cartItems.ResumeLayout();cartItems.AutoScrollPosition=new Point(0,scroll);cartItems.Visible=items.Count>0;cartEmpty.Visible=items.Count==0;if(cartEmpty.Visible)cartEmpty.BringToFront();
  }
  void SizeCartItems(){foreach(Control child in cartItems.Controls)child.Width=Math.Max(100,cartItems.ClientSize.Width-2);}
  void UpdateSelection(){
   if(addButton==null)return;bool selected=inventory.CurrentRow!=null;editButton.Enabled=selected;adjustButton.Enabled=selected;
   string state=selected?Convert.ToString(inventory.CurrentRow.Cells["state"].Value):"";addButton.Enabled=selected&&state=="Disponível";selection.Text=selected?"1 peça selecionada" : "Selecione uma peça no estoque";
  }
  void PaintInventoryCell(object sender,DataGridViewCellPaintingEventArgs e){
   if(e.RowIndex<0||e.ColumnIndex<0)return;string column=inventory.Columns[e.ColumnIndex].Name;
   if(column!="state"&&column!="name")return;e.PaintBackground(e.ClipBounds,true);
   if(column=="state"){
    string text=Convert.ToString(e.FormattedValue);Color ink=Color.FromArgb(0,109,75),fill=Color.FromArgb(225,247,235);
    if(text=="No caixa"){ink=Color.FromArgb(146,82,9);fill=Color.FromArgb(255,239,204);}else if(text=="Em conflito"){ink=Color.FromArgb(165,48,52);fill=Color.FromArgb(255,231,231);}else if(text=="Sem saldo"){ink=DesktopTheme.Muted;fill=Color.FromArgb(237,241,246);}
    var badge=new Rectangle(e.CellBounds.X+7,e.CellBounds.Y+(e.CellBounds.Height-26)/2,e.CellBounds.Width-14,26);e.Graphics.SmoothingMode=System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
    using(var path=DesktopTheme.Round(badge,5))using(var brush=new SolidBrush(fill))e.Graphics.FillPath(brush,path);
    using(var font=DesktopTheme.TextFont(8.5f))TextRenderer.DrawText(e.Graphics,text,font,badge,ink,TextFormatFlags.HorizontalCenter|TextFormatFlags.VerticalCenter|TextFormatFlags.EndEllipsis);
   }else{
    bool compact=!inventory.Columns["barcode"].Visible;
    using(var font=DesktopTheme.TextFont(9.5f,FontStyle.Bold))TextRenderer.DrawText(e.Graphics,Convert.ToString(e.FormattedValue),font,new Rectangle(e.CellBounds.X+11,e.CellBounds.Y+(compact?9:4),e.CellBounds.Width-18,compact?24:e.CellBounds.Height-8),DesktopTheme.Ink,TextFormatFlags.VerticalCenter|TextFormatFlags.EndEllipsis|TextFormatFlags.NoPrefix);
    if(compact)using(var font=DesktopTheme.TextFont(8))TextRenderer.DrawText(e.Graphics,Convert.ToString(inventory.Rows[e.RowIndex].Cells["barcode"].Value),font,new Rectangle(e.CellBounds.X+11,e.CellBounds.Y+34,e.CellBounds.Width-18,20),DesktopTheme.Muted,TextFormatFlags.EndEllipsis|TextFormatFlags.NoPrefix);
    if((e.State&DataGridViewElementStates.Selected)!=0)using(var brush=new SolidBrush(DesktopTheme.Teal))e.Graphics.FillRectangle(brush,e.CellBounds.X,e.CellBounds.Y+8,3,e.CellBounds.Height-16);
   }
   e.Paint(e.ClipBounds,DataGridViewPaintParts.Border);e.Handled=true;
  }
  void Create(){using(var dialog=new FieldsDialog(null,true)){if(dialog.ShowDialog(this)!=DialogResult.OK)return;var fields=dialog.Values();var draft=Json.Read<ProductDraft>(Json.Write(fields));draft.request_id=Guid.NewGuid().ToString();draft.variants=dialog.Variants();var result=store.CreateProduct(draft);MessageBox.Show(this,((System.Collections.ICollection)result["units"]).Count+" peças criadas com códigos individuais na cópia do SIC.","Cadastro concluído");}}
  void Edit(){var unit=store.Lookup(Selected(inventory));using(var dialog=new FieldsDialog(unit,false)){if(dialog.ShowDialog(this)!=DialogResult.OK)return;var draft=Json.Read<EditDraft>(Json.Write(dialog.Values()));draft.request_id=Guid.NewGuid().ToString();draft.revision=Convert.ToInt64(unit["revision"]);store.Edit((string)unit["barcode"],draft);}}
  void AddSelected(){store.AddCart(new CartDraft{request_id=Guid.NewGuid().ToString(),barcode=Selected(inventory)});}
  void ExportLabels(){using(var file=new SaveFileDialog{Filter="Etiquetas imprimíveis (*.html)|*.html",FileName="etiquetas-lineboard.html"}){if(file.ShowDialog(this)!=DialogResult.OK)return;System.IO.File.WriteAllText(file.FileName,Labels.Html(store.Catalog().Where(x=>Convert.ToDecimal(x["quantity"])==1),50,30),System.Text.Encoding.UTF8);MessageBox.Show(this,"Etiquetas salvas. Abra o arquivo no navegador para imprimir.\nFormato inicial: 50 × 30 mm; a medida final depende da impressora escolhida.","Etiquetas individuais");}}
  public void RenderPreview(string path){
   renderingPreview=true;StartPosition=FormStartPosition.Manual;Location=new Point(-20000,-20000);ShowInTaskbar=false;Show();refreshTimer.Stop();RefreshData();Application.DoEvents();RenderChildren(this);
   using(var bitmap=new Bitmap(ClientSize.Width,ClientSize.Height)){Controls[0].DrawToBitmap(bitmap,new Rectangle(Point.Empty,ClientSize));bitmap.Save(path,System.Drawing.Imaging.ImageFormat.Png);}Hide();
  }
  static void RenderChildren(Control parent){parent.CreateControl();parent.PerformLayout();foreach(Control child in parent.Controls)RenderChildren(child);}
  void RemoveItem(string barcode){store.RemoveCart(new CartDraft{request_id=Guid.NewGuid().ToString(),barcode=barcode});}
  void Adjust(){var code=Selected(inventory);using(var dialog=new AdjustmentDialog()){if(dialog.ShowDialog(this)!=DialogResult.OK)return;store.Adjust(new AdjustmentDraft{request_id=Guid.NewGuid().ToString(),barcode=code,quantity=dialog.Quantity,reason=dialog.Reason});}}
  void Confirm(){
   if(pendingConfirmation==null){var current=store.Cart();if(MessageBox.Show(this,"Confirmar os itens e registrar o pagamento informado?\nTotal: "+Convert.ToDecimal(current["total"]).ToString("C",CultureInfo.GetCultureInfo("pt-BR"))+"\n\nTeste na cópia do SIC. Nenhuma cobrança ou nota será emitida.","Conferir venda",MessageBoxButtons.YesNo,MessageBoxIcon.Question)!=DialogResult.Yes)return;
    pendingConfirmation=Guid.NewGuid().ToString();pendingDraft=new ConfirmDraft{request_id=pendingConfirmation,version=Convert.ToInt64(current["version"]),payment=new[]{"pix","cash","credit","debit","google_pay"}[payment.SelectedIndex]};
   }
   try{var result=store.Confirm(pendingDraft);pendingConfirmation=null;pendingDraft=null;MessageBox.Show(this,"Venda gravada no laboratório. Registro SIC: "+result["sic_sale_id"]+"\nEstoque baixado uma vez. Pagamento apenas registrado.\nEmissão fiscal não solicitada.","Venda registrada");}
   catch(DomainError){pendingConfirmation=null;pendingDraft=null;throw;}
  }
  void ShowRows(string title,List<Dictionary<string,object>> rows){
   using(var form=new Form{Text=title,Width=1050,Height=640,MinimumSize=new Size(720,460)}){
    DesktopTheme.Form(form);var layout=DesktopTheme.Rows(68,-1,56);layout.Padding=new Padding(20);form.Controls.Add(layout);
    var heading=DesktopTheme.Rows(36,24);heading.Controls.Add(DesktopTheme.Label(title,19,DesktopTheme.Ink,FontStyle.Bold),0,0);heading.Controls.Add(DesktopTheme.Label(rows.Count+" registros locais",9,DesktopTheme.Muted),0,1);layout.Controls.Add(heading,0,0);
    var card=new Surface{Dock=DockStyle.Fill};layout.Controls.Add(card,0,1);
    if(rows.Count>0){var grid=Grid();grid.RowTemplate.Height=42;grid.AutoSizeColumnsMode=DataGridViewAutoSizeColumnsMode.DisplayedCells;grid.DataSource=Table(rows,rows[0].Keys.ToArray());
     var labels=new Dictionary<string,string>{{"id","Registro"},{"barcode","Código"},{"delta","Variação"},{"reason","Motivo"},{"sic_document_id","Documento SIC"},{"created_at","Data"},{"event_id","Evento"},{"kind","Operação"},{"payload","Dados do evento"},{"state","Situação"},{"attempts","Tentativas"},{"last_error","Último retorno"}};
     foreach(DataGridViewColumn col in grid.Columns){if(labels.ContainsKey(col.Name))col.HeaderText=labels[col.Name];col.MinimumWidth=100;}card.Controls.Add(grid);
    }else card.Controls.Add(new EmptyState{Heading="Nenhum registro por aqui",Description="As operações aparecerão nesta tela conforme você usar o sistema.",Glyph="history"});
    var close=new ActionButton{Text="Fechar",Dock=DockStyle.Right,Width=110,DialogResult=DialogResult.Cancel,Margin=new Padding(0,12,0,0)};layout.Controls.Add(close,0,2);form.CancelButton=close;form.ShowDialog(this);
   }
  }
 }
  internal sealed class LegacyFieldsDialog : Form {
  readonly Dictionary<string,TextBox> inputs=new Dictionary<string,TextBox>();readonly Dictionary<string,TextBox> taxes=new Dictionary<string,TextBox>();readonly DataGridView variants;
  readonly bool creating;
  readonly Label summaryName=DesktopTheme.Label("Produto novo",17,DesktopTheme.Ink,FontStyle.Bold),summaryPrice=DesktopTheme.Label("R$ 0,00",12,DesktopTheme.Ink),summaryVariants=DesktopTheme.Label("0",12,DesktopTheme.Ink),summaryPieces=DesktopTheme.Label("0",12,DesktopTheme.Ink);
   public LegacyFieldsDialog(Dictionary<string,object> current,bool creating){
   this.creating=creating;DesktopTheme.Form(this);Text=creating?"Novo produto":"Editar peça";Width=820;Height=780;MinimumSize=new Size(700,640);MinimizeBox=false;ShowInTaskbar=false;
   var root=DesktopTheme.Rows(82,-1,64);root.ColumnCount=2;root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,69));root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,31));root.Padding=new Padding(22,12,22,12);Controls.Add(root);Width=1120;MinimumSize=new Size(900,640);
   var heading=DesktopTheme.Rows(40,32);heading.Controls.Add(DesktopTheme.Label(creating?"Novo produto":"Editar peça",22,DesktopTheme.Ink,FontStyle.Bold),0,0);heading.Controls.Add(DesktopTheme.Label(creating?"Preencha a ficha e defina cores, tamanhos e quantidades na grade.":"As alterações serão aplicadas somente à peça selecionada.",9.5f,DesktopTheme.Muted),0,1);root.Controls.Add(heading,0,0);
   var tabs=new TabControl{Dock=DockStyle.Fill,Padding=new Point(20,10),Font=DesktopTheme.TextFont(10)};root.Controls.Add(tabs,0,1);var basics=new TabPage("Ficha do produto"){BackColor=Color.White};var taxPage=new TabPage("Dados fiscais"){BackColor=Color.White};tabs.TabPages.Add(basics);
   var fields=new TableLayoutPanel{Dock=DockStyle.Fill,AutoScroll=true,ColumnCount=2,Padding=new Padding(18)};fields.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute,170));fields.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100));basics.Controls.Add(fields);
   var labels=new[]{"Nome","Marca / fabricante","Cor","Tamanho","Preço de custo","Preço de venda","Localização","Referência da foto","Observações","Código interno"};
   var keys=new[]{"name","brand","color","size","cost","price","location","photo","notes","internal_code"};
   int fieldRow=0;for(int i=0;i<keys.Length;i++){var key=keys[i];object value=null;if(current!=null)current.TryGetValue(key=="photo"?"photo_path":key,out value);var box=new TextBox{Dock=DockStyle.Fill,Font=DesktopTheme.TextFont(11),Margin=new Padding(3,7,3,4),AccessibleName=labels[i],Text=value==null?(key=="cost"||key=="price"?"0,00":""):Convert.ToString(value,CultureInfo.GetCultureInfo("pt-BR"))};inputs[key]=box;if(creating&&(key=="color"||key=="size"))continue;fields.Controls.Add(DesktopTheme.Label(labels[i],10,DesktopTheme.Muted),0,fieldRow);fields.Controls.Add(box,1,fieldRow++);fields.RowStyles.Add(new RowStyle(SizeType.Absolute,43));}fields.RowCount=fieldRow+1;fields.RowStyles.Add(new RowStyle(SizeType.Percent,100));
   var fiscal=new TableLayoutPanel{Dock=DockStyle.Fill,AutoScroll=true,ColumnCount=2,Padding=new Padding(14)};fiscal.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute,200));fiscal.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100));taxPage.Controls.Add(fiscal);
   int row=0;foreach(var key in Fiscal.TextFields.Keys.Concat(Fiscal.Numbers)){object value=null;if(current!=null)current.TryGetValue(key,out value);var box=new TextBox{Dock=DockStyle.Fill,Font=DesktopTheme.TextFont(11),Margin=new Padding(3,7,3,4),AccessibleName=TaxLabel(key),Text=Convert.ToString(value,CultureInfo.GetCultureInfo("pt-BR"))};taxes[key]=box;fiscal.Controls.Add(DesktopTheme.Label(TaxLabel(key),10,DesktopTheme.Muted),0,row);fiscal.Controls.Add(box,1,row);fiscal.RowStyles.Add(new RowStyle(SizeType.Absolute,43));row++;}
   fiscal.RowCount=row+1;fiscal.RowStyles.Add(new RowStyle(SizeType.Percent,100));
   if(creating){var page=new TabPage("Grade e quantidades"){BackColor=Color.White,Padding=new Padding(16)};tabs.TabPages.Add(page);var grade=DesktopTheme.Rows(52,-1);grade.Controls.Add(DesktopTheme.Label("Cada peça recebe um código próprio. Preencha a última linha para adicionar uma variante.",9.5f,DesktopTheme.Muted),0,0);page.Controls.Add(grade);variants=new DataGridView{Dock=DockStyle.Fill,AllowUserToAddRows=true,AutoSizeColumnsMode=DataGridViewAutoSizeColumnsMode.Fill,AccessibleName="Grade de cores, tamanhos e quantidades"};DesktopTheme.Grid(variants);variants.RowTemplate.Height=44;variants.Columns.Add("color","COR");variants.Columns.Add("size","TAMANHO");variants.Columns.Add("quantity","QUANTIDADE DE PEÇAS");variants.Rows.Add("","",1);grade.Controls.Add(variants,0,1);inputs["color"].Enabled=false;inputs["size"].Enabled=false;}
   tabs.TabPages.Add(taxPage);
   var summary=BuildSummary();root.Controls.Add(summary,1,1);
   foreach(var box in inputs.Values)box.TextChanged+=(s,e)=>UpdateSummary();
   var bottom=new FlowLayoutPanel{Dock=DockStyle.Fill,FlowDirection=FlowDirection.RightToLeft,WrapContents=false,Padding=new Padding(0,14,0,0),Margin=Padding.Empty};var save=new ActionButton{Text=creating?"Cadastrar produto":"Salvar alterações",Primary=true,Width=166,Height=40,Margin=new Padding(8,0,0,0)};save.Click+=(s,e)=>{try{Validate();if(creating)variants.EndEdit();Values();if(creating)Variants();DialogResult=DialogResult.OK;Close();}catch(Exception ex){MessageBox.Show(this,ex.Message,"Confira os dados");}};bottom.Controls.Add(save);var cancel=new ActionButton{Text="Cancelar",DialogResult=DialogResult.Cancel,Width=110,Height=40};bottom.Controls.Add(cancel);root.Controls.Add(bottom,0,2);AcceptButton=save;CancelButton=cancel;
  }
  static string TaxLabel(string key){var labels=new Dictionary<string,string>{{"codipi","NCM"},{"cst","CST / CSOSN"},{"cean","GTIN do produto"},{"ceantrib","GTIN tributável"},{"cest","CEST"},{"icms","ICMS (%)"},{"ipi","IPI (%)"},{"origem","Origem"},{"cclasstrib","Classificação tributária"},{"ipi_cst","CST do IPI"},{"cst_pis","CST do PIS"},{"cst_cofins","CST da COFINS"},{"cbenef","Código de benefício fiscal"},{"cst_ibscbs","CST IBS / CBS"},{"basecalculo","Base de cálculo"},{"pesobruto","Peso bruto"},{"pesoliq","Peso líquido"},{"ipi_basecalc","Base de cálculo do IPI"},{"fcp","FCP (%)"},{"cprodanp","Código ANP"}};return labels.ContainsKey(key)?labels[key]:key;}
  public UnitFields Values(){decimal cost,price;if(!Decimal.TryParse(inputs["cost"].Text,NumberStyles.Number,CultureInfo.GetCultureInfo("pt-BR"),out cost)||!Decimal.TryParse(inputs["price"].Text,NumberStyles.Number,CultureInfo.GetCultureInfo("pt-BR"),out price))throw new DomainError("Confira os valores de custo e venda.");
   var f=new UnitFields{name=inputs["name"].Text,brand=inputs["brand"].Text,color=inputs["color"].Text,size=inputs["size"].Text,cost=cost,price=price,location=inputs["location"].Text,photo=inputs["photo"].Text,notes=inputs["notes"].Text,internal_code=inputs["internal_code"].Text,fiscal=new Dictionary<string,object>()};
   foreach(var entry in taxes){if(String.IsNullOrWhiteSpace(entry.Value.Text))continue;if(Fiscal.TextFields.ContainsKey(entry.Key))f.fiscal[entry.Key]=entry.Value.Text;else{decimal number;if(!Decimal.TryParse(entry.Value.Text,NumberStyles.Number,CultureInfo.GetCultureInfo("pt-BR"),out number))throw new DomainError("Confira o campo fiscal "+entry.Key);f.fiscal[entry.Key]=number;}}
   return Validation.Fields(f);
  }
  Control BuildSummary(){var card=new Surface{Dock=DockStyle.Fill,Padding=new Padding(18),Margin=new Padding(12,0,0,0)};var rows=DesktopTheme.Rows(46,50,44,44,54,-1);card.Controls.Add(rows);rows.Controls.Add(DesktopTheme.Label("Resumo do cadastro",17,DesktopTheme.Ink,FontStyle.Bold),0,0);rows.Controls.Add(summaryName,0,1);var line=DesktopTheme.Rows(30,30,30);line.Controls.Add(DesktopTheme.Label("Preço por peça",9.5f,DesktopTheme.Muted),0,0);line.Controls.Add(summaryPrice,1,0);line.Controls.Add(DesktopTheme.Label("Variações",9.5f,DesktopTheme.Muted),0,1);line.Controls.Add(summaryVariants,1,1);line.Controls.Add(DesktopTheme.Label("Peças a cadastrar",9.5f,DesktopTheme.Muted),0,2);line.Controls.Add(summaryPieces,1,2);rows.Controls.Add(line,0,2);var note=new Surface{Fill=Color.FromArgb(235,250,249),Edge=Color.FromArgb(158,231,226),Padding=new Padding(12,8,12,8),Dock=DockStyle.Fill};note.Controls.Add(DesktopTheme.Label("Cada peça recebe um código próprio.\nOs códigos são gerados automaticamente ao cadastrar.",9,Color.FromArgb(9,82,104)));rows.Controls.Add(note,0,3);var example=DesktopTheme.Label("Exemplo de etiqueta\n\n      |||||||||||||||\n\nCódigo gerado no cadastro",9,DesktopTheme.Muted);example.TextAlign=ContentAlignment.MiddleCenter;rows.Controls.Add(example,0,4);return card;}
  void UpdateSummary(){if(summaryName==null)return;string name=inputs.ContainsKey("name")?inputs["name"].Text.Trim():"";summaryName.Text=String.IsNullOrWhiteSpace(name)?"Produto novo":name;decimal price;if(!Decimal.TryParse(inputs.ContainsKey("price")?inputs["price"].Text:"0",NumberStyles.Number,CultureInfo.GetCultureInfo("pt-BR"),out price))price=0;summaryPrice.Text=price.ToString("C2",CultureInfo.GetCultureInfo("pt-BR"));int rows=0,pieces=0;if(variants!=null)foreach(DataGridViewRow row in variants.Rows){if(row.IsNewRow)continue;int q;if(Int32.TryParse(Convert.ToString(row.Cells[2].Value),out q)&&q>0){rows++;pieces+=q;}}summaryVariants.Text=rows.ToString();summaryPieces.Text=pieces.ToString();}
  public List<VariantDraft> Variants(){var result=new List<VariantDraft>();foreach(DataGridViewRow row in variants.Rows){if(row.IsNewRow)continue;int quantity;if(!Int32.TryParse(Convert.ToString(row.Cells[2].Value),out quantity)||quantity<1||quantity>500)throw new DomainError("Informe de 1 a 500 peças por variante.");result.Add(new VariantDraft{color=Convert.ToString(row.Cells[0].Value),size=Convert.ToString(row.Cells[1].Value),quantity=quantity});}if(result.Count==0)throw new DomainError("Adicione uma variante.");return result;}
 }
 public sealed class AdjustmentDialog : Form {
  readonly ComboBox quantity=new ComboBox{DropDownStyle=ComboBoxStyle.DropDownList,Dock=DockStyle.Fill};readonly TextBox reason=new TextBox{Dock=DockStyle.Fill,Multiline=true,MaxLength=500};
  public int Quantity{get{return quantity.SelectedIndex;}} public string Reason{get{return reason.Text;}}
  public AdjustmentDialog(){
   DesktopTheme.Form(this);Text="Entrada / ajuste";Size=new Size(510,414);FormBorderStyle=FormBorderStyle.FixedDialog;MinimizeBox=false;MaximizeBox=false;ShowInTaskbar=false;
   var root=DesktopTheme.Rows(42,36,26,38,28,-1,58);root.Padding=new Padding(24,14,24,16);Controls.Add(root);root.Controls.Add(DesktopTheme.Label("Entrada / ajuste",21,DesktopTheme.Ink,FontStyle.Bold),0,0);root.Controls.Add(DesktopTheme.Label("Atualize a disponibilidade da peça selecionada.",9.5f,DesktopTheme.Muted),0,1);
   root.Controls.Add(DesktopTheme.Label("Novo saldo",10),0,2);quantity.AccessibleName="Novo saldo";quantity.Items.AddRange(new object[]{"Indisponível (saldo 0)","Disponível (saldo 1)"});quantity.SelectedIndex=1;root.Controls.Add(quantity,0,3);root.Controls.Add(DesktopTheme.Label("Motivo do ajuste (obrigatório)",10),0,4);reason.AccessibleName="Motivo do ajuste";root.Controls.Add(reason,0,5);
   var bottom=new FlowLayoutPanel{Dock=DockStyle.Fill,FlowDirection=FlowDirection.RightToLeft,Padding=new Padding(0,12,0,0),Margin=Padding.Empty};var save=new ActionButton{Text="Registrar ajuste",Primary=true,Width=150,Height=40,Enabled=false,Margin=new Padding(8,0,0,0)};reason.TextChanged+=(s,e)=>save.Enabled=!String.IsNullOrWhiteSpace(reason.Text);save.Click+=(s,e)=>{if(!String.IsNullOrWhiteSpace(reason.Text))DialogResult=DialogResult.OK;};var cancel=new ActionButton{Text="Cancelar",DialogResult=DialogResult.Cancel,Width=106,Height=40};bottom.Controls.Add(save);bottom.Controls.Add(cancel);root.Controls.Add(bottom,0,6);AcceptButton=save;CancelButton=cancel;
  }
 }
}
