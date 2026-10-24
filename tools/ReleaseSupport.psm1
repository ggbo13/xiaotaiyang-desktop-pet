Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Get-PetRuntimeFiles {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $required=@('xiaotaiyang.ps1','小太阳.ps1','启动桌宠.bat','启动桌宠.vbs','README.md','分享版说明.txt','project.psd1')
    foreach($module in @('PetPaths','PetConfig','PetStore','PetReminder','PetIntent','PetTalk','PetTray','PetWindow','PetMusic','PetGrowth','PetAutoStart')){
        $required+="modules/$module.psm1"
    }
    $required+=@('assets/pet.png','assets/pet_horse.png','assets/pet_run.png','assets/pet_sleep.png','assets/sun.png',
        'assets/interactions/pet_dress.png','assets/interactions/pet_wave.png','assets/interactions/pet_highfive_horse.png',
        'assets/interactions/pet.wav','assets/interactions/feed.wav','assets/interactions/highfive.wav')
    foreach($skin in @('moonlit','festival','western')){
        foreach($image in @('pet.png','pet_horse.png','pet_run.png','pet_sleep.png','pet_dress.png','pet_wave.png','pet_highfive_horse.png')){
            $required+="assets/skins/$skin/$image"
        }
    }
    foreach($relative in $required){
        if(-not (Test-Path -LiteralPath (Join-Path $ProjectRoot $relative) -PathType Leaf)){throw "缺少运行文件：$relative"}
    }
    # 只接收资源类型；保留本机参考图，但不向安装包或公开仓库分发。
    $absoluteRoot=[IO.Path]::GetFullPath($ProjectRoot).TrimEnd([char]92,[char]47)
    $extra=@(Get-ChildItem -LiteralPath (Join-Path $absoluteRoot 'assets') -File -Recurse | Where-Object {
        $_.Extension -in @('.png','.wav') -and $_.Name -ne 'music-reference.png' -and $_.Name -notmatch '(^|[-_])concept\.png$'
    } | ForEach-Object {$_.FullName.Substring($absoluteRoot.Length+1).Replace([char]92,[char]47)})
    return @($required+$extra | Sort-Object -Unique)
}

function New-PetInstallerStage {
    param([Parameter(Mandatory)][string]$ProjectRoot,[Parameter(Mandatory)][string]$Destination)
    if(Test-Path -LiteralPath $Destination){throw "目标已经存在，不覆盖：$Destination"}
    $files=@(Get-PetRuntimeFiles -ProjectRoot $ProjectRoot)
    $stageRoot=[IO.Path]::GetFullPath($Destination)
    New-Item -ItemType Directory -Path $stageRoot | Out-Null
    foreach($relative in $files){
        $target=Join-Path $stageRoot $relative
        New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent) | Out-Null
        Copy-Item -LiteralPath (Join-Path $ProjectRoot $relative) -Destination $target
    }
    [IO.File]::WriteAllText((Join-Path $stageRoot 'installed-mode.flag'),'installed')
    return [pscustomobject]@{Path=$stageRoot;Files=@($files+'installed-mode.flag')}
}

function New-PetInstalledLauncher {
    param([Parameter(Mandatory)][string]$ProjectRoot,[Parameter(Mandatory)][string]$OutputDirectory,[string]$IconPath)
    $metadata=Import-PowerShellDataFile (Join-Path $ProjectRoot 'project.psd1')
    if($metadata.Version -notmatch '^\d+\.\d+\.\d+$'){throw '版本号必须为数字三段式。'}
    $compiler=Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
    if(-not (Test-Path -LiteralPath $compiler)){$compiler=Join-Path $env:WINDIR 'Microsoft.NET/Framework/v4.0.30319/csc.exe'}
    if(-not (Test-Path -LiteralPath $compiler)){throw '缺少系统 .NET Framework 编译器。'}
    New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
    $output=Join-Path $OutputDirectory '小太阳桌宠.exe'
    $versionFile=Join-Path $OutputDirectory 'Launcher.Version.g.cs'
    if((Test-Path -LiteralPath $output) -or (Test-Path -LiteralPath $versionFile)){throw '启动器构建目标已存在，不覆盖。'}
    $attributes=@(
        ('[assembly: System.Reflection.AssemblyVersion("{0}.0")]' -f $metadata.Version),
        ('[assembly: System.Reflection.AssemblyFileVersion("{0}.0")]' -f $metadata.Version),
        '[assembly: System.Reflection.AssemblyTitle("小太阳桌宠")]',
        '[assembly: System.Reflection.AssemblyDescription("小太阳桌宠安装版启动器")]',
        '[assembly: System.Reflection.AssemblyProduct("小太阳桌宠")]',
        '[assembly: System.Reflection.AssemblyCompany("小太阳桌宠项目")]'
    )
    [IO.File]::WriteAllLines($versionFile,[string[]]$attributes,(New-Object Text.UTF8Encoding($true)))
    $compilerArgs=@('/nologo','/target:winexe','/optimize+','/platform:anycpu','/reference:System.Windows.Forms.dll',"/out:$output")
    if($IconPath){$compilerArgs+="/win32icon:$IconPath"}
    $compilerArgs+=@((Join-Path $ProjectRoot 'tools/InstalledLauncher.cs'),$versionFile)
    $compilerOutput=@(& $compiler @compilerArgs 2>&1)
    [IO.File]::WriteAllLines((Join-Path $OutputDirectory 'launcher-compile.log'),[string[]]$compilerOutput)
    if($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $output)){throw ('启动器编译失败：'+($compilerOutput -join ' '))}
    return [IO.Path]::GetFullPath($output)
}

