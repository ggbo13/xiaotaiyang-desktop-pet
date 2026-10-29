using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;

namespace OceanMaid {
    public sealed class Frame {
        public string file { get; set; }
        public double durationMs { get; set; }
        public string state { get; set; }
    }
    public sealed class Animation {
        public Frame[] idle { get; set; }
        public Frame[] interaction { get; set; }
        public static Animation Load(string directory) {
            var data = new JavaScriptSerializer().Deserialize<Animation>(File.ReadAllText(Path.Combine(directory, "animation.json")));
            if (data == null) throw new InvalidDataException("缺少动画清单");
            foreach (var list in new[] { data.idle, data.interaction }) {
                if (list == null || list.Length == 0 || list.Length > 2000) throw new InvalidDataException("动画序列无效");
                foreach (var f in list) {
                    if (f == null || string.IsNullOrWhiteSpace(f.file) || Path.IsPathRooted(f.file) || f.file.Contains("..") || f.file.Contains(":")) throw new InvalidDataException("素材路径无效");
                    if (double.IsNaN(f.durationMs) || double.IsInfinity(f.durationMs) || f.durationMs <= 0 || f.durationMs > 10000) throw new InvalidDataException("动画帧时长无效");
                    if (!File.Exists(Path.Combine(directory, f.file))) throw new FileNotFoundException("缺少动画素材", f.file);
                }
            }
            return data;
        }
    }
    public sealed class Player {
        public readonly Animation Animation;
        public bool Busy, Paused, Dragging, Hidden, Locked;
        public double Position { get; private set; }
        double last;
        public Player(Animation animation, double now) { Animation = animation; last = now; }
        public bool Frozen { get { return Paused || Dragging || Hidden || Locked; } }
        public void Tick(double now) {
            if (now < last) throw new ArgumentException("时钟不能倒退");
            double delta = now - last; last = now;
            if (Frozen) return;
            Position += delta;
            double duration = (Busy ? Animation.interaction : Animation.idle).Sum(f => f.durationMs);
            if (Position >= duration && Busy) { Position -= duration; Busy = false; duration = Animation.idle.Sum(f => f.durationMs); }
            Position %= duration;
        }
        public bool Play() { if (Busy || Frozen) return false; Busy = true; Position = 0; return true; }
        public void Reset() { Busy = false; Position = 0; }
        public Frame Current {
            get {
                var frames = Busy ? Animation.interaction : Animation.idle;
                double time = Position;
                foreach (var f in frames) { if (time < f.durationMs) return f; time -= f.durationMs; }
                return frames[frames.Length - 1];
            }
        }
    }
    public sealed class Settings {
        public int Height = 280;
        public int X = int.MinValue, Y = int.MinValue;
        public bool Topmost = true, Paused = false, AutoInteract = false;
        public void Validate() { Height = Math.Max(150, Math.Min(800, Height)); }
        public static Settings Load(string path, out string warning) {
            warning = null;
            if (!File.Exists(path)) return new Settings();
            try {
                var value = new JavaScriptSerializer().Deserialize<Settings>(File.ReadAllText(path));
                if (value == null) throw new InvalidDataException();
                value.Validate(); return value;
            } catch (Exception e) {
                warning = "设置无法读取，已使用默认值；原设置文件仍保留。";
                if (!(e is IOException || e is ArgumentException || e is InvalidOperationException || e is InvalidDataException)) throw;
                return new Settings();
            }
        }
        public static void Save(string path, Settings value) {
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            // 损坏配置另存备份，普通保存使用同目录原子替换。
            string temp = path + ".new-" + Guid.NewGuid().ToString("N");
            File.WriteAllText(temp, new JavaScriptSerializer().Serialize(value));
            if (File.Exists(path)) File.Replace(temp, path, null); else File.Move(temp, path);
        }
        public static Point Fit(Point point, Size size, Rectangle[] areas) {
            Rectangle best = areas[0]; long bestDistance = long.MaxValue;
            foreach (var area in areas) {
                long dx = point.X < area.Left ? (long)area.Left - point.X : point.X > area.Right ? (long)point.X - area.Right : 0;
                long dy = point.Y < area.Top ? (long)area.Top - point.Y : point.Y > area.Bottom ? (long)point.Y - area.Bottom : 0;
                long distance = dx * dx + dy * dy;
                if (distance < bestDistance) { bestDistance = distance; best = area; }
            }
            return new Point(Math.Max(best.Left, Math.Min(point.X, best.Right - size.Width)), Math.Max(best.Top, Math.Min(point.Y, best.Bottom - size.Height)));
        }
    }
    internal static class Native {
        [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x,y; public POINT(int x,int y){this.x=x;this.y=y;} }
        [StructLayout(LayoutKind.Sequential)] public struct SIZE { public int cx,cy; public SIZE(int x,int y){cx=x;cy=y;} }
        [StructLayout(LayoutKind.Sequential, Pack=1)] public struct BLEND { public byte op,flags,alpha,format; }
        [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr window);
        [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr window,IntPtr dc);
        [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr dc);
        [DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr dc,IntPtr obj);
        [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr obj);
        [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr dc);
        [DllImport("user32.dll",SetLastError=true)] public static extern bool UpdateLayeredWindow(IntPtr window,IntPtr dst,ref POINT position,ref SIZE size,IntPtr src,ref POINT source,int key,ref BLEND blend,int flags);
        [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr window);
        [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    }
    public sealed class Pet : Form {
        readonly string assets, settingsPath, reportPath;
        readonly Settings settings;
        readonly Player player;
        readonly Stopwatch clock = Stopwatch.StartNew();
        readonly Timer timer = new Timer();
        readonly NotifyIcon tray = new NotifyIcon();
        readonly ContextMenuStrip roleMenu;
        readonly Dictionary<string,Bitmap> cache = new Dictionary<string,Bitmap>();
        readonly LinkedList<string> lru = new LinkedList<string>();
        readonly Random random = new Random();
        readonly Icon ownedIcon;
        Bitmap current;
        string currentKey;
        bool down, dragging, closing, settingsCorrupt, startupAvailable=true;
        Point downScreen, downWindow;
        double nextAuto = 90000;
        int scaleHeight;
        readonly bool smoke, uiTest;
        int smokeStage;
        readonly List<string> smokeChecks = new List<string>();
        public Pet(string root, string data, bool smokeMode, string report, bool interactiveTest) {
            assets = Path.Combine(root,"assets"); settingsPath = Path.Combine(data,"settings.json"); reportPath=report; smoke=smokeMode; uiTest=interactiveTest;
            string warning; settings = Settings.Load(settingsPath,out warning); settingsCorrupt=warning != null;
            player = new Player(Animation.Load(assets),clock.Elapsed.TotalMilliseconds); player.Paused=settings.Paused;
            Text="海洋女仆桌宠"; FormBorderStyle=FormBorderStyle.None; ShowInTaskbar=uiTest; TopMost=settings.Topmost;
            AutoScaleMode=AutoScaleMode.None; StartPosition=FormStartPosition.Manual;
            ownedIcon=new Icon(Path.Combine(assets,"pet.ico")); Icon=ownedIcon;
            tray.Icon=ownedIcon; tray.Text="海洋女仆桌宠"; tray.Visible=true;
            tray.ContextMenuStrip=MakeMenu(); tray.DoubleClick += delegate { SetHidden(false); };
            roleMenu=MakeMenu();
            timer.Interval=15; timer.Tick += OnTick;
            SystemEvents.DisplaySettingsChanged += DisplaysChanged;
            SystemEvents.SessionSwitch += SessionChanged;
            Shown += delegate {
                ResizePet(settings.Height);
                var area=Screen.PrimaryScreen.WorkingArea;
                Location=settings.X == int.MinValue ? new Point(area.Right-Width-28,area.Bottom-Height) : new Point(settings.X,settings.Y);
                Clamp(); Render(true); timer.Start();
                if(warning != null) tray.ShowBalloonTip(6000,"设置提示",warning,ToolTipIcon.Warning);
            };
        }
        protected override bool ShowWithoutActivation { get { return !uiTest; } }
        // 交互测试允许工具发现窗口；正式运行始终隐藏任务栏按钮且不抢焦点。
        protected override CreateParams CreateParams { get { var p=base.CreateParams; p.ExStyle |= 0x80000; if(!uiTest)p.ExStyle|=0x80|0x08000000; return p; } }
        protected override void OnPaint(PaintEventArgs e) { }
        protected override void OnPaintBackground(PaintEventArgs e) { }
        int Dpi { get { try { return (int)Native.GetDpiForWindow(Handle); } catch(EntryPointNotFoundException){return 96;} } }
        void Sync(){player.Tick(clock.Elapsed.TotalMilliseconds);}
        void Clamp(){Location=Settings.Fit(Location,Size,Screen.AllScreens.Select(s=>s.WorkingArea).ToArray());}
        void ResizePet(int height) {
            settings.Height=Math.Max(150,Math.Min(800,height));
            int next=(int)Math.Round(settings.Height*Math.Max(96,Dpi)/96.0);
            if(next != scaleHeight){current=null;currentKey=null;foreach(var b in cache.Values)b.Dispose();cache.Clear();lru.Clear();scaleHeight=next;}
            Size=new Size((int)Math.Round(scaleHeight*736.0/1056),scaleHeight); Clamp(); Render(true);
        }
        Bitmap GetFrame(string file) {
            Bitmap bitmap;
            if(cache.TryGetValue(file,out bitmap)){lru.Remove(file);lru.AddLast(file);return bitmap;}
            using(var original=new Bitmap(Path.Combine(assets,file))) {
                bitmap=new Bitmap(Width,Height,PixelFormat.Format32bppPArgb);
                using(var g=Graphics.FromImage(bitmap)) {
                    g.CompositingMode=CompositingMode.SourceCopy;g.InterpolationMode=InterpolationMode.HighQualityBicubic;
                    g.PixelOffsetMode=PixelOffsetMode.HighQuality;g.DrawImage(original,new Rectangle(0,0,Width,Height));
                }
            }
            cache.Add(file,bitmap);lru.AddLast(file);
            while(cache.Count>20){string oldest=lru.First.Value;lru.RemoveFirst();cache[oldest].Dispose();cache.Remove(oldest);}
            return bitmap;
        }
        void Render(bool force) {
            if(!IsHandleCreated || scaleHeight==0 || player.Hidden) return;
            string key=player.Current.file;
            if(!force && key==currentKey)return;
            current=GetFrame(key);currentKey=key;
            IntPtr screen=Native.GetDC(IntPtr.Zero), memory=IntPtr.Zero, handle=IntPtr.Zero, previous=IntPtr.Zero;
            try {
                memory=Native.CreateCompatibleDC(screen);handle=current.GetHbitmap(Color.FromArgb(0));previous=Native.SelectObject(memory,handle);
                var position=new Native.POINT(Left,Top);var size=new Native.SIZE(Width,Height);var source=new Native.POINT(0,0);
                var blend=new Native.BLEND{op=0,flags=0,alpha=255,format=1};
                if(!Native.UpdateLayeredWindow(Handle,screen,ref position,ref size,memory,ref source,0,ref blend,2))throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            }finally{if(previous!=IntPtr.Zero)Native.SelectObject(memory,previous);if(handle!=IntPtr.Zero)Native.DeleteObject(handle);if(memory!=IntPtr.Zero)Native.DeleteDC(memory);Native.ReleaseDC(IntPtr.Zero,screen);}
        }
        bool Opaque(Point point){return current!=null && point.X>=0 && point.Y>=0 && point.X<current.Width && point.Y<current.Height && current.GetPixel(point.X,point.Y).A>=16;}
        protected override void WndProc(ref Message m) {
            if(m.Msg==0x21){m.Result=new IntPtr(3);return;}
            if(m.Msg==0x84 && !Capture){long p=m.LParam.ToInt64();var point=PointToClient(new Point((short)(p&65535),(short)((p>>16)&65535)));m.Result=new IntPtr(Opaque(point)?1:-1);return;}
            if(m.Msg==0x2E0){base.WndProc(ref m);BeginInvoke(new Action(delegate{ResizePet(settings.Height);Clamp();}));return;}
            base.WndProc(ref m);
        }
        protected override void OnMouseDown(MouseEventArgs e) {
            base.OnMouseDown(e);if(e.Button!=MouseButtons.Left)return;
            down=true;dragging=false;downScreen=Cursor.Position;downWindow=Location;Capture=true;
        }
        protected override void OnMouseMove(MouseEventArgs e) {
            base.OnMouseMove(e);if(!down)return;
            var p=Cursor.Position;int dx=p.X-downScreen.X,dy=p.Y-downScreen.Y;
            if(!dragging && (Math.Abs(dx)>=SystemInformation.DragSize.Width || Math.Abs(dy)>=SystemInformation.DragSize.Height)){Sync();dragging=true;player.Dragging=true;}
            if(dragging)Location=new Point(downWindow.X+dx,downWindow.Y+dy);
        }
        protected override void OnMouseUp(MouseEventArgs e) {
            base.OnMouseUp(e);
            if(e.Button==MouseButtons.Right){roleMenu.Show(Cursor.Position);return;}
            if(e.Button!=MouseButtons.Left || !down)return;
            bool wasDragging=dragging;Sync();down=false;dragging=false;player.Dragging=false;Capture=false;
            if(wasDragging){Clamp();Save();}else Play();
        }
        protected override void OnMouseCaptureChanged(EventArgs e){base.OnMouseCaptureChanged(e);if(down&&!Capture){Sync();down=false;dragging=false;player.Dragging=false;Clamp();Save();}}
        void Play(){Sync();if(player.Play())Render(true);}
        void Pause(){Sync();player.Paused=!player.Paused;settings.Paused=player.Paused;Save();}
        void Reset(){Sync();player.Reset();Render(true);}
        void SetHidden(bool hidden){Sync();player.Hidden=hidden;if(hidden)Hide();else{Show();Clamp();Render(true);}}
        void Save() {
            settings.X=Left;settings.Y=Top;settings.Paused=player.Paused;settings.Topmost=TopMost;
            try {
                if(settingsCorrupt && File.Exists(settingsPath)){File.Copy(settingsPath,settingsPath+".corrupt-"+DateTime.UtcNow.ToString("yyyyMMddHHmmssfff"));settingsCorrupt=false;}
                Settings.Save(settingsPath,settings);
            }catch(Exception e){if(e is IOException || e is UnauthorizedAccessException){tray.ShowBalloonTip(5000,"设置未保存",e.Message,ToolTipIcon.Warning);}else throw;}
        }
        bool AutoStartEnabled(){try{using(var key=Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run")){return key!=null && key.GetValue("OceanMaidDesktopPet")!=null;}}catch(System.Security.SecurityException){startupAvailable=false;return false;}catch(UnauthorizedAccessException){startupAvailable=false;return false;}}
        void ToggleAutoStart(){try{using(var key=Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run")){if(key.GetValue("OceanMaidDesktopPet")!=null)key.DeleteValue("OceanMaidDesktopPet");else key.SetValue("OceanMaidDesktopPet","\""+Application.ExecutablePath+"\"");}}catch(Exception e){MessageBox.Show(e.Message,"无法更改开机启动");}}
        ToolStripMenuItem Item(string text,Action action,bool check=false){var item=new ToolStripMenuItem(text);item.Checked=check;item.Click+=delegate{action();};return item;}
        ContextMenuStrip MakeMenu(){
            var menu=new ContextMenuStrip();
            menu.Items.Add(Item("互动 / 打招呼",Play));menu.Items.Add(Item("恢复待机",Reset));
            menu.Items.Add(Item("暂停动画",Pause,player.Paused));menu.Items.Add(Item("隐藏桌宠",delegate{SetHidden(!player.Hidden);},player.Hidden));
            var size=new ToolStripMenuItem("调整大小");
            foreach(int h in new[]{150,200,280,350}){int value=h;size.DropDownItems.Add(Item(value+" px",delegate{ResizePet(value);Save();},settings.Height==value));}
            size.DropDownItems.Add(Item("自定义…",CustomSize));menu.Items.Add(size);
            menu.Items.Add(Item("置顶",delegate{TopMost=!TopMost;Save();},TopMost));
            menu.Items.Add(Item("偶尔自动打招呼",delegate{settings.AutoInteract=!settings.AutoInteract;nextAuto=clock.Elapsed.TotalMilliseconds+90000+random.Next(90000);Save();},settings.AutoInteract));
            var startup=Item("开机启动",ToggleAutoStart,AutoStartEnabled());startup.Enabled=startupAvailable;menu.Items.Add(startup);
            menu.Items.Add(new ToolStripSeparator());menu.Items.Add(Item("退出桌宠",Close));
            // 托盘菜单每次展开时刷新勾选状态，保持与角色菜单一致。
            menu.Opening+=delegate { ((ToolStripMenuItem)menu.Items[2]).Checked=player.Paused;((ToolStripMenuItem)menu.Items[3]).Checked=player.Hidden;((ToolStripMenuItem)menu.Items[5]).Checked=TopMost;((ToolStripMenuItem)menu.Items[6]).Checked=settings.AutoInteract;((ToolStripMenuItem)menu.Items[7]).Checked=AutoStartEnabled();foreach(ToolStripMenuItem option in ((ToolStripMenuItem)menu.Items[4]).DropDownItems)option.Checked=option.Text==settings.Height+" px"; };
            return menu;
        }
        void CustomSize(){using(var form=new Form{Text="调整桌宠大小",Width=290,Height=160,FormBorderStyle=FormBorderStyle.FixedDialog,StartPosition=FormStartPosition.CenterScreen,MaximizeBox=false,MinimizeBox=false,TopMost=true}){
            var label=new Label{Text="高度（150–800，随屏幕缩放）",Left=15,Top=16,Width=250};
            var number=new NumericUpDown{Minimum=150,Maximum=800,Value=settings.Height,Left=16,Top=44,Width=130};
            var button=new Button{Text="应用",Left=165,Top=43,Width=90,DialogResult=DialogResult.OK};form.Controls.AddRange(new Control[]{label,number,button});form.AcceptButton=button;
            if(form.ShowDialog()==DialogResult.OK){ResizePet((int)number.Value);Save();}
        }}
        void DisplaysChanged(object sender,EventArgs args){if(!closing && IsHandleCreated)BeginInvoke(new Action(delegate{Clamp();ResizePet(settings.Height);Save();}));}
        void SessionChanged(object sender,SessionSwitchEventArgs args){if(!closing && IsHandleCreated)BeginInvoke(new Action(delegate{Sync();if(args.Reason==SessionSwitchReason.SessionLock)player.Locked=true;else if(args.Reason==SessionSwitchReason.SessionUnlock)player.Locked=false;}));}
        void OnTick(object sender,EventArgs args){
            Sync();timer.Interval=player.Frozen?200:15;
            if(!player.Frozen){if(settings.AutoInteract && !player.Busy && clock.Elapsed.TotalMilliseconds>=nextAuto){Play();nextAuto=clock.Elapsed.TotalMilliseconds+90000+random.Next(90000);}Render(false);}
            if(smoke)Smoke();
        }
        void Smoke(){
            double seconds=clock.Elapsed.TotalSeconds;
            if(smokeStage==0 && seconds>0.6){if(!tray.Visible || current==null || Opaque(new Point(0,0)))throw new Exception("窗口/托盘/透明角落验证失败");smokeChecks.Add("真实分层窗口、托盘与透明角落通过");ResizePet(200);Save();Play();smokeStage++;}
            if(smokeStage==1 && seconds>2){Pause();roleMenu.Show(this,new Point(30,30));roleMenu.Close();roleMenu.Show(this,new Point(30,30));roleMenu.Close();if(roleMenu.IsDisposed)throw new Exception("菜单过早释放");smokeChecks.Add("调整尺寸、互动、暂停与菜单重复展开通过");smokeStage++;}
            if(smokeStage==2 && seconds>2.6){Pause();SetHidden(true);smokeStage++;}
            if(smokeStage==3 && seconds>3.2){SetHidden(false);smokeChecks.Add("隐藏与托盘恢复通过");smokeStage++;}
            if(smokeStage==4 && seconds>16){if(player.Busy)throw new Exception("互动没有返回待机");Save();string warning;var saved=Settings.Load(settingsPath,out warning);if(saved.Height!=200 || saved.X!=Left || saved.Y!=Top || warning!=null)throw new Exception("设置持久化验证失败");smokeChecks.Add("动作完成回待机、位置和尺寸持久化通过");if(cache.Count>20)throw new Exception("缓存越界");File.WriteAllText(reportPath,new JavaScriptSerializer().Serialize(new{passed=true,checks=smokeChecks,cacheFrames=cache.Count,workingSet=Process.GetCurrentProcess().WorkingSet64}));Close();}
        }
        protected override void OnFormClosed(FormClosedEventArgs e){closing=true;timer.Stop();Save();tray.Visible=false;tray.Dispose();SystemEvents.DisplaySettingsChanged-=DisplaysChanged;SystemEvents.SessionSwitch-=SessionChanged;foreach(var bitmap in cache.Values)bitmap.Dispose();ownedIcon.Dispose();timer.Dispose();base.OnFormClosed(e);}
    }
    internal static class Program {
        [STAThread] static int Main(string[] args){
            string data=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"OceanMaidDesktopPet");string report=null;
            for(int i=0;i<args.Length;i++){if(args[i]=="--data-dir" && i+1<args.Length)data=Path.GetFullPath(args[++i]);else if(args[i]=="--report"&&i+1<args.Length)report=Path.GetFullPath(args[++i]);}
            bool smoke=args.Contains("--smoke");
            try{
                if(args.Contains("--self-test")){SelfTest.Run(report);return 0;}
                bool created;using(var mutex=new System.Threading.Mutex(true,smoke?"Local\\OceanMaidSmoke-"+Process.GetCurrentProcess().Id:"Local\\OceanMaidDesktopPet",out created)){
                    if(!created){MessageBox.Show("桌宠已在运行，请从系统托盘操作。","海洋女仆桌宠");return 0;}
                    try{Native.SetProcessDpiAwarenessContext(new IntPtr(-4));}catch(EntryPointNotFoundException){}
                    Application.EnableVisualStyles();Application.SetCompatibleTextRenderingDefault(false);
                    Application.SetUnhandledExceptionMode(UnhandledExceptionMode.ThrowException);
                    Application.Run(new Pet(AppDomain.CurrentDomain.BaseDirectory,data,smoke,report,args.Contains("--ui-test")));
                }
                return 0;
            }catch(Exception e){if(report!=null)File.WriteAllText(report,e.ToString());if(!smoke && !args.Contains("--self-test"))MessageBox.Show(e.Message,"桌宠启动失败");return 1;}
        }
    }
}
