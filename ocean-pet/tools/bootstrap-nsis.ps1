param([string]$CacheRoot=(Join-Path (Split-Path $PSScriptRoot -Parent) '.tools/nsis-verified'))
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$expected='C7D27F780DDB6CFFB4730138CD1591E841F4B7EDB155856901CDF5F214394FA1'
$archive=Join-Path $CacheRoot 'nsis-3.11.zip'
New-Item -ItemType Directory -Force -Path $CacheRoot | Out-Null
if(-not (Test-Path -LiteralPath $archive)){
    # Tauri 官方构建依赖镜像保留原始 NSIS ZIP；摘要固定，不执行未知下载内容。
    Invoke-WebRequest -Uri 'https://github.com/tauri-apps/binary-releases/releases/download/nsis-3.11/nsis-3.11.zip' -OutFile $archive -UseBasicParsing
}
if((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $expected){throw 'NSIS ZIP 摘要不符，停止。请人工检查缓存，不会自动删除或替换。'}
$nsisRoot=Join-Path $CacheRoot 'nsis-3.11'
if(-not (Test-Path -LiteralPath $nsisRoot)){Expand-Archive -LiteralPath $archive -DestinationPath $CacheRoot}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip=[IO.Compression.ZipFile]::OpenRead($archive)
try{
    # 缓存也逐文件核验，避免只验证压缩包却执行了被改动的缓存程序。
    foreach($entry in $zip.Entries){
        if(-not $entry.Name){continue}
        $relative=$entry.FullName.Replace([char]92,[char]47)
        if($relative -match '(^|/)\.\.(/|$)' -or [IO.Path]::IsPathRooted($relative)){throw 'NSIS归档包含无效路径。'}
        $path=Join-Path $CacheRoot $relative
        if(-not (Test-Path -LiteralPath $path -PathType Leaf)){throw "NSIS缓存不完整：$relative"}
        $stream=$entry.Open();$sha=[Security.Cryptography.SHA256]::Create()
        try{$hash=[BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','')}finally{$stream.Dispose();$sha.Dispose()}
        if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $hash){throw "NSIS缓存已改变：$relative"}
    }
}finally{$zip.Dispose()}
$compiler=Join-Path $nsisRoot 'makensis.exe'
$version=@(& $compiler /VERSION)
if($LASTEXITCODE -ne 0 -or ($version -join '') -notmatch '^v3\.11'){throw 'NSIS版本验证失败。'}
Write-Host 'NSIS 3.11 ZIP、缓存与编译器版本验证通过。'
return [IO.Path]::GetFullPath($compiler)
