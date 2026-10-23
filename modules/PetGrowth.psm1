Set-StrictMode -Version Latest

Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue

$script:GrowthForm = $null

function New-PetGrowthState {
    param([datetime]$Now = (Get-Date))
    return @{
        intimacy = 0
        mood = 70
        unlockedSkins = @('original', 'western')
        rewardedKeys = @()
        interactionCooldowns = @{}
        activeSeconds = 0
        lastMoodDecayAt = $Now.ToString('o')
        daily = @{
            date = $Now.ToString('yyyy-MM-dd')
            companion = 0
            interaction = 0
            todo = 0
            countdown = 0
        }
    }
}

function Initialize-PetGrowth {
    param([hashtable]$Store, [datetime]$Now = (Get-Date))
    if (-not $Store.ContainsKey('growth') -or $Store['growth'] -isnot [System.Collections.IDictionary]) {
        $Store['growth'] = New-PetGrowthState -Now $Now
    }
    $growth = $Store['growth']
    $defaults = New-PetGrowthState -Now $Now
    foreach ($key in $defaults.Keys) {
        if (-not $growth.ContainsKey($key)) { $growth[$key] = $defaults[$key] }
    }
    if ($growth['interactionCooldowns'] -isnot [System.Collections.IDictionary]) { $growth['interactionCooldowns'] = @{} }
    # 继承旧喂食的有效冷却，避免升级后额外领取一次亲密度；旧字段保留。
    $cooldowns = $growth['interactionCooldowns']
    if ($cooldowns.ContainsKey('feed') -and $cooldowns['feed']) {
        try {
            $legacyUntil = [datetime]::Parse([string]$cooldowns['feed'])
            $currentUntil = [datetime]::MinValue
            if ($cooldowns.ContainsKey('highfive') -and $cooldowns['highfive']) {
                try { $currentUntil = [datetime]::Parse([string]$cooldowns['highfive']) } catch { }
            }
            if ($legacyUntil -gt $currentUntil) { $cooldowns['highfive'] = $legacyUntil.ToString('o') }
        } catch { }
    }
    if ($growth['daily'] -isnot [System.Collections.IDictionary]) { $growth['daily'] = $defaults['daily'] }
    foreach ($dailyKey in $defaults['daily'].Keys) {
        if (-not $growth['daily'].ContainsKey($dailyKey)) { $growth['daily'][$dailyKey] = $defaults['daily'][$dailyKey] }
    }
    if ($null -eq $growth['rewardedKeys']) { $growth['rewardedKeys'] = @() }
    if ($null -eq $growth['unlockedSkins']) { $growth['unlockedSkins'] = @('original', 'western') }
    Update-PetGrowthDaily -Store $Store -Now $Now
    Update-PetGrowthUnlocks -Store $Store | Out-Null
    return $growth
}

function Update-PetGrowthDaily {
    param([hashtable]$Store, [datetime]$Now = (Get-Date))
    $growth = $Store['growth']
    if ($null -eq $growth) { return }
    $today = $Now.ToString('yyyy-MM-dd')
    $daily = $growth['daily']
    if ($daily -isnot [System.Collections.IDictionary] -or [string]$daily['date'] -ne $today) {
        $growth['daily'] = @{
            date = $today; companion = 0; interaction = 0; todo = 0; countdown = 0
        }
        $growth['activeSeconds'] = 0
    }
}

function Update-PetGrowthUnlocks {
    param([hashtable]$Store)
    $growth = $Store['growth']
    if ($null -eq $growth) { return @() }
    $unlocked = @($growth['unlockedSkins'])
    if ($unlocked -notcontains 'original') { $unlocked += 'original' }
    # 牛仔皮肤免费开放，迁移旧存档时加入可用列表，但不产生解锁提示。
    if ($unlocked -notcontains 'western') { $unlocked += 'western' }
    $newItems = [System.Collections.ArrayList]@()
    if ([int]$growth['intimacy'] -ge 60 -and $unlocked -notcontains 'moonlit') {
        $unlocked += 'moonlit'; $null = $newItems.Add('moonlit')
    }
    if ([int]$growth['intimacy'] -ge 150 -and $unlocked -notcontains 'festival') {
        $unlocked += 'festival'; $null = $newItems.Add('festival')
    }
    $growth['unlockedSkins'] = @($unlocked | Select-Object -Unique)
    return $newItems.ToArray()
}

