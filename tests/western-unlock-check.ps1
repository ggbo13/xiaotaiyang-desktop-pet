$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$projectRoot=Split-Path $PSScriptRoot -Parent
$previousData=$env:XIAOTAIYANG_DATA_DIR
$isolated=Join-Path ([IO.Path]::GetTempPath()) ('pet-western-gate-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $isolated | Out-Null
$env:XIAOTAIYANG_DATA_DIR=$isolated
foreach($module in @('PetGrowth','PetConfig','PetStore')){Import-Module (Join-Path $projectRoot "modules/$module.psm1") -Force}
function Assert($Value,[string]$Message){if(-not $Value){throw $Message}}
function Read-SkinButtons($Store,$Config){
    Show-PetGrowthWindow -Store $Store -Config $Config -AssetsPath (Join-Path $projectRoot 'assets')
    [Windows.Forms.Application]::DoEvents()
    $form=[Windows.Forms.Application]::OpenForms | Where-Object Text -eq '成长与外观' | Select-Object -First 1
    try{
        $gallery=$form.Controls | Where-Object Tag -eq 'skin-gallery'
        $result=@{}
        foreach($card in $gallery.Controls){
            $button=$card.Controls | Where-Object {$_ -is [Windows.Forms.Button]} | Select-Object -First 1
            $result[[string]$card.Tag]=@{Enabled=$button.Enabled;Text=$button.Text}
        }
        return $result
    }finally{$form.Close();$form.Dispose()}
}
try{
    # 若只改菜单文案却仍允许点击，零亲密度的真实按钮断言会失败。
    $fresh=@{items=@();growth=(New-PetGrowthState)}
    $buttons=Read-SkinButtons $fresh @{skinId='original'}
    Assert (-not $buttons.western.Enabled -and $buttons.western.Text -eq '亲密度 100 解锁') '零亲密度仍可使用复古牛仔，或门槛文案错误'
    foreach($case in @(@{Points=59;Moon=$false;Western=$false;Festival=$false},@{Points=60;Moon=$true;Western=$false;Festival=$false},@{Points=99;Moon=$true;Western=$false;Festival=$false},@{Points=100;Moon=$true;Western=$true;Festival=$false},@{Points=149;Moon=$true;Western=$true;Festival=$false},@{Points=150;Moon=$true;Western=$true;Festival=$true})){
        $store=@{items=@();growth=(New-PetGrowthState)};$store.growth.intimacy=$case.Points
        $buttons=Read-SkinButtons $store @{skinId='original'}
        Assert ($buttons.moonlit.Enabled -eq $case.Moon -and $buttons.western.Enabled -eq $case.Western -and $buttons.festival.Enabled -eq $case.Festival) "皮肤边界规则错误：$($case.Points)"
    }
    $store=@{items=@();growth=(New-PetGrowthState)};$store.growth.intimacy=99
    $reward=Add-PetGrowthReward -Store $store -Category interaction -Points 1 -DailyCap 999
    Assert (@($reward.newlyUnlocked) -contains 'western') '首次达到100没有解锁牛仔'
    Assert (@(Update-PetGrowthUnlocks -Store $store).Count -eq 0) '牛仔重复解锁提示'
    # 旧版免费记录保留，但不能绕过新的使用门槛；其他已解锁皮肤不收回。
    $legacy=@{items=@(@{id='kept';title='保留待办'});growth=(New-PetGrowthState)}
    $legacy.growth.intimacy=43;$legacy.growth.mood=81
    $legacy.growth.unlockedSkins=@('original','western','moonlit')
    $legacy.growth.rewardedKeys=@('todo:kept');$legacy.growth.interactionCooldowns=@{highfive=(Get-Date).AddHours(1).ToString('o')}
    $before=$legacy | ConvertTo-Json -Depth 10 -Compress
    $buttons=Read-SkinButtons $legacy @{skinId='original'}
    Assert (-not $buttons.western.Enabled -and $buttons.moonlit.Enabled) '旧免费标记绕过100门槛，或误锁月夜'
    Assert (($legacy | ConvertTo-Json -Depth 10 -Compress) -eq $before) '查看皮肤修改了旧成长、冷却或事项'
    foreach($entry in @('xiaotaiyang.ps1','小太阳.ps1')){
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot $entry),[ref]$tokens,[ref]$errors)
        $parts=@();$collect=$false
        foreach($statement in $ast.EndBlock.Statements){
            if($statement.Extent.Text -match '^\$script:Config = Read-PetConfig'){$collect=$true}
            if($statement.Extent.Text -match '^\$null = Initialize-PetTalk'){$collect=$false}
            if($collect){$parts+=$statement.Extent.Text}
        }
        foreach($points in @(99,100)){
            $fixture=@{items=@();growth=(New-PetGrowthState)};$fixture.growth.intimacy=$points
            $fixture.growth.unlockedSkins=@('original','western')
            Write-PetStore -Store $fixture
            Write-PetConfig -Config @{skinId='western';voice=$false;autoStart=$false}
            . ([scriptblock]::Create($parts -join "`n"))
            $expected=if($points -lt 100){'original'}else{'western'}
            Assert ($script:Config.skinId -eq $expected -and (Read-PetConfig).skinId -eq $expected) "$entry 未正确恢复并保存可用皮肤：$points"
            Assert ((Get-PetStore).growth.intimacy -eq $points -and @((Get-PetStore).growth.unlockedSkins) -contains 'western') '入口改动了亲密度或旧解锁记录'
        }
    }
    Write-Output 'WESTERN UNLOCK PASSED: 0/59/60/99/100/149/150、旧存档和两个入口持久化'
}finally{$env:XIAOTAIYANG_DATA_DIR=$previousData}