function Get-PetPublicFiles {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $files=@(Get-PetRuntimeFiles -ProjectRoot $ProjectRoot)+@(
        'AGENTS.md','.gitignore','.github/workflows/build.yml','docs/releasing.md','docs/preview.png',
        'tools/ReleaseSupport.psm1','tools/InstalledLauncher.cs','tools/installer.nsi',
        'tools/build-installer.ps1','tools/bootstrap-nsis.ps1','tools/export-public.ps1','tools/publish-release.ps1'
    )
    foreach($test in @('basic-functions-check','growth-tests','highfive-check','interval-reminder-check',
        'preview-check','music-cover-check','music-form-check','parser-tests','launcher-check','launcher-probe','western-unlock-check',
        'installer-check','installed-launcher-check','installer-artifact-check','public-package-check','release-syntax-check','publish-prepare-check','installation-policy-check')){
        $files+="tests/$test.ps1"
    }
    foreach($relative in $files){
        if(-not (Test-Path -LiteralPath (Join-Path $ProjectRoot $relative) -PathType Leaf)){throw "缺少公开文件：$relative"}
    }
    return @($files | Sort-Object -Unique)
}

function Test-PetPublicSource {
    param([Parameter(Mandatory)][string]$Path)
    $sourceRoot=[IO.Path]::GetFullPath($Path).TrimEnd([char]92,[char]47)
    foreach($file in Get-ChildItem -LiteralPath $sourceRoot -File -Recurse -Force){
        $relative=$file.FullName.Substring($sourceRoot.Length+1).Replace([char]92,[char]47)
        if($relative -match '(^|/)(data|build|dist|\.tools|\.git)/|(^|/)(\.env($|\.)|id_(rsa|ed25519)$)|\.(pfx|p12|pem|key)$|music-reference|concept\.png$'){
            [pscustomobject]@{Path=$relative;Kind='excluded-file'}
        }
        if(($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){[pscustomobject]@{Path=$relative;Kind='linked-file'}}
        if($file.Extension -notin @('.ps1','.psm1','.psd1','.cs','.nsi','.md','.txt','.yml','.yaml','.bat','.vbs','')){continue}
        $content=[IO.File]::ReadAllText($file.FullName)
        if($content -match '(sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{40,}|AKIA[0-9A-Z]{16}|-----BEGIN (RSA |OPENSSH |EC |DSA )?PRIVATE KEY-----)'){
            # 只报告相对路径与类别，不把凭据原文写进日志。
            [pscustomobject]@{Path=$relative;Kind='credential'}
        }
        if($content -match '(?i)[A-Z]:[\\/]+Users[\\/]+[^\\/\s"<>]+|/(Users|home)/[^/\s"<>]+'){
            [pscustomobject]@{Path=$relative;Kind='personal-path'}
        }
    }
}

function New-PetPublicSnapshot {
    param([Parameter(Mandatory)][string]$ProjectRoot,[Parameter(Mandatory)][string]$Destination)
    if(Test-Path -LiteralPath $Destination){throw '公开快照目标已存在，不覆盖。'}
    $files=@(Get-PetPublicFiles -ProjectRoot $ProjectRoot)
    $snapshotRoot=[IO.Path]::GetFullPath($Destination)
    New-Item -ItemType Directory -Path $snapshotRoot | Out-Null
    foreach($relative in $files){
        $target=Join-Path $snapshotRoot $relative
        New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent) | Out-Null
        Copy-Item -LiteralPath (Join-Path $ProjectRoot $relative) -Destination $target
    }
    $issues=@(Test-PetPublicSource -Path $snapshotRoot)
    if($issues.Count){throw ('公开快照安全检查未通过：'+($issues | ConvertTo-Json -Compress))}
    return [pscustomobject]@{Path=$snapshotRoot;Files=$files}
}

Export-ModuleMember -Function Get-PetRuntimeFiles, New-PetInstallerStage, New-PetInstalledLauncher, Get-PetPublicFiles, Test-PetPublicSource, New-PetPublicSnapshot