function Get-PetGrowthStage {
    param([int]$Intimacy)
    if ($Intimacy -ge 150) { return @{ title='最佳搭档'; level=5; floor=150; next=$null } }
    if ($Intimacy -ge 100) { return @{ title='亲密朋友'; level=4; floor=100; next=150 } }
    if ($Intimacy -ge 60) { return @{ title='默契伙伴'; level=3; floor=60; next=100 } }
    if ($Intimacy -ge 30) { return @{ title='渐渐熟悉'; level=2; floor=30; next=60 } }
    return @{ title='初次见面'; level=1; floor=0; next=30 }
}

function Get-PetMoodLabel {
    param([int]$Mood)
    if ($Mood -ge 85) { return '兴奋' }
    if ($Mood -ge 65) { return '开心' }
    if ($Mood -ge 40) { return '平静' }
    return '低落'
}

function Add-PetMood {
    param([hashtable]$Store, [int]$Points, [datetime]$Now = (Get-Date))
    $growth = Initialize-PetGrowth -Store $Store -Now $Now
    $growth['mood'] = [Math]::Max(20, [Math]::Min(100, [int]$growth['mood'] + $Points))
    return [int]$growth['mood']
}

function Add-PetGrowthReward {
    param(
        [hashtable]$Store,
        [ValidateSet('companion','interaction','todo','countdown')][string]$Category,
        [int]$Points,
        [int]$DailyCap,
        [string]$RewardKey = '',
        [int]$MoodPoints = 0,
        [datetime]$Now = (Get-Date)
    )
    $growth = Initialize-PetGrowth -Store $Store -Now $Now
    if ($RewardKey -and @($growth['rewardedKeys']) -contains $RewardKey) {
        return @{ awarded=$false; points=0; newlyUnlocked=@(); reason='already' }
    }
    $daily = $growth['daily']
    $used = [int]$daily[$Category]
    $available = [Math]::Max(0, $DailyCap - $used)
    $awarded = [Math]::Min($Points, $available)
    if ($RewardKey) { $growth['rewardedKeys'] = @($growth['rewardedKeys']) + $RewardKey }
    if ($awarded -gt 0) {
        $daily[$Category] = $used + $awarded
        $growth['intimacy'] = [int]$growth['intimacy'] + $awarded
    }
    if ($MoodPoints -ne 0) { $null = Add-PetMood -Store $Store -Points $MoodPoints -Now $Now }
    $newly = @(Update-PetGrowthUnlocks -Store $Store)
    return @{ awarded=($awarded -gt 0); points=$awarded; newlyUnlocked=$newly; reason=$(if ($awarded -gt 0) {'ok'} else {'cap'}) }
}

function Invoke-PetGrowthInteraction {
    param(
        [hashtable]$Store,
        [ValidateSet('pet','highfive','feed','greet')][string]$Kind,
        [datetime]$Now = (Get-Date)
    )
    # feed 只作为旧调用兼容别名，菜单与新存档统一使用 highfive。
    if ($Kind -eq 'feed') { $Kind = 'highfive' }
    $rules = @{
        pet = @{ points=2; mood=8; cooldown=15; text='摸摸' }
        highfive = @{ points=3; mood=15; cooldown=60; text='击掌' }
        greet = @{ points=1; mood=5; cooldown=60; text='打招呼' }
    }
    $rule = $rules[$Kind]
    $growth = Initialize-PetGrowth -Store $Store -Now $Now
    $cooldowns = $growth['interactionCooldowns']
    $ready = $true
    if ($cooldowns.ContainsKey($Kind) -and $cooldowns[$Kind]) {
        try { $ready = ([datetime]::Parse([string]$cooldowns[$Kind]) -le $Now) } catch { $ready = $true }
    }
    $null = Add-PetMood -Store $Store -Points ([int]$rule.mood) -Now $Now
    if (-not $ready) {
        return @{ awarded=$false; points=0; mood=[int]$growth['mood']; label=$rule.text; cooldown=$true; newlyUnlocked=@() }
    }
    $cooldowns[$Kind] = $Now.AddMinutes([double]$rule.cooldown).ToString('o')
    $result = Add-PetGrowthReward -Store $Store -Category interaction -Points ([int]$rule.points) -DailyCap 999 -Now $Now
    return @{ awarded=$result.awarded; points=$result.points; mood=[int]$growth['mood']; label=$rule.text; cooldown=$false; newlyUnlocked=$result.newlyUnlocked }
}

