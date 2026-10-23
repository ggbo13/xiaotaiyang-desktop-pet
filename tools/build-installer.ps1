param(
    [string]$OutputDirectory=(Join-Path (Split-Path $PSScriptRoot -Parent) 'dist'),
    [ValidatePattern('^\d{8}-\d{6}$')][string]$BuildStamp,
    [string]$NsisPath
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'ReleaseSupport.psm1') -Force
$metadata=Import-PowerShellDataFile (Join-Path $root 'project.psd1')
if($metadata.Version -notmatch '^\d+\.\d+\.\d+$'){throw '版本号必须为数字三段式。'}
if(-not $BuildStamp){$BuildStamp=[TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([datetime]::UtcNow,'Taipei Standard Time').ToString('yyyyMMdd-HHmmss')}
$name='XiaoTaiYang-Setup-{0}-{1}' -f $metadata.Version,$BuildStamp
$outputRoot=[IO.Path]::GetFullPath($OutputDirectory)
$installer=Join-Path $outputRoot ($name+'.exe')
$manifestPath=Join-Path $outputRoot ($name+'.manifest.json')
$checksumPath=Join-Path $outputRoot ($name+'.sha256')
foreach($path in @($installer,$manifestPath,$checksumPath)){if(Test-Path -LiteralPath $path){throw "发布目标已存在，不覆盖：$path"}}
$work=Join-Path $root ('build/nsis-'+$BuildStamp+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $work | Out-Null
$stage=New-PetInstallerStage -ProjectRoot $root -Destination (Join-Path $work 'payload')
if(-not $NsisPath){$NsisPath=& (Join-Path $PSScriptRoot 'bootstrap-nsis.ps1')}
if(-not (Test-Path -LiteralPath $NsisPath -PathType Leaf)){throw '找不到NSIS编译器。'}
$compilerVersion=(@(& $NsisPath /VERSION) -join '').Trim()
if($LASTEXITCODE -ne 0 -or $compilerVersion -notmatch '^v3\.11'){throw '本构建使用固定版本NSIS 3.11。'}

# 图标只在独立构建目录中生成，保留原素材和全部旧产物。
Add-Type -AssemblyName System.Drawing
$source=[Drawing.Bitmap]::FromFile((Join-Path $root 'assets/sun.png'))
$scaled=New-Object Drawing.Bitmap 256,256
$graphics=[Drawing.Graphics]::FromImage($scaled)
$png=New-Object IO.MemoryStream
$icon=Join-Path $work 'sun.ico'
try{
    $graphics.Clear([Drawing.Color]::Transparent)
    $graphics.InterpolationMode=[Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $graphics.DrawImage($source,0,0,256,256)
    $scaled.Save($png,[Drawing.Imaging.ImageFormat]::Png)
    $bytes=$png.ToArray()
    $file=[IO.File]::Create($icon);$writer=New-Object IO.BinaryWriter($file)
    try{
        $writer.Write([uint16]0);$writer.Write([uint16]1);$writer.Write([uint16]1)
        $writer.Write([byte]0);$writer.Write([byte]0);$writer.Write([byte]0);$writer.Write([byte]0)
        $writer.Write([uint16]1);$writer.Write([uint16]32);$writer.Write([uint32]$bytes.Length);$writer.Write([uint32]22);$writer.Write($bytes)
    }finally{$writer.Dispose();$file.Dispose()}
}finally{$png.Dispose();$graphics.Dispose();$scaled.Dispose();$source.Dispose()}
$launcher=New-PetInstalledLauncher -ProjectRoot $root -OutputDirectory (Join-Path $work 'launcher') -IconPath $icon
Copy-Item -LiteralPath $launcher -Destination (Join-Path $stage.Path '小太阳桌宠.exe')
$nsisRoot=Split-Path $NsisPath -Parent
$license=@('COPYING','COPYING.txt','LICENSE.txt' | ForEach-Object {Join-Path $nsisRoot $_} | Where-Object {Test-Path -LiteralPath $_}) | Select-Object -First 1
if(-not $license){throw '缺少NSIS许可说明。'}
Copy-Item -LiteralPath $license -Destination (Join-Path $stage.Path 'NSIS-LICENSE.txt')
$runtimeFiles=@(Get-ChildItem -LiteralPath $stage.Path -File -Recurse | ForEach-Object {
    [pscustomobject]@{Path=$_.FullName.Substring($stage.Path.Length+1).Replace([char]92,[char]47);Sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}
} | Sort-Object Path)
$payloadInfo=@{Version=$metadata.Version;AppId=$metadata.AppId;Files=$runtimeFiles} | ConvertTo-Json -Depth 5
[IO.File]::WriteAllText((Join-Path $stage.Path 'runtime-manifest.json'),$payloadInfo,(New-Object Text.UTF8Encoding($true)))
$relativeFiles=@($runtimeFiles.Path)+@('runtime-manifest.json')
$installLines=@();$uninstallLines=@();$directories=@()
foreach($relative in $relativeFiles){
    $directory=[IO.Path]::GetDirectoryName($relative).Replace([char]47,[char]92)
    $suffix=if($directory){'\'+$directory}else{''}
    $installLines+=('SetOutPath "$INSTDIR{0}"' -f $suffix)
    $installLines+=('File "{0}"' -f (Join-Path $stage.Path $relative).Replace('$','$$'))
    $uninstallLines+=('Delete "$INSTDIR\{0}"' -f $relative.Replace([char]47,[char]92))
    while($directory){
        $directories+=$directory
        $directory=[IO.Path]::GetDirectoryName($directory)
    }
}
foreach($directory in @($directories | Sort-Object -Unique | Sort-Object Length -Descending)){$uninstallLines+=('RMDir "$INSTDIR\{0}"' -f $directory)}
$installInclude=Join-Path $work 'files-install.nsh'
$uninstallInclude=Join-Path $work 'files-uninstall.nsh'
[IO.File]::WriteAllLines($installInclude,[string[]]$installLines,(New-Object Text.UTF8Encoding($true)))
[IO.File]::WriteAllLines($uninstallInclude,[string[]]$uninstallLines,(New-Object Text.UTF8Encoding($true)))
New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
$arguments=@('/NOCONFIG','/NOCD','/V3',"/DAPP_VERSION=$($metadata.Version)","/DOUTPUT_FILE=$installer", "/DAPP_ICON=$icon", "/DINSTALL_FILES=$installInclude", "/DUNINSTALL_FILES=$uninstallInclude",(Join-Path $PSScriptRoot 'installer.nsi'))
$log=@(& $NsisPath @arguments 2>&1)
[IO.File]::WriteAllLines((Join-Path $work 'nsis.log'),[string[]]$log)
if($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $installer)){throw ('NSIS编译失败：'+($log -join "`n"))}
$hash=(Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash
[IO.File]::WriteAllText($checksumPath,($hash+'  '+[IO.Path]::GetFileName($installer)+"`r`n"),[Text.Encoding]::ASCII)
$sourceFiles=@(Get-PetPublicFiles -ProjectRoot $root)
$sourceHashes=@($sourceFiles | Sort-Object -Unique | ForEach-Object {[pscustomobject]@{Path=$_;Sha256=(Get-FileHash -LiteralPath (Join-Path $root $_) -Algorithm SHA256).Hash}})
$manifest=[ordered]@{Version=$metadata.Version;AppId=$metadata.AppId;Compiler='NSIS 3.11';BuildStamp=$BuildStamp;Signed=$false;Installer=[IO.Path]::GetFileName($installer);InstallerSha256=$hash;RuntimeFiles=$runtimeFiles;SourceFiles=$sourceHashes}
[IO.File]::WriteAllText($manifestPath,($manifest | ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($true)))
Write-Host "NSIS BUILD OK: $installer"
return [pscustomobject]@{InstallerPath=$installer;ManifestPath=$manifestPath;ChecksumPath=$checksumPath;PayloadDirectory=$stage.Path;WorkDirectory=$work;BuildStamp=$BuildStamp;Version=$metadata.Version;Sha256=$hash}
