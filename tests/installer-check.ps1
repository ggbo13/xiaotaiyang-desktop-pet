$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path $PSScriptRoot -Parent
$temp=Join-Path ([IO.Path]::GetTempPath()) ('小太阳 安装验证 '+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
$script:Failures=0
function Assert($Value,[string]$Message){if(-not $Value){throw $Message}}
function Check([string]$Name,[scriptblock]$Body){try{& $Body;Write-Output "PASS: $Name"}catch{$script:Failures++;Write-Output "FAIL: $Name -- $($_.Exception.Message)"}}
$originalData=$env:XIAOTAIYANG_DATA_DIR
try{
    # 捕捉安装标记被忽略，以及安装时覆盖既有便携路径或测试覆盖路径的错误。
    Check '便携与安装版的数据目录分离，环境覆盖仍优先' {
        Import-Module (Join-Path $root 'modules/PetPaths.psm1') -Force
        $env:XIAOTAIYANG_DATA_DIR=$null
        $fixture=Join-Path $temp '应用 目录'
        New-Item -ItemType Directory -Path $fixture | Out-Null
        Assert ((Get-PetDataRoot -ApplicationRoot $fixture) -eq (Join-Path $fixture 'data')) '便携路径改变'
        [IO.File]::WriteAllText((Join-Path $fixture 'installed-mode.flag'),'installed')
        $expected=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'XiaoTaiYangDesktopPet/data'
        Assert ((Get-PetDataRoot -ApplicationRoot $fixture) -eq $expected) '安装版仍向程序目录写数据'
        $env:XIAOTAIYANG_DATA_DIR=Join-Path $temp '覆盖 存档'
        Assert ((Get-PetDataRoot -ApplicationRoot $fixture) -eq $env:XIAOTAIYANG_DATA_DIR) '覆盖数据路径被忽略'
    }
    Check '运行文件清单覆盖四皮肤，排除专辑参考与个人资料' {
        Import-Module (Join-Path $root 'tools/ReleaseSupport.psm1') -Force
        $files=@(Get-PetRuntimeFiles -ProjectRoot $root)
        foreach($required in @('xiaotaiyang.ps1','小太阳.ps1','modules/PetPaths.psm1','modules/PetReminder.psm1','assets/sun.png','assets/interactions/highfive.wav','assets/skins/western/pet_highfive_horse.png','assets/skins/moonlit/pet_sleep.png','assets/skins/festival/pet_wave.png')){
            Assert ($files -contains $required) "缺少运行文件：$required"
        }
        Assert (@($files | Where-Object {$_ -match '(^|/)(data|build|dist|\.tools)/|music-reference|concept|config\.json|todos\.json'}).Count -eq 0) '运行清单包含个人或开发参考文件'
        Assert ($files.Count -eq @($files | Select-Object -Unique).Count) '清单有重复文件'
    }
    Check '真实生成载荷不携带个人数据，已有目标不被覆盖' {
        Import-Module (Join-Path $root 'tools/ReleaseSupport.psm1') -Force
        $destination=Join-Path $temp '安装载荷'
        $stage=New-PetInstallerStage -ProjectRoot $root -Destination $destination
        Assert (Test-Path -LiteralPath (Join-Path $stage.Path 'installed-mode.flag')) '缺少安装标记'
        Assert (Test-Path -LiteralPath (Join-Path $stage.Path 'assets/skins/western/pet.png')) '皮肤未复制'
        Assert (-not (Test-Path -LiteralPath (Join-Path $stage.Path 'data'))) '载荷含data目录'
        Assert (-not (Test-Path -LiteralPath (Join-Path $stage.Path 'assets/music-reference.png'))) '载荷含专辑参考'
        $sentinel=Join-Path $destination '用户保留文件.txt'
        [IO.File]::WriteAllText($sentinel,'必须保留')
        $blocked=$false
        try{$null=New-PetInstallerStage -ProjectRoot $root -Destination $destination}catch{$blocked=$true}
        Assert ($blocked -and [IO.File]::ReadAllText($sentinel) -eq '必须保留') '重复构建覆盖既有目录'
    }
    Check '缺少必要素材时构建停止，而不是悄悄发布残缺包' {
        Import-Module (Join-Path $root 'tools/ReleaseSupport.psm1') -Force
        $fixture=Join-Path $temp '缺少太阳的项目'
        New-Item -ItemType Directory -Path $fixture | Out-Null
        # 从一开始就不复制该文件；测试不会删除任何项目文件。
        foreach($relative in @(Get-PetRuntimeFiles -ProjectRoot $root | Where-Object {$_ -ne 'assets/sun.png'})){
            $target=Join-Path $fixture $relative
            New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent) | Out-Null
            Copy-Item -LiteralPath (Join-Path $root $relative) -Destination $target
        }
        $blocked=$false
        try{$null=New-PetInstallerStage -ProjectRoot $fixture -Destination (Join-Path $temp '拒绝残缺载荷')}catch{$blocked=$_.Exception.Message -match 'sun\.png'}
        Assert $blocked '缺少太阳仍被打包'
    }
}finally{$env:XIAOTAIYANG_DATA_DIR=$originalData}
Write-Output "INSTALLER CHECK: failures=$script:Failures; isolated=$temp"
if($script:Failures){exit 1}
