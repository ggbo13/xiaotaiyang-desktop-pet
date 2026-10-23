# 小太阳 Windows 桌宠
# 兼容 Windows PowerShell 5.1 与 PowerShell 7；需要 STA 与 WPF。
# 建议双击 启动桌宠.bat 运行，或用：
#   powershell -NoProfile -ExecutionPolicy Bypass -STA -File 小太阳.ps1
Set-StrictMode -Version Latest

$ErrorActionPreference = 'Stop'
$script:Root = Split-Path $MyInvocation.MyCommand.Path -Parent
$script:Modules = Join-Path $script:Root "modules"
$script:Assets = Join-Path $script:Root "assets"
$script:EntryScript = $MyInvocation.MyCommand.Path
# 安装版统一自启入口，避免中文入口卸载后留下另一条失效路径。
if(Test-Path -LiteralPath (Join-Path $script:Root 'installed-mode.flag')){
    $script:EntryScript=Join-Path $script:Root 'xiaotaiyang.ps1'
}

# ---------------------------------------------------------------- single instance
$script:Mutex = $null
try {
    $created = $false
    $script:Mutex = New-Object System.Threading.Mutex($true, 'Global\XiaoTaiYangDesktopPet', [ref]$created)
    if (-not $created) {
        # Already running elsewhere: don't silently vanish — tell the user why.
        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
            $null = [System.Windows.Forms.MessageBox]::Show(
                '小太阳已经在运行啦～请到右下角托盘找到它。',
                '小太阳桌宠',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information)
        }
        catch { }
        exit 0
    }
}
catch {
    # if mutex fails, still allow one instance
}

# ---------------------------------------------------------------- load modules
Import-Module (Join-Path $script:Modules 'PetConfig.psm1') -Force
Import-Module (Join-Path $script:Modules 'PetStore.psm1') -Force
Import-Module (Join-Path $script:Modules 'PetTalk.psm1') -Force
Import-Module (Join-Path $script:Modules 'PetWindow.psm1') -Force
Import-Module (Join-Path $script:Modules 'PetTray.psm1') -Force
Import-Module (Join-Path $script:Modules 'PetReminder.psm1') -Force
Import-Module (Join-Path $script:Modules 'PetAutoStart.psm1') -Force
Import-Module (Join-Path $script:Modules 'PetMusic.psm1') -Force
Import-Module (Join-Path $script:Modules 'PetGrowth.psm1') -Force

$script:Config = Read-PetConfig
$script:Config.sleepAfterMin = 3
$script:Store = Get-PetStore
$growthBeforeUpgrade = $script:Store['growth'] | ConvertTo-Json -Depth 8 -Compress
$null = Initialize-PetGrowth -Store $script:Store
$script:GrowthNeedsSave = $growthBeforeUpgrade -ne ($script:Store['growth'] | ConvertTo-Json -Depth 8 -Compress)
if (@($script:Store.growth.unlockedSkins) -notcontains [string]$script:Config.skinId) {
    $script:Config.skinId = 'original'
}

# TTS
$null = Initialize-PetTalk -Volume $script:Config.volume -Rate $script:Config.rate

# Music recognition (SMTC). Graceful if the platform doesn't expose it.
$script:MusicReady = Initialize-PetMusic

