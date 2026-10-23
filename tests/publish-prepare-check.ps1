param([Parameter(Mandatory)][string]$ManifestPath)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$result=& (Join-Path $root 'tools/publish-release.ps1') -PrepareOnly -ManifestPath $ManifestPath
if(-not $result.Prepared -or -not (Test-Path -LiteralPath $result.Snapshot)){throw '只准备模式未生成安全快照'}
$bad=Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$bad.SourceFiles=@($bad.SourceFiles | Select-Object -Skip 1)
$folder=Split-Path $ManifestPath -Parent
$badPath=Join-Path $folder ('bad-source-list-'+[guid]::NewGuid().ToString('N')+'.manifest.json')
[IO.File]::WriteAllText($badPath,($bad | ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($true)))
$blocked=$false
try{$null=& (Join-Path $root 'tools/publish-release.ps1') -PrepareOnly -ManifestPath $badPath}catch{$blocked=$_.Exception.Message -match '源文件清单不完整'}
if(-not $blocked){throw '发布未拒绝省略源文件的清单'}
Write-Output 'PUBLISH PREPARE PASSED: 完整源码绑定、安全快照与缺项拒绝；未连接或修改 GitHub'
