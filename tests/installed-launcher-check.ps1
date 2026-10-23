$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'tools/ReleaseSupport.psm1') -Force
$probeRoot=Join-Path ([IO.Path]::GetTempPath()) ('桌宠 安装启动器 '+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $probeRoot | Out-Null
# 真实编译器、真实启动器、真实子进程；仅把桌宠入口换成不启动界面的探针。
$launcher=New-PetInstalledLauncher -ProjectRoot $root -OutputDirectory $probeRoot
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'launcher-probe.ps1') -Destination (Join-Path $probeRoot 'xiaotaiyang.ps1')
New-Item -ItemType Directory -Path (Join-Path $probeRoot 'modules') | Out-Null
$verify=Start-Process -FilePath $launcher -ArgumentList '--verify' -WindowStyle Hidden -Wait -PassThru
if($verify.ExitCode -ne 0){throw '有效安装布局校验失败'}
$process=Start-Process -FilePath $launcher -WindowStyle Hidden -Wait -PassThru
if($process.ExitCode -ne 0){throw '安装启动器失败'}
$probe=Join-Path $probeRoot 'probe.json'
$deadline=(Get-Date).AddSeconds(20)
while(-not (Test-Path -LiteralPath $probe) -and (Get-Date) -lt $deadline){Start-Sleep -Milliseconds 100}
if(-not (Test-Path -LiteralPath $probe)){throw '启动器没有运行入口探针'}
$result=Get-Content -LiteralPath $probe -Raw | ConvertFrom-Json
if($result.hostVersion -notlike '5.1.*' -or $result.apartmentState -ne 'STA' -or $result.consoleVisible){throw '不是隐藏的PowerShell 5.1/STA'}
if($result.scriptPath -ne (Join-Path $probeRoot 'xiaotaiyang.ps1')){throw '中文空格路径丢失'}
$assembly=[Reflection.Assembly]::LoadFile($launcher)
if($assembly.GetManifestResourceNames().Count -ne 0){throw '启动器不应内嵌自解压载荷'}
$incomplete=Join-Path $probeRoot '缺少入口'
New-Item -ItemType Directory -Path $incomplete | Out-Null
$incompleteLauncher=Join-Path $incomplete '小太阳桌宠.exe'
Copy-Item -LiteralPath $launcher -Destination $incompleteLauncher
$verify=Start-Process -FilePath $incompleteLauncher -ArgumentList '--verify' -WindowStyle Hidden -Wait -PassThru
if($verify.ExitCode -ne 2){throw '残缺安装未被校验发现'}
Write-Output "INSTALLED LAUNCHER PASSED: 5.1/STA/Hidden/中文路径，无嵌入ZIP；$probeRoot"
