using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.Linq;
using System.Windows.Forms;

namespace Lineboard {
 // Cadastro visual do desktop. A ficha, a grade e o resumo ficam no mesmo fluxo
 // para que o operador possa conferir o resultado antes de gravar no SIC de laboratório.
 public sealed class FieldsDialog : Form {
  static readonly CultureInfo Pt = CultureInfo.GetCultureInfo("pt-BR");
  readonly Dictionary<string,TextBox> inputs = new Dictionary<string,TextBox>();
  readonly Dictionary<string,TextBox> taxes = new Dictionary<string,TextBox>();
  readonly bool creating;
  DataGridView variants;
  readonly Label summaryName = DesktopTheme.Label("Produto novo",17,DesktopTheme.Ink,FontStyle.Bold);
  readonly Label summaryPrice = DesktopTheme.Label("R$ 0,00",11,DesktopTheme.Ink,FontStyle.Bold);
  readonly Label summaryVariants = DesktopTheme.Label("0",11,DesktopTheme.Ink,FontStyle.Bold);
  readonly Label summaryPieces = DesktopTheme.Label("0",11,DesktopTheme.Ink,FontStyle.Bold);
  readonly SampleLabel sample = new SampleLabel();
  Panel details;
  Surface additionalCard;
  ActionButton additionalToggle;
  readonly TableLayoutPanel leftContent;
  readonly Panel bodyScroll;
  readonly Dictionary<string,object> current;

