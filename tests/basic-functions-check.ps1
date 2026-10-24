param([string]$Entry = 'xiaotaiyang.ps1')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
$script:failures = 0
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
function Check($Name, [scriptblock]$Body) {
    try {
        # 可见动画在真实显示的离屏测试窗口中验证，隐藏暂停另有专门用例。
        $windowVariable=Get-Variable Window -Scope Script -ErrorAction SilentlyContinue
        if($windowVariable -and $windowVariable.Value){$windowVariable.Value.Show()}
        & $Body; Write-Output "PASS: $Name"
    }
    catch { $script:failures++; Write-Output "FAIL: $Name -- $($_.Exception.Message)" }
}
$temp = Join-Path ([IO.Path]::GetTempPath()) ('pet-check-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
# 导入前指定全新数据目录，测试不读取个人存档，也不依赖运行实例的文件哈希。
$previousDataDir = $env:XIAOTAIYANG_DATA_DIR
$env:XIAOTAIYANG_DATA_DIR = $temp
foreach ($name in @('PetConfig','PetStore','PetWindow','PetTray','PetReminder','PetTalk','PetMusic','PetAutoStart','PetGrowth')) {
    Import-Module (Join-Path $root "modules\$name.psm1") -Force -DisableNameChecking
}
Assert ((Get-PetStorePath) -eq (Join-Path $temp 'todos.json')) 'Store path is not isolated'
Assert ((Get-PetConfigPath) -eq (Join-Path $temp 'config.json')) 'Config path is not isolated'
# 只在本测试进程中静音；声音识别保护另由音乐测试验证，避免测试声打扰当前桌宠。
$originalInteractionSound = & (Get-Module PetWindow) { (Get-Command Play-PetInteractionSound).ScriptBlock }
& (Get-Module PetWindow) { function script:Play-PetInteractionSound { param([string]$Kind) } }
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root $Entry), [ref]$tokens, [ref]$errors)
Assert ($errors.Count -eq 0) 'Entry script syntax error'
foreach ($node in $ast.EndBlock.Statements) {
    if ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
        . ([scriptblock]::Create($node.Extent.Text))
    }
}
Check 'actual startup persists legacy growth and preserves selected skins and items' {
    $statements = @($ast.EndBlock.Statements)
    $initParts = @(); $catchUpParts = @(); $inInit = $false; $inCatchUp = $false
    foreach ($statement in $statements) {
        $source = $statement.Extent.Text
        if ($source -match '^\$script:Config = Read-PetConfig') { $inInit = $true }
        if ($source -match '^\$null = Initialize-PetTalk') { $inInit = $false }
        if ($source -match '^\$script:PendingCatchUpText =') { $inCatchUp = $true }
        if ($source -match '^Add-Type -AssemblyName PresentationFramework') { $inCatchUp = $false }
        if ($inInit) { $initParts += $source }
        if ($inCatchUp) { $catchUpParts += $source }
    }
    Assert ($initParts.Count -ge 6 -and $catchUpParts.Count -ge 4) 'Startup AST extraction missed initialization or catch-up'
    $startupPath = Join-Path $temp 'extracted-startup.ps1'
    [IO.File]::WriteAllText($startupPath, (($initParts + $catchUpParts) -join "`r`n"), (New-Object Text.UTF8Encoding($true)))
    foreach ($selected in @('moonlit','festival')) {
        $now = Get-Date
        $legacyGrowth = New-PetGrowthState -Now $now
        $legacyGrowth.intimacy = 170; $legacyGrowth.mood = 81
        $legacyGrowth.unlockedSkins = @('original','moonlit','festival')
        $legacyGrowth.rewardedKeys = @('todo:legacy-todo')
        $legacyGrowth.interactionCooldowns = @{ feed=$now.AddMinutes(-10).ToString('o') }
        $legacyGrowth.daily.todo = 8; $legacyGrowth.daily.companion = 2
        $fixture = @{ items=@(); growth=$legacyGrowth }
        $null = Add-PetItem -Store $fixture -Item @{ title='测试待办'; type='todo'; dueAt=$null; completed=$true }
        $null = Add-PetItem -Store $fixture -Item @{ title='测试提醒'; type='reminder'; dueAt=$now.AddDays(1).ToString('o') }
        $ids = @($fixture.items | ForEach-Object { $_.id })
        $due = $fixture.items[1].dueAt
        Write-PetStore -Store $fixture
        Write-PetConfig -Config @{ skinId=$selected; voice=$false; autoStart=$false }
        . $startupPath
        Assert ($script:GrowthNeedsSave) 'Legacy western migration was not detected for persistence'
        $reloaded = Get-PetStore
        Assert ($reloaded.growth.intimacy -eq 170 -and $reloaded.growth.mood -eq 81) 'Startup changed intimacy or mood'
        Assert ($reloaded.growth.daily.todo -eq 8 -and $reloaded.growth.daily.companion -eq 2) 'Startup reset current daily rewards'
        Assert (@($reloaded.growth.rewardedKeys) -contains 'todo:legacy-todo') 'Startup lost awarded-item history'
        Assert ($reloaded.growth.interactionCooldowns.feed -eq $legacyGrowth.interactionCooldowns.feed) 'Startup lost interaction cooldown'
        Assert (@($reloaded.growth.unlockedSkins) -contains 'western' -and @($reloaded.growth.unlockedSkins) -contains $selected) 'Startup did not persist all available skins'
        Assert ($script:Config.skinId -eq $selected -and (Read-PetConfig).skinId -eq $selected) 'Startup reset selected old skin'
        Assert ($reloaded.items.Count -eq 2 -and $reloaded.items[0].id -eq $ids[0] -and $reloaded.items[0].completed -and $reloaded.items[1].id -eq $ids[1] -and $reloaded.items[1].dueAt -eq $due -and -not $reloaded.items[1].completed) 'Startup changed existing todo or reminder'
        Write-PetConfig -Config @{ skinId='western'; voice=$false; autoStart=$false }
        . $startupPath
        Assert ($script:Config.skinId -eq 'western' -and (Read-PetConfig).skinId -eq 'western') 'Western selection did not survive reload'
        Assert ((Get-PetStore).growth.intimacy -eq 170) 'Reload changed old intimacy'
    }
    # 更早的存档没有成长字段；真实启动仍需补齐并保存，同时正常补报过期提醒。
    $older = @{ items=@() }
    $null = Add-PetItem -Store $older -Item @{ title='旧版过期提醒'; type='reminder'; dueAt=(Get-Date).AddMinutes(-5).ToString('o') }
    Write-PetStore -Store $older
    Write-PetConfig -Config @{ skinId='original'; voice=$false; autoStart=$false }
    . $startupPath
    $upgraded = Get-PetStore
    Assert ($upgraded.growth.intimacy -eq 0 -and $upgraded.growth.mood -eq 70 -and @($upgraded.growth.unlockedSkins) -notcontains 'western') 'Pre-growth startup migration did not persist locked defaults'
    Assert ($upgraded.items.Count -eq 1 -and $upgraded.items[0].completed -and $script:PendingCatchUpText -eq '旧版过期提醒') 'Startup catch-up lost the legacy reminder'
}
$script:Config = @{ topmost=$false; windowX=-1000; windowY=-1000; music=$false; voice=$false; autoStart=$false; idleChatter=$false; sleepAfterMin=3; skinId='original' }
$script:Store = @{ items=@() }
$null = Initialize-PetGrowth -Store $script:Store
$script:LastInteraction = Get-Date
$script:ShuttingDown=$false; $script:AlertLock=$false; $script:IdleChatterCount=0; $script:PeakStreak=0; $script:MusicReady=$false
$script:Activity=$false; $script:Playing=$false
$script:ManualSleep=$false
$script:MusicSilenceSince=$null
$script:DisplayedMusicKey=''
$script:LastGrowthPersist=Get-Date
$script:AlertUntil=[datetime]::MinValue
function Get-PetGlobalActivity { return $script:Activity }
function Test-PetMusicPlaying { return $script:Playing }
function Show-PetTrayNotification { param($Title,$Text) $script:LastNotification=$Text }
$script:Window = New-PetWindow -Config $script:Config
$trayNode = $ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$script:Tray' } | Select-Object -First 1
. ([scriptblock]::Create($trayNode.Extent.Text))
function Menu($Text) { return ($script:Tray.ContextMenuStrip.Items | Where-Object Text -eq $Text | Select-Object -First 1) }
try {
    Check 'fullscreen bounds distinguish true fullscreen from maximized work area' {
        & (Get-Module PetWindow) {
            if (-not (Initialize-PetFullscreenWatch)) { throw 'Fullscreen watcher initialization failed' }
            if (-not [PetFullscreenWatch]::Covers(0,0,1920,1080,0,0,1920,1080)) { throw 'True fullscreen not detected' }
            if ([PetFullscreenWatch]::Covers(0,0,1920,1040,0,0,1920,1080)) { throw 'Maximized work area treated as fullscreen' }
        }
    }
    Check 'real countdown dialog: zero defaults, wheel routing, bounds, button spacing' {
        & (Get-Module PetTray) {
            # Construct the actual dialog without entering its blocking ShowDialog loop.
            $fn = (Get-Command Show-PetCountdownDialog).ScriptBlock.Ast
            if ($fn -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $fn = $fn.Body }
            $tryNode = $fn.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] } | Select-Object -First 1
            $parts = @()
            foreach ($statement in $tryNode.Body.Statements) {
                if ($statement.Extent.Text.Contains('$form.ShowDialog()')) { break }
                $parts += $statement.Extent.Text
            }
            . ([scriptblock]::Create($parts -join "`n"))
            try {
                if (($hour.Text + $minute.Text + $second.Text) -ne '000000') { throw 'Default is not 00:00:00' }
                $method = [System.Windows.Forms.Control].GetMethod('OnMouseWheel', [Reflection.BindingFlags]'Instance,NonPublic')
                foreach ($field in @($hour,$minute,$second)) {
                    $up = New-Object System.Windows.Forms.HandledMouseEventArgs([System.Windows.Forms.MouseButtons]::None,0,0,0,120)
                    $method.Invoke($field, [object[]]@($up.PSObject.BaseObject)) | Out-Null
                    if ($field.Text -ne '01') { throw 'Wheel did not increase selected field' }
                    $down = New-Object System.Windows.Forms.HandledMouseEventArgs([System.Windows.Forms.MouseButtons]::None,0,0,0,-120)
                    $method.Invoke($field, [object[]]@($down.PSObject.BaseObject)) | Out-Null
                    $method.Invoke($field, [object[]]@($down.PSObject.BaseObject)) | Out-Null
                    if ($field.Text -ne '00') { throw 'Lower boundary failed' }
                    if ($field.Bottom -ge $start.Top) { throw 'Input overlaps button row' }
                }
                $minute.Text='59'
                $method.Invoke($minute, [object[]]@($up.PSObject.BaseObject)) | Out-Null
                if ($minute.Text -ne '59') { throw 'Minute boundary failed' }
            } finally { $form.Dispose() }
        }
    }
    Check 'pet context menu owns interactions and cooldown prevents point farming' {
        Assert ($null -eq (Menu '互动')) 'Interaction should not appear in tray menu'
        Assert ($null -ne (Menu '成长与外观…')) 'Growth window entry missing'
        $interaction=$script:Window.ContextMenu
        Assert ($null -ne $interaction -and $interaction.Items.Count -eq 5) 'Pet context menu missing'
        Assert ([string]$interaction.Items[0].Header -eq '摸摸' -and [string]$interaction.Items[1].Header -eq '击掌' -and [string]$interaction.Items[2].Header -eq '打招呼') 'Pet interaction order is wrong'
        $beforePoints=[int]$script:Store.growth.intimacy
        $beforeMood=[int]$script:Store.growth.mood
        $interaction.Items[0].RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.MenuItem]::ClickEvent))
        Assert ([int]$script:Store.growth.intimacy -eq ($beforePoints+2)) 'Pet interaction did not reward intimacy'
        Assert ([int]$script:Store.growth.mood -eq ($beforeMood+8)) 'Pet interaction did not improve mood'
        Assert ($script:Window.FindName('PetScale').HasAnimatedProperties) 'Pet interaction animation did not start'
        Assert ($script:Window.FindName('InteractionLayer').Children.Count -ge 2) 'Pet interaction particles missing'
        $interaction.Items[0].RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.MenuItem]::ClickEvent))
        Assert ([int]$script:Store.growth.intimacy -eq ($beforePoints+2)) 'Interaction cooldown allowed duplicate intimacy'
        Assert ([int]$script:Store.growth.mood -gt ($beforeMood+8)) 'Cooldown interaction should still improve mood'
        $dressPath=& (Get-Module PetWindow) { Get-PetThemedAssetPath 'pet_dress.png' }
        Assert (Test-Path -LiteralPath $dressPath) 'Dress interaction sprite missing'
        Assert ($script:Window.FindName('PetRotate').HasAnimatedProperties) 'Dress spin did not start'
        $interaction.Items[1].RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.MenuItem]::ClickEvent))
        Assert ($script:Window.FindName('InteractionLayer').Children.Count -eq 4 -and $script:Window.FindName('PetWaveArm').Visibility -eq 'Visible') 'High five hand or contact particles missing'
        # 旧喂食入口仅保留给旧内部调用，继续检验其中断清理不会影响新互动。
        Start-PetInteractionAnimation -Kind 'feed'
        $effectLayer=$script:Window.FindName('InteractionLayer')
        Assert ($effectLayer.Children.Count -ge 18) 'Explosion, full smoke cover or heart-eye layers missing'
        $hearts=@($effectLayer.Children | Where-Object { $_ -is [System.Windows.Controls.TextBlock] -and $_.Text -eq '♥' })
        $heartLeft=@($hearts | ForEach-Object { [System.Windows.Controls.Canvas]::GetLeft($_) })
        $heartTop=@($hearts | ForEach-Object { [System.Windows.Controls.Canvas]::GetTop($_) })
        # 气泡换行后精灵高度会变化，按实际图片区域检查旧兼容特效，不能使用屏幕定值。
        $image=$script:Window.FindName('PetImage');$origin=$image.TranslatePoint([Windows.Point]::new(0,0),$effectLayer)
        Assert ($heartLeft.Count -eq 2 -and $heartLeft[0] -lt $heartLeft[1] -and $heartLeft[0] -gt $origin.X+$image.ActualWidth*.25 -and $heartLeft[1] -lt $origin.X+$image.ActualWidth*.8 -and $heartTop[0] -ge $origin.Y -and $heartTop[0] -lt $origin.Y+$image.ActualHeight*.35) 'Standing heart eyes are not aligned over both eyes'
        Set-PetState -State 'run'
        Start-PetInteractionAnimation -Kind 'feed'
        $horseHearts=@($script:Window.FindName('InteractionLayer').Children | Where-Object { $_ -is [System.Windows.Controls.TextBlock] -and $_.Text -eq '♥' })
        $horseHeartTop=[System.Windows.Controls.Canvas]::GetTop($horseHearts[0])
        $image=$script:Window.FindName('PetImage');$origin=$image.TranslatePoint([Windows.Point]::new(0,0),$effectLayer)
        Assert ($horseHearts.Count -eq 2 -and $horseHeartTop -ge $origin.Y -and $horseHeartTop -lt $origin.Y+$image.ActualHeight*.23) 'Horseback heart eyes do not use the rider eye profile'
        $frame=New-Object System.Windows.Threading.DispatcherFrame
        $wait=New-Object System.Windows.Threading.DispatcherTimer
        $wait.Interval=[TimeSpan]::FromMilliseconds(2300)
        $wait.Add_Tick({ $wait.Stop(); $frame.Continue=$false })
        $wait.Start(); [System.Windows.Threading.Dispatcher]::PushFrame($frame)
        Assert ((Get-PetCurrentState) -eq 'run') 'Horse state was not restored after feed interaction'
        Assert ($script:Window.FindName('PetImage').Source.UriSource.LocalPath -eq (& (Get-Module PetWindow) { Get-PetThemedAssetPath 'pet_horse.png' })) 'Horse sprite was not restored after feed interaction'
        Assert ($script:Window.FindName('PetTranslate').HasAnimatedProperties) 'Horse gallop did not resume after feed interaction ended'
        Start-PetInteractionAnimation -Kind 'greet'
        Assert ($script:Window.FindName('PetWaveArm').Margin -eq $script:Window.FindName('PetImage').Margin) 'Waving arm shifts away from body during playback'
        $frame=New-Object System.Windows.Threading.DispatcherFrame
        $wait=New-Object System.Windows.Threading.DispatcherTimer
        $wait.Interval=[TimeSpan]::FromMilliseconds(1350)
        $wait.Add_Tick({ $wait.Stop(); $frame.Continue=$false })
        $wait.Start(); [System.Windows.Threading.Dispatcher]::PushFrame($frame)
        Assert ((Get-PetCurrentState) -eq 'run' -and $script:Window.FindName('PetTranslate').HasAnimatedProperties) 'Horse gallop did not resume after greeting'
        (Get-Module PetWindow).SessionState.PSVariable.Set('MusicForm','record'); Set-PetState -State 'idle'; Set-PetState -State 'run'
        Assert ($script:Window.FindName('PetImage').Visibility -eq 'Collapsed') 'Record form setup failed'
        Start-PetInteractionAnimation -Kind 'feed'
        Assert ($script:Window.FindName('PetImage').Visibility -eq 'Collapsed' -and $script:Window.FindName('InteractionLayer').Children.Count -eq 0) 'Record playback form should not start pet interactions'
        (Get-Module PetWindow).SessionState.PSVariable.Set('MusicForm','horse'); Set-PetState -State 'idle'
        $script:Window.Show(); $script:Window.UpdateLayout()
        $interaction.Items[2].RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.MenuItem]::ClickEvent))
        $wavePath=& (Get-Module PetWindow) { Get-PetThemedAssetPath 'pet_wave.png' }
        Assert ($script:Window.FindName('PetImage').Source.UriSource.LocalPath -eq $wavePath) 'Stable waving sprite did not load'
        Assert (-not $script:Window.FindName('PetRotate').HasAnimatedProperties) 'Waving rotates the whole body or face'
        $waveArm=$script:Window.FindName('PetWaveArm')
        Assert ($waveArm.Visibility -eq 'Visible' -and $waveArm.Source.UriSource.LocalPath -eq $wavePath) 'Separate waving arm did not load'
        Assert ($script:Window.FindName('PetImage').Clip -ne $null -and $waveArm.Clip -ne $null) 'Waving arm and body clips were not applied'
        Assert ($script:Window.FindName('WaveArmRotate').HasAnimatedProperties) 'Only-arm waving animation did not start'
        foreach($sound in @('pet.wav','feed.wav','highfive.wav')) {
            Assert (Test-Path -LiteralPath (Join-Path $root "assets\interactions\$sound")) "Interaction sound missing: $sound"
        }
        $script:Window.Hide()
    }
    Check 'bubble timer and topmost preference survive repeated show' {
        Show-PetBubble -Text '第一次' -Seconds 4
        $bubbleTimer=& (Get-Module PetWindow) { $script:BubbleTimer }
        Show-PetBubble -Text '第二次' -Seconds 7
        Assert ([object]::ReferenceEquals($bubbleTimer, (& (Get-Module PetWindow) { $script:BubbleTimer }))) 'Repeated bubble created another timer'
        Assert ($bubbleTimer.Interval.TotalSeconds -eq 7) 'Repeated bubble did not reset the timer interval'
        Set-PetTopmost -Top:$false
        Show-PetWindow
        Assert (-not $script:Window.Topmost) 'Manual show unexpectedly forces topmost'
        $script:Window.Hide()
        Toggle-PetWindow
        Assert (-not $script:Window.Topmost) 'Tray show unexpectedly forces topmost'
        $script:Window.Hide()
        Set-PetTopmost -Top:$true
    }
    Check 'actual tray add / complete / restore / delete, persisted reload' {
        $m=Get-Module PetTray
        & $m { & $script:TodoAddHandler -Title '  isolated test  ' }
        Assert ($script:Store.items.Count -eq 1) 'Add failed'
        Assert ((Get-PetStore).items[0].title -eq 'isolated test') 'Persistence or trim failed'
        $todoMenu=Menu '我的待办'
        $todoMenu.DropDownItems[2].DropDownItems[0].PerformClick()
        Assert ($script:Store.items[0].completed) 'Completion failed'
        $todoMenu.DropDownItems[2].DropDownItems[0].PerformClick()
        Assert (-not $script:Store.items[0].completed) 'Restore failed'
        $todoMenu.DropDownItems[2].DropDownItems[2].PerformClick()
        Assert ((Get-PetStore).items.Count -eq 0) 'Deletion persistence failed'
    }
    Check 'countdown presets replace previous timer and persist before expiry' {
        $menu=Menu '倒计时'
        $menu.DropDownItems[0].PerformClick()
        Assert ((Get-PetActiveCountdown -Store $script:Store).durationSeconds -eq 300) '5 minute preset failed'
        $menu.DropDownItems[1].PerformClick()
        Assert ($script:Store.items.Count -eq 1) 'Timer replacement failed'
        Assert ((Get-PetActiveCountdown -Store (Get-PetStore)).durationSeconds -eq 600) 'Timer not persisted'
    }
    Check 'custom timer handles 25-hour display without wrapping' {
        & (Get-Module PetTray) { & $script:CountdownCustomHandler -Seconds 90000 }
        Assert ($script:Window.FindName('CountdownText').Text -like '*25:00:*') 'Hours wrap at 24'
    }
    Check 'countdown speech reads duration instead of clock time' {
        foreach ($case in @(
            @{seconds=5; expected='5秒'},
            @{seconds=90; expected='1分钟30秒'},
            @{seconds=60; expected='1分钟'},
            @{seconds=3600; expected='1小时0分钟0秒'},
            @{seconds=3661; expected='1小时1分钟1秒'},
            @{seconds=90000; expected='25小时0分钟0秒'}
        )) {
            $item=[pscustomobject]@{type='countdown';durationSeconds=$case.seconds;title='自定义 00:01:00'}
            $spoken=Get-PetDueSpeechText -Items @($item)
            Assert ($spoken -eq "到时间啦，$($case.expected)倒计时结束了。") "Wrong spoken duration for $($case.seconds) seconds: $spoken"
        }
        $legacy=[pscustomobject]@{type='countdown';durationSeconds=$null;title='自定义 00:02:03'}
        $reminder=[pscustomobject]@{type='reminder';durationSeconds=$null;title='开会'}
        Assert ((Get-PetDueSpeechText -Items @($legacy,$reminder)) -eq '到时间啦，2分钟3秒倒计时结束了、开会。') 'Legacy countdown or mixed reminder speech failed'
    }
    Check 'expiry fires once and hides countdown readout' {
        $cd=Get-PetActiveCountdown -Store $script:Store
        $cd.dueAt=(Get-Date).AddSeconds(-1).ToString('o')
        Invoke-PetTick
        Assert ($cd.completed) 'Countdown did not complete'
        Assert ($script:Window.FindName('CountdownBorder').Visibility -eq 'Collapsed') 'Readout remained visible'
        Assert ((Get-PetDueAndAdvance -Store $script:Store -Now (Get-Date)).Count -eq 0) 'Reminder fired twice'
    }
    Check 'completion sun rotates with clean pixel edges across skins' {
        foreach ($skin in @('original','moonlit','festival','western')) {
            Set-PetSkin -SkinId $skin
            Set-PetState -State 'happy'
            $source=$script:Window.FindName('PetImage').Source
            Assert ($source.UriSource.LocalPath -eq (Get-PetAssetPath 'sun.png')) "Happy state changed the sun artwork under $skin skin"
            Assert ($script:Window.FindName('PetRotate').HasAnimatedProperties) "Happy state does not rotate under $skin skin"
            Assert ($script:Window.FindName('PetScale').HasAnimatedProperties) "Happy feedback is missing under $skin skin"
            Assert ([System.Windows.Media.RenderOptions]::GetBitmapScalingMode($script:Window.FindName('PetImage')) -eq [System.Windows.Media.BitmapScalingMode]::NearestNeighbor) "Happy state uses blurry scaling under $skin skin"
        }
        Set-PetSkin -SkinId 'original'
        Set-PetState -State 'idle'
        Assert ([System.Windows.Media.RenderOptions]::GetBitmapScalingMode($script:Window.FindName('PetImage')) -eq [System.Windows.Media.BitmapScalingMode]::HighQuality) 'Normal pet scaling was not restored'
    }
    Check 'cancel countdown via real tray click: hidden, persisted, no future alert, todos intact' {
        $script:Store=@{items=@()}
        $todo=Add-PetItem -Store $script:Store -Item @{title='keep this todo'; type='todo'; dueAt=$null}
        $menu=Menu '倒计时'
        $menu.DropDownItems[0].PerformClick()
        $cancel=$menu.DropDownItems | Where-Object Text -eq '取消当前倒计时' | Select-Object -First 1
        Assert ($null -ne $cancel) 'Cancel menu missing'
        $cancel.PerformClick()
        Assert ($null -eq (Get-PetActiveCountdown -Store $script:Store)) 'Timer still active'
        Assert ($script:Window.FindName('CountdownBorder').Visibility -eq 'Collapsed') 'Readout remained visible'
        $reloaded=Get-PetStore
        Assert ($null -eq (Get-PetActiveCountdown -Store $reloaded)) 'Cancelled timer returns after reload'
        Assert ($reloaded.items.Count -eq 1 -and $reloaded.items[0].id -eq $todo.id) 'Unrelated todo changed'
        Assert ((Get-PetDueAndAdvance -Store $reloaded -Now (Get-Date).AddDays(8)).Count -eq 0) 'Cancelled timer still fires'
        $cancel.PerformClick()
        Assert ($script:Store.items.Count -eq 1) 'Repeated cancellation changed todos'
        Assert ($script:Window.FindName('BubbleText').Text -like '*当前没有*') 'No-timer feedback missing'
        & (Get-Module PetTray) { & $script:CountdownCustomHandler -Seconds 60 }
        $cancel.PerformClick()
        Assert ($null -eq (Get-PetActiveCountdown -Store (Get-PetStore))) 'Custom timer cancellation failed'
    }
    Check 'three-minute inactivity sleeps even with music; activity wakes' {
        $script:AlertLock=$false
        $script:Store=@{items=@()}; $script:Config.music=$true; $script:Playing=$true
        $script:LastInteraction=(Get-Date).AddSeconds(-181)
        Set-PetState -State 'idle'; Invoke-PetTick
        Assert ((Get-PetCurrentState) -eq 'sleep') 'Music overrides inactivity sleep'
        $script:Activity=$true; Invoke-PetTick
        Assert ((Get-PetCurrentState) -eq 'run') 'Activity did not wake to running'
        $script:Activity=$false; $script:Playing=$false
        Invoke-PetTick
        Assert ((Get-PetCurrentState) -eq 'run') 'Silence grace was not kept'
        $script:MusicSilenceSince=(Get-Date).AddSeconds(-1.4)
        Invoke-PetTick
        Assert ((Get-PetCurrentState) -eq 'run') '1.5-second silence grace ended early'
        $script:MusicSilenceSince=(Get-Date).AddSeconds(-1.6)
        Invoke-PetTick
        Assert ((Get-PetCurrentState) -eq 'idle') 'Music pause did not restore idle'
    }
    Check 'tray manual nap survives timer until next input' {
        $script:Config.music=$false; $script:LastInteraction=Get-Date
        (Menu '打盹').PerformClick(); Invoke-PetTick
        Assert ((Get-PetCurrentState) -eq 'sleep') 'Manual nap immediately cancelled'
        $script:Activity=$true; Invoke-PetTick; $script:Activity=$false
        Assert ((Get-PetCurrentState) -eq 'idle') 'Manual nap does not wake'
    }
    Check 'music and voice toggles update state, checkmark, saved config' {
        $script:Config.music=$true; Set-PetState -State 'run'
        (Menu '音乐识别').PerformClick()
        Assert ((Get-PetCurrentState) -eq 'idle') 'Music off did not stop running'
        Assert (-not (Read-PetConfig).music) 'Music flag not saved'
        (Menu '开启语音').PerformClick()
        Assert ((Menu '开启语音').Checked -and (Read-PetConfig).voice) 'Voice toggle failed'
    }
    Check 'horse gallop keeps head inside window' {
        (Get-Module PetWindow).SessionState.PSVariable.Set('MusicForm','horse')
        Set-PetState -State 'idle'; Set-PetState -State 'run'
        $margin=$script:Window.FindName('PetImage').Margin
        Assert ($margin.Top -ge 14) 'Horse sprite has no top clearance for gallop'
        Assert ($script:Window.FindName('PetTranslate').HasAnimatedProperties) 'Horse gallop animation is missing'
        Set-PetState -State 'idle'
        Assert ($script:Window.FindName('PetImage').Margin.Top -eq 5) 'Normal sprite margin was not restored'
    }
    Check 'sleep stops running animation; command controls absent' {
        Set-PetState -State 'run'; Set-PetState -State 'sleep'
        Assert (-not $script:Window.FindName('PetTranslate').HasAnimatedProperties) 'Gallop continues during sleep'
        Assert (-not $script:Window.FindName('PetRotate').HasAnimatedProperties) 'Rocking continues during sleep'
        Assert ($null -eq $script:Window.FindName('InputBox')) 'Command input still exists'
    }
    Check 'reminders, recurrence and startup catch-up using isolated store' {
        $s=@{items=@()}; $now=Get-Date
        $null=Add-PetItem -Store $s -Item @{title='overdue'; type='reminder'; dueAt=$now.AddMinutes(-1).ToString('o')}
        Assert ((Invoke-PetCatchUp -Store $s -Now $now).Count -eq 1) 'Catchup failed'
        Assert ((Invoke-PetCatchUp -Store $s -Now $now).Count -eq 0) 'Catchup duplicated'
        $null=Add-PetItem -Store $s -Item @{title='recurring'; type='reminder'; dueAt=$now.AddMinutes(-1).ToString('o'); recurrence=@{Kind='daily'; Hour=9; Minute=0}}
        Assert ((Get-PetDueAndAdvance -Store $s -Now $now).Count -eq 1) 'Recurring reminder failed'
        Assert ([datetime]::Parse($s.items[1].dueAt) -gt $now) 'Recurrence not advanced'
    }
    Check 'legacy timed todos migrate to reminder menu without changing schedule or completion' {
        $legacyPath=Join-Path $temp 'legacy-reminders.json'
        $migratedPath=Join-Path $temp 'migrated-reminders.json'
        $legacyDue=(Get-Date).AddDays(1).ToString('o')
        $legacyFired=(Get-Date).AddDays(-1).ToString('o')
        $fixture=@{items=@(
            @{id='legacy-pending'; title='旧格式提醒'; type='todo'; dueAt=$legacyDue; completed=$false; lastFiredAt=$null},
            @{id='legacy-delivered'; title='旧格式已提醒'; type='todo'; dueAt=$legacyDue; completed=$true; lastFiredAt=$legacyFired},
            @{id='legacy-no-type'; title='无类型旧提醒'; dueAt=$legacyDue; completed=$false; lastFiredAt=$null},
            @{id='ordinary-todo'; title='普通待办'; type='todo'; dueAt=$null; completed=$false; lastFiredAt=$null},
            @{id='untyped-todo'; title='无类型普通待办'; dueAt=$null; completed=$false; lastFiredAt=$null},
            @{id='legacy-countdown'; title='原倒计时'; type='countdown'; dueAt=$legacyDue; completed=$false; lastFiredAt=$null; durationSeconds=60}
        )}
        Write-PetStore -Store $fixture -Path $legacyPath
        $legacyHash=(Get-FileHash $legacyPath).Hash
        $migrated=Get-PetStore -Path $legacyPath
        Assert ((Get-FileHash $legacyPath).Hash -eq $legacyHash) 'Reading legacy store unexpectedly rewrote it'
        Assert ($migrated.items.Count -eq $fixture.items.Count) 'Migration lost or duplicated items'
        foreach ($original in $fixture.items) {
            $item=@($migrated.items | Where-Object id -eq $original.id)
            Assert ($item.Count -eq 1) 'Migration changed an item id'
            Assert ($item[0].title -eq $original.title -and $item[0].dueAt -eq $original.dueAt) 'Migration changed title or scheduled time'
            Assert ($item[0].completed -eq $original.completed -and $item[0].lastFiredAt -eq $original.lastFiredAt) 'Migration changed reminder delivery state'
        }
        Assert (@($migrated.items | Where-Object type -eq 'reminder').Count -eq 3) 'Timed legacy todos were not migrated'
        Assert (@($migrated.items | Where-Object type -eq 'todo').Count -eq 2) 'Untimed todos were misclassified'
        Assert (($migrated.items | Where-Object id -eq 'legacy-countdown').type -eq 'countdown') 'Countdown type changed'
        Write-PetStore -Store $migrated -Path $migratedPath
        $reloaded=Get-PetStore -Path $migratedPath
        Assert (@($reloaded.items | Where-Object type -eq 'reminder').Count -eq 3) 'Migrated types did not persist'
        $savedStore=$script:Store
        try {
            $script:Store=$reloaded
            Update-PetTodoMenu; Update-PetReminderMenu
            $reminderEntries=@((Menu '提醒').DropDownItems | Where-Object { $_.Tag })
            Assert ($reminderEntries.Count -eq 3) 'Legacy reminders missing from reminder menu'
            Assert (@($reminderEntries | Where-Object Tag -eq 'legacy-delivered')[0].Text.Contains('已提醒')) 'Delivered legacy reminder lost visible status'
            Assert (@((Menu '我的待办').DropDownItems | Where-Object Text -like '*旧提醒*').Count -eq 0) 'Legacy reminder leaked into todo menu'
            Assert (@((Menu '我的待办').DropDownItems | Where-Object Text -like '*旧格式*').Count -eq 0) 'Legacy typed reminder leaked into todo menu'
            Assert (@((Menu '我的待办').DropDownItems | Where-Object Text -like '*普通待办*').Count -eq 2) 'Ordinary legacy todos disappeared'
        } finally {
            $script:Store=$savedStore
            Update-PetTodoMenu; Update-PetReminderMenu
        }
    }
    Check 'reminder dialog validates inputs and submits both timing modes' {
        $click=[System.Windows.Forms.Button].GetMethod('OnClick',[Reflection.BindingFlags]'Instance,NonPublic')
        foreach ($modeIndex in @(0,1)) {
            $dialog=New-PetReminderDialog
            try {
                $input=$dialog.Controls.Find('ReminderTitle',$true)[0]
                $mode=$dialog.Controls.Find('ReminderMode',$true)[0]
                $save=$dialog.Controls.Find('SaveReminder',$true)[0]
                $error=$dialog.Controls.Find('ReminderError',$true)[0]
                $mode.SelectedIndex=$modeIndex
                $click.Invoke($save,[object[]]@([EventArgs]::Empty)) | Out-Null
                Assert ($null -eq $dialog.Tag -and $error.Text.Length -gt 0) 'Blank title accepted'
                $input.Text='  测试提醒  '
                if ($modeIndex -eq 0) {
                    $date=$dialog.Controls.Find('ReminderDate',$true)[0]
                    $clock=$dialog.Controls.Find('ReminderTime',$true)[0]
                    $date.Value=(Get-Date).AddDays(-1)
                    $click.Invoke($save,[object[]]@([EventArgs]::Empty)) | Out-Null
                    Assert ($null -eq $dialog.Tag) 'Past time accepted'
                    $target=(Get-Date).AddDays(1).Date.AddHours(14).AddMinutes(30)
                    $date.Value=$target; $clock.Value=$target
                }
                else {
                    $click.Invoke($save,[object[]]@([EventArgs]::Empty)) | Out-Null
                    Assert ($null -eq $dialog.Tag) 'Zero delay accepted'
                    $dialog.Controls.Find('ReminderMinutes',$true)[0].Value=1
                    $dialog.Controls.Find('ReminderSeconds',$true)[0].Value=30
                }
                $error.Text=''
                # Render actual laid-out controls offscreen, not a hidden blank form.
                $dialog.ShowInTaskbar=$false
                $dialog.StartPosition='Manual'
                $dialog.Location=New-Object System.Drawing.Point(-10000,-10000)
                $dialog.Show(); $dialog.PerformLayout()
                [System.Windows.Forms.Application]::DoEvents()
                $bitmap=New-Object System.Drawing.Bitmap($dialog.Width,$dialog.Height)
                try {
                    $dialog.DrawToBitmap($bitmap,(New-Object System.Drawing.Rectangle(0,0,$dialog.Width,$dialog.Height)))
                    $bitmap.Save((Join-Path $temp "reminder-mode-$modeIndex.png"))
                } finally { $bitmap.Dispose(); $dialog.Hide() }
                $beforeClick=Get-Date
                $click.Invoke($save,[object[]]@([EventArgs]::Empty)) | Out-Null
                Assert ($null -ne $dialog.Tag) ('Valid request rejected: ' + $error.Text)
                Assert ($dialog.Tag.Title -eq '测试提醒') 'Title not trimmed'
                if ($modeIndex -eq 0) { Assert ($dialog.Tag.DueAt -eq $target) 'Absolute date or time lost' }
                else { Assert ([Math]::Abs(($dialog.Tag.DueAt-$beforeClick).TotalSeconds-90) -lt 2) 'Relative delay incorrect' }
            } finally { $dialog.Dispose() }
        }
    }
    Check 'separate reminder submenu adds, persists, notifies once, and deletes without affecting todos or countdown' {
        $script:Store=@{items=@()}; $script:AlertLock=$false; $script:Config.voice=$false
        $reminderMenu=Menu '提醒'
        Assert ($null -ne $reminderMenu) 'Reminder parent menu missing'
        Assert ($null -eq (Menu '添加提醒…')) 'Add reminder is still a top-level item'
        Assert ($reminderMenu.DropDownItems[0].Text -eq '添加提醒…') 'Add reminder must be first in reminder submenu'
        & (Get-Module PetTray) { & $script:TodoAddHandler -Title '保留的普通待办' }
        $todo=$script:Store.items[0]
        Invoke-PetStartCountdown -Seconds 60 -Label 'keep countdown'
        $countdown=Get-PetActiveCountdown -Store $script:Store
        $request=New-PetReminderRequest -Title '喝水' -Mode after -DelaySeconds 90
        & (Get-Module PetTray) {
            param($r,$addItem)
            # Exercise the relocated menu's actual click event without opening
            # a modal dialog; removing this module-local mock reveals the original.
            $script:TestReminderRequest=$r
            function script:Show-PetReminderDialog { return $script:TestReminderRequest }
            try { $addItem.PerformClick() }
            finally {
                Remove-Item Function:script:Show-PetReminderDialog
                Remove-Variable TestReminderRequest -Scope Script
            }
        } $request $reminderMenu.DropDownItems[0]
        Assert (@($script:Store.items | Where-Object { $_.type -eq 'reminder' -and $_.title -eq '喝水' }).Count -eq 1) 'Reminder submenu add click is not connected'
        $request=New-PetReminderRequest -Title '开会' -Mode at -At (Get-Date).AddMinutes(10)
        & (Get-Module PetTray) { param($r) & $script:ReminderAddHandler -Title $r.Title -DueAt $r.DueAt } $request
        $request=New-PetReminderRequest -Title '删除这个提醒' -Mode after -DelaySeconds 100
        & (Get-Module PetTray) { param($r) & $script:ReminderAddHandler -Title $r.Title -DueAt $r.DueAt } $request
        $reloaded=Get-PetStore
        Assert ($reloaded.items.Count -eq 5) 'Reminders not persisted independently'
        Assert (@($reloaded.items | Where-Object type -eq 'reminder').Count -eq 3) 'Added reminders have wrong type'
        Update-PetTodoMenu; Update-PetReminderMenu
        $reminderEntries=@($reminderMenu.DropDownItems | Where-Object { $_.Tag })
        Assert ($reminderEntries.Count -eq 3) 'Reminder submenu contains unrelated items or is missing reminders'
        foreach ($entry in $reminderEntries) {
            Assert ($entry.Text.Contains('待提醒')) 'Pending reminder status missing'
            Assert ($entry.DropDownItems.Count -eq 0 -and $entry.Text.StartsWith('删除提醒｜')) 'Reminder deletion should stay in second-level menu'
        }
        Assert (@((Menu '我的待办').DropDownItems | Where-Object Text -match '喝水|开会|删除这个提醒').Count -eq 0) 'Reminders leaked into todo menu'
        Assert (@((Menu '我的待办').DropDownItems | Where-Object Text -eq '保留的普通待办').Count -eq 1) 'Ordinary todo missing from todo menu'
        Assert (@($reminderEntries | Where-Object { $_.Tag -eq $todo.id -or $_.Tag -eq $countdown.id }).Count -eq 0) 'Todo or countdown leaked into reminder menu'
        & (Get-Module PetTray) { param($id) & $script:ReminderDeleteHandler -Id $id } $todo.id
        & (Get-Module PetTray) { param($id) & $script:ReminderDeleteHandler -Id $id } $countdown.id
        Assert ($script:Store.items.Count -eq 5) 'Reminder deletion accepted a non-reminder id'
        $protectedReminder=$script:Store.items | Where-Object { $_.type -eq 'reminder' -and $_.title -eq '喝水' } | Select-Object -First 1
        & (Get-Module PetTray) { param($id) & $script:TodoCompleteHandler -Id $id } $protectedReminder.id
        & (Get-Module PetTray) { param($id) & $script:TodoDeleteHandler -Id $id } $protectedReminder.id
        Assert (@($script:Store.items | Where-Object { $_.id -eq $protectedReminder.id -and -not $_.completed }).Count -eq 1) 'Todo callbacks modified a reminder'
        $deleteEntry=$reminderEntries | Where-Object Text -like '*删除这个提醒*' | Select-Object -First 1
        Assert ($null -ne $deleteEntry) 'Reminder to delete is missing'
        $deletedId=[string]$deleteEntry.Tag
        $deleteEntry.PerformClick()
        $script:Store=Get-PetStore
        Assert ($script:Store.items.Count -eq 4 -and @($script:Store.items | Where-Object id -eq $deletedId).Count -eq 0) 'Deleted reminder returns after reload'
        Assert (@($script:Store.items | Where-Object { $_.id -eq $todo.id -and $_.title -eq '保留的普通待办' -and -not $_.completed }).Count -eq 1) 'Reminder deletion changed ordinary todo'
        Assert ((Get-PetActiveCountdown -Store $script:Store).id -eq $countdown.id) 'Reminder deletion changed countdown'
        Update-PetReminderMenu
        Assert (@($reminderMenu.DropDownItems | Where-Object Tag -eq $deletedId).Count -eq 0) 'Deleted reminder returns in menu after reload'
        foreach ($r in @($script:Store.items | Where-Object type -eq 'reminder')) { $r.dueAt=(Get-Date).AddSeconds(-1).ToString('o') }
        $script:LastInteraction=(Get-Date).AddMinutes(-5)
        $elapsed=[Diagnostics.Stopwatch]::StartNew()
        Invoke-PetTick
        $elapsed.Stop()
        Assert ($elapsed.Elapsed.TotalSeconds -lt 2) 'Reminder blocked UI thread'
        Assert ($script:LastNotification -like '*喝水*' -and $script:LastNotification -like '*开会*') 'Simultaneous reminder was lost'
        Assert ($script:LastNotification -notlike '*删除这个提醒*') 'Deleted reminder still notified'
        Assert ((Get-PetCurrentState) -eq 'alert') 'Sleep overwrote reminder'
        Assert ($null -ne (Get-PetActiveCountdown -Store $script:Store)) 'Reminder cancelled countdown'
        $script:LastNotification='no second notification'
        Invoke-PetTick
        Assert ($script:LastNotification -eq 'no second notification') 'Reminder notified twice'
        Assert (@((Get-PetStore).items | Where-Object { $_.type -eq 'reminder' -and $_.completed }).Count -eq 2) 'Delivered reminders not persisted'
        $deliveredEntries=@($reminderMenu.DropDownItems | Where-Object { $_.Tag })
        Assert ($deliveredEntries.Count -eq 2 -and @($deliveredEntries | Where-Object Text -like '*已提醒*').Count -eq 2) 'Delivered reminder menu status not refreshed'
        Assert (@((Menu '我的待办').DropDownItems | Where-Object Text -match '喝水|开会').Count -eq 0) 'Delivered reminders appeared in todo menu'
        $script:AlertUntil=(Get-Date).AddSeconds(-1)
        Invoke-PetTick
        Assert ((Get-PetCurrentState) -eq 'sleep') 'Alert never released after display interval'
    }
    Check 'autostart command targets existing script with STA and hidden window' {
        $cmd=Get-PetAutoStartCommand -EntryScript (Join-Path $root $Entry)
        Assert ($cmd.Contains('-STA') -and $cmd.Contains('-WindowStyle Hidden') -and $cmd.Contains($Entry)) 'Autostart command invalid'
    }
    Check 'music session Playing/Paused enum maps correctly' {
        & (Get-Module PetMusic) {
            $null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionPlaybackStatus, Windows.Media.Control, ContentType=WindowsRuntime]
            $originalManager=$script:Manager; $originalLoaded=$script:Loaded
            $originalAudioActive=$script:SelectedAudioActive; $originalAudioSource=$script:SelectedAudioSource
            $session=[pscustomobject]@{SourceAppUserModelId='isolated-test'; PlaybackStatus=[Windows.Media.Control.GlobalSystemMediaTransportControlsSessionPlaybackStatus]::Playing}
            $session | Add-Member ScriptMethod GetPlaybackInfo { return [pscustomobject]@{PlaybackStatus=$this.PlaybackStatus} }
            $manager=[pscustomobject]@{Session=$session}
            $manager | Add-Member ScriptMethod GetCurrentSession { return $this.Session }
            try {
                $script:Manager=$manager; $script:Loaded=$true; $script:SelectedAudioActive=$false; $script:SelectedAudioSource=$null
                if (-not (Get-PetMusicStatus).Playing) { throw 'Playing session not detected' }
                $session.PlaybackStatus=[Windows.Media.Control.GlobalSystemMediaTransportControlsSessionPlaybackStatus]::Paused
                if ((Get-PetMusicStatus).Playing) { throw 'Paused session reported playing' }
                $script:SelectedAudioActive=$true; $script:SelectedAudioSource='hillslite'
                $audiblePaused=Get-PetMusicStatus
                if (-not $audiblePaused.Playing -or $audiblePaused.App -ne 'hillslite') { throw 'Audible Hills session flickered to paused' }
            } finally {
                $script:Manager=$originalManager; $script:Loaded=$originalLoaded
                $script:SelectedAudioActive=$originalAudioActive; $script:SelectedAudioSource=$originalAudioSource
            }
        }
    }
} finally {
    Stop-PetTray; Set-PetAllowClose; $script:Window.Close()
    Assert ((Get-PetStorePath) -eq (Join-Path $temp 'todos.json') -and (Get-PetConfigPath) -eq (Join-Path $temp 'config.json')) 'Test persistence path escaped isolated directory'
    & (Get-Module PetWindow) { param($original) Set-Item Function:script:Play-PetInteractionSound -Value $original } $originalInteractionSound
    $env:XIAOTAIYANG_DATA_DIR = $previousDataDir
}
Write-Output "RESULT: $Entry failures=$script:failures; temporary data=$temp"
if ($script:failures) { exit 1 }
