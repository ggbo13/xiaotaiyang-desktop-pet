$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent
Import-Module (Join-Path $root 'modules\PetGrowth.psm1') -Force

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$now = Get-Date '2026-09-16 12:00:00'
$store = @{ items = @() }
$growth = Initialize-PetGrowth -Store $store -Now $now
Assert ($growth.intimacy -eq 0 -and $growth.mood -eq 70) '旧数据未正确补齐成长字段'
Assert (@($growth.unlockedSkins) -notcontains 'western') '新存档提前开放复古牛仔皮肤'

$legacyStore = @{
    items = @(@{ id='old-todo'; text='保留原待办' })
    reminders = @(@{ id='old-reminder'; text='保留原提醒' })
    growth = @{
        intimacy = 43
        mood = 81
        unlockedSkins = @('original', 'moonlit')
        rewardedKeys = @('todo:old-todo')
        daily = @{ date=$now.ToString('yyyy-MM-dd'); companion=2; interaction=3; todo=8; countdown=0 }
    }
}
$legacy = Initialize-PetGrowth -Store $legacyStore -Now $now
Assert ($legacy.intimacy -eq 43 -and $legacy.mood -eq 81 -and $legacy.daily.todo -eq 8) '迁移修改了旧成长进度'
Assert (@($legacy.rewardedKeys) -contains 'todo:old-todo' -and $legacyStore.items[0].text -eq '保留原待办' -and $legacyStore.reminders[0].text -eq '保留原提醒') '迁移修改了旧待办、提醒或奖励记录'
Assert (@($legacy.unlockedSkins) -notcontains 'western' -and @($legacy.unlockedSkins) -contains 'moonlit') '迁移提前开放牛仔或改动了原皮肤'
Assert (@(Update-PetGrowthUnlocks -Store $legacyStore).Count -eq 0) '未满100不应产生牛仔解锁提示'
Assert (@($legacy.unlockedSkins | Where-Object { $_ -eq 'western' }).Count -eq 0) '重复初始化提前开放牛仔皮肤'

$pet = Invoke-PetGrowthInteraction -Store $store -Kind pet -Now $now
Assert ($pet.points -eq 2 -and $store.growth.mood -eq 78) '摸摸奖励错误'
$petAgain = Invoke-PetGrowthInteraction -Store $store -Kind pet -Now $now.AddMinutes(1)
Assert (-not $petAgain.awarded -and $store.growth.intimacy -eq 2 -and $store.growth.mood -eq 86) '互动冷却没有阻止重复亲密度'

$todo = Add-PetGrowthReward -Store $store -Category todo -Points 8 -DailyCap 32 -RewardKey 'todo:one' -MoodPoints 5 -Now $now
$todoAgain = Add-PetGrowthReward -Store $store -Category todo -Points 8 -DailyCap 32 -RewardKey 'todo:one' -MoodPoints 5 -Now $now
Assert ($todo.awarded -and -not $todoAgain.awarded -and $store.growth.daily.todo -eq 8) '待办奖励可重复领取'

1..10 | ForEach-Object { $null = Add-PetGrowthReward -Store $store -Category todo -Points 8 -DailyCap 32 -RewardKey "todo:$_" -Now $now }
Assert ($store.growth.daily.todo -eq 32) '待办每日上限错误'

$store.growth.intimacy = 59
$unlock = Add-PetGrowthReward -Store $store -Category interaction -Points 1 -DailyCap 999 -Now $now
Assert (@($unlock.newlyUnlocked) -contains 'moonlit') '月夜皮肤没有在 60 点解锁'
Assert (@($unlock.newlyUnlocked) -notcontains 'western') '牛仔皮肤进入了亲密度解锁提示'
$store.growth.intimacy = 149
$unlock = Add-PetGrowthReward -Store $store -Category interaction -Points 1 -DailyCap 999 -Now $now
Assert (@($unlock.newlyUnlocked) -contains 'festival') '庆典皮肤没有在 150 点解锁'
Assert (@($store.growth.unlockedSkins | Where-Object { $_ -eq 'festival' }).Count -eq 1) '皮肤被重复解锁'

$fresh = @{ items=@() }
$null = Initialize-PetGrowth -Store $fresh -Now $now
$clock = Update-PetGrowthClock -Store $fresh -UserActive $true -ElapsedSeconds 900 -Now $now
Assert ($fresh.growth.daily.companion -eq 1 -and $fresh.growth.intimacy -eq 1) '有效陪伴没有结算'
1..20 | ForEach-Object { $null = Update-PetGrowthClock -Store $fresh -UserActive $true -ElapsedSeconds 900 -Now $now }
Assert ($fresh.growth.daily.companion -eq 8) '陪伴每日上限错误'
$null = Update-PetGrowthClock -Store $fresh -UserActive $false -ElapsedSeconds 1 -Now $now.AddHours(5)
Assert ($fresh.growth.mood -ge 20) '心情衰减低于下限'
$null = Initialize-PetGrowth -Store $fresh -Now $now.AddDays(1)
Assert ($fresh.growth.daily.companion -eq 0 -and $fresh.growth.daily.date -eq $now.AddDays(1).ToString('yyyy-MM-dd')) '跨日计数没有重置'

foreach ($theme in @('moonlit','festival')) {
    foreach ($file in @('pet.png','pet_horse.png','pet_run.png','pet_sleep.png','sun.png')) {
        $path = Join-Path $root "assets\skins\$theme\$file"
        Assert (Test-Path -LiteralPath $path) "缺少皮肤素材：$theme/$file"
        $image = [Drawing.Bitmap]::FromFile($path)
        $original = [Drawing.Image]::FromFile((Join-Path $root "assets\$file"))
        try {
            Assert ($image.Width -eq $original.Width -and $image.Height -eq $original.Height) "皮肤素材尺寸变化：$theme/$file"
            Assert ($image.GetPixel(0,0).A -eq 0 -and $image.GetPixel($image.Width-1,$image.Height-1).A -eq 0) "皮肤素材透明边缘异常：$theme/$file"
        }
        finally { $image.Dispose(); $original.Dispose() }
    }
}

Write-Output 'GROWTH TESTS PASSED'