# Catch up on anything due while the app was closed.
$script:PendingCatchUpText = $null
# 沿用已升级的存档，避免再次读取旧文件丢失新增皮肤和成长字段。
$missed = Invoke-PetCatchUp -Store $script:Store -Now (Get-Date)
if ($script:GrowthNeedsSave -or $missed.Count -gt 0) {
    Write-PetStore -Store $script:Store
}
if ($missed.Count -gt 0) {
    $script:PendingCatchUpText = (($missed | ForEach-Object { $_.title }) -join '、')
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml -ErrorAction SilentlyContinue
[System.Windows.Application]::new() | Out-Null
[System.Windows.Application]::Current.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown

$script:App = [System.Windows.Application]::Current
$script:LastInteraction = Get-Date
$script:IdleChatterCount = 0
$script:ShuttingDown = $false
$script:AlertLock = $false
$script:AlertUntil = [datetime]::MinValue
$script:PeakStreak = 0
$script:LastMusicDetected = $false
$script:MusicSilenceSince = $null
$script:DisplayedMusicKey = ''
$script:ManualSleep = $false
$script:LastGrowthPersist = Get-Date

function Show-PetNewUnlocks {
    param([object[]]$SkinIds)
    foreach ($skinId in @($SkinIds)) {
        $name = switch ($skinId) { 'moonlit' { '月夜' } 'festival' { '庆典' } 'western' { '复古牛仔' } default { '原版小太阳' } }
        Show-PetBubble -Text ("亲密度升级！已解锁【{0}】外观，去【成长与外观】看看吧～" -f $name) -Seconds 8
        Show-PetTrayNotification -Title '解锁新外观' -Text ("已解锁【{0}】主题" -f $name)
    }
}

function Show-PetSchedule {
    param([string]$Filter)
    $now = Get-Date
    $today = $now.Date
    switch ($Filter) {
        'week' {
            $end = $today.AddDays(7)
            $items = @($script:Store.items | Where-Object {
                (-not $_.completed) -and $_.dueAt -and ([datetime]::Parse($_.dueAt)).Date -ge $today -and ([datetime]::Parse($_.dueAt)).Date -lt $end
            })
            $header = '本周的安排'
        }
        default {
            $items = @($script:Store.items | Where-Object { $_.type -eq 'todo' -and -not $_.completed })
            $header = '我的待办'
        }
    }
    $items = @($items | Sort-Object { if ($_.dueAt) { [datetime]::Parse($_.dueAt) } else { [datetime]::MaxValue } })
    if ($items.Count -eq 0) {
        Set-PetState -State 'idle'
        Show-PetBubble -Text ("{0}现在是空的喵～要不要加一个？" -f $header)
        return
    }
    $lines = [System.Collections.ArrayList]@()
    $null = $lines.Add($header)
    foreach ($it in $items) {
        if ($it.dueAt) {
            $t = ([datetime]::Parse($it.dueAt)).ToString('M月d日 HH:mm')
            $stateTxt = if ($it.completed) { '✓' } else { '·' }
            $null = $lines.Add("  {0} {1}  {2}" -f $stateTxt, $t, $it.title)
        }
        else {
            $stateTxt = if ($it.completed) { '✓' } else { '·' }
            $null = $lines.Add("  {0} 任意时间  {1}" -f $stateTxt, $it.title)
        }
    }
    Set-PetState -State 'idle'
    Show-PetBubble -Text ($lines -join "`n") -Seconds 12
}

function Invoke-PetCountdownDisplay {
    $cd = Get-PetActiveCountdown -Store $script:Store
    if ($null -eq $cd) {
        Hide-PetCountdown
        return
    }
    $remaining = Get-PetCountdownRemaining -Item $cd
    if ($remaining -gt 0) {
        $ts = [TimeSpan]::FromSeconds($remaining)
        Set-PetCountdown -Text ("剩余 {0:D2}:{1:D2}:{2:D2}" -f [int][Math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds)
    }
    else {
        Hide-PetCountdown
    }
}

function Invoke-PetStartCountdown {
    param(
        [double]$Seconds,
        [string]$Label
    )
    if ($Seconds -le 0) { return }
    if ([string]::IsNullOrWhiteSpace($Label)) { $Label = "倒计时" }
    # Only one countdown at a time: drop any existing one first.
    Remove-PetCountdown -Store $script:Store
    $due = (Get-Date).AddSeconds($Seconds)
    $null = Add-PetItem -Store $script:Store -Item @{
        title = $Label; type = 'countdown'; dueAt = $due.ToString('o'); durationSeconds = $Seconds
    }
    Set-PetState -State 'working'
    Show-PetBubble -Text ("倒计时开始喵～{0}，已设为 {1} 秒！" -f $Label, $Seconds)
    Write-PetStore -Store $script:Store
    Invoke-PetCountdownDisplay
}

function Update-PetDetectedMusicCover {
    param($MediaStatus)
    if ($null -eq $MediaStatus -or (-not $MediaStatus.Title -and -not $MediaStatus.App)) { return }
    $displayKey = "$($MediaStatus.App)`n$($MediaStatus.Title)`n$($MediaStatus.Artist)"
    if ($displayKey -ne $script:DisplayedMusicKey -or $null -ne $MediaStatus.Cover) {
        Set-PetMusicCover -Cover $MediaStatus.Cover
        $script:DisplayedMusicKey = $displayKey
    }
}

function Test-PetMusicPlaying {
    if (Test-PetSpeaking) { Set-PetLocalSoundActive -Seconds 1.8 }
    # 音效和语音期间沿用播放前的真实状态，媒体会话与音量检测都不能被自身声音唤起。
    if (Test-PetLocalSoundActive) { $script:PeakStreak = 0; return [bool]$script:LastMusicDetected }
    $mediaStatus = $null
    if ($script:MusicReady) {
        try {
            $mediaStatus = Get-PetMusicStatus
            if ([bool]$mediaStatus.Playing) {
                Update-PetDetectedMusicCover -MediaStatus $mediaStatus
                $script:PeakStreak = 0
                $script:LastMusicDetected = $true
                return $true
            }
            # 播放器明确暂停时，不让系统提示音重新触发音乐形态。
            if ($mediaStatus.HasSession) { $script:PeakStreak = 0; $script:LastMusicDetected = $false; return $false }
        } catch { }
    }
    try {
        if ((Get-PetAudioPeak) -gt 0.015) {
            $script:PeakStreak++
            # 网易云没有媒体会话时，声音恢复的第一个采样就取消静音倒计时。
            if ($null -ne $mediaStatus -and $mediaStatus.App -eq 'cloudmusic') {
                Update-PetDetectedMusicCover -MediaStatus $mediaStatus
                $script:LastMusicDetected = $true
                return $true
            }
            if ($script:PeakStreak -ge 2) {
                Update-PetDetectedMusicCover -MediaStatus $mediaStatus
                $script:LastMusicDetected = $true
                return $true
            }
            $script:LastMusicDetected = $false
            return $false
        }
    } catch { }
    $script:PeakStreak = 0
    $script:LastMusicDetected = $false
    return $false
}

function Invoke-PetTick {
    $script:LastTick = (Get-Date)
    # 前台应用真正全屏时隐藏桌宠，退出全屏后静默恢复。
    try { $null = Update-PetFullscreenVisibility } catch { }
    $hadInput = $false
    try {
        $hadInput = [bool](Get-PetGlobalActivity)
        if ($hadInput) {
            $script:LastInteraction = Get-Date
            $script:ManualSleep = $false
        }
    } catch { }
    # 用户最近两分钟内操作过电脑时才累计陪伴，避免挂机刷取亲密度。
    try {
        $growthTick = Update-PetGrowthClock -Store $script:Store -UserActive (((Get-Date) - $script:LastInteraction).TotalMinutes -lt 2) -ElapsedSeconds 1 -Now $script:LastTick
        if ($growthTick.reward -and $growthTick.reward.newlyUnlocked) { Show-PetNewUnlocks -SkinIds $growthTick.reward.newlyUnlocked }
        if ($growthTick.changed -or ($script:LastTick - $script:LastGrowthPersist).TotalSeconds -ge 60) {
            Write-PetStore -Store $script:Store
            $script:LastGrowthPersist = $script:LastTick
        }
    } catch { }
    # keep the overhead countdown readout fresh every second
    try { Invoke-PetCountdownDisplay } catch { }
    # Keep the alert visible without blocking the UI or delaying another due item.
    if ($script:AlertLock -and $script:LastTick -ge $script:AlertUntil) {
        $script:AlertLock = $false
        Set-PetState -State 'idle'
    }
    $due = Get-PetDueAndAdvance -Store $script:Store -Now $script:LastTick
    if ($due.Count -gt 0) {
        foreach ($dueItem in @($due | Where-Object { $_.type -eq 'countdown' -and [double]$_.durationSeconds -ge 600 })) {
            $growthReward = Add-PetGrowthReward -Store $script:Store -Category countdown -Points 6 -DailyCap 18 -RewardKey ("countdown:{0}" -f $dueItem.id) -MoodPoints 6 -Now $script:LastTick
            if ($growthReward.newlyUnlocked) { Show-PetNewUnlocks -SkinIds $growthReward.newlyUnlocked }
        }
        Write-PetStore -Store $script:Store
        $script:AlertLock = $true
        $script:AlertUntil = $script:LastTick.AddSeconds(8)
        $titles = (@($due | ForEach-Object { $_.title }) -join '、')
        $hasReminder = @($due | Where-Object { $_.type -ne 'countdown' }).Count -gt 0
        if (@($due | Where-Object { $_.type -eq 'countdown' }).Count -gt 0) { Hide-PetCountdown }
        if ($hasReminder) {
            Set-PetState -State 'alert'
            Set-PetSign -Text ("到时间啦！`n{0}" -f $titles)
        }
        else { Set-PetState -State 'happy' }
        Show-PetBubble -Text ("到时间啦：{0}" -f $titles) -Seconds 8
        Show-PetTrayNotification -Title '小太阳提醒' -Text $titles
        $null = Invoke-PetSpeak -Text (Get-PetDueSpeechText -Items @($due)) -Enabled $script:Config.voice
        try { Update-PetTodoMenu } catch { }
        try { Update-PetReminderMenu } catch { }
        return
    }
    if ($script:AlertLock) { return }
    # idle chatter
    if ($script:Config.idleChatter) {
        $idleMins = ((Get-Date) - $script:LastInteraction).TotalMinutes
        if ($idleMins -ge ($script:Config.chatterEveryMin * ($script:IdleChatterCount + 1))) {
            $script:IdleChatterCount++
            $moodLabel = Get-PetMoodLabel -Mood ([int]$script:Store.growth.mood)
            $msgs = switch ($moodLabel) {
                '低落' { @('今天安静地陪着你也很好。','来摸摸我吧，我会开心一点～') }
                '平静' { @('我在陪着你哦，慢慢来～','休息一下，喝口水吧！') }
                '兴奋' { @('今天状态超好，一起把事情都完成吧！','见到你真开心，右键点我一起玩吧～') }
                default { @('今天也一起加油呀！','右键托盘就能查看待办和成长档案哦～') }
            }
            Show-PetBubble -Text ($msgs | Get-Random) -Seconds 5
        }
    }
    # sleep after long inactivity
    if (-not $script:ShuttingDown) {
        $idleMins = ((Get-Date) - $script:LastInteraction).TotalMinutes
        if ($script:ManualSleep -or $idleMins -ge $script:Config.sleepAfterMin) {
            if ((Get-PetCurrentState) -ne 'sleep') { Set-PetState -State 'sleep' }
            return
        }
        elseif ((Get-PetCurrentState) -eq 'sleep') {
            Set-PetState -State 'idle'
        }
    }
    # music-driven state: when a song plays, the horse runs; otherwise it stands.
    if ([bool]$script:Config.music) {
        try {
            $current = Get-PetCurrentState
            $playing = Test-PetMusicPlaying
            if ($playing) {
                $script:MusicSilenceSince = $null
            }
            elseif ($current -eq 'run') {
                # 首次检测到静音时开始计时，至少保留 1.5 秒再判断停播。
                if ($null -eq $script:MusicSilenceSince) {
                    $script:MusicSilenceSince = $script:LastTick
                    $playing = $true
                }
                elseif (($script:LastTick - $script:MusicSilenceSince).TotalSeconds -lt 1.5) {
                    $playing = $true
                }
            }
            if ($playing) {
                # Wake up to run if the pet was asleep or idle.
                if ($current -eq 'idle' -or $current -eq 'sleep' -or $current -eq 'run' -or $current -eq 'music-stopping') {
                    Set-PetState -State 'run'
                }
            }
            else {
                # Back to standing idle, unless we're mid-animation or sleeping.
                if ($current -eq 'run') {
                    Stop-PetMusicState
                }
            }
        }
        catch { }
    }
}

$script:Timer = New-Object System.Windows.Threading.DispatcherTimer
$script:Timer.Interval = [TimeSpan]::FromSeconds(1)
$script:Timer.Add_Tick({ Invoke-PetTick })
$script:Timer.Start()

# ---------------------------------------------------------------- window
$script:Window = New-PetWindow -Config $script:Config
Set-PetSkin -SkinId ([string]$script:Config.skinId)

# ---------------------------------------------------------------- tray
function Restore-PetWindow {
    Toggle-PetWindow
}
$script:Tray = New-PetTray `
    -IconPath (Get-PetAssetPath 'sun.png') `
    -RestoreHandler { Restore-PetWindow } `
    -ListAllHandler { Show-PetSchedule -Filter 'all' } `
    -TodoProviderHandler {
        # return all todo items (including completed) for the submenu, so checked
        # items stay visible with a strike-through until un-checked.
        @($script:Store.items | Where-Object { $_.type -eq 'todo' } |
            Sort-Object { if ($_.completed) { 1 } else { 0 } }, { if ($_.dueAt) { [datetime]::Parse($_.dueAt) } else { [datetime]::MaxValue } })
    } `
    -TodoCompleteHandler {
        param($Id)
        if ($Id) {
            $target = @($script:Store.items | Where-Object { $_.id -eq $Id -and $_.type -eq 'todo' } | Select-Object -First 1)
            if ($target.Count -eq 0) { return }
            $wasDone = $false
            if ($target.Count -gt 0) { $wasDone = [bool]$target[0].completed }
            # Toggle completion so the user can check and un-check.
            Set-PetItemCompleted -Store $script:Store -Id $Id -Completed (-not $wasDone)
            if (-not $wasDone) {
                $growthReward = Add-PetGrowthReward -Store $script:Store -Category todo -Points 8 -DailyCap 32 -RewardKey ("todo:{0}" -f $Id) -MoodPoints 5
                if ($growthReward.newlyUnlocked) { Show-PetNewUnlocks -SkinIds $growthReward.newlyUnlocked }
            }
            Write-PetStore -Store $script:Store
            $name = if ($target.Count -gt 0) { $target[0].title } else { '该待办' }
            if (-not $wasDone) {
                Set-PetState -State 'happy'
                Show-PetBubble -Text ("完成啦喵～{0} 搞定！" -f $name)
                $null = Invoke-PetSpeak -Text "完成啦，干得漂亮！" -Enabled $script:Config.voice
            }
            else {
                Set-PetState -State 'idle'
                Show-PetBubble -Text ("撤销啦喵～{0} 重新待办。" -f $name)
            }
            try { Update-PetTodoMenu } catch { }
        }
    } `
    -TodoDeleteHandler {
        param($Id)
        $target = @($script:Store.items | Where-Object { $_.id -eq $Id -and $_.type -eq 'todo' } | Select-Object -First 1)
        if ($target.Count -eq 0) { return }
        $name = [string]$target[0].title
        Remove-PetItem -Store $script:Store -Id $Id
        Write-PetStore -Store $script:Store
        Set-PetState -State 'idle'
        Show-PetBubble -Text ("已删除待办：{0}" -f $name)
        try { Update-PetTodoMenu } catch { }
    } `
    -TodoAddHandler {
        param($Title)
        if ([string]::IsNullOrWhiteSpace($Title)) { return }
        $null = Add-PetItem -Store $script:Store -Item @{ title = $Title.Trim(); type = 'todo'; dueAt = $null; recurrence = $null }
        Write-PetStore -Store $script:Store
        Set-PetState -State 'working'
        Show-PetBubble -Text ("已添加待办：{0}" -f $Title.Trim())
        try { Update-PetTodoMenu } catch { }
    } `
    -ReminderAddHandler {
        param($Title, $DueAt, $Recurrence=$null)
        $request = New-PetReminderRequest -Title $Title -Mode at -At $DueAt
        if($null -ne $Recurrence){
            if($Recurrence.Kind -ne 'interval'){throw '重复提醒仅支持时间间隔。'}
            $request.Recurrence=(New-PetReminderRequest -Title $Title -Mode interval -DelaySeconds ([double]$Recurrence.IntervalMinutes * 60)).Recurrence
        }
        $item = Add-PetItem -Store $script:Store -Item @{
            title=$request.Title; type='reminder'; dueAt=$request.DueAt.ToString('o'); recurrence=$request.Recurrence
        }
        try { Write-PetStore -Store $script:Store }
        catch { Remove-PetItem -Store $script:Store -Id $item.id; throw }
        $script:LastInteraction = Get-Date
        $script:ManualSleep = $false
        Set-PetState -State 'idle'
        Show-PetBubble -Text ('提醒已设置：{0}，{1:MM-dd HH:mm:ss}' -f $request.Title, $request.DueAt)
        try { Update-PetReminderMenu } catch { }
    } `
    -ReminderProviderHandler {
        @($script:Store.items | Where-Object { $_.type -eq 'reminder' } |
            Sort-Object { if ($_.completed) { 1 } else { 0 } }, { if ($_.dueAt) { [datetime]::Parse($_.dueAt) } else { [datetime]::MaxValue } })
    } `
    -ReminderDeleteHandler {
        param($Id)
        $target = @($script:Store.items | Where-Object { $_.id -eq $Id -and $_.type -eq 'reminder' } | Select-Object -First 1)
        if ($target.Count -eq 0) { return }
        $previousItems = @($script:Store.items)
        Remove-PetItem -Store $script:Store -Id $Id
        try { Write-PetStore -Store $script:Store }
        catch { $script:Store['items'] = $previousItems; throw }
        $script:LastInteraction = Get-Date
        $script:ManualSleep = $false
        Set-PetState -State 'idle'
        Show-PetBubble -Text ('已删除提醒：{0}，不会再提醒。' -f $target[0].title)
        try { Update-PetReminderMenu } catch { }
    } `
    -CountdownPresetHandler {
        param($Minutes)
        $sec = [double]$Minutes * 60
        Invoke-PetStartCountdown -Seconds $sec -Label ("{0}分钟" -f $Minutes)
    } `
    -CountdownCustomHandler {
        param($Seconds)
        $ts = [TimeSpan]::FromSeconds([double]$Seconds)
        $display = '{0:D2}:{1:D2}:{2:D2}' -f [int][Math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds
        Invoke-PetStartCountdown -Seconds ([double]$Seconds) -Label ("自定义 {0}" -f $display)
    } `
    -CountdownCancelHandler {
        $active = Get-PetActiveCountdown -Store $script:Store
        if ($null -eq $active) {
            Hide-PetCountdown
            Show-PetBubble -Text '当前没有正在进行的倒计时喵～'
            return
        }
        Remove-PetCountdown -Store $script:Store
        Write-PetStore -Store $script:Store
        Hide-PetCountdown
        if ((Get-PetCurrentState) -eq 'working') { Set-PetState -State 'idle' }
        Show-PetBubble -Text '当前倒计时已取消，不会再提醒啦～'
    } `
    -InteractionHandler {
        param($Kind)
        $script:LastInteraction = Get-Date
        $script:ManualSleep = $false
        $result = Invoke-PetGrowthInteraction -Store $script:Store -Kind $Kind
        Write-PetStore -Store $script:Store
        if ($Kind -eq 'pet') {
            $message = if ($result.cooldown) { '再摸摸也很开心～亲密度奖励还在休息。' } else { '好舒服呀～亲密度增加啦！' }
        }
        elseif ($Kind -eq 'highfive' -or $Kind -eq 'feed') {
            $message = if ($result.cooldown) { '击掌！默契满分～亲密度奖励还在休息。' } else { '啪！合作愉快，心情和亲密度都增加啦！' }
        }
        else {
            $greetings = @('你好呀，今天也一起加油！','我一直在这里陪着你～','见到你真开心！')
            $message = $greetings | Get-Random
            if ($result.cooldown) { $message += ' 亲密度奖励还在休息。' }
            $null = Invoke-PetSpeak -Text $message -Enabled $script:Config.voice
        }
        Show-PetBubble -Text $message -Seconds 6
        Start-PetInteractionAnimation -Kind $Kind
        if ($result.newlyUnlocked) { Show-PetNewUnlocks -SkinIds $result.newlyUnlocked }
    } `
    -GrowthWindowHandler {
        Show-PetGrowthWindow -Store $script:Store -Config $script:Config -AssetsPath $script:Assets -SkinChangedHandler {
            param($SkinId)
            $script:Config.skinId = $SkinId
            Write-PetConfig -Config $script:Config
            Set-PetSkin -SkinId $SkinId
            Show-PetBubble -Text '新外观已经换好啦～'
        }
    } `
    -IdleHandler {
        $null = Get-PetGlobalActivity
        $script:ManualSleep = $true
        Set-PetState -State 'sleep'
    } `
    -AutoStartHandler {
        if (Test-PetAutoStart) { Disable-PetAutoStart; $script:Config.autoStart = $false }
        else { $cmd = Enable-PetAutoStart -EntryScript $script:EntryScript; $script:Config.autoStart = $true }
        Write-PetConfig -Config $script:Config
        Set-PetTrayToggle -Name '开机启动' -Checked $script:Config.autoStart
        Show-PetBubble -Text $(if ($script:Config.autoStart) { '开机启动已开启喵～' } else { '开机启动已关闭喵～' })
    } `
    -MuteHandler {
        $script:Config.voice = -not $script:Config.voice
        Write-PetConfig -Config $script:Config
        Set-PetTrayToggle -Name '开启语音' -Checked $script:Config.voice
        Show-PetBubble -Text $(if ($script:Config.voice) { '语音已开启喵～' } else { '已静音喵～' })
    } `
    -MusicToggleHandler {
        $script:Config.music = -not $script:Config.music
        $script:MusicSilenceSince = $null
        Write-PetConfig -Config $script:Config
        Set-PetTrayToggle -Name '音乐识别' -Checked ([bool]$script:Config.music)
        if (-not [bool]$script:Config.music) {
            $script:PeakStreak = 0
            $script:LastMusicDetected = $false
            if ((Get-PetCurrentState) -eq 'run') { Set-PetState -State 'idle' }
        }
        elseif (Test-PetMusicPlaying) { Set-PetState -State 'run' }
        Show-PetBubble -Text $(if ($script:Config.music) { '音乐识别已开启喵～马会跟着音乐跑起来！' } else { '音乐识别已关闭喵～马回到原地待命。' })
    } `
    -PlayPauseHandler {
        $ok = Invoke-PetMediaCommand -Control 'toggle'
        Show-PetBubble -Text $(if ($ok) { '好嘞～播放/暂停已切换！' } else { '喵…暂时控制不了音乐，先打开音乐播放器试试？' })
    } `
    -NextHandler {
        $ok = Invoke-PetMediaCommand -Control 'next'
        Show-PetBubble -Text $(if ($ok) { '切到下一首啦～' } else { '喵…没有可切的歌曲。' })
    } `
    -PrevHandler {
        $ok = Invoke-PetMediaCommand -Control 'prev'
        Show-PetBubble -Text $(if ($ok) { '回到上一首啦～' } else { '喵…没有上一首。' })
    } `
    -ExitHandler { Stop-PetApp }

# reflect persisted states in tray
Set-PetTrayToggle -Name '开机启动' -Checked ([bool]$script:Config.autoStart)
Set-PetTrayToggle -Name '开启语音' -Checked ([bool]$script:Config.voice)
Set-PetTrayToggle -Name '音乐识别' -Checked ([bool]$script:Config.music)

# Auto-enable start-with-Windows on first run if the setting is on but not registered.
if ([bool]$script:Config.autoStart -and -not (Test-PetAutoStart -EntryScript $script:EntryScript)) {
    try {
        $null = Enable-PetAutoStart -EntryScript $script:EntryScript
    }
    catch { }
}

# ---------------------------------------------------------------- first message
if ($script:PendingCatchUpText) {
    Set-PetState -State 'alert'
    Set-PetSign -Text ("你不在时错过啦`n{0}" -f $script:PendingCatchUpText)
    Show-PetBubble -Text ("欢迎回来喵～有 {0} 在你不在时到期了，我帮你记着了！" -f $script:PendingCatchUpText) -Seconds 12
    Show-PetTrayNotification -Title '错过的提醒' -Text $script:PendingCatchUpText
    $null = Invoke-PetSpeak -Text "欢迎回来，你不在时有几件事到期了。" -Enabled $script:Config.voice
}
else {
    Show-PetBubble -Text ("小太阳上线啦喵～要倒计时、记待办还是看日程？") -Seconds 6
    $null = Invoke-PetSpeak -Text "小太阳上线啦，今天也要一起加油哦！" -Enabled $script:Config.voice
}

# ---------------------------------------------------------------- shutdown
function Stop-PetApp {
    if ($script:ShuttingDown) { return }
    $script:ShuttingDown = $true
    try { $script:Timer.Stop() } catch { }
    try { Stop-PetSpeak } catch { }
    try { Stop-PetTray } catch { }
    try { Write-PetStore -Store $script:Store } catch { }
    try {
        # persist current window position
        $script:Config.windowX = $script:Window.Left
        $script:Config.windowY = $script:Window.Top
        Write-PetConfig -Config $script:Config
    } catch { }
    try { Set-PetAllowClose } catch { }
    try { $script:App.Shutdown() } catch { }
}
# ---------------------------------------------------------------- run
$script:Window.Show()
try {
    $script:App.Run()
}
finally {
    if ($script:Mutex) { try { $script:Mutex.ReleaseMutex() } catch { } }
}
