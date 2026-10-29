using System;
using System.IO;
using System.Drawing;
using System.Collections.Generic;
using System.Web.Script.Serialization;

namespace OceanMaid {
    internal static class SelfTest {
        static void Assert(bool condition,string message){if(!condition)throw new Exception(message);}
        public static void Run(string report) {
            var passed=new List<string>();
            var a=new Animation {idle=new[]{new Frame{file="idle",durationMs=1000}},interaction=new[]{
                new Frame{file="start",durationMs=1200},new Frame{file="hold",durationMs=2800},
                new Frame{file="end",durationMs=1000},new Frame{file="happy",durationMs=600}}};
            var p=new Player(a,0);Assert(p.Play(),"首次互动未接受");
            p.Tick(1199);Assert(p.Current.file=="start","起始帧边界错误");p.Tick(1200);Assert(p.Current.file=="hold","保持边界错误");
            Assert(!p.Play(),"重复点击入队");p.Tick(4000);Assert(p.Current.file=="end","恢复边界错误");p.Tick(5000);Assert(p.Current.file=="happy","微笑边界错误");
            p.Tick(5600);Assert(!p.Busy&&p.Current.file=="idle","结束未返回待机");passed.Add("完整动作边界与重复点击");
            p=new Player(a,0);p.Play();p.Tick(750);p.Paused=true;p.Tick(90000);Assert(p.Position==750,"暂停丢失进度");
            p.Dragging=true;p.Paused=false;p.Tick(180000);Assert(p.Position==750,"拖拽被恢复暂停覆盖");
            Assert(!p.Play(),"拖动期间接受点击");p.Dragging=false;p.Tick(180450);Assert(p.Current.file=="hold","冻结后时钟补偿错误");passed.Add("暂停、拖拽独立冻结与恢复");
            p.Hidden=true;p.Tick(300000);Assert(p.Position==1200,"隐藏仍推进");p.Hidden=false;p.Locked=true;p.Tick(400000);Assert(p.Position==1200,"锁屏仍推进");
            p.Locked=false;p.Tick(410000);Assert(!p.Busy&&p.Position==600,"跨多个阶段的余量错误");passed.Add("隐藏、锁屏与稀疏更新");
            bool rejected=false;try{p.Tick(0);}catch(ArgumentException){rejected=true;}Assert(rejected,"倒退时钟未拒绝");passed.Add("无效时钟");
            var areas=new[]{new Rectangle(-1920,0,1920,1040),new Rectangle(0,0,1920,1040)};
            var fit=Settings.Fit(new Point(99999,99999),new Size(200,280),areas);Assert(fit==new Point(1720,760),"屏外位置未纠正");
            fit=Settings.Fit(new Point(-1800,100),new Size(200,280),areas);Assert(fit.X==-1800&&fit.Y==100,"负坐标副屏位置丢失");passed.Add("多屏工作区与负坐标");
            string dir=Path.Combine(Path.GetDirectoryName(report),"settings-test-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(dir);
            string path=Path.Combine(dir,"settings.json");var s=new Settings{Height=350,X=-1700,Y=110,Topmost=false,Paused=true};Settings.Save(path,s);
            string warning;var loaded=Settings.Load(path,out warning);Assert(warning==null&&loaded.Height==350&&loaded.X==-1700&&!loaded.Topmost&&loaded.Paused,"设置往返不一致");
            s.Height=200;Settings.Save(path,s);loaded=Settings.Load(path,out warning);Assert(loaded.Height==200,"第二次原子保存失败");
            string damaged=Path.Combine(dir,"damaged.json");File.WriteAllText(damaged,"broken");loaded=Settings.Load(damaged,out warning);Assert(warning!=null&&loaded.Height==280&&File.ReadAllText(damaged)=="broken","损坏配置未保留");passed.Add("设置保存、更新及损坏文件保留");
            string manifestDir=Path.Combine(dir,"manifest");Directory.CreateDirectory(manifestDir);File.WriteAllText(Path.Combine(manifestDir,"animation.json"),"{\"idle\":[{\"file\":\"../secret.png\",\"durationMs\":40}],\"interaction\":[]}");
            rejected=false;try{Animation.Load(manifestDir);}catch(InvalidDataException){rejected=true;}Assert(rejected,"越界清单未拒绝");passed.Add("素材清单路径约束");
            File.WriteAllText(report,new JavaScriptSerializer().Serialize(new{passed=true,checks=passed}));
        }
    }
}
