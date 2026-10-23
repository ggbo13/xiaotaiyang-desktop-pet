$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path $PSScriptRoot -Parent
$output=Join-Path ([IO.Path]::GetTempPath()) ('小太阳 安装包验收 '+[guid]::NewGuid().ToString('N'))
$artifact=& (Join-Path $root 'tools/build-installer.ps1') -OutputDirectory $output
if(-not (Test-Path -LiteralPath $artifact.InstallerPath)){throw '未生成安装包'}
if((Get-AuthenticodeSignature -LiteralPath $artifact.InstallerPath).Status -ne 'NotSigned'){throw '本轮要求输出未签名安装包'}
$manifest=Get-Content -LiteralPath $artifact.ManifestPath -Raw | ConvertFrom-Json
$expected=Import-PowerShellDataFile (Join-Path $root 'project.psd1')
if($manifest.Version -ne $expected.Version -or $manifest.Compiler -ne 'NSIS 3.11'){throw '版本或编译器元数据错误'}
if(@($manifest.SourceFiles | Where-Object {$_.Path -eq 'tools/publish-release.ps1'}).Count -ne 1){throw '构建清单未绑定发布工具源码'}
if((Get-FileHash -LiteralPath $artifact.InstallerPath -Algorithm SHA256).Hash -ne $manifest.InstallerSha256){throw '安装包哈希不一致'}
foreach($file in $manifest.RuntimeFiles){
    if($file.Path -match '(^|/)(data|build|dist|\.tools)/|music-reference|concept|\.g\.cs$|compile\.log$'){throw "包内含私人或开发文件：$($file.Path)"}
    if((Get-FileHash -LiteralPath (Join-Path $artifact.PayloadDirectory $file.Path) -Algorithm SHA256).Hash -ne $file.Sha256){throw "载荷哈希错误：$($file.Path)"}
}
foreach($required in @('小太阳桌宠.exe','installed-mode.flag','modules/PetPaths.psm1','assets/skins/western/pet.png')){
    if(@($manifest.RuntimeFiles | Where-Object {$_.Path -eq $required}).Count -ne 1){throw "缺少载荷：$required"}
}
$before=Get-FileHash -LiteralPath $artifact.InstallerPath -Algorithm SHA256
$uninstallTable=Get-Content -LiteralPath (Join-Path $artifact.WorkDirectory 'files-uninstall.nsh') -Raw
if(-not $uninstallTable.Contains('RMDir "$INSTDIR\assets\skins"')){throw '卸载清单未包含空的中间资源目录'}
$installerSource=Get-Content -LiteralPath (Join-Path $root 'tools/installer.nsi') -Raw
if(-not $installerSource.Contains('un.CheckRegisteredLocation')){throw '卸载器未验证注册的安装位置'}
$rejected=$false
try{$null=& (Join-Path $root 'tools/build-installer.ps1') -OutputDirectory $output -BuildStamp $artifact.BuildStamp}catch{$rejected=$true}
if(-not $rejected -or (Get-FileHash -LiteralPath $artifact.InstallerPath -Algorithm SHA256).Hash -ne $before.Hash){throw '重复构建覆盖已有安装包'}
Write-Output "INSTALLER ARTIFACT PASSED: $($artifact.InstallerPath); runtime=$($manifest.RuntimeFiles.Count)"
