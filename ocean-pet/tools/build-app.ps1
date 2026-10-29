param([string]$OutputDirectory)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$meta=Import-PowerShellDataFile (Join-Path $root 'project.psd1')
if(-not $OutputDirectory){$OutputDirectory=Join-Path (Split-Path $root -Parent) ('build/ocean-app-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6))}
if(Test-Path -LiteralPath $OutputDirectory){throw '构建目录已存在，保留旧产物，不覆盖。'}
$out=New-Item -ItemType Directory -Path $OutputDirectory
$compiler=Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
$versionFile=Join-Path $out 'Version.g.cs'
[IO.File]::WriteAllText($versionFile,('[assembly:System.Reflection.AssemblyVersion("{0}.0")][assembly:System.Reflection.AssemblyFileVersion("{0}.0")]' -f $meta.Version))
$exe=Join-Path $out 'OceanMaid.exe'
$compileArgs=@('/nologo','/target:winexe','/optimize+','/platform:anycpu','/reference:System.dll','/reference:System.Core.dll','/reference:System.Drawing.dll','/reference:System.Windows.Forms.dll','/reference:System.Web.Extensions.dll',('/win32icon:'+(Join-Path $root 'assets/pet.ico')),('/out:'+$exe),$versionFile,(Join-Path $root 'src/OceanMaid.cs'),(Join-Path $root 'src/SelfTest.cs'))
& $compiler @compileArgs
if($LASTEXITCODE -ne 0){throw '应用编译失败。'}
Copy-Item -LiteralPath (Join-Path $root 'assets') -Destination (Join-Path $out 'assets') -Recurse
Write-Output $out.FullName
