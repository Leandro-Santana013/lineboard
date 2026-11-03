using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace Lineboard {
 // Shared desktop styles. These controls retain native keyboard and accessibility behavior.
 internal static class DesktopTheme {
  public static readonly Color Canvas=Color.FromArgb(245,245,245), Ink=Color.FromArgb(32,32,32), Muted=Color.FromArgb(109,109,109);
  public static readonly Color Border=Color.FromArgb(229,229,229), Accent=Color.FromArgb(41,41,41), Sidebar=Color.FromArgb(17,17,17);
  public static Font TextFont(float size=10,FontStyle style=FontStyle.Regular){return new Font("Segoe UI",size,style);}
  public static Label Label(string text,float size=10,Color? color=null,FontStyle style=FontStyle.Regular){
   return new Label{Text=text,Font=TextFont(size,style),ForeColor=color??Ink,BackColor=Color.Transparent,AutoEllipsis=true,TextAlign=ContentAlignment.MiddleLeft,Dock=DockStyle.Fill,Margin=Padding.Empty};
  }
  public static TableLayoutPanel Rows(params float[] heights){
   var p=new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=1,RowCount=heights.Length,Margin=Padding.Empty,Padding=Padding.Empty,BackColor=Color.Transparent};
   p.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100));
   foreach(var h in heights)p.RowStyles.Add(new RowStyle(h<0?SizeType.Percent:SizeType.Absolute,h<0?100:h));return p;
  }
  public static void Form(Form form){form.Font=TextFont();form.ForeColor=Ink;form.BackColor=Canvas;form.StartPosition=FormStartPosition.CenterParent;form.AutoScaleMode=AutoScaleMode.Dpi;form.Icon=System.Drawing.Icon.ExtractAssociatedIcon(Application.ExecutablePath);}
  public static PictureBox StoreLogo(){
   var box=new PictureBox{Dock=DockStyle.Fill,SizeMode=PictureBoxSizeMode.Zoom,BackColor=Color.Black,AccessibleName="Lines Boardshop",Margin=Padding.Empty};
   using(var stream=typeof(DesktopTheme).Assembly.GetManifestResourceStream("Lineboard.StoreLogo")){
    if(stream!=null)using(var source=Image.FromStream(stream)){box.Image=new Bitmap(source);}
   }
   box.Disposed+=(s,e)=>{if(box.Image!=null)box.Image.Dispose();};return box;
  }
  public static void Grid(DataGridView grid){
   grid.BackgroundColor=Color.White;grid.BorderStyle=BorderStyle.None;grid.RowHeadersVisible=false;grid.EnableHeadersVisualStyles=false;
   grid.GridColor=Border;grid.CellBorderStyle=DataGridViewCellBorderStyle.SingleHorizontal;grid.ColumnHeadersBorderStyle=DataGridViewHeaderBorderStyle.None;
   grid.ColumnHeadersHeight=38;grid.ColumnHeadersHeightSizeMode=DataGridViewColumnHeadersHeightSizeMode.DisableResizing;
   grid.ColumnHeadersDefaultCellStyle=new DataGridViewCellStyle{BackColor=Color.FromArgb(245,245,245),ForeColor=Muted,Font=TextFont(8.5f,FontStyle.Bold),Padding=new Padding(10,0,8,0),SelectionBackColor=Color.FromArgb(245,245,245),SelectionForeColor=Muted};
   grid.DefaultCellStyle=new DataGridViewCellStyle{BackColor=Color.White,ForeColor=Ink,SelectionBackColor=Color.FromArgb(242,242,242),SelectionForeColor=Ink,Font=TextFont(9.5f),Padding=new Padding(10,0,8,0)};
   grid.RowTemplate.Height=62;grid.AllowUserToResizeRows=false;grid.AutoSizeColumnsMode=DataGridViewAutoSizeColumnsMode.Fill;
  }
  public static GraphicsPath Round(RectangleF bounds,float radius){
   var path=new GraphicsPath();float d=radius*2;path.AddArc(bounds.X,bounds.Y,d,d,180,90);path.AddArc(bounds.Right-d,bounds.Y,d,d,270,90);path.AddArc(bounds.Right-d,bounds.Bottom-d,d,d,0,90);path.AddArc(bounds.X,bounds.Bottom-d,d,d,90,90);path.CloseFigure();return path;
  }
  public static void Icon(Graphics g,string kind,Rectangle bounds,Color color){
   var previous=g.Save();g.TranslateTransform(bounds.X,bounds.Y);g.ScaleTransform(bounds.Width/24f,bounds.Height/24f);g.SmoothingMode=SmoothingMode.AntiAlias;
   using(var pen=new Pen(color,1.6f)){pen.StartCap=LineCap.Round;pen.EndCap=LineCap.Round;pen.LineJoin=LineJoin.Round;
    switch(kind){
     case "store":g.DrawRectangle(pen,4,11,16,10);g.DrawLines(pen,new[]{new Point(3,10),new Point(5,4),new Point(19,4),new Point(21,10)});g.DrawLine(pen,3,10,21,10);g.DrawRectangle(pen,10,14,5,7);break;
     case "history":g.DrawEllipse(pen,3,3,18,18);g.DrawLines(pen,new[]{new Point(12,7),new Point(12,12),new Point(16,14)});break;
     case "tag":g.DrawPolygon(pen,new[]{new Point(3,4),new Point(13,4),new Point(22,13),new Point(13,22),new Point(3,12)});g.DrawEllipse(pen,7,7,2,2);break;
     case "phone":g.DrawRectangle(pen,6,2,12,20);g.DrawLine(pen,11,18,13,18);break;
     case "sync":g.DrawArc(pen,3,4,18,16,205,150);g.DrawArc(pen,3,4,18,16,25,150);g.DrawLines(pen,new[]{new Point(18,3),new Point(21,8),new Point(16,8)});g.DrawLines(pen,new[]{new Point(6,21),new Point(3,16),new Point(8,16)});break;
     case "cloud":g.DrawArc(pen,6,5,12,12,180,180);g.DrawArc(pen,14,10,8,9,260,190);g.DrawArc(pen,2,10,8,9,90,180);g.DrawLine(pen,6,19,18,19);break;
     case "cart":g.DrawLines(pen,new[]{new Point(2,3),new Point(5,3),new Point(8,16),new Point(19,16),new Point(22,7),new Point(6,7)});g.DrawEllipse(pen,8,19,2,2);g.DrawEllipse(pen,18,19,2,2);break;
     case "search":g.DrawEllipse(pen,3,3,12,12);g.DrawLine(pen,14,14,21,21);break;
     case "edit":g.DrawPolygon(pen,new[]{new Point(4,15),new Point(16,3),new Point(21,8),new Point(9,20),new Point(3,21)});g.DrawLine(pen,13,6,18,11);break;
     case "box":g.DrawPolygon(pen,new[]{new Point(3,7),new Point(12,2),new Point(21,7),new Point(21,17),new Point(12,22),new Point(3,17)});g.DrawLines(pen,new[]{new Point(3,7),new Point(12,12),new Point(21,7)});g.DrawLine(pen,12,12,12,22);break;
     case "info":g.DrawEllipse(pen,3,3,18,18);g.DrawLine(pen,12,10,12,17);g.DrawLine(pen,12,7,12,7.3f);break;
     case "plus":g.DrawLine(pen,12,5,12,19);g.DrawLine(pen,5,12,19,12);break;
     case "settings":g.DrawEllipse(pen,5,5,14,14);g.DrawEllipse(pen,9,9,6,6);for(int angle=0;angle<360;angle+=45){double a=angle*Math.PI/180;g.DrawLine(pen,12+(float)Math.Cos(a)*7,12+(float)Math.Sin(a)*7,12+(float)Math.Cos(a)*10,12+(float)Math.Sin(a)*10);}break;
     case "close":g.DrawEllipse(pen,2,2,20,20);g.DrawLine(pen,8,8,16,16);g.DrawLine(pen,16,8,8,16);break;
    }
   }g.Restore(previous);
  }
 }
 internal sealed class Surface : Panel {
  public Color Edge=DesktopTheme.Border;public Color Fill=Color.White;
  public Surface(){DoubleBuffered=true;BackColor=Color.Transparent;Padding=new Padding(16);Margin=Padding.Empty;}
  protected override void OnPaint(PaintEventArgs e){e.Graphics.SmoothingMode=SmoothingMode.AntiAlias;using(var path=DesktopTheme.Round(new RectangleF(.5f,.5f,Width-1,Height-1),7))using(var fill=new SolidBrush(Fill))using(var edge=new Pen(Edge)){e.Graphics.FillPath(fill,path);e.Graphics.DrawPath(edge,path);}base.OnPaint(e);}
 }
 internal sealed class ActionButton : Button {
  public bool Primary,Navigation,Active;public string Glyph;
  bool hover;
  public ActionButton(){SetStyle(ControlStyles.OptimizedDoubleBuffer|ControlStyles.UserPaint|ControlStyles.AllPaintingInWmPaint|ControlStyles.ResizeRedraw,true);FlatStyle=FlatStyle.Flat;FlatAppearance.BorderSize=0;Cursor=Cursors.Hand;Font=DesktopTheme.TextFont(9.5f);Height=40;Margin=Padding.Empty;BackColor=Color.Transparent;UseVisualStyleBackColor=false;}
  protected override void OnMouseEnter(EventArgs e){hover=true;Invalidate();base.OnMouseEnter(e);}
  protected override void OnMouseLeave(EventArgs e){hover=false;Invalidate();base.OnMouseLeave(e);}
  protected override void OnPaint(PaintEventArgs e){
   var g=e.Graphics;g.SmoothingMode=SmoothingMode.AntiAlias;
   Color fill=Navigation?(Active?Color.FromArgb(60,60,60):hover?Color.FromArgb(50,50,50):DesktopTheme.Sidebar):Primary?(Enabled?(hover?Color.FromArgb(86,86,86):DesktopTheme.Accent):Color.FromArgb(226,226,226)):(Enabled?(hover?Color.FromArgb(245,245,245):Color.White):Color.FromArgb(248,248,248));
   Color ink=Navigation?Color.FromArgb(236,236,236):Primary&&Enabled?Color.White:Enabled?DesktopTheme.Accent:Color.FromArgb(141,141,141);
   using(var path=DesktopTheme.Round(new RectangleF(.5f,.5f,Width-1,Height-1),6))using(var brush=new SolidBrush(fill)){g.FillPath(brush,path);if(!Navigation&&!Primary)using(var pen=new Pen(DesktopTheme.Border))g.DrawPath(pen,path);}
   if(Navigation&&Active)using(var brush=new SolidBrush(Color.FromArgb(144,144,144)))g.FillRectangle(brush,0,10,3,Height-20);
   int icon=String.IsNullOrEmpty(Glyph)?0:20;var measured=TextRenderer.MeasureText(Text,Font);int left=Navigation?14:Math.Max(8,(Width-measured.Width-icon-(icon==0?0:8))/2);
   if(icon>0)DesktopTheme.Icon(g,Glyph,new Rectangle(left,(Height-20)/2,20,20),ink);
   TextRenderer.DrawText(g,Text,Font,new Rectangle(left+(icon==0?0:28),0,Width-left-(icon==0?0:28)-6,Height),ink,TextFormatFlags.VerticalCenter|TextFormatFlags.Left|TextFormatFlags.EndEllipsis|TextFormatFlags.NoPrefix);
   if(Focused&&ShowFocusCues)ControlPaint.DrawFocusRectangle(g,new Rectangle(5,5,Width-10,Height-10),ink,fill);
  }
 }
 internal sealed class EmptyState : Control {
  public string Heading="Nenhuma peça cadastrada",Description="Cadastre o primeiro produto para começar.",Glyph="box";
  public EmptyState(){SetStyle(ControlStyles.UserPaint|ControlStyles.OptimizedDoubleBuffer|ControlStyles.AllPaintingInWmPaint|ControlStyles.ResizeRedraw,true);BackColor=Color.White;Dock=DockStyle.Fill;TabStop=false;}
  protected override void OnPaint(PaintEventArgs e){int y=Math.Max(18,(Height-130)/2);DesktopTheme.Icon(e.Graphics,Glyph,new Rectangle((Width-36)/2,y,36,36),Color.FromArgb(159,159,159));using(var title=DesktopTheme.TextFont(11,FontStyle.Bold))using(var body=DesktopTheme.TextFont(9)){TextRenderer.DrawText(e.Graphics,Heading,title,new Rectangle(12,y+50,Width-24,28),DesktopTheme.Ink,TextFormatFlags.HorizontalCenter|TextFormatFlags.EndEllipsis);TextRenderer.DrawText(e.Graphics,Description,body,new Rectangle(18,y+84,Width-36,50),DesktopTheme.Muted,TextFormatFlags.HorizontalCenter|TextFormatFlags.WordBreak);}base.OnPaint(e);}
 }
 internal sealed class CartItem : Panel {
  readonly string name,variant,barcode,price;readonly ActionButton remove;
  public CartItem(string name,string variant,string barcode,string price,Action action){
   this.name=name;this.variant=variant;this.barcode=barcode;this.price=price;DoubleBuffered=true;Height=104;BackColor=Color.White;Margin=Padding.Empty;AccessibleName=name+", "+variant+", "+price;
   remove=new ActionButton{Text="",Glyph="close",Width=28,Height=30,AccessibleName="Remover "+name+" do caixa",TabStop=true};remove.Click+=(s,e)=>action();Controls.Add(remove);
  }
  protected override void OnLayout(LayoutEventArgs e){base.OnLayout(e);if(remove!=null)remove.SetBounds(Width-30,34,28,30);}
  protected override void OnPaint(PaintEventArgs e){
   using(var bold=DesktopTheme.TextFont(10,FontStyle.Bold))using(var regular=DesktopTheme.TextFont(9))using(var small=DesktopTheme.TextFont(8.5f)){
    TextRenderer.DrawText(e.Graphics,name,bold,new Rectangle(0,10,Width-4,24),DesktopTheme.Ink,TextFormatFlags.EndEllipsis|TextFormatFlags.NoPrefix);
    var size=TextRenderer.MeasureText(price,bold);int priceLeft=Width-size.Width-40;
    TextRenderer.DrawText(e.Graphics,variant,regular,new Rectangle(0,38,Math.Max(20,priceLeft-8),22),DesktopTheme.Muted,TextFormatFlags.EndEllipsis|TextFormatFlags.NoPrefix);
    TextRenderer.DrawText(e.Graphics,price,bold,new Rectangle(priceLeft,38,size.Width,22),DesktopTheme.Ink,TextFormatFlags.Right);
    TextRenderer.DrawText(e.Graphics,barcode,small,new Rectangle(0,66,Width-8,22),DesktopTheme.Muted,TextFormatFlags.EndEllipsis);
   }using(var pen=new Pen(DesktopTheme.Border))e.Graphics.DrawLine(pen,0,Height-1,Width,Height-1);base.OnPaint(e);
  }
 }
}
