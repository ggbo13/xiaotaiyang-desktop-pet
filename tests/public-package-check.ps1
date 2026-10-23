$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'tools/ReleaseSupport.psm1') -Force
$temp=Join-Path ([IO.Path]::GetTempPath()) ('桌宠 公开快照 '+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
$snapshot=New-PetPublicSnapshot -ProjectRoot $root -Destination (Join-Path $temp 'source')
foreach($required in @('AGENTS.md','project.psd1','tools/build-installer.ps1','tools/installer.nsi','tools/publish-release.ps1','tests/installer-check.ps1','.github/workflows/build.yml','docs/preview.png')){
    if(-not (Test-Path -LiteralPath (Join-Path $snapshot.Path $required))){throw "公开快照缺少：$required"}
}
if(@(Get-ChildItem -LiteralPath $snapshot.Path -File -Recurse | Where-Object {$_.FullName -match '[\\/](data|build|dist|\.tools)[\\/]|music-reference|concept\.png$'}).Count -gt 0){throw '公开快照含私人或开发参考内容'}
$issues=@(Test-PetPublicSource -Path $snapshot.Path)
if($issues.Count){throw ('公开快照安全检查失败：'+($issues | ConvertTo-Json -Compress))}
$bad=Join-Path $temp '坏样本';New-Item -ItemType Directory -Path $bad | Out-Null
$credential='ghp_'+('A'*36)
[IO.File]::WriteAllText((Join-Path $bad '设置.txt'),$credential)
$issues=@(Test-PetPublicSource -Path $bad)
if(@($issues | Where-Object Kind -eq 'credential').Count -ne 1){throw '未拦截凭据样本'}
if(($issues | ConvertTo-Json -Compress).Contains($credential)){throw '安全报告泄露凭据本身'}
$privatePath='C:'+('\Users\')+'private-person\secret.json'
[IO.File]::WriteAllText((Join-Path $bad '路径.txt'),$privatePath)
if(@(Test-PetPublicSource -Path $bad | Where-Object Kind -eq 'personal-path').Count -ne 1){throw '未拦截个人绝对路径'}
$blocked=$false
try{$null=New-PetPublicSnapshot -ProjectRoot $root -Destination $snapshot.Path}catch{$blocked=$true}
if(-not $blocked){throw '公开快照覆盖已有目录'}
Write-Output "PUBLIC PACKAGE PASSED: files=$($snapshot.Files.Count); $($snapshot.Path)"
