param([Parameter(Mandatory)][string]$ManifestPath)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$meta=Import-PowerShellDataFile (Join-Path $root 'project.psd1')
$repo='ggbo13/xiaotaiyang-desktop-pet';$tag='ocean-v'+$meta.Version
if($meta.Repository -ne $repo){throw '仓库不匹配。'}
function Run([string]$Exe,[string[]]$Arguments){
    $result=@(& $Exe @Arguments 2>&1 | ForEach-Object {"$_"})
    if($LASTEXITCODE -ne 0){throw ($result -join "`n")}
    return ($result -join "`n")
}
$manifest=Get-Content $ManifestPath -Raw | ConvertFrom-Json
$installer=Join-Path (Split-Path $ManifestPath -Parent) $manifest.Installer
if($manifest.Version -ne $meta.Version -or $manifest.AppId -ne $meta.AppId -or (Get-FileHash $installer).Hash -ne $manifest.InstallerSha256){throw '安装包摘要或版本不符。'}
$work=Join-Path (Split-Path $root -Parent) ('build/ocean-publish-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $work | Out-Null
$checkout=Join-Path $work 'repository'
$null=Run git @('-c','credential.helper=','-c','credential.helper=!gh auth git-credential','clone','--single-branch','--branch','main',"https://github.com/$repo.git",$checkout)
$existingFiles=@(Run git @('-C',$checkout,'ls-files','ocean-pet')) -split "`n"
$tags=Run git @('-C',$checkout,'tag','--list',$tag)
if($tags.Trim()){throw '版本标签已存在，禁止覆盖。'}
$files=@('README.md','project.psd1','src/OceanMaid.cs','src/SelfTest.cs','tools/build-app.ps1','tools/test-app.ps1','tools/build-installer.ps1','tools/bootstrap-nsis.ps1','tools/installer.nsi','tools/publish-release.ps1','assets/animation.json','assets/pet.ico')
$files+=@(Get-ChildItem (Join-Path $root 'assets/frames-v1') -Filter '*.png' -File | ForEach-Object {'assets/frames-v1/'+$_.Name})
$files+=@(Get-ChildItem (Join-Path $root 'assets/transitions-v1') -Filter '*.png' -File | ForEach-Object {'assets/transitions-v1/'+$_.Name})
foreach($existing in $existingFiles){if($existing.Trim() -and $existing.Substring(10) -notin $files){throw "远端含额外文件，需要人工审查：$existing"}}
$sourceHashes=@()
foreach($relative in $files){
    $source=Join-Path $root $relative
    if((Get-Item $source).Attributes -band [IO.FileAttributes]::ReparsePoint){throw '公开快照不接受链接。'}
    if($relative -notmatch '\.(png|ico)$'){
        $text=[IO.File]::ReadAllText($source)
        if($text -match '(?i)[A-Z]:[\\/]Users[\\/]|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]+|sk-[A-Za-z0-9]{30,}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'){throw "发现私人路径或凭据：$relative"}
    }
    $target=Join-Path $checkout ('ocean-pet/'+$relative)
    New-Item -ItemType Directory -Force (Split-Path $target -Parent) | Out-Null
    Copy-Item -LiteralPath $source -Destination $target
    $sourceHashes+=[pscustomobject]@{Path=$relative;Sha256=(Get-FileHash $source).Hash}
}
$null=Run git @('-C',$checkout,'add','--','ocean-pet')
$null=Run git @('-C',$checkout,'diff','--cached','--check')
$user=(Run gh @('api','user')) | ConvertFrom-Json
if($user.login -ne 'ggbo13'){throw '登录账号不匹配。'}
$identity=@('-c',('user.name='+$user.login),'-c',('user.email='+$user.id+'+'+$user.login+'@users.noreply.github.com'))
$null=Run git (@('-C',$checkout)+$identity+@('commit','-m',('Release independent Ocean Maid '+$tag)))
$auth=@('-C',$checkout,'-c','credential.helper=','-c','credential.helper=!gh auth git-credential')
$null=Run git ($auth+@('push','origin','main'))
$null=Run git (@('-C',$checkout)+$identity+@('tag','-a',$tag,'-m',('Ocean Maid '+$meta.Version)))
$null=Run git ($auth+@('push','origin',$tag))
$notes=Join-Path $work 'notes.md'
$body="海洋女仆桌宠独立 NSIS 安装版。保留小太阳原程序与数据。`n`n提供透明动画、点击互动、拖拽、托盘、隐藏恢复、尺寸调整、暂停和设置保存。默认关闭开机启动和自动互动。`n`n核心测试与真实窗口回归通过，未执行真实安装/升级/卸载流程验收。源视频尾鳍和鞋底部分裁切保留。安装包未签名。`n`nSHA256："+$manifest.InstallerSha256
[IO.File]::WriteAllText($notes,$body,[Text.UTF8Encoding]::new($false))
$checksum=[IO.Path]::ChangeExtension($installer,'sha256')
$sourceManifest=Join-Path $work 'OceanMaid-source-sha256.json'
[IO.File]::WriteAllText($sourceManifest,($sourceHashes | ConvertTo-Json -Depth 3),[Text.UTF8Encoding]::new($true))
$assets=@($installer,$checksum,$ManifestPath,$sourceManifest)
$null=Run gh (@('release','create',$tag,'--repo',$repo,'--verify-tag','--latest=false','--title',('海洋女仆桌宠 '+$meta.Version),'--notes-file',$notes)+$assets)
$download=Join-Path $work 'download'
$null=Run gh @('release','download',$tag,'--repo',$repo,'--dir',$download)
foreach($local in $assets){if((Get-FileHash $local).Hash -ne (Get-FileHash (Join-Path $download ([IO.Path]::GetFileName($local)))).Hash){throw '下载摘要不一致。'}}
$release=Run gh @('release','view',$tag,'--repo',$repo,'--json','url,tagName,assets')
[IO.File]::WriteAllText((Join-Path $work 'published.json'),$release)
Write-Output $release
