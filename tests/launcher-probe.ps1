$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# 供启动器验收复制成临时入口，只记录进程信息，不创建桌宠或读取数据。
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PetLauncherProbeWindow {
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
}
'@
$console = [PetLauncherProbeWindow]::GetConsoleWindow()
$result = [ordered]@{
    hostVersion = $PSVersionTable.PSVersion.ToString()
    apartmentState = [Threading.Thread]::CurrentThread.ApartmentState.ToString()
    executable = (Get-Process -Id $PID).Path
    commandLine = [Environment]::CommandLine
    consoleVisible = ($console -ne [IntPtr]::Zero -and [PetLauncherProbeWindow]::IsWindowVisible($console))
    scriptPath = $MyInvocation.MyCommand.Path
}
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'probe.json'), ($result | ConvertTo-Json), (New-Object Text.UTF8Encoding($true)))