  public FieldsDialog(Dictionary<string,object> current,bool creating) {
   this.current=current;this.creating=creating;
   DesktopTheme.Form(this);Text=creating?"Novo produto":"Editar peça";
   Width=1224;Height=794;MinimumSize=new Size(900,640);MinimizeBox=false;MaximizeBox=true;ShowInTaskbar=false;
   FormBorderStyle=FormBorderStyle.Sizable;Padding=Padding.Empty;

   var root=new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=1,RowCount=4,Padding=new Padding(26,16,26,14),Margin=Padding.Empty,BackColor=DesktopTheme.Canvas};
   root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100));
   root.RowStyles.Add(new RowStyle(SizeType.Absolute,72));
   root.RowStyles.Add(new RowStyle(SizeType.Absolute,38));
   root.RowStyles.Add(new RowStyle(SizeType.Percent,100));
   root.RowStyles.Add(new RowStyle(SizeType.Absolute,56));
   Controls.Add(root);

   root.Controls.Add(BuildHeader(),0,0);
   root.Controls.Add(BuildNotice(),0,1);

   var body=new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=3,RowCount=1,Margin=new Padding(0,14,0,10),Padding=Padding.Empty,BackColor=Color.Transparent};
   body.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100));body.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute,16));body.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute,330));
   body.RowStyles.Add(new RowStyle(SizeType.Percent,100));
   bodyScroll=new Panel{Dock=DockStyle.Fill,AutoScroll=true,BackColor=Color.Transparent,Margin=Padding.Empty,Padding=Padding.Empty};
   leftContent=new TableLayoutPanel{Dock=DockStyle.Top,AutoSize=true,AutoSizeMode=AutoSizeMode.GrowAndShrink,ColumnCount=1,RowCount=4,Margin=Padding.Empty,Padding=Padding.Empty,BackColor=Color.Transparent};
   leftContent.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100));
   leftContent.Controls.Add(BuildProductInfo(),0,0);
   leftContent.Controls.Add(BuildGrade(),0,1);
   additionalCard=BuildAdditional();
   leftContent.Controls.Add(additionalCard,0,2);
   leftContent.RowStyles.Add(new RowStyle(SizeType.AutoSize));leftContent.RowStyles.Add(new RowStyle(SizeType.AutoSize));leftContent.RowStyles.Add(new RowStyle(SizeType.AutoSize));leftContent.RowStyles.Add(new RowStyle(SizeType.Percent,100));
   bodyScroll.Controls.Add(leftContent);
   body.Controls.Add(bodyScroll,0,0);
   body.Controls.Add(BuildSummary(),2,0);
   root.Controls.Add(body,0,2);

   root.Controls.Add(BuildFooter(),0,3);
   bodyScroll.Resize+=(s,e)=>{leftContent.Width=Math.Max(0,bodyScroll.ClientSize.Width-(bodyScroll.VerticalScroll.Visible?SystemInformation.VerticalScrollBarWidth:0));};
   Shown+=(s,e)=>{leftContent.Width=Math.Max(0,bodyScroll.ClientSize.Width-(bodyScroll.VerticalScroll.Visible?SystemInformation.VerticalScrollBarWidth:0));UpdateSummary();};
   UpdateSummary();
  }

  Control BuildHeader() {
   var header=new Panel{Dock=DockStyle.Fill,Margin=Padding.Empty,BackColor=Color.Transparent};
   var title=DesktopTheme.Label(creating?"Novo produto":"Editar peça",25,DesktopTheme.Ink,FontStyle.Bold);title.SetBounds(0,0,Math.Max(300,ClientSize.Width-180),36);title.Anchor=AnchorStyles.Left|AnchorStyles.Top|AnchorStyles.Right;
   var subtitle=DesktopTheme.Label(creating?"Cadastre o produto e informe as peças disponíveis.":"Altere os dados da peça selecionada.",10.5f,DesktopTheme.Muted);subtitle.SetBounds(0,39,Math.Max(300,ClientSize.Width-180),25);subtitle.Anchor=AnchorStyles.Left|AnchorStyles.Top|AnchorStyles.Right;
   var badge=new PreviewBadge{Text="PRÉVIA VISUAL",Size=new Size(112,29),Location=new Point(265,4),Anchor=AnchorStyles.Top|AnchorStyles.Left};
   var back=new ActionButton{Text="←  Voltar",Width=102,Height=38,Anchor=AnchorStyles.Top|AnchorStyles.Right,Margin=Padding.Empty};back.Location=new Point(Math.Max(0,ClientSize.Width-102),2);back.Click+=(s,e)=>{DialogResult=DialogResult.Cancel;Close();};
   header.Controls.Add(title);header.Controls.Add(subtitle);if(creating)header.Controls.Add(badge);header.Controls.Add(back);
   header.Resize+=(s,e)=>{title.Width=Math.Max(300,header.ClientSize.Width-180);subtitle.Width=title.Width;back.Left=header.ClientSize.Width-back.Width;};
   return header;
  }

  Control BuildNotice() {
   var notice=new Surface{Dock=DockStyle.Fill,Fill=Color.FromArgb(255,248,231),Edge=Color.FromArgb(244,214,161),Padding=new Padding(14,0,12,0),Margin=Padding.Empty};
   var label=DesktopTheme.Label("Ambiente de teste  •  Emissão fiscal indisponível",9.5f,Color.FromArgb(136,79,14));label.Padding=new Padding(30,0,0,0);
   label.Paint+=(s,e)=>DesktopTheme.Icon(e.Graphics,"info",new Rectangle(0,(label.Height-21)/2,21,21),Color.FromArgb(180,112,18));notice.Controls.Add(label);return notice;
  }

  Control BuildProductInfo() {
   int rowCount=creating?4:5;
   var card=new Surface{Dock=DockStyle.Top,Height=creating?210:266,Margin=new Padding(0,0,0,12),Padding=new Padding(18,13,18,11)};
   var layout=new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=2,RowCount=rowCount,Margin=Padding.Empty,Padding=Padding.Empty};
   layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,50));layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,50));
   layout.RowStyles.Add(new RowStyle(SizeType.Absolute,34));
   layout.RowStyles.Add(new RowStyle(SizeType.Absolute,55));
   layout.RowStyles.Add(new RowStyle(SizeType.Absolute,55));
   layout.RowStyles.Add(new RowStyle(SizeType.Absolute,55));
   if(!creating)layout.RowStyles.Add(new RowStyle(SizeType.Absolute,55));
   layout.Controls.Add(SectionHeader("1","Informações do produto"),0,0);layout.SetColumnSpan(layout.GetControlFromPosition(0,0),2);
   layout.Controls.Add(FieldBlock("name","Nome do produto *",Value("name"),false),0,1);layout.SetColumnSpan(layout.GetControlFromPosition(0,1),2);
   layout.Controls.Add(FieldBlock("brand","Marca (opcional)",Value("brand"),false),0,2);
   layout.Controls.Add(FieldBlock("internal_code","Código interno (opcional)",Value("internal_code"),false),1,2);
   layout.Controls.Add(FieldBlock("cost","Preço de custo",Value("cost",true),true),0,3);
   layout.Controls.Add(FieldBlock("price","Preço de venda *",Value("price",true),true),1,3);
   if(!creating){layout.Controls.Add(FieldBlock("color","Cor",Value("color"),false),0,4);layout.Controls.Add(FieldBlock("size","Tamanho",Value("size"),false),1,4);}
   card.Controls.Add(layout);

   // A criação usa a grade como fonte das variações; os campos continuam no
   // dicionário para que o contrato de UnitFields permaneça igual ao da edição.
   if(creating){inputs["color"]=NewInput("color",Value("color"));inputs["size"]=NewInput("size",Value("size"));inputs["color"].Visible=false;inputs["size"].Visible=false;}
   return card;
  }

  Control BuildGrade() {
   var card=new Surface{Dock=DockStyle.Top,Height=creating?245:184,Margin=new Padding(0,0,0,12),Padding=new Padding(18,13,18,10)};
   var layout=new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=1,RowCount=4,Margin=Padding.Empty,Padding=Padding.Empty};layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100));
   layout.RowStyles.Add(new RowStyle(SizeType.Absolute,34));layout.RowStyles.Add(new RowStyle(SizeType.Absolute,28));layout.RowStyles.Add(new RowStyle(SizeType.Percent,100));layout.RowStyles.Add(new RowStyle(SizeType.Absolute,36));
   layout.Controls.Add(SectionHeader("2","Cores, tamanhos e quantidades"),0,0);
   var helper=DesktopTheme.Label(creating?"Adicione uma linha para cada combinação de cor e tamanho.":"Variação da peça selecionada.",9.5f,DesktopTheme.Muted);helper.Padding=new Padding(32,0,0,0);layout.Controls.Add(helper,0,1);
   BuildVariantsGrid();layout.Controls.Add(variants,0,2);
   var footer=new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=2,RowCount=1,Margin=Padding.Empty};footer.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100));footer.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
   if(creating){var add=new ActionButton{Text="Adicionar variação",Glyph="plus",Width=164,Height=32,Margin=Padding.Empty};add.Click+=(s,e)=>{variants.Rows.Add("","",1,"−","+","×");UpdateSummary();};footer.Controls.Add(add,0,0);}
   var total=DesktopTheme.Label("0 peças no total",9,DesktopTheme.Muted,FontStyle.Bold);total.Name="gradeTotal";total.TextAlign=ContentAlignment.MiddleRight;footer.Controls.Add(total,1,0);layout.Controls.Add(footer,0,3);card.Controls.Add(layout);
   return card;
  }

  void BuildVariantsGrid() {
   variants=new DataGridView{Dock=DockStyle.Fill,ReadOnly=false,AllowUserToAddRows=false,AllowUserToDeleteRows=false,MultiSelect=false,SelectionMode=DataGridViewSelectionMode.CellSelect,AutoGenerateColumns=false,AutoSizeColumnsMode=DataGridViewAutoSizeColumnsMode.Fill,AccessibleName="Grade de cores, tamanhos e quantidades",Margin=Padding.Empty};
   DesktopTheme.Grid(variants);variants.RowTemplate.Height=32;variants.ColumnHeadersHeight=28;variants.DefaultCellStyle.Padding=new Padding(6,0,6,0);
   var colors=new DataGridViewComboBoxColumn{Name="color",HeaderText="COR",FlatStyle=FlatStyle.Flat,FillWeight=30};colors.Items.AddRange(new object[]{"","Preta","Branca","Azul","Verde","Vermelha","Amarela","Areia","Bege","Cinza"});
   var sizes=new DataGridViewComboBoxColumn{Name="size",HeaderText="TAMANHO",FlatStyle=FlatStyle.Flat,FillWeight=20};sizes.Items.AddRange(new object[]{"","PP","P","M","G","GG","36","38","40","42","44"});
   var quantity=new DataGridViewTextBoxColumn{Name="quantity",HeaderText="QUANTIDADE",FillWeight=15};quantity.DefaultCellStyle.Alignment=DataGridViewContentAlignment.MiddleCenter;
   var minus=new DataGridViewButtonColumn{Name="minus",HeaderText="",Text="−",UseColumnTextForButtonValue=true,FillWeight=7};
   var plus=new DataGridViewButtonColumn{Name="plus",HeaderText="",Text="+",UseColumnTextForButtonValue=true,FillWeight=7};
   var remove=new DataGridViewButtonColumn{Name="remove",HeaderText="",Text="×",UseColumnTextForButtonValue=true,FillWeight=8};
   variants.Columns.Add(colors);variants.Columns.Add(sizes);variants.Columns.Add(quantity);variants.Columns.Add(minus);variants.Columns.Add(plus);variants.Columns.Add(remove);
   if(current!=null){AddComboValue(colors,Value("color"));AddComboValue(sizes,Value("size"));variants.Rows.Add(Value("color"),Value("size"),1,"−","+","×");variants.ReadOnly=true;}
   else variants.Rows.Add("","",1,"−","+","×");
   variants.CellContentClick+=(s,e)=>{
    if(e.RowIndex<0||e.ColumnIndex<0||variants.ReadOnly)return;string name=variants.Columns[e.ColumnIndex].Name;
    if(name=="minus"||name=="plus"){int q=QuantityAt(e.RowIndex);q=name=="minus"?Math.Max(1,q-1):Math.Min(500,q+1);variants.Rows[e.RowIndex].Cells["quantity"].Value=q;variants.EndEdit();UpdateSummary();}
    else if(name=="remove"){variants.Rows.RemoveAt(e.RowIndex);if(variants.Rows.Count==0)variants.Rows.Add("","",1,"−","+","×");UpdateSummary();}
   };
   variants.CellValueChanged+=(s,e)=>UpdateSummary();variants.RowsRemoved+=(s,e)=>UpdateSummary();variants.CellEndEdit+=(s,e)=>UpdateSummary();
   variants.CurrentCellDirtyStateChanged+=(s,e)=>{if(variants.IsCurrentCellDirty)variants.CommitEdit(DataGridViewDataErrorContexts.Commit);};
   variants.DataError+=(s,e)=>{e.ThrowException=false;};
   variants.CellPainting+=PaintVariantCell;
  }

  static void AddComboValue(DataGridViewComboBoxColumn column,string value){if(String.IsNullOrWhiteSpace(value))return;if(!column.Items.Contains(value))column.Items.Add(value);}

  void PaintVariantCell(object sender,DataGridViewCellPaintingEventArgs e) {
   if(e.RowIndex<0||e.ColumnIndex<0)return;string name=variants.Columns[e.ColumnIndex].Name;
   if(name!="remove"&&name!="minus"&&name!="plus")return;
   e.PaintBackground(e.CellBounds,true);e.Graphics.SmoothingMode=SmoothingMode.AntiAlias;
   Color ink=name=="remove"?Color.FromArgb(224,58,66):DesktopTheme.Accent;
   using(var font=DesktopTheme.TextFont(13,FontStyle.Bold))TextRenderer.DrawText(e.Graphics,name=="minus"?"−":name=="plus"?"+":"×",font,e.CellBounds,ink,TextFormatFlags.HorizontalCenter|TextFormatFlags.VerticalCenter);
   e.Paint(e.ClipBounds,DataGridViewPaintParts.Border);e.Handled=true;
  }

  Control BuildSummary() {
   var card=new Surface{Dock=DockStyle.Fill,Padding=new Padding(18),Margin=Padding.Empty};
   var rows=new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=1,RowCount=8,Margin=Padding.Empty,Padding=Padding.Empty};rows.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100));
   rows.RowStyles.Add(new RowStyle(SizeType.Absolute,35));rows.RowStyles.Add(new RowStyle(SizeType.Absolute,51));rows.RowStyles.Add(new RowStyle(SizeType.Absolute,1));
   rows.RowStyles.Add(new RowStyle(SizeType.Absolute,42));rows.RowStyles.Add(new RowStyle(SizeType.Absolute,42));rows.RowStyles.Add(new RowStyle(SizeType.Absolute,42));rows.RowStyles.Add(new RowStyle(SizeType.Absolute,101));rows.RowStyles.Add(new RowStyle(SizeType.Percent,100));
   rows.Controls.Add(DesktopTheme.Label("Resumo do cadastro",17,DesktopTheme.Ink,FontStyle.Bold),0,0);summaryName.AutoEllipsis=true;summaryName.Padding=new Padding(0,4,0,0);rows.Controls.Add(summaryName,0,1);
   var divider=new Panel{Dock=DockStyle.Fill,BackColor=DesktopTheme.Border,Margin=Padding.Empty};rows.Controls.Add(divider,0,2);
   rows.Controls.Add(Metric("Preço por peça",summaryPrice),0,3);rows.Controls.Add(Metric("Variações",summaryVariants),0,4);rows.Controls.Add(Metric("Peças a cadastrar",summaryPieces),0,5);
   var note=new Surface{Dock=DockStyle.Fill,Fill=Color.FromArgb(247,247,247),Edge=Color.FromArgb(215,215,215),Padding=new Padding(12,8,12,8),Margin=new Padding(0,10,0,10)};
   var noteText=DesktopTheme.Label("Cada peça recebe um código próprio.\nOs códigos são gerados automaticamente ao cadastrar.",9,Color.FromArgb(68,68,68));noteText.TextAlign=ContentAlignment.MiddleLeft;note.Controls.Add(noteText);rows.Controls.Add(note,0,6);
   sample.Dock=DockStyle.Fill;sample.Margin=new Padding(0,8,0,0);sample.AccessibleName="Exemplo de etiqueta; código gerado no cadastro";rows.Controls.Add(sample,0,7);card.Controls.Add(rows);return card;
  }

  static Control Metric(string label,Label value) {
   var row=new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=2,RowCount=1,Margin=Padding.Empty,Padding=Padding.Empty};row.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100));row.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute,95));
   var text=DesktopTheme.Label(label,9.5f,DesktopTheme.Muted);text.TextAlign=ContentAlignment.MiddleLeft;value.TextAlign=ContentAlignment.MiddleRight;value.Dock=DockStyle.Fill;row.Controls.Add(text,0,0);row.Controls.Add(value,1,0);return row;
  }

  Surface BuildAdditional() {
   var card=new Surface{Dock=DockStyle.Top,AutoSize=true,AutoSizeMode=AutoSizeMode.GrowAndShrink,Margin=new Padding(0,0,0,12),Padding=Padding.Empty};
   var outer=new TableLayoutPanel{Dock=DockStyle.Fill,AutoSize=true,AutoSizeMode=AutoSizeMode.GrowAndShrink,ColumnCount=1,RowCount=2,Margin=Padding.Empty,Padding=Padding.Empty};outer.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100));outer.RowStyles.Add(new RowStyle(SizeType.Absolute,44));outer.RowStyles.Add(new RowStyle(SizeType.AutoSize));
   additionalToggle=new ActionButton{Text="  Informações adicionais     Localização, observações e dados fiscais",Glyph="plus",Dock=DockStyle.Fill,Margin=Padding.Empty,TextAlign=ContentAlignment.MiddleLeft};additionalToggle.Click+=(s,e)=>ToggleAdditional();outer.Controls.Add(additionalToggle,0,0);
   details=new Panel{Dock=DockStyle.Top,AutoSize=true,AutoSizeMode=AutoSizeMode.GrowAndShrink,Visible=false,Padding=new Padding(18,8,18,14),BackColor=Color.White};details.Controls.Add(BuildAdditionalContent());outer.Controls.Add(details,0,1);card.Controls.Add(outer);return card;
  }

  Control BuildAdditionalContent() {
   var content=new TableLayoutPanel{Dock=DockStyle.Top,AutoSize=true,AutoSizeMode=AutoSizeMode.GrowAndShrink,ColumnCount=2,Margin=Padding.Empty,Padding=Padding.Empty};content.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,50));content.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,50));
   content.RowStyles.Add(new RowStyle(SizeType.Absolute,55));content.RowStyles.Add(new RowStyle(SizeType.Absolute,80));
   content.Controls.Add(FieldBlock("location","Localização",Value("location"),false),0,0);content.Controls.Add(FieldBlock("photo","Referência da foto",Value("photo_path"),false),1,0);
   content.Controls.Add(FieldBlock("notes","Observações",Value("notes"),false,true),0,1);content.SetColumnSpan(content.GetControlFromPosition(0,1),2);
   var fiscalTitle=DesktopTheme.Label("Dados fiscais",12,DesktopTheme.Ink,FontStyle.Bold);fiscalTitle.Padding=new Padding(0,10,0,0);content.Controls.Add(fiscalTitle,0,2);content.SetColumnSpan(fiscalTitle,2);content.RowStyles.Add(new RowStyle(SizeType.Absolute,32));
   var fiscal=new TableLayoutPanel{Dock=DockStyle.Top,AutoSize=true,AutoSizeMode=AutoSizeMode.GrowAndShrink,ColumnCount=2,Margin=Padding.Empty,Padding=Padding.Empty};fiscal.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,50));fiscal.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,50));
   var keys=Fiscal.TextFields.Keys.Concat(Fiscal.Numbers).ToArray();int row=0;for(int i=0;i<keys.Length;i+=2){fiscal.RowStyles.Add(new RowStyle(SizeType.Absolute,55));var first=FieldTax(keys[i]);fiscal.Controls.Add(first,0,row);if(i+1<keys.Length)fiscal.Controls.Add(FieldTax(keys[i+1]),1,row);row++;}fiscal.RowCount=row;content.Controls.Add(fiscal,0,3);content.SetColumnSpan(fiscal,2);content.RowStyles.Add(new RowStyle(SizeType.AutoSize));return content;
  }

  Control FieldTax(string key) {
   object value=null;if(current!=null)current.TryGetValue(key,out value);var box=NewInput(key,Format(value));taxes[key]=box;return FieldBlock(box,TaxLabel(key));
  }

  void ToggleAdditional() {
   details.Visible=!details.Visible;additionalToggle.Glyph=details.Visible?"close":"plus";additionalToggle.Text=details.Visible?"  Informações adicionais     Ocultar localização, observações e dados fiscais":"  Informações adicionais     Localização, observações e dados fiscais";additionalCard.Height=details.Visible?details.PreferredSize.Height+44:44;leftContent.PerformLayout();bodyScroll.PerformLayout();
  }

  Control BuildFooter() {
   var footer=new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=2,RowCount=1,Margin=Padding.Empty,Padding=Padding.Empty};footer.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100));footer.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
   var hint=DesktopTheme.Label(creating?"Confira as quantidades antes de cadastrar.":"As alterações serão gravadas na peça selecionada.",8.5f,DesktopTheme.Muted);hint.Padding=new Padding(4,9,0,0);footer.Controls.Add(hint,0,0);
   var buttons=new FlowLayoutPanel{Dock=DockStyle.Fill,FlowDirection=FlowDirection.RightToLeft,WrapContents=false,Margin=Padding.Empty,Padding=new Padding(0,2,0,0),AutoSize=true};
   var save=new ActionButton{Text=creating?"Cadastrar produto":"Salvar alterações",Primary=true,Width=174,Height=42,Margin=new Padding(8,0,0,0)};save.Click+=(s,e)=>SaveDraft();
   var cancel=new ActionButton{Text="Cancelar",Width=112,Height=42,DialogResult=DialogResult.Cancel,Margin=Padding.Empty};buttons.Controls.Add(save);buttons.Controls.Add(cancel);footer.Controls.Add(buttons,1,0);AcceptButton=save;CancelButton=cancel;return footer;
  }

  void SaveDraft() {
   try { if(creating)variants.EndEdit();Values();if(creating)Variants();DialogResult=DialogResult.OK;Close(); }
   catch(Exception ex) { MessageBox.Show(this,MessageFor(ex),"Confira os dados",MessageBoxButtons.OK,MessageBoxIcon.Warning); }
  }

  static string MessageFor(Exception ex) {
   var error=ex as DomainError;if(error==null)return ex.Message;
   var messages=new Dictionary<string,string>{{"INVALID_FIELD","Informe o nome e confira os campos de texto."},{"INVALID_PRICE","Informe valores de custo e venda positivos, com até quatro casas decimais."},{"INVALID_VARIANTS","Confira as cores, tamanhos e quantidades da grade."},{"INVALID_FISCAL_FIELD","Confira o valor de um dos campos fiscais."}};
   return messages.ContainsKey(error.Code)?messages[error.Code]:ex.Message;
  }

  Control SectionHeader(string number,string title) {
   var flow=new FlowLayoutPanel{Dock=DockStyle.Fill,FlowDirection=FlowDirection.LeftToRight,WrapContents=false,Margin=Padding.Empty,Padding=Padding.Empty};flow.Controls.Add(new SectionBadge(number));var text=DesktopTheme.Label(title,12.5f,DesktopTheme.Ink,FontStyle.Bold);text.AutoSize=false;text.Width=420;text.Padding=new Padding(9,0,0,0);flow.Controls.Add(text);return flow;
  }

  Control FieldBlock(string key,string label,string value,bool money,bool multiline=false) { return FieldBlock(CreateInput(key,value,money,multiline),label); }
  Control FieldBlock(Control box,string label) {
   var block=new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=1,RowCount=2,Margin=new Padding(0,0,8,4),Padding=Padding.Empty};block.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100));block.RowStyles.Add(new RowStyle(SizeType.Absolute,19));block.RowStyles.Add(new RowStyle(SizeType.Percent,100));
   block.Controls.Add(DesktopTheme.Label(label,9.5f,DesktopTheme.Muted),0,0);block.Controls.Add(box,0,1);return block;
  }

  Control CreateInput(string key,string value,bool money=false,bool multiline=false) {
   var box=NewInput(key,value);box.Multiline=multiline;box.ScrollBars=multiline?ScrollBars.Vertical:ScrollBars.None;box.Height=multiline?60:31;
   if(money){var editor=new Panel{Dock=DockStyle.Fill,BackColor=Color.White,BorderStyle=BorderStyle.FixedSingle,Margin=Padding.Empty};var currency=DesktopTheme.Label("R$",9.5f,DesktopTheme.Muted);currency.Dock=DockStyle.Left;currency.Width=31;currency.TextAlign=ContentAlignment.MiddleCenter;box.BorderStyle=BorderStyle.None;box.Dock=DockStyle.Fill;box.Margin=Padding.Empty;editor.Controls.Add(box);editor.Controls.Add(currency);var holder=new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=1,RowCount=1,Margin=Padding.Empty,Padding=Padding.Empty};holder.Controls.Add(editor,0,0);return AttachInput(key,box,holder);}
   return AttachInput(key,box,box);
  }

  Control AttachInput(string key,TextBox box,Control container) {
   inputs[key]=box;box.AccessibleName=key;box.Font=DesktopTheme.TextFont(10.5f);box.BackColor=Color.White;box.ForeColor=DesktopTheme.Ink;box.Margin=Padding.Empty;if(box.BorderStyle!=BorderStyle.None)box.BorderStyle=BorderStyle.FixedSingle;box.TextChanged+=(s,e)=>UpdateSummary();return container;
  }

  TextBox NewInput(string key,string value) {
   var box=new TextBox{Text=value??"",Dock=DockStyle.Fill,BorderStyle=BorderStyle.FixedSingle,Font=DesktopTheme.TextFont(10.5f),BackColor=Color.White,ForeColor=DesktopTheme.Ink,Margin=Padding.Empty,AccessibleName=key};return box;
  }

  string Value(string key,bool monetary=false) {object value=null;if(current!=null){string lookup=key=="photo"?"photo_path":key;current.TryGetValue(lookup,out value);}if(value==null)return monetary?"0,00":"";return monetary?Format(value):Convert.ToString(value,Pt);}
  static string Format(object value) {if(value==null)return "";decimal decimalValue;try{decimalValue=Convert.ToDecimal(value,CultureInfo.InvariantCulture);}catch{return Convert.ToString(value,Pt);}return decimalValue.ToString("N2",Pt);}

  static int QuantityAt(DataGridViewRow row) {int quantity;if(row==null||!Int32.TryParse(Convert.ToString(row.Cells["quantity"].Value),NumberStyles.Integer,CultureInfo.InvariantCulture,out quantity))quantity=1;return Math.Max(1,Math.Min(500,quantity));}
  int QuantityAt(int row) {return QuantityAt(variants.Rows[row]);}

  public UnitFields Values() {
   decimal cost,price;if(!Decimal.TryParse(inputs["cost"].Text,NumberStyles.Number,Pt,out cost)||!Decimal.TryParse(inputs["price"].Text,NumberStyles.Number,Pt,out price))throw new DomainError("INVALID_PRICE");
   var fields=new UnitFields{name=inputs["name"].Text,brand=inputs["brand"].Text,color=inputs.ContainsKey("color")?inputs["color"].Text:"",size=inputs.ContainsKey("size")?inputs["size"].Text:"",cost=cost,price=price,location=inputs.ContainsKey("location")?inputs["location"].Text:"",photo=inputs.ContainsKey("photo")?inputs["photo"].Text:"",notes=inputs.ContainsKey("notes")?inputs["notes"].Text:"",internal_code=inputs.ContainsKey("internal_code")?inputs["internal_code"].Text:"",fiscal=new Dictionary<string,object>()};
   foreach(var entry in taxes){if(String.IsNullOrWhiteSpace(entry.Value.Text))continue;if(Fiscal.TextFields.ContainsKey(entry.Key))fields.fiscal[entry.Key]=entry.Value.Text;else{decimal number;if(!Decimal.TryParse(entry.Value.Text,NumberStyles.Number,Pt,out number))throw new DomainError("INVALID_FISCAL_FIELD");fields.fiscal[entry.Key]=number;}}
   return Validation.Fields(fields);
  }

  public List<VariantDraft> Variants() {
   if(variants==null)throw new DomainError("INVALID_VARIANTS");variants.EndEdit();var result=new List<VariantDraft>();
   foreach(DataGridViewRow row in variants.Rows){if(row.IsNewRow)continue;string color=Convert.ToString(row.Cells["color"].Value).Trim(),size=Convert.ToString(row.Cells["size"].Value).Trim();int quantity;if(String.IsNullOrWhiteSpace(color)&&String.IsNullOrWhiteSpace(size))continue;if(String.IsNullOrWhiteSpace(color)||String.IsNullOrWhiteSpace(size)||!Int32.TryParse(Convert.ToString(row.Cells["quantity"].Value),NumberStyles.Integer,CultureInfo.InvariantCulture,out quantity)||quantity<1||quantity>500)throw new DomainError("INVALID_VARIANTS");result.Add(new VariantDraft{color=color,size=size,quantity=quantity});}
   if(result.Count==0)throw new DomainError("INVALID_VARIANTS");if(result.Count>100)throw new DomainError("INVALID_VARIANTS");return result;
  }

  static string TaxLabel(string key) {var labels=new Dictionary<string,string>{{"codipi","NCM"},{"cst","CST / CSOSN"},{"cean","GTIN do produto"},{"ceantrib","GTIN tributável"},{"cest","CEST"},{"icms","ICMS (%)"},{"ipi","IPI (%)"},{"origem","Origem"},{"cclasstrib","Classificação tributária"},{"ipi_cst","CST do IPI"},{"cst_pis","CST do PIS"},{"cst_cofins","CST da COFINS"},{"cbenef","Código de benefício fiscal"},{"cst_ibscbs","CST IBS / CBS"},{"basecalculo","Base de cálculo"},{"pesobruto","Peso bruto"},{"pesoliq","Peso líquido"},{"ipi_basecalc","Base de cálculo do IPI"},{"fcp","FCP (%)"},{"cprodanp","Código ANP"}};return labels.ContainsKey(key)?labels[key]:key;}

  void UpdateSummary() {
   if(!inputs.ContainsKey("name"))return;string name=inputs["name"].Text.Trim();summaryName.Text=String.IsNullOrWhiteSpace(name)?"Produto novo":name;
   decimal price;if(!Decimal.TryParse(inputs.ContainsKey("price")?inputs["price"].Text:"0",NumberStyles.Number,Pt,out price))price=0;summaryPrice.Text=price.ToString("C2",Pt);
   int rows=0,pieces=0;if(variants!=null)foreach(DataGridViewRow row in variants.Rows){if(row.IsNewRow)continue;string color=Convert.ToString(row.Cells["color"].Value).Trim(),size=Convert.ToString(row.Cells["size"].Value).Trim();int quantity;if(!String.IsNullOrWhiteSpace(color)&&!String.IsNullOrWhiteSpace(size)&&Int32.TryParse(Convert.ToString(row.Cells["quantity"].Value),NumberStyles.Integer,CultureInfo.InvariantCulture,out quantity)&&quantity>0){rows++;pieces+=quantity;}}
   summaryVariants.Text=rows.ToString();summaryPieces.Text=pieces.ToString();sample.ProductName=String.IsNullOrWhiteSpace(name)?"Produto novo":name;sample.Variant=variants==null?"Cor · Tamanho":FirstVariant();sample.Price=summaryPrice.Text;sample.Invalidate();
   var total=leftContent.Controls.OfType<Surface>().SelectMany(x=>x.Controls.Cast<Control>()).SelectMany(x=>x.Controls.Cast<Control>()).OfType<Label>().FirstOrDefault(x=>x.Name=="gradeTotal");if(total!=null)total.Text=pieces+" peças no total";
  }

  string FirstVariant() {if(variants!=null)foreach(DataGridViewRow row in variants.Rows){if(row.IsNewRow)continue;string color=Convert.ToString(row.Cells["color"].Value).Trim(),size=Convert.ToString(row.Cells["size"].Value).Trim();if(color.Length>0||size.Length>0)return color+" · "+size;}return "Cor · Tamanho";}
 }

 internal sealed class SectionBadge : Control {
  readonly string number;public SectionBadge(string number){this.number=number;Width=30;Height=30;Margin=new Padding(0,1,0,0);SetStyle(ControlStyles.UserPaint|ControlStyles.OptimizedDoubleBuffer|ControlStyles.AllPaintingInWmPaint,true);}
  protected override void OnPaint(PaintEventArgs e){using(var brush=new SolidBrush(DesktopTheme.Accent))e.Graphics.FillEllipse(brush,0,0,Width-1,Height-1);using(var font=DesktopTheme.TextFont(11,FontStyle.Bold))TextRenderer.DrawText(e.Graphics,number,font,new Rectangle(0,0,Width,Height),Color.White,TextFormatFlags.HorizontalCenter|TextFormatFlags.VerticalCenter);}
 }

 internal sealed class PreviewBadge : Control {
  public new string Text{get;set;}protected override void OnPaint(PaintEventArgs e){using(var path=DesktopTheme.Round(new RectangleF(.5f,.5f,Width-1,Height-1),6))using(var pen=new Pen(DesktopTheme.Accent))e.Graphics.DrawPath(pen,path);using(var font=DesktopTheme.TextFont(8.5f,FontStyle.Bold))TextRenderer.DrawText(e.Graphics,Text,font,ClientRectangle,DesktopTheme.Accent,TextFormatFlags.HorizontalCenter|TextFormatFlags.VerticalCenter);}
 }

 internal sealed class SampleLabel : Control {
  public new string ProductName="Produto novo";public string Variant="Cor · Tamanho",Price="R$ 0,00";
  public SampleLabel(){SetStyle(ControlStyles.UserPaint|ControlStyles.OptimizedDoubleBuffer|ControlStyles.AllPaintingInWmPaint|ControlStyles.ResizeRedraw,true);BackColor=Color.White;}
  protected override void OnPaint(PaintEventArgs e){base.OnPaint(e);int width=Math.Min(220,Math.Max(150,Width-28)),height=Math.Min(194,Math.Max(146,Height-12));var box=new Rectangle((Width-width)/2,6,width,height);using(var path=DesktopTheme.Round(box,7))using(var brush=new SolidBrush(Color.White))using(var pen=new Pen(Color.FromArgb(188,188,188))){e.Graphics.FillPath(brush,path);e.Graphics.DrawPath(pen,path);}using(var bold=DesktopTheme.TextFont(10,FontStyle.Bold))using(var regular=DesktopTheme.TextFont(8.5f)){TextRenderer.DrawText(e.Graphics,"Exemplo de etiqueta",regular,new Rectangle(0,0,Width,22),DesktopTheme.Muted,TextFormatFlags.HorizontalCenter);TextRenderer.DrawText(e.Graphics,ProductName,bold,new Rectangle(box.X+8,box.Y+12,box.Width-16,22),DesktopTheme.Ink,TextFormatFlags.HorizontalCenter|TextFormatFlags.EndEllipsis);TextRenderer.DrawText(e.Graphics,Variant,regular,new Rectangle(box.X+8,box.Y+38,box.Width-16,20),DesktopTheme.Muted,TextFormatFlags.HorizontalCenter|TextFormatFlags.EndEllipsis);int left=box.X+22,top=box.Y+65,right=box.Right-22;using(var brush=new SolidBrush(Color.Black)){int[] bars={2,4,2,1,3,2,1,4,2,2,1,3,2,1,4,2,3,1,2,4,1,2,3,1,3,2,1,4};int x=left;for(int i=0;i<bars.Length&&x<right;i++){int bar=bars[i];if(x+bar>right)bar=right-x;if(bar>0)e.Graphics.FillRectangle(brush,x,top,bar,43);x+=bar+2;}}TextRenderer.DrawText(e.Graphics,Price,bold,new Rectangle(box.X+8,box.Bottom-42,box.Width-16,22),DesktopTheme.Ink,TextFormatFlags.HorizontalCenter);TextRenderer.DrawText(e.Graphics,"Código gerado no cadastro",regular,new Rectangle(box.X+8,box.Bottom-20,box.Width-16,18),DesktopTheme.Muted,TextFormatFlags.HorizontalCenter|TextFormatFlags.EndEllipsis);}}
 }
}
