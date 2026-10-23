$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'modules\PetWindow.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'modules\PetGrowth.psm1') -Force -DisableNameChecking
$script:Failures=0
function Assert($Value,[string]$Message) {if(-not $Value){throw $Message}}
function Check([string]$Name,[scriptblock]$Body) {
    try {& $Body;Write-Output "PASS: $Name"}catch{$script:Failures++;Write-Output "FAIL: $Name -- $($_.Exception.Message)"}
}
Check '旧喂食冷却迁移且不改变成长进度' {
    $now=Get-Date '2026-10-22 12:00:00'
    $store=@{items=@();growth=(New-PetGrowthState -Now $now)}
    $store.growth.intimacy=50;$store.growth.mood=70
    $store.growth.interactionCooldowns.feed=$now.AddMinutes(20).ToString('o')
    $null=Initialize-PetGrowth -Store $store -Now $now
    Assert ($store.growth.interactionCooldowns.ContainsKey('highfive')) '未迁移旧喂食冷却'
    $blocked=Invoke-PetGrowthInteraction -Store $store -Kind highfive -Now $now
    Assert ($blocked.cooldown -and $blocked.points -eq 0 -and $store.growth.intimacy -eq 50 -and $store.growth.mood -eq 85) '冷却期奖励或心情错误'
    $ready=Invoke-PetGrowthInteraction -Store $store -Kind highfive -Now $now.AddMinutes(21)
    Assert ($ready.points -eq 3 -and $store.growth.intimacy -eq 53 -and $store.growth.mood -eq 100) '击掌未继承原奖励'
    Assert ($store.growth.interactionCooldowns.highfive -eq $now.AddMinutes(81).ToString('o')) '击掌冷却不是60分钟'
}
[Windows.Application]::new()|Out-Null
[Windows.Application]::Current.ShutdownMode='OnExplicitShutdown'
$window=New-PetWindow -Config @{topmost=$false;windowX=-1000;windowY=-1000}
$window.Show();$window.UpdateLayout()
# 仅屏蔽实际扬声器输出，状态、素材、计时器与控件均使用真实实现。
& (Get-Module PetWindow) { function script:Play-PetInteractionSound {param($Kind)} }
function Pump([int]$Milliseconds) {
    $frame=New-Object Windows.Threading.DispatcherFrame
    $timer=New-Object Windows.Threading.DispatcherTimer
    $timer.Interval=[TimeSpan]::FromMilliseconds($Milliseconds)
    $timer.Add_Tick(({$timer.Stop();$frame.Continue=$false}).GetNewClosure())
    $timer.Start();[Windows.Threading.Dispatcher]::PushFrame($frame)
}
try {
    Check '右键菜单只替换喂食为击掌' {
        Set-PetContextMenuHandlers -InteractionHandler {param($Kind)}
        $menu=$window.ContextMenu
        Assert ($menu.Items.Count -eq 5 -and $menu.Items[0].Header -eq '摸摸' -and $menu.Items[1].Header -eq '击掌' -and $menu.Items[1].Tag -eq 'highfive' -and $menu.Items[2].Header -eq '打招呼') '互动菜单不符合替换要求'
    }
    Check '同一图片复用冻结实例并限制缓存' {
        $path=Join-Path $root 'assets\pet.png'
        $a=ConvertTo-PetImageSource $path;$b=ConvertTo-PetImageSource $path
        Assert ([object]::ReferenceEquals($a,$b) -and $a.IsFrozen) '同一图片重复分配'
        foreach($skin in @('original','moonlit','festival','western')) {
            Set-PetSkin $skin
            foreach($state in @('idle','run','sleep','happy')){Set-PetState $state}
        }
        & (Get-Module PetWindow) {
            if($script:ImageCache.Count -gt 6 -or $script:ImageCacheBytes -gt 8MB){throw '图片缓存超出六张/8MiB'}
        }
    }
    Check '互动恢复计时器复用且最后一次点击生效' {
        Set-PetSkin original;Set-PetState idle
        Start-PetInteractionAnimation highfive
        $first=& (Get-Module PetWindow) {$script:InteractionResetTimer}
        Pump 850
        Start-PetInteractionAnimation highfive
        $second=& (Get-Module PetWindow) {$script:InteractionResetTimer}
        Assert ([object]::ReferenceEquals($first,$second)) '重复互动新建了计时器'
        Pump 700
        Assert ($window.FindName('InteractionLayer').Children.Count -gt 0) '旧计时器提前终止新互动'
        Pump 800
        Assert ($window.FindName('InteractionLayer').Children.Count -eq 0) '互动结束后特效未释放'
        Assert ($null -eq $window.FindName('PetWaveArm').Source) '互动结束后仍持有手臂图片'
    }
    Check '击掌接触点随图片留白和气泡缩放对齐' {
        Set-PetSkin original
        foreach($bubble in @($false,$true)){
            Set-PetState idle
            if($bubble){Show-PetBubble -Text '啪！合作愉快，心情和亲密度都增加啦！' -Seconds 6}else{$window.FindName('Bubble').Visibility='Collapsed'}
            Start-PetInteractionAnimation highfive
            $image=$window.FindName('PetImage');$layer=$window.FindName('InteractionLayer')
            $palm=$layer.Children|Where-Object {$_ -is [Windows.Shapes.Path]}|Select-Object -First 1
            $origin=$image.TranslatePoint([Windows.Point]::new(0,0),$layer)
            # 站立原图为488×832，手掌中心在约60,341；独立按纵向适配计算图片留白。
            $drawWidth=$image.ActualHeight*488.0/832
            $expectedX=$origin.X+($image.ActualWidth-$drawWidth)/2+$drawWidth*60/488
            Assert ([Math]::Abs(([Windows.Controls.Canvas]::GetLeft($palm)+$palm.Width/2)-$expectedX) -lt 1) '击掌接触点偏离人物手掌'
            Assert ($palm.Height -le $image.ActualHeight*.16) '气泡缩小人物后，对方手掌没有同步缩放'
        }
    }
    Check '碰掌时星光实际可见并在结束后释放' {
        Set-PetSkin original;Set-PetState idle
        Start-PetInteractionAnimation highfive;Pump 650
        $stars=@($window.FindName('InteractionLayer').Children|Where-Object {$_ -is [Windows.Controls.TextBlock] -and $_.Text -eq '✦'})
        Assert ($stars.Count -eq 3 -and @($stars|Where-Object {$_.Opacity -gt .2}).Count -eq 3) '碰掌阶段星光没有显示'
        Pump 850
        Assert ($window.FindName('InteractionLayer').Children.Count -eq 0) '星光结束后未释放'
    }
    Check '四套皮肤骑马击掌结束恢复奔跑' {
        foreach($skin in @('original','moonlit','festival','western')) {
            Set-PetSkin $skin;Set-PetState run
            Start-PetInteractionAnimation highfive
            Assert ($window.FindName('InteractionLayer').Children.Count -gt 0) "$skin 缺少击掌效果"
            Assert (-not $window.FindName('PetRotate').HasAnimatedProperties) "$skin 击掌时身体没有固定"
            Pump 1520
            Assert ((Get-PetCurrentState) -eq 'run' -and $window.FindName('PetTranslate').HasAnimatedProperties) "$skin 击掌后没有恢复奔跑"
        }
    }
    Check '状态或皮肤切换中断互动且不会被旧计时器恢复' {
        Set-PetState run;Start-PetInteractionAnimation highfive;Set-PetState sleep;Pump 1500
        Assert ((Get-PetCurrentState) -eq 'sleep' -and -not $window.FindName('PetTranslate').HasAnimatedProperties) '旧互动覆盖睡眠状态'
        Set-PetState idle;Start-PetInteractionAnimation highfive;Set-PetSkin moonlit;Pump 1500
        Assert ($window.FindName('InteractionLayer').Children.Count -eq 0 -and $window.FindName('PetImage').Source.UriSource.LocalPath -like '*moonlit*') '切皮肤后保留旧互动'
    }
    Check '隐藏时停止视觉动画且显示时恢复当前状态' {
        Set-PetState run;$window.Hide();Pump 60
        Assert (-not $window.FindName('PetTranslate').HasAnimatedProperties) '隐藏时奔跑仍在执行'
        Set-PetState idle;Set-PetState run
        Assert (-not $window.FindName('PetTranslate').HasAnimatedProperties) '隐藏中的状态更新重启动画'
        $window.Show();Pump 60
        Assert ((Get-PetCurrentState) -eq 'run' -and $window.FindName('PetTranslate').HasAnimatedProperties) '显示后没有恢复奔跑'
    }
    Check '成长预览为缩略图且关闭后释放' {
        $store=@{items=@();growth=(New-PetGrowthState)};$store.growth.intimacy=160
        Show-PetGrowthWindow -Store $store -Config @{skinId='original'} -AssetsPath (Join-Path $root 'assets')
        [Windows.Forms.Application]::DoEvents()
        $form=[Windows.Forms.Application]::OpenForms|Where-Object Text -eq '成长与外观'|Select-Object -First 1
        $gallery=$form.Controls|Where-Object Tag -eq 'skin-gallery'
        $boxes=@($gallery.Controls|ForEach-Object {$_.Controls}|Where-Object {$_ -is [Windows.Forms.PictureBox]})
        Assert ($boxes.Count -eq 8) '预览数量变化'
        foreach($box in $boxes){Assert ($box.Image.Width -le 376 -and $box.Image.Height -ge 140 -and $box.Image.Height -le 280) '预览未按框尺寸加载清晰缩略图'}
        $form.Close();[Windows.Forms.Application]::DoEvents()
        Assert ($form.IsDisposed) '成长窗口关闭后未释放'
    }
    Check '隐藏恢复后保留正在显示的提醒告示' {
        Set-PetState alert;Set-PetSign -Text '测试提醒：喝水'
        $window.Hide();Pump 30;$window.Show();Pump 30
        Assert ($window.FindName('SignBorder').Visibility -eq 'Visible' -and $window.FindName('SignText').Text -eq '测试提醒：喝水') '恢复视觉动画时清掉了提醒告示'
    }
    Check '黑胶切换皮肤不持有隐藏的旧皮肤图片' {
        Set-PetSkin western;Set-PetState run
        & (Get-Module PetWindow) {Switch-PetMusicForm}
        Set-PetSkin moonlit
        Assert ($null -eq $window.FindName('PetImage').Source -and $null -eq $window.FindName('PetWaveArm').Source) '黑胶隐藏控件仍保留旧皮肤图片'
        & (Get-Module PetWindow) {Switch-PetMusicForm}
        Assert ($window.FindName('PetImage').Source.UriSource.LocalPath -like '*moonlit*') '黑胶切回骑马未使用当前皮肤'
    }
} finally {Set-PetAllowClose;$window.Close();[Windows.Application]::Current.Shutdown()}
Write-Output "HIGHFIVE CHECK: failures=$script:Failures"
if($script:Failures){exit 1}
