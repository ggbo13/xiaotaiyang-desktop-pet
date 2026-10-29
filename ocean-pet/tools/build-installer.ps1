$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$repoRoot=Split-Path $root -Parent
$meta=Import-PowerShellDataFile (Join-Path $root 'project.psd1')
$stamp=[TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([datetime]::UtcNow,'Taipei Standard Time').ToString('yyyyMMdd-HHmmss')
$work=Join-Path $repoRoot ('build/ocean-installer-'+$stamp)
New-Item -ItemType Directory -Path $work | Out-Null
$app=& (Join-Path $PSScriptRoot 'build-app.ps1') -OutputDirectory (Join-Path $work 'app')
$null=& (Join-Path $PSScriptRoot 'test-app.ps1') -AppDirectory $app
$compiler=& (Join-Path $PSScriptRoot 'bootstrap-nsis.ps1') -CacheRoot (Join-Path $repoRoot '.tools/nsis-verified')
$payload=Join-Path $work 'payload'
New-Item -ItemType Directory -Path $payload | Out-Null
Copy-Item (Join-Path $app 'OceanMaid.exe') $payload
Copy-Item (Join-Path $app 'assets') $payload -Recurse
Copy-Item (Join-Path $root 'README.md') $payload
Copy-Item (Join-Path (Split-Path $compiler -Parent) 'COPYING') (Join-Path $payload 'NSIS-COPYING.txt')
[IO.File]::WriteAllText((Join-Path $payload 'OceanMaid.install'),$meta.AppId)
$files=@(Get-ChildItem $payload -Recurse -File | ForEach-Object {[pscustomobject]@{Path=$_.FullName.Substring($payload.Length+1).Replace('\','/');Sha256=(Get-FileHash $_.FullName).Hash}})
$install=@();$uninstall=@()
foreach($file in $files){
    $relative=$file.Path.Replace('/','\');$parent=Split-Path $relative -Parent
    $install+='SetOutPath "$INSTDIR\'+$parent+'"'
    $install+='File "'+(Join-Path $payload $relative)+'"'
    $uninstall+='Delete "$INSTDIR\'+$relative+'"'
}
foreach($dir in @(Get-ChildItem $payload -Directory -Recurse | Sort-Object {$_.FullName.Length} -Descending)){$uninstall+='RMDir "$INSTDIR\'+$dir.FullName.Substring($payload.Length+1)+'"'}
$utf8=[Text.UTF8Encoding]::new($true)
$inc=Join-Path $work 'install.nsh';$uninc=Join-Path $work 'uninstall.nsh'
[IO.File]::WriteAllLines($inc,$install,$utf8);[IO.File]::WriteAllLines($uninc,$uninstall,$utf8)
$dist=Join-Path $repoRoot 'dist';New-Item -ItemType Directory -Force $dist | Out-Null
$output=Join-Path $dist ('OceanMaid-Setup-'+$meta.Version+'-'+$stamp+'.exe')
if(Test-Path $output){throw '安装包已存在，禁止覆盖。'}
& $compiler /V2 ('/DOUTPUT_FILE='+$output) ('/DAPP_VERSION='+$meta.Version) ('/DAPP_ICON='+(Join-Path $root 'assets/pet.ico')) ('/DINSTALL_FILES='+$inc) ('/DUNINSTALL_FILES='+$uninc) (Join-Path $PSScriptRoot 'installer.nsi')
if($LASTEXITCODE -ne 0){throw 'NSIS 构建失败。'}
$hash=(Get-FileHash $output).Hash
[IO.File]::WriteAllText([IO.Path]::ChangeExtension($output,'sha256'),($hash+'  '+[IO.Path]::GetFileName($output)+"`n"))
$manifest=[pscustomobject]@{AppId=$meta.AppId;Version=$meta.Version;BuildStamp=$stamp;Signed=$false;Installer=[IO.Path]::GetFileName($output);InstallerSha256=$hash;PayloadFiles=$files}
$manifestPath=[IO.Path]::ChangeExtension($output,'json')
[IO.File]::WriteAllText($manifestPath,($manifest | ConvertTo-Json -Depth 5),$utf8)
Write-Output $manifestPath
