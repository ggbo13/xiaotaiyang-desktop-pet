param([switch]$CreateRepository,[switch]$PrepareOnly,[string]$ManifestPath)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'ReleaseSupport.psm1') -Force
$metadata=Import-PowerShellDataFile (Join-Path $root 'project.psd1')
if($metadata.Repository -ne 'ggbo13/xiaotaiyang-desktop-pet'){throw '发布目标与已授权仓库不一致。'}
$repo=$metadata.Repository
$tag='v'+$metadata.Version
$work=Join-Path $root ('build/publish-'+[datetime]::Now.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $work | Out-Null
$snapshot=New-PetPublicSnapshot -ProjectRoot $root -Destination (Join-Path $work 'source')
if($ManifestPath){
    $ManifestPath=[IO.Path]::GetFullPath($ManifestPath)
}else{
    $built=& (Join-Path $PSScriptRoot 'build-installer.ps1')
    $ManifestPath=$built.ManifestPath
}
$manifest=Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
if($manifest.Version -ne $metadata.Version -or $manifest.AppId -ne $metadata.AppId -or $manifest.Signed -ne $false){throw '安装包版本、身份或签名策略不匹配。'}
$installer=Join-Path (Split-Path $ManifestPath -Parent) $manifest.Installer
if([IO.Path]::GetFileName($manifest.Installer) -ne $manifest.Installer){throw '安装包文件名不能包含路径。'}
$checksum=[IO.Path]::ChangeExtension($installer,'sha256')
if((Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash -ne $manifest.InstallerSha256){throw '安装包 SHA256 不匹配。'}
if(-not (Test-Path -LiteralPath $checksum) -or -not ([IO.File]::ReadAllText($checksum).StartsWith($manifest.InstallerSha256))){throw '缺少匹配的校验文件。'}
$expectedFiles=@(Get-PetPublicFiles -ProjectRoot $root)
if(@($manifest.SourceFiles).Count -ne $expectedFiles.Count -or @($manifest.SourceFiles.Path | Sort-Object -Unique).Count -ne $expectedFiles.Count){throw '源文件清单不完整或存在重复项。'}
foreach($source in $manifest.SourceFiles){
    if($source.Path -notin $expectedFiles){throw '源文件清单不完整或包含清单外文件。'}
    if($source.Path -match '(^|/)\.\.(/|$)|^[\\/]|:'){throw '源文件摘要清单包含越界路径。'}
    if((Get-FileHash -LiteralPath (Join-Path $root $source.Path) -Algorithm SHA256).Hash -ne $source.Sha256){throw "源码已变化，必须重新构建：$($source.Path)"}
    if((Get-FileHash -LiteralPath (Join-Path $snapshot.Path $source.Path) -Algorithm SHA256).Hash -ne $source.Sha256){throw '公开快照与已构建源码不一致，停止发布。'}
}
if($PrepareOnly){
    return [pscustomobject]@{Prepared=$true;Snapshot=$snapshot.Path;Installer=$installer;Manifest=$ManifestPath;Checksum=$checksum;Tag=$tag;WorkDirectory=$work}
}

function Invoke-ReleaseCommand {
    param([string]$File,[string[]]$Arguments,[switch]$AllowFailure)
    $previous=$ErrorActionPreference
    $ErrorActionPreference='Continue'
    try{$lines=@(& $File @Arguments 2>&1 | ForEach-Object {"$_"});$code=$LASTEXITCODE}finally{$ErrorActionPreference=$previous}
    $output=$lines -join "`n"
    if($code -ne 0 -and -not $AllowFailure){throw ("命令失败：{0}，退出码 {1}：{2}" -f $File,$code,$output)}
    return [pscustomobject]@{ExitCode=$code;Text=$output}
}

$user=(Invoke-ReleaseCommand 'gh' @('api','user')).Text | ConvertFrom-Json
if($user.login -ne ($repo.Split('/')[0])){throw '当前 GitHub 账号不是已授权仓库的所有者。'}
$probe=Invoke-ReleaseCommand 'gh' @('api',"repos/$repo") -AllowFailure
$exists=$probe.ExitCode -eq 0
if($exists){
    if($CreateRepository){throw '指定名称的仓库已经存在，不能当作新库创建。'}
    $remote=$probe.Text | ConvertFrom-Json
    if($remote.full_name -ne $repo -or $remote.private){throw '远端仓库身份或公开状态不符。'}
    if($remote.default_branch -ne 'main'){throw '远端默认分支不是 main，停止自动发布。'}
}elseif(-not $CreateRepository -or $probe.Text -notmatch 'HTTP 404'){
    throw '未确认新库可用，或缺少首次创建授权参数；不会创建或覆盖仓库。'
}
if($exists){
    $releaseProbe=Invoke-ReleaseCommand 'gh' @('api',"repos/$repo/releases/tags/$tag") -AllowFailure
    if($releaseProbe.ExitCode -eq 0){throw '该版本已经发布，不覆盖已有 Release。'}
    if($releaseProbe.Text -notmatch 'HTTP 404'){throw '无法确认远端版本状态。'}
}
$checkout=Join-Path $work 'repository'
if($exists){
    $null=Invoke-ReleaseCommand 'git' @('-c','credential.helper=','-c','credential.helper=!gh auth git-credential','clone','--single-branch','--branch','main',"https://github.com/$repo.git",$checkout)
    $tracked=(Invoke-ReleaseCommand 'git' @('-C',$checkout,'-c','core.quotepath=false','ls-files')).Text -split "`n"
    foreach($path in $tracked){if($path.Trim() -and $path.Trim() -notin $snapshot.Files){throw "远端含清单外文件，必须人工审查，不自动删除：$path"}}
    $existingTag=Invoke-ReleaseCommand 'git' @('-C',$checkout,'show-ref','--verify',"refs/tags/$tag") -AllowFailure
    if($existingTag.ExitCode -eq 0){throw '远端已有同名标签，不覆盖。'}
}else{
    New-Item -ItemType Directory -Path $checkout | Out-Null
    $null=Invoke-ReleaseCommand 'git' @('-C',$checkout,'init','-b','main')
}
foreach($relative in $snapshot.Files){
    $target=Join-Path $checkout $relative
    New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent) | Out-Null
    Copy-Item -LiteralPath (Join-Path $snapshot.Path $relative) -Destination $target
}
$null=Invoke-ReleaseCommand 'git' (@('-C',$checkout,'add','--')+$snapshot.Files)
$null=Invoke-ReleaseCommand 'git' @('-C',$checkout,'diff','--cached','--check')
$identity=@('-c',"user.name=$($user.login)",'-c',"user.email=$($user.id)+$($user.login)@users.noreply.github.com")
$null=Invoke-ReleaseCommand 'git' (@('-C',$checkout)+$identity+@('commit','-m',"Release $tag - NSIS installer"))
$commit=(Invoke-ReleaseCommand 'git' @('-C',$checkout,'rev-parse','HEAD')).Text.Trim()
if(-not $exists){
    $null=Invoke-ReleaseCommand 'gh' @('repo','create',$repo,'--public','--description',$metadata.Description)
    $null=Invoke-ReleaseCommand 'git' @('-C',$checkout,'remote','add','origin',"https://github.com/$repo.git")
}
$gitAuth=@('-C',$checkout,'-c','credential.helper=','-c','credential.helper=!gh auth git-credential')
$null=Invoke-ReleaseCommand 'git' ($gitAuth+@('push','-u','origin','main'))
$null=Invoke-ReleaseCommand 'git' (@('-C',$checkout)+$identity+@('tag','-a',$tag,'-m',"小太阳桌宠 $tag"))
$null=Invoke-ReleaseCommand 'git' ($gitAuth+@('push','origin',$tag))
$notes=Join-Path $work 'release-notes.md'
$text=@"
小太阳桌宠 $tag，Windows 10/11 当前用户 NSIS 安装版。

- 下载 Setup EXE 安装；退出旧桌宠后升级，桌面或开始菜单启动。
- 首次安装可选导入旧 data；升级和卸载保留个人数据。
- 包含四套皮肤、成长互动、音乐形态、待办、倒计时和三种提醒（含重复提醒）。
- 安装器和启动器未签名，仍可能有安全提示；请核对随附 SHA256。
- 源码、载荷摘要清单不含个人记录。构建时间：$($manifest.BuildStamp)。

SHA256：$($manifest.InstallerSha256)
"@
[IO.File]::WriteAllText($notes,$text,(New-Object Text.UTF8Encoding($false)))
$null=Invoke-ReleaseCommand 'gh' @('release','create',$tag,'--repo',$repo,'--verify-tag','--title',"小太阳桌宠 $tag",'--notes-file',$notes,$installer,$checksum,$ManifestPath)
$readback=(Invoke-ReleaseCommand 'gh' @('api',"repos/$repo")).Text | ConvertFrom-Json
$branch=(Invoke-ReleaseCommand 'gh' @('api',"repos/$repo/commits/main")).Text | ConvertFrom-Json
$release=(Invoke-ReleaseCommand 'gh' @('release','view',$tag,'--repo',$repo,'--json','url,assets,tagName')).Text | ConvertFrom-Json
if($readback.private -or $readback.full_name -ne $repo -or $branch.sha -ne $commit -or $release.tagName -ne $tag){throw '远端公开状态、提交或版本回读不一致。'}
$download=Join-Path $work 'download-verification'
$null=Invoke-ReleaseCommand 'gh' @('release','download',$tag,'--repo',$repo,'--dir',$download)
foreach($local in @($installer,$checksum,$ManifestPath)){
    $remoteFile=Join-Path $download ([IO.Path]::GetFileName($local))
    if((Get-FileHash -LiteralPath $remoteFile -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash){throw '下载资产与本地 SHA256 不一致。'}
}
$result=[pscustomobject]@{RepositoryUrl=$readback.html_url;ReleaseUrl=$release.url;Commit=$commit;Tag=$tag;Installer=$installer;Sha256=$manifest.InstallerSha256;WorkDirectory=$work}
[IO.File]::WriteAllText((Join-Path $work 'published.json'),($result | ConvertTo-Json),(New-Object Text.UTF8Encoding($true)))
return $result