function Update-PetGrowthClock {
    param(
        [hashtable]$Store,
        [bool]$UserActive,
        [int]$ElapsedSeconds = 1,
        [datetime]$Now = (Get-Date)
    )
    $growth = Initialize-PetGrowth -Store $Store -Now $Now
    $changed = $false
    $reward = $null
    if ($UserActive) {
        $growth['activeSeconds'] = [int]$growth['activeSeconds'] + $ElapsedSeconds
        while ([int]$growth['activeSeconds'] -ge 900 -and [int]$growth['daily']['companion'] -lt 8) {
            $growth['activeSeconds'] = [int]$growth['activeSeconds'] - 900
            $reward = Add-PetGrowthReward -Store $Store -Category companion -Points 1 -DailyCap 8 -Now $Now
            $changed = $changed -or [bool]$reward.awarded
        }
    }
    $lastDecay = $Now
    try { $lastDecay = [datetime]::Parse([string]$growth['lastMoodDecayAt']) } catch { }
    $periods = [int][Math]::Floor(($Now - $lastDecay).TotalMinutes / 30)
    if ($periods -gt 0) {
        $before = [int]$growth['mood']
        $growth['mood'] = [Math]::Max(20, $before - $periods)
        $growth['lastMoodDecayAt'] = $lastDecay.AddMinutes(30 * $periods).ToString('o')
        $changed = $changed -or ([int]$growth['mood'] -ne $before)
    }
    return @{ changed=$changed; reward=$reward }
}

function Get-PetSkinAssetPath {
    param([string]$AssetsPath, [string]$SkinId, [string]$FileName = 'pet.png')
    if ([string]::IsNullOrWhiteSpace($SkinId) -or $SkinId -eq 'original') { return Join-Path $AssetsPath $FileName }
    return Join-Path (Join-Path (Join-Path $AssetsPath 'skins') $SkinId) $FileName
}

