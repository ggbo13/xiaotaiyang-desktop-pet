param([switch]$SkipVbs)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
$temp = Join-Path ([IO.Path]::GetTempPath()) ('桌宠 启动器验收 ' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
$expectedShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $expectedShell)) { throw '本项验收需要 Windows PowerShell 5.1' }
Import-Module (Join-Path $root 'modules\PetAutoStart.psm1') -Force

foreach ($launcher in @('vbs','bat','autostart')) {
    $caseDir = Join-Path $temp ("中文 路径 $launcher")
    New-Item -ItemType Directory -Path $caseDir | Out-Null
    $probeEntry = Join-Path $caseDir 'xiaotaiyang.ps1'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'launcher-probe.ps1') -Destination $probeEntry
    if ($launcher -eq 'vbs') {
        $source = Join-Path $root '启动桌宠.vbs'
        $bytes = [IO.File]::ReadAllBytes($source)
        if ($bytes[0] -ne 255 -or $bytes[1] -ne 254) { throw 'VBS 应为 UTF-16LE Unicode 编码' }
        $copy = Join-Path $caseDir '启动桌宠.vbs'
        Copy-Item -LiteralPath $source -Destination $copy
        if($SkipVbs){Write-Output 'SKIP: 当前受限环境不运行 VBS；编码检查已完成';continue}
        # 批处理模式禁止测试弹出系统脚本宿主对话框，失败只通过退出码报告。
        $hostProcess=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\wscript.exe') -ArgumentList ('//B //NoLogo "{0}"' -f $copy) -WindowStyle Hidden -Wait -PassThru
        if($hostProcess.ExitCode -ne 0){throw "VBS脚本宿主拒绝运行，退出码：$($hostProcess.ExitCode)"}
    }
    elseif ($launcher -eq 'bat') {
        $copy = Join-Path $caseDir '启动桌宠.bat'
        Copy-Item -LiteralPath (Join-Path $root '启动桌宠.bat') -Destination $copy
        Start-Process -FilePath $env:ComSpec -ArgumentList ('/d /c ""{0}""' -f $copy) -WindowStyle Hidden -Wait
    }
    else {
        # 仅执行生成的开机启动命令，不调用注册表读写接口。
        $command = Get-PetAutoStartCommand -EntryScript $probeEntry
        Start-Process -FilePath $env:ComSpec -ArgumentList ('/d /c "{0}"' -f $command) -WindowStyle Hidden -Wait
    }
    $resultPath = Join-Path $caseDir 'probe.json'
    $deadline = (Get-Date).AddSeconds(15)
    while (-not (Test-Path -LiteralPath $resultPath) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
    if (-not (Test-Path -LiteralPath $resultPath)) { throw "$launcher 启动器没有执行探针" }
    $result = [IO.File]::ReadAllText($resultPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($result.hostVersion -notlike '5.1.*' -or $result.executable -ne $expectedShell) { throw "$launcher 没有优先使用系统 PowerShell 5.1" }
    if ($result.apartmentState -ne 'STA') { throw "$launcher 没有使用 STA" }
    if ($result.commandLine -notmatch '-WindowStyle\s+Hidden' -or $result.consoleVisible) { throw "$launcher 没有隐藏控制台" }
    if ($result.scriptPath -ne $probeEntry) { throw "$launcher 丢失空格或中文路径" }
    Write-Output "PASS: $launcher uses $($result.hostVersion), STA, Hidden; Chinese path with spaces"
}
Write-Output "LAUNCHER CHECK PASSED; isolated probes=$temp"
