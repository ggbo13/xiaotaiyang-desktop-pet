using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

internal static class InstalledLauncher
{
    [STAThread]
    private static int Main(string[] args)
    {
        string appDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        string entry = Path.Combine(appDir, "xiaotaiyang.ps1");
        if (args.Length == 1 && args[0] == "--verify")
            return File.Exists(entry) && Directory.Exists(Path.Combine(appDir, "modules")) ? 0 : 2;
        try
        {
            // 安装器已经放好程序文件，这里只启动，不写入或解压任何载荷。
            if (!File.Exists(entry)) throw new FileNotFoundException("程序文件不完整，请重新安装。", entry);
            string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
            if (!File.Exists(powershell)) throw new FileNotFoundException("没有找到 Windows PowerShell 5.1。", powershell);
            var start = new ProcessStartInfo
            {
                FileName = powershell,
                Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File \"" + entry + "\"",
                WorkingDirectory = appDir,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };
            using (Process process = Process.Start(start)) { }
            return 0;
        }
        catch (Exception ex)
        {
            MessageBox.Show("小太阳桌宠启动失败：\r\n" + ex.Message, "小太阳桌宠",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