function New-PetPreviewImage {
    param([string]$Path, [int]$MaxWidth=188, [int]$MaxHeight=140, [double]$DisplayScale=1)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $stream = [IO.File]::OpenRead($Path)
    try {
        $source = [System.Drawing.Image]::FromStream($stream)
        try {
            $ratio = [Math]::Min(1.0, [Math]::Min($MaxWidth*$DisplayScale/$source.Width, $MaxHeight*$DisplayScale/$source.Height))
            $width = [Math]::Max(1,[int][Math]::Round($source.Width*$ratio))
            $height = [Math]::Max(1,[int][Math]::Round($source.Height*$ratio))
            $thumbnail = New-Object Drawing.Bitmap($width,$height,[Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $graphics = [Drawing.Graphics]::FromImage($thumbnail)
            try {
                $graphics.Clear([Drawing.Color]::Transparent)
                $graphics.CompositingMode = [Drawing.Drawing2D.CompositingMode]::SourceCopy
                $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $graphics.DrawImage($source,(New-Object Drawing.Rectangle(0,0,$width,$height)))
            } finally { $graphics.Dispose() }
            return $thumbnail
        } finally { $source.Dispose() }
    } finally { $stream.Dispose() }
}

function Show-PetGrowthWindow {
    param(
        [hashtable]$Store,
        [hashtable]$Config,
        [string]$AssetsPath,
        [scriptblock]$SkinChangedHandler
    )
    if ($script:GrowthForm -and -not $script:GrowthForm.IsDisposed) {
        $script:GrowthForm.Activate(); return
    }
    $growth = Initialize-PetGrowth -Store $Store
    $stage = Get-PetGrowthStage -Intimacy ([int]$growth['intimacy'])
    $form = New-Object System.Windows.Forms.Form
    $script:GrowthForm = $form
    # WinForms 事件在函数返回后才触发，显式捕获引用，避免严格模式下找不到局部变量。
    $formRef = $form
    $configRef = $Config
    $skinHandlerRef = $SkinChangedHandler
    $form.Text = '成长与外观'
    $form.ClientSize = New-Object System.Drawing.Size(740, 615)
    $form.FormBorderStyle = 'FixedDialog'; $form.MaximizeBox = $false
    $form.StartPosition = 'CenterScreen'; $form.BackColor = [Drawing.Color]::FromArgb(245,247,252)
    $previewGraphics = $form.CreateGraphics()
    try { $previewScale = [Math]::Max(1.0,$previewGraphics.DpiX/96.0) } finally { $previewGraphics.Dispose() }
    $form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)

    $hero = New-Object Windows.Forms.Panel
    $hero.Location = New-Object Drawing.Point(18,16); $hero.Size = New-Object Drawing.Size(704,132)
    $hero.BackColor = [Drawing.Color]::FromArgb(31,42,73)
    $title = New-Object Windows.Forms.Label
    $title.Text = '小太阳成长档案'; $title.ForeColor = [Drawing.Color]::White
    $title.Font = New-Object Drawing.Font('Microsoft YaHei UI',17,[Drawing.FontStyle]::Bold)
    $title.Location = New-Object Drawing.Point(22,15); $title.AutoSize = $true
    $stageLabel = New-Object Windows.Forms.Label
    $stageLabel.Text = ('Lv.{0}  {1}' -f $stage.level,$stage.title); $stageLabel.ForeColor=[Drawing.Color]::FromArgb(255,211,92)
    $stageLabel.Font=New-Object Drawing.Font('Microsoft YaHei UI',11,[Drawing.FontStyle]::Bold)
    $stageLabel.Location=New-Object Drawing.Point(24,55); $stageLabel.AutoSize=$true
    $progress = New-Object Windows.Forms.ProgressBar
    $progress.Location=New-Object Drawing.Point(25,84); $progress.Size=New-Object Drawing.Size(360,18)
    $progress.Minimum=0; $progress.Maximum=100
    if ($null -eq $stage.next) { $progress.Value=100 }
    else { $progress.Value=[Math]::Min(100,[int](100*(([int]$growth.intimacy-$stage.floor)/([double]($stage.next-$stage.floor))))) }
    $progressText = New-Object Windows.Forms.Label
    $progressText.Text = if ($null -eq $stage.next) { '亲密度 {0} · 已达到最高阶段' -f $growth.intimacy } else { '亲密度 {0} / {1}' -f $growth.intimacy,$stage.next }
    $progressText.ForeColor=[Drawing.Color]::FromArgb(224,230,246); $progressText.Location=New-Object Drawing.Point(397,84); $progressText.AutoSize=$true
    $mood = New-Object Windows.Forms.Label
    $mood.Text=('心情  {0} · {1}' -f $growth.mood,(Get-PetMoodLabel -Mood ([int]$growth.mood)))
    $mood.ForeColor=[Drawing.Color]::White; $mood.Font=New-Object Drawing.Font('Microsoft YaHei UI',11)
    $mood.Location=New-Object Drawing.Point(530,25); $mood.AutoSize=$true
    $hero.Controls.AddRange(@($title,$stageLabel,$progress,$progressText,$mood))

    $today = New-Object Windows.Forms.Label
    $today.Text=('今日获得  陪伴 {0}/8   互动 {1}   待办 {2}/32   倒计时 {3}/18' -f $growth.daily.companion,$growth.daily.interaction,$growth.daily.todo,$growth.daily.countdown)
    $today.Location=New-Object Drawing.Point(22,161); $today.Size=New-Object Drawing.Size(696,25)
    $today.ForeColor=[Drawing.Color]::FromArgb(65,73,94)
    $section = New-Object Windows.Forms.Label
    $section.Text='选择外观'; $section.Font=New-Object Drawing.Font('Microsoft YaHei UI',12,[Drawing.FontStyle]::Bold)
    $section.Location=New-Object Drawing.Point(20,194); $section.AutoSize=$true

    $gallery = New-Object Windows.Forms.Panel
    $gallery.Tag = 'skin-gallery'
    $gallery.Location = New-Object Drawing.Point(18,225); $gallery.Size = New-Object Drawing.Size(704,348)
    $gallery.AutoScroll = $true; $gallery.BackColor = [Drawing.Color]::FromArgb(245,247,252)

    $skins = @(
        @{id='original'; name='原版小太阳'; need=0},
        @{id='moonlit'; name='月夜'; need=60},
        @{id='festival'; name='庆典'; need=150},
        @{id='western'; name='复古牛仔'; need=0}
    )
    $skinIndex = 0
    foreach ($skin in $skins) {
        $left = ($skinIndex % 2) * 340
        $top = [int][Math]::Floor($skinIndex / 2) * 262
        $card = New-Object Windows.Forms.Panel
        $card.Tag = [string]$skin.id
        $card.Location=New-Object Drawing.Point($left,$top); $card.Size=New-Object Drawing.Size(328,250)
        $card.BackColor=[Drawing.Color]::White; $card.BorderStyle='FixedSingle'
        $picture = New-Object Windows.Forms.PictureBox
        $picture.Location=New-Object Drawing.Point(8,10); $picture.Size=New-Object Drawing.Size(115,140)
        $picture.SizeMode='Zoom'
        $previewPath=Get-PetSkinAssetPath -AssetsPath $AssetsPath -SkinId $skin.id -FileName 'pet.png'
        $picture.Image=New-PetPreviewImage -Path $previewPath -MaxWidth 115 -MaxHeight 140 -DisplayScale $previewScale
        $horsePicture = New-Object Windows.Forms.PictureBox
        $horsePicture.Location=New-Object Drawing.Point(130,10); $horsePicture.Size=New-Object Drawing.Size(188,140)
        $horsePicture.SizeMode='Zoom'
        $horsePath=Get-PetSkinAssetPath -AssetsPath $AssetsPath -SkinId $skin.id -FileName 'pet_horse.png'
        $horsePicture.Image=New-PetPreviewImage -Path $horsePath -MaxWidth 188 -MaxHeight 140 -DisplayScale $previewScale
        $idleLabel=New-Object Windows.Forms.Label
        $idleLabel.Text='站立'; $idleLabel.TextAlign='MiddleCenter'
        $idleLabel.Location=New-Object Drawing.Point(8,151); $idleLabel.Size=New-Object Drawing.Size(115,20)
        $horseLabel=New-Object Windows.Forms.Label
        $horseLabel.Text='骑马'; $horseLabel.TextAlign='MiddleCenter'
        $horseLabel.Location=New-Object Drawing.Point(130,151); $horseLabel.Size=New-Object Drawing.Size(188,20)
        $name=New-Object Windows.Forms.Label
        $name.Text=$skin.name; $name.TextAlign='MiddleCenter'; $name.Font=New-Object Drawing.Font('Microsoft YaHei UI',10,[Drawing.FontStyle]::Bold)
        $name.Location=New-Object Drawing.Point(8,176); $name.Size=New-Object Drawing.Size(310,24)
        $button=New-Object Windows.Forms.Button
        $button.Tag = [string]$skin.id
        $button.Location=New-Object Drawing.Point(84,207); $button.Size=New-Object Drawing.Size(160,31)
        $isUnlocked=@($growth.unlockedSkins) -contains $skin.id
        $button.Enabled=$isUnlocked -and ([string]$Config.skinId -ne $skin.id)
        $button.Text=if (-not $isUnlocked) { '亲密度 {0} 解锁' -f $skin.need } elseif ([string]$Config.skinId -eq $skin.id) { '当前使用' } else { '使用此外观' }
        if ($isUnlocked) { $button.BackColor=[Drawing.Color]::FromArgb(255,205,73); $button.FlatStyle='Flat' }
        $skinId=[string]$skin.id
        $button.Add_Click(({
            $configRef['skinId']=$skinId
            if ($skinHandlerRef) { & $skinHandlerRef -SkinId $skinId | Out-Null }
            $formRef.Close()
        }).GetNewClosure())
        $card.Controls.AddRange(@($picture,$horsePicture,$idleLabel,$horseLabel,$name,$button)); $gallery.Controls.Add($card)
        $skinIndex++
    }
    $hint=New-Object Windows.Forms.Label
    $hint.Text='完成待办、有效倒计时和日常互动可以提升亲密度。冷却期间互动仍会回应。'
    $hint.Location=New-Object Drawing.Point(22,584); $hint.Size=New-Object Drawing.Size(696,24)
    $hint.ForeColor=[Drawing.Color]::FromArgb(100,106,122)
    $form.Controls.AddRange(@($hero,$today,$section,$gallery,$hint))
    $form.Add_FormClosed({ param($sender,$e)
        foreach ($skinGallery in @($sender.Controls | Where-Object { $_.Tag -eq 'skin-gallery' })) {
            foreach ($cardControl in @($skinGallery.Controls)) {
                foreach ($box in @($cardControl.Controls | Where-Object { $_ -is [Windows.Forms.PictureBox] })) {
                    if ($box.Image) { $box.Image.Dispose(); $box.Image=$null }
                }
            }
        }
        $script:GrowthForm=$null
    })
    $form.Show()
}

Export-ModuleMember -Function New-PetGrowthState, Initialize-PetGrowth, Update-PetGrowthDaily, Update-PetGrowthUnlocks, Get-PetGrowthStage, Get-PetMoodLabel, Add-PetMood, Add-PetGrowthReward, Invoke-PetGrowthInteraction, Update-PetGrowthClock, Get-PetSkinAssetPath, Show-PetGrowthWindow
