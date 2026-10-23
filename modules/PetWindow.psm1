Set-StrictMode -Version Latest

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml -ErrorAction SilentlyContinue

$script:Root = Split-Path $PSScriptRoot -Parent
$script:Assets = Join-Path $script:Root "assets"
$script:Window = $null
$script:PetImage = $null
$script:SignBorder = $null
$script:SignText = $null
$script:Bubble = $null
$script:BubbleText = $null
$script:CountdownText = $null
$script:CountdownBorder = $null
$script:AllowClose = $false
$script:PetTransform = $null
$script:PetScale = $null
$script:PetRotate = $null
$script:PetTranslate = $null
$script:State = 'idle'
$script:BubbleTimer = $null
$script:InputWatchOn = $false
$script:LastInputStamp = -1
$script:FullscreenWatchReady = $false
$script:FullscreenHidden = $false
$script:TopmostPreferred = $true
$script:MusicForm = 'horse'
$script:RecordView = $null
$script:RecordRotate = $null
$script:RecordDisc = $null
$script:SkinId = 'original'
$script:InteractionLayer = $null
$script:PetWaveArm = $null
$script:WaveArmRotate = $null
$script:PetInteractionHandler = $null
$script:PetGrowthHandler = $null
$script:InteractionSoundPlayer = $null
$script:InteractionResetTimer = $null
$script:InteractionReturnState = $null
$script:InteractionSoundTimer = $null
$script:ImageCache = New-Object Collections.Specialized.OrderedDictionary ([StringComparer]::OrdinalIgnoreCase)
$script:ImageCacheBytes = 0L
$script:VisualsSuspended = $true
$script:HighfivePalmBrush = $null

function Set-PetMusicCover {
    param([System.Windows.Media.ImageSource]$Cover)
    if ($null -eq $script:Window) { return }
    # 未提供封面时使用桌宠图，避免把上一首歌或参考图当成当前封面。
    if ($null -eq $Cover) {
        $Cover = $script:DefaultMusicCover
    }
    $script:Window.FindName('RecordCover').ImageSource = $Cover
    $script:Window.FindName('RecordLabel').Fill.ImageSource = $Cover
}

function New-PetDefaultMusicCover {
    $sun = ConvertTo-PetImageSource -Path (Get-PetAssetPath 'sun.png')
    $drawing = New-Object System.Windows.Media.DrawingGroup
    $drawing.Children.Add([System.Windows.Media.GeometryDrawing]::new(
        [System.Windows.Media.Brushes]::White, $null,
        [System.Windows.Media.RectangleGeometry]::new([System.Windows.Rect]::new(0, 0, 620, 620))))
    # 透明太阳图铺在纯白底上，形成干净的缺省唱片封面。
    $drawing.Children.Add([System.Windows.Media.ImageDrawing]::new(
        $sun, [System.Windows.Rect]::new(0, 2.5, 620, 615)))
    $drawing.Freeze()
    $image = [System.Windows.Media.DrawingImage]::new($drawing)
    $image.Freeze()
    return $image
}

function Switch-PetMusicForm {
    if ($script:State -ne 'run') { return }
    $script:MusicForm = if ($script:MusicForm -eq 'record') { 'horse' } else { 'record' }
    # 强制重绘，但保留音乐播放的逻辑状态。
    $script:State = 'idle'
    Set-PetState -State 'run'
}

function Start-PetRecordEntrance {
    if ($script:VisualsSuspended -or $null -eq $script:RecordDisc) { return }
    [System.Windows.Controls.Canvas]::SetLeft($script:RecordDisc, 20)
    $slide = New-Object System.Windows.Media.Animation.DoubleAnimation
    $slide.From = 20
    $slide.To = 167
    $slide.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(520))
    $slide.EasingFunction = New-Object System.Windows.Media.Animation.CubicEase
    $slide.EasingFunction.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
    $script:RecordDisc.BeginAnimation([System.Windows.Controls.Canvas]::LeftProperty, $slide)
}

function Stop-PetMusicState {
    if ($script:State -ne 'run') { return }
    if ($script:VisualsSuspended) { Set-PetState -State 'idle'; return }
    if ($script:MusicForm -ne 'record' -or $null -eq $script:RecordDisc) {
        Set-PetState -State 'idle'
        return
    }
    # 停播时先停止旋转，再把唱片完整收入封面后方。
    $script:State = 'music-stopping'
    $script:RecordRotate.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $null)
    $currentLeft = [double]$script:RecordDisc.GetValue([System.Windows.Controls.Canvas]::LeftProperty)
    $slide = New-Object System.Windows.Media.Animation.DoubleAnimation
    $slide.From = $currentLeft
    $slide.To = 20
    $slide.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(460))
    $slide.EasingFunction = New-Object System.Windows.Media.Animation.CubicEase
    $slide.EasingFunction.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseIn
    $slide.Add_Completed({
        if ($script:State -eq 'music-stopping') { Set-PetState -State 'idle' }
    })
    $script:RecordDisc.BeginAnimation([System.Windows.Controls.Canvas]::LeftProperty, $slide)
}

function Get-PetAssetPath {
    param([string]$Name)
    return Join-Path $script:Assets $Name
}

function Get-PetThemedAssetPath {
    param([string]$Name)
    if ($script:SkinId -and $script:SkinId -ne 'original') {
        $candidate = Join-Path (Join-Path (Join-Path $script:Assets 'skins') $script:SkinId) $Name
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    $interactionCandidate = Join-Path (Join-Path $script:Assets 'interactions') $Name
    if (Test-Path -LiteralPath $interactionCandidate) { return $interactionCandidate }
    return Get-PetAssetPath $Name
}

function Set-PetSkin {
    param([ValidateSet('original','moonlit','festival','western')][string]$SkinId)
    if ($script:SkinId -ne $SkinId) {
        # 旧皮肤不驻留缓存；活动控件的引用由状态刷新统一释放。
        $script:ImageCache.Clear(); $script:ImageCacheBytes=0L
    }
    $script:SkinId = $SkinId
    if ($null -ne $script:Window) {
        $state = $script:State
        if ($state -eq 'music-stopping') { $state = 'idle' }
        $script:State = '__skin-refresh'
        Set-PetState -State $state
    }
}

function Set-PetImageSource {
    param([System.Windows.Controls.Image]$Image, [string]$Path)
    if (-not (Test-Path $Path)) { return }
    $bitmap = ConvertTo-PetImageSource -Path $Path
    if (-not [object]::ReferenceEquals($Image.Source,$bitmap)) { $Image.Source=$bitmap }
}

# Convert a package-uri-free image path to an ImageSource.
function ConvertTo-PetImageSource {
    param([string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    if ($script:ImageCache.Contains($fullPath)) {
        $entry=$script:ImageCache[$fullPath]
        $script:ImageCache.Remove($fullPath); $script:ImageCache.Add($fullPath,$entry)
        return $entry.Image
    }
    $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
    $bmp.BeginInit()
    $bmp.UriSource = [uri]::new($fullPath)
    # 保留 WPF 对相同 URI 的解码复用，应用层缓存淘汰后也不强制复制整张位图。
    $bmp.CreateOptions = [System.Windows.Media.Imaging.BitmapCreateOptions]::None
    $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bmp.EndInit()
    $bmp.Freeze()
    $bytes = [long]$bmp.PixelWidth * $bmp.PixelHeight * 4
    while ($script:ImageCache.Count -gt 0 -and ($script:ImageCache.Count -ge 6 -or $script:ImageCacheBytes+$bytes -gt 8MB)) {
        $script:ImageCacheBytes -= [long]$script:ImageCache[0].Bytes
        $script:ImageCache.RemoveAt(0)
    }
    if ($bytes -le 8MB) {
        $script:ImageCache.Add($fullPath,@{Image=$bmp;Bytes=$bytes})
        $script:ImageCacheBytes += $bytes
    }
    return $bmp
}

function Clear-PetAnimations {
    param(
        [object]$Target
    )
    if ($null -eq $Target) { return }
    try {
        $Target.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $null)
        $Target.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $null)
        $Target.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $null)
        $Target.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $null)
        $Target.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $null)
    }
    catch { }
}

function New-PetDoubleAnim {
    param(
        [double]$From,
        [double]$To,
        [double]$Seconds,
        [bool]$AutoReverse = $true,
        [double]$Repeat = -1,
        [string]$Ease = 'cubic'
    )
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation
    $a.From = $From
    $a.To = $To
    $a.Duration = [System.Windows.Duration]::new([TimeSpan]::FromSeconds($Seconds))
    $a.AutoReverse = $AutoReverse
    if ($Repeat -lt 0) {
        $a.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    }
    else {
        $a.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::new([double]$Repeat)
    }
    if ($Ease -eq 'quad') {
        $a.EasingFunction = New-Object System.Windows.Media.Animation.QuadraticEase
    }
    elseif ($Ease -eq 'elastic') {
        $a.EasingFunction = New-Object System.Windows.Media.Animation.ElasticEase
    }
    else {
        $a.EasingFunction = New-Object System.Windows.Media.Animation.CubicEase
    }
    return $a
}

function Start-PetTranslate {
    param(
        [double]$FromY,
        [double]$ToY,
        [double]$Seconds,
        [bool]$AutoReverse = $true
    )
    if ($script:VisualsSuspended -or $null -eq $script:PetTranslate) { return }
    $script:PetTranslate.BeginAnimation(
        [System.Windows.Media.TranslateTransform]::YProperty,
        (New-PetDoubleAnim -From $FromY -To $ToY -Seconds $Seconds -AutoReverse $AutoReverse -Repeat 1)
    )
}

function Start-PetBob {
    param(
        [double]$Amplitude = 5,
        [double]$Seconds = 1.6
    )
    if ($script:VisualsSuspended -or $null -eq $script:PetTranslate) { return }
    $script:PetTranslate.BeginAnimation(
        [System.Windows.Media.TranslateTransform]::YProperty,
        (New-PetDoubleAnim -From 0 -To (-$Amplitude) -Seconds $Seconds -AutoReverse $true -Repeat -1 -Ease 'quad')
    )
}

function Start-PetGallop {
    param(
        [double]$Amplitude = 9,
        [double]$Seconds = 0.32
    )
    if ($script:VisualsSuspended -or $null -eq $script:PetTranslate) { return }
    # Fast vertical bounce (the gallop stride) ...
    $script:PetTranslate.BeginAnimation(
        [System.Windows.Media.TranslateTransform]::YProperty,
        (New-PetDoubleAnim -From 0 -To (-$Amplitude) -Seconds $Seconds -AutoReverse $true -Repeat -1 -Ease 'quad')
    )
    # ... plus a slight forward lunge (X) and rocking so it reads as galloping.
    if ($null -ne $script:PetTranslate) {
        $script:PetTranslate.BeginAnimation(
            [System.Windows.Media.TranslateTransform]::XProperty,
            (New-PetDoubleAnim -From -4 -To 4 -Seconds ($Seconds * 2) -AutoReverse $true -Repeat -1 -Ease 'quad')
        )
    }
    if ($null -ne $script:PetRotate) {
        $script:PetRotate.BeginAnimation(
            [System.Windows.Media.RotateTransform]::AngleProperty,
            (New-PetDoubleAnim -From -3 -To 3 -Seconds ($Seconds * 2) -AutoReverse $true -Repeat -1 -Ease 'quad')
        )
    }
}

function Start-PetJump {
    param([int]$Times = 2)
    if ($script:VisualsSuspended -or $null -eq $script:PetTranslate) { return }
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation
    $a.From = 0
    $a.To = -32
    $a.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(320))
    $a.AutoReverse = $true
    $a.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::new([double]$Times)
    $a.EasingFunction = New-Object System.Windows.Media.Animation.QuadraticEase
    $script:PetTranslate.BeginAnimation(
        [System.Windows.Media.TranslateTransform]::YProperty, $a
    )
}

function Start-PetSpinPulse {
    if ($script:VisualsSuspended -or $null -eq $script:PetScale -or $null -eq $script:PetRotate) { return }
    # 恢复太阳原本的整图旋转，同时保留轻微放大回弹。
    $script:PetRotate.BeginAnimation(
        [System.Windows.Media.RotateTransform]::AngleProperty,
        (New-PetDoubleAnim -From 0 -To 360 -Seconds 2.4 -AutoReverse $false -Repeat -1 -Ease 'quad')
    )
    $script:PetScale.BeginAnimation(
        [System.Windows.Media.ScaleTransform]::ScaleXProperty,
        (New-PetDoubleAnim -From 1.0 -To 1.12 -Seconds 0.9 -AutoReverse $true -Repeat -1 -Ease 'quad')
    )
    $script:PetScale.BeginAnimation(
        [System.Windows.Media.ScaleTransform]::ScaleYProperty,
        (New-PetDoubleAnim -From 1.0 -To 1.12 -Seconds 0.9 -AutoReverse $true -Repeat -1 -Ease 'quad')
    )
}

function New-PetKeyframeAnimation {
    param([double[]]$Values, [double[]]$Times)
    $animation = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
    for ($i = 0; $i -lt $Values.Count; $i++) {
        $frame = New-Object System.Windows.Media.Animation.SplineDoubleKeyFrame
        $frame.Value = $Values[$i]
        $frame.KeyTime = [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromSeconds($Times[$i]))
        if ($i -gt 0) {
            $frame.KeySpline = [System.Windows.Media.Animation.KeySpline]::new(0.25, 0.1, 0.25, 1)
        }
        $null = $animation.KeyFrames.Add($frame)
    }
    $animation.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::Stop
    return $animation
}

function Add-PetInteractionParticle {
    param(
        [string]$Text,
        [string]$Color,
        [double]$Left,
        [double]$Top,
        [double]$Delay = 0,
        [double]$Size = 15
    )
    if ($null -eq $script:InteractionLayer) { return }
    $particle = New-Object System.Windows.Controls.TextBlock
    $particle.Text = $Text
    $particle.FontSize = $Size
    $particle.FontWeight = [System.Windows.FontWeights]::Bold
    $particle.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($Color)
    $particle.Opacity = 0
    $particle.IsHitTestVisible = $false
    [System.Windows.Controls.Canvas]::SetLeft($particle, $Left)
    [System.Windows.Controls.Canvas]::SetTop($particle, $Top)
    $translate = New-Object System.Windows.Media.TranslateTransform
    $particle.RenderTransform = $translate
    $script:InteractionLayer.Children.Add($particle) | Out-Null

    # 数组中的时间运算必须括起，避免 PowerShell 把加法解析成数组拼接。
    $opacity = New-PetKeyframeAnimation -Values @(0,1,1,0) -Times @($Delay,($Delay+0.12),($Delay+0.58),($Delay+0.9))
    $rise = New-PetKeyframeAnimation -Values @(8,0,-18,-30) -Times @($Delay,($Delay+0.15),($Delay+0.58),($Delay+0.9))
    $particle.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $opacity)
    $translate.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $rise)
}

function Add-PetBurstCircle {
    param(
        [string]$Color,
        [double]$Left,
        [double]$Top,
        [double]$Size,
        [double]$Delay,
        [double]$DriftX,
        [double]$DriftY,
        [double]$Duration = 0.8,
        [double]$HoldFraction = 0.55,
        [double]$PeakOpacity = 0.96,
        [double]$HoldOpacity = 0.88
    )
    if ($null -eq $script:InteractionLayer) { return }
    $shape = New-Object System.Windows.Shapes.Ellipse
    $shape.Width = $shape.Height = $Size
    $shape.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString($Color)
    $shape.Opacity = 0
    $shape.IsHitTestVisible = $false
    [System.Windows.Controls.Canvas]::SetLeft($shape, $Left)
    [System.Windows.Controls.Canvas]::SetTop($shape, $Top)
    $scale = New-Object System.Windows.Media.ScaleTransform
    $move = New-Object System.Windows.Media.TranslateTransform
    $group = New-Object System.Windows.Media.TransformGroup
    $group.Children.Add($scale) | Out-Null; $group.Children.Add($move) | Out-Null
    $shape.RenderTransformOrigin = [System.Windows.Point]::new(0.5,0.5)
    $shape.RenderTransform = $group
    $script:InteractionLayer.Children.Add($shape) | Out-Null
    $end = $Delay + $Duration
    $shape.BeginAnimation([System.Windows.UIElement]::OpacityProperty,
        (New-PetKeyframeAnimation -Values @(0,$PeakOpacity,$HoldOpacity,0) -Times @($Delay,($Delay+0.06),($Delay+$Duration*$HoldFraction),$end)))
    $scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty,
        (New-PetKeyframeAnimation -Values @(0.15,1.0,1.55) -Times @($Delay,($Delay+0.12),$end)))
    $scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty,
        (New-PetKeyframeAnimation -Values @(0.15,1.0,1.55) -Times @($Delay,($Delay+0.12),$end)))
    $move.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty,
        (New-PetKeyframeAnimation -Values @(0,$DriftX) -Times @($Delay,$end)))
    $move.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty,
        (New-PetKeyframeAnimation -Values @(0,$DriftY) -Times @($Delay,$end)))
}

function Get-PetInteractionFaceProfile {
    param([string]$State)
    # 根据精灵原图中的归一化眼位和当前实际缩放尺寸换算，气泡占用高度后仍能对准。
    if ($State -eq 'run') { $kind = 'horse' } else { $kind = 'standing' }
    if ($kind -eq 'horse') {
        $anchor = @{ LeftX = 0.465; RightX = 0.585; Y = 0.162; HalfGlyph = 4.0; GlyphCenterY = 6.0 }
    } else {
        $anchor = @{ LeftX = 0.430; RightX = 0.640; Y = 0.252; HalfGlyph = 4.5; GlyphCenterY = 6.5 }
    }
    if ($script:SkinId -eq 'western') {
        # 牛仔原图单独标定眼位，并包含素材统一增加的透明边距。
        if ($kind -eq 'horse') {
            $anchor.LeftX = (8 + 559 * 0.476) / 576
            $anchor.RightX = (8 + 559 * 0.578) / 576
            $anchor.Y = (12 + 812 * 0.169) / 837
        } else {
            $anchor.LeftX = (7 + 473 * 0.445) / 488
            $anchor.RightX = (7 + 473 * 0.637) / 488
            $anchor.Y = (12 + 807 * 0.269) / 832
        }
    }
    try { $script:Window.UpdateLayout() } catch { }
    $imageWidth = [double]$script:PetImage.ActualWidth
    $imageHeight = [double]$script:PetImage.ActualHeight
    $hostWidth = [double]$script:PetImage.Parent.ActualWidth
    $hostHeight = [double]$script:PetImage.Parent.ActualHeight
    if ($imageWidth -le 0 -or $imageHeight -le 0 -or $hostWidth -le 0 -or $hostHeight -le 0) {
        if ($kind -eq 'horse') { return @{ LeftEyeX = 52; RightEyeX = 65; EyeY = 23; Kind = $kind } }
        return @{ LeftEyeX = 49; RightEyeX = 68; EyeY = 36; Kind = $kind }
    }
    # 实际坐标包含骑马形态不对称的顶部留白，不能用简单居中公式估算。
    $imageOrigin = $script:PetImage.TranslatePoint([System.Windows.Point]::new(0,0), $script:PetImage.Parent)
    $imageLeft = $imageOrigin.X
    $imageTop = $imageOrigin.Y
    return @{
        LeftEyeX = $imageLeft + $imageWidth * $anchor.LeftX - $anchor.HalfGlyph
        RightEyeX = $imageLeft + $imageWidth * $anchor.RightX - $anchor.HalfGlyph
        EyeY = $imageTop + $imageHeight * $anchor.Y - $anchor.GlyphCenterY
        Kind = $kind
    }
}

function Add-PetHeartEyes {
    param([hashtable]$FaceProfile)
    if ($null -eq $FaceProfile) { $FaceProfile = Get-PetInteractionFaceProfile -State 'idle' }
    foreach ($left in @([double]$FaceProfile.LeftEyeX,[double]$FaceProfile.RightEyeX)) {
        $heart = New-Object System.Windows.Controls.TextBlock
        $heart.Text = '♥'
        if ($FaceProfile.Kind -eq 'horse') { $heart.FontSize = 9 } else { $heart.FontSize = 10 }
        $heart.FontWeight = [System.Windows.FontWeights]::Bold
        $heart.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFFF315F')
        $heart.Opacity = 0
        $heart.IsHitTestVisible = $false
        [System.Windows.Controls.Canvas]::SetLeft($heart, $left)
        [System.Windows.Controls.Canvas]::SetTop($heart, [double]$FaceProfile.EyeY)
        $script:InteractionLayer.Children.Add($heart) | Out-Null
        $blink = New-PetKeyframeAnimation -Values @(0,0,1,0.25,1,0.25,1,0) -Times @(0,1.02,1.12,1.30,1.48,1.66,1.86,2.10)
        $heart.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $blink)
    }
}

function Play-PetInteractionSound {
    param([ValidateSet('pet','highfive','feed','greet')][string]$Kind)
    # 打招呼只保留语音问候，不再叠加提示音效。
    if ($Kind -eq 'greet') { return }
    $path = Join-Path (Join-Path $script:Assets 'interactions') ($Kind + '.wav')
    if (-not (Test-Path -LiteralPath $path)) { return }
    try {
        if ($script:InteractionSoundPlayer) { $script:InteractionSoundPlayer.Stop(); $script:InteractionSoundPlayer.Dispose(); $script:InteractionSoundPlayer=$null }
        # 在播放音效前标记当前进程的声音，供音量回退检测排除。
        if (Get-Command Set-PetLocalSoundActive -ErrorAction SilentlyContinue) {
            Set-PetLocalSoundActive -Seconds 2.3
        }
        $script:InteractionSoundPlayer = New-Object System.Media.SoundPlayer $path
        $script:InteractionSoundPlayer.Play()
    } catch { }
}

function Get-PetWaveArmGeometry {
    param([System.Windows.Controls.Image]$Image)
    if ($null -eq $Image.Source -or $Image.ActualWidth -le 0 -or $Image.ActualHeight -le 0) { return $null }
    $sourceWidth = [double]$Image.Source.Width
    $sourceHeight = [double]$Image.Source.Height
    if ($sourceWidth -le 0 -or $sourceHeight -le 0) { return $null }
    $scale = [Math]::Min($Image.ActualWidth / $sourceWidth, $Image.ActualHeight / $sourceHeight)
    $drawWidth = $sourceWidth * $scale
    $drawHeight = $sourceHeight * $scale
    $left = ($Image.ActualWidth - $drawWidth) / 2
    $top = ($Image.ActualHeight - $drawHeight) / 2
    # 裁剪左手和前臂，身体、脸与肩膀留在静止层。
    $outline = @(
        @(0,280), @(120,280), @(120,333), @(141,348), @(152,384),
        @(145,421), @(125,449), @(74,447), @(0,413)
    )
    $pivotX = 132.0
    $pivotY = 407.0
    $padX = 0.0; $padY = 0.0; $spriteScaleX = 1.0; $spriteScaleY = 1.0
    if ($script:SkinId -eq 'western') {
        # 牛仔流苏袖子整体随手臂摆动，避免袖口留下一截静止碎片。
        $outline = @(
            @(0,280), @(119,280), @(119,337), @(156,349), @(175,374),
            @(161,415), @(158,468), @(146,508), @(84,516), @(0,433)
        )
        $pivotX = 164.0; $pivotY = 385.0
        $padX = 7.0; $padY = 12.0; $spriteScaleX = 473.0 / 488; $spriteScaleY = 807.0 / 832
    }
    $points = New-Object 'System.Collections.Generic.List[System.Windows.Point]'
    foreach ($position in $outline) {
        $points.Add([System.Windows.Point]::new(
            $left + (($padX + [double]$position[0] * $spriteScaleX) / 488) * $drawWidth,
            $top + (($padY + [double]$position[1] * $spriteScaleY) / 832) * $drawHeight
        ))
    }
    $geometry = New-Object System.Windows.Media.StreamGeometry
    $context = $geometry.Open()
    $context.BeginFigure($points[0], $true, $true)
    $context.PolyLineTo($points.GetRange(1, $points.Count - 1), $true, $false)
    $context.Close()
    $geometry.Freeze()
    return @{
        Geometry = $geometry
        PivotX = $left + (($padX + $pivotX * $spriteScaleX) / 488) * $drawWidth
        PivotY = $top + (($padY + $pivotY * $spriteScaleY) / 832) * $drawHeight
    }
}

function Start-PetWaveArm {
    if ($null -eq $script:PetWaveArm -or $null -eq $script:WaveArmRotate) { return }
    # 播放状态的主图有额外顶部留白，手臂层必须沿用完全相同的边距。
    $script:PetWaveArm.Margin = $script:PetImage.Margin
    $script:PetWaveArm.Visibility = [System.Windows.Visibility]::Visible
    $script:Window.UpdateLayout()
    $arm = Get-PetWaveArmGeometry -Image $script:PetWaveArm
    if ($null -eq $arm) { return }
    $script:PetWaveArm.Clip = $arm.Geometry
    $whole = [System.Windows.Media.RectangleGeometry]::new(
        [System.Windows.Rect]::new(0, 0, $script:PetImage.ActualWidth, $script:PetImage.ActualHeight))
    $script:PetImage.Clip = [System.Windows.Media.CombinedGeometry]::new(
        [System.Windows.Media.GeometryCombineMode]::Exclude, $whole, $arm.Geometry)
    $script:WaveArmRotate.CenterX = $arm.PivotX
    $script:WaveArmRotate.CenterY = $arm.PivotY
    # 手臂小幅摆动；身体与面部没有任何旋转、缩放或换帧。
    $wave = New-PetKeyframeAnimation -Values @(0,-7,8,-7,8,-4,0) -Times @(0,0.17,0.34,0.51,0.70,0.89,1.10)
    $script:WaveArmRotate.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $wave)
}

function Stop-PetInteractionResources {
    if ($script:InteractionResetTimer) { $script:InteractionResetTimer.Stop() }
    if ($script:InteractionSoundTimer) { $script:InteractionSoundTimer.Stop() }
    $script:InteractionReturnState=$null
    if ($script:InteractionSoundPlayer) {
        try { $script:InteractionSoundPlayer.Stop(); $script:InteractionSoundPlayer.Dispose() } catch { }
        $script:InteractionSoundPlayer=$null
    }
    if ($script:PetWaveArm) {
        $script:WaveArmRotate.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty,$null)
        $script:PetWaveArm.Visibility='Collapsed'; $script:PetWaveArm.Source=$null; $script:PetWaveArm.Clip=$null
    }
    if ($script:PetImage) { $script:PetImage.Clip=$null }
    if ($script:InteractionLayer) {
        foreach ($child in $script:InteractionLayer.Children) {
            $child.BeginAnimation([System.Windows.UIElement]::OpacityProperty,$null)
            if ($child.RenderTransform -is [System.Windows.Media.TransformGroup]) {
                foreach ($transform in $child.RenderTransform.Children) { Clear-PetAnimations $transform }
            } else { Clear-PetAnimations $child.RenderTransform }
        }
        $script:InteractionLayer.Children.Clear()
    }
}

function Stop-PetVisualAnimations {
    Stop-PetInteractionResources
    foreach ($target in @($script:PetScale,$script:PetRotate,$script:PetTranslate)) { Clear-PetAnimations $target }
    if ($script:RecordRotate) { $script:RecordRotate.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty,$null) }
    if ($script:RecordDisc) { $script:RecordDisc.BeginAnimation([System.Windows.Controls.Canvas]::LeftProperty,$null) }
}

function Start-PetHighfive {
    param([string]$ReturnState)
    $horse=$ReturnState -eq 'run'
    $path=if($horse){Get-PetThemedAssetPath 'pet_highfive_horse.png'}else{Get-PetThemedAssetPath 'pet_wave.png'}
    Set-PetImageSource -Image $script:PetImage -Path $path
    Set-PetImageSource -Image $script:PetWaveArm -Path $path
    $script:PetWaveArm.Margin=$script:PetImage.Margin
    $script:PetWaveArm.Visibility='Visible'
    $script:Window.UpdateLayout()
    $image=$script:PetImage
    $scale=[Math]::Min($image.ActualWidth/$image.Source.Width,$image.ActualHeight/$image.Source.Height)
    $drawWidth=$image.Source.Width*$scale;$drawHeight=$image.Source.Height*$scale
    $drawLeft=($image.ActualWidth-$drawWidth)/2;$drawTop=($image.ActualHeight-$drawHeight)/2
    if ($horse) {
        # 四套骑马图独立标定手掌和肩部；只裁出抬起的手臂，脸部与马保持静止。
        $profile=switch($script:SkinId){
            'moonlit' {@{x=.783;y=.178;px=.69;py=.29;side=1}}
            'festival' {@{x=.779;y=.174;px=.69;py=.28;side=1}}
            'western' {@{x=.342;y=.168;px=.455;py=.295;side=-1}}
            default {@{x=.795;y=.200;px=.705;py=.295;side=1}}
        }
        $outline=if($profile.side -lt 0){
            @(@(.25,.10),@(.39,.10),@(.43,.245),@(.49,.28),@(.45,.34),@(.31,.34),@(.25,.23))
        }else{
            @(@(.735,.115),@(.90,.115),@(.93,.35),@(.72,.36),@(.64,.31),@(.69,.27),@(.735,.26))
        }
        $width=$drawWidth;$height=$drawHeight
        $geometry=New-Object System.Windows.Media.StreamGeometry
        $context=$geometry.Open()
        $context.BeginFigure([Windows.Point]::new($drawLeft+$width*$outline[0][0],$drawTop+$height*$outline[0][1]),$true,$true)
        foreach($point in $outline|Select-Object -Skip 1){$context.LineTo([Windows.Point]::new($drawLeft+$width*$point[0],$drawTop+$height*$point[1]),$true,$false)}
        $context.Close();$geometry.Freeze()
        $arm=@{Geometry=$geometry;PivotX=$drawLeft+$width*$profile.px;PivotY=$drawTop+$height*$profile.py}
    }else{
        $arm=Get-PetWaveArmGeometry -Image $script:PetWaveArm
        $profile=@{x=.123;y=.410;side=-1}
        if($script:SkinId -eq 'western'){$profile.x=(7+473*.123)/488;$profile.y=(12+807*.410)/832}
    }
    if($null -eq $arm){return}
    $script:PetWaveArm.Clip=$arm.Geometry
    $whole=[Windows.Media.RectangleGeometry]::new([Windows.Rect]::new(0,0,$script:PetImage.ActualWidth,$script:PetImage.ActualHeight))
    $script:PetImage.Clip=[Windows.Media.CombinedGeometry]::new([Windows.Media.GeometryCombineMode]::Exclude,$whole,$arm.Geometry)
    $script:WaveArmRotate.CenterX=$arm.PivotX;$script:WaveArmRotate.CenterY=$arm.PivotY
    $side=[double]$profile.side
    $script:WaveArmRotate.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty,
        (New-PetKeyframeAnimation -Values @(($side*18),($side*6),0,(-$side*6),0,($side*12)) -Times @(0,.25,.46,.57,.78,1.32)))
    $origin=$script:PetImage.TranslatePoint([Windows.Point]::new(0,0),$script:InteractionLayer)
    $contactX=$origin.X+$drawLeft+$drawWidth*$profile.x
    $contactY=$origin.Y+$drawTop+$drawHeight*$profile.y
    # 对方手掌用像素路径绘制，接触点由当前素材和实际布局换算，不写死屏幕坐标。
    $palm=New-Object Windows.Shapes.Path
    $palm.Data=[Windows.Media.Geometry]::Parse('M 3,11 L 3,3 L 5,3 L 5,0 L 7,0 L 7,9 L 8,9 L 8,1 L 10,1 L 10,10 L 11,10 L 11,3 L 13,3 L 13,13 L 12,16 L 10,19 L 10,23 L 4,23 L 4,19 L 1,15 L 0,11 L 2,10 Z')
    if($null -eq $script:HighfivePalmBrush){
        # 固定像素明暗共享为冻结画刷，不在每次击掌时重建纹理。
        $drawing=New-Object Windows.Media.DrawingGroup
        foreach($part in @(
            @{color='#FFE9A676';path='M 0,0 L 13,0 L 13,23 L 0,23 Z'},
            @{color='#FFFFCC9A';path='M 3,1 L 6,1 L 6,11 L 10,11 L 10,2 L 12,2 L 12,15 L 9,18 L 5,18 L 2,14 L 2,11 L 3,11 Z'},
            @{color='#FFC17C58';path='M 4,13 L 6,13 L 6,15 L 9,15 L 9,16 L 5,16 L 5,15 L 4,15 Z'},
            @{color='#FF785040';path='M 4,20 L 10,20 L 10,23 L 4,23 Z'}
        )){
            $brush=[Windows.Media.BrushConverter]::new().ConvertFromString($part.color)
            $drawing.Children.Add([Windows.Media.GeometryDrawing]::new($brush,$null,[Windows.Media.Geometry]::Parse($part.path)))
        }
        $drawing.Freeze()
        $script:HighfivePalmBrush=[Windows.Media.DrawingBrush]::new($drawing)
        $script:HighfivePalmBrush.ViewboxUnits='Absolute';$script:HighfivePalmBrush.Viewbox=[Windows.Rect]::new(0,0,13,23)
        $script:HighfivePalmBrush.Freeze()
    }
    $palm.Fill=$script:HighfivePalmBrush
    $palm.Stroke=[Windows.Media.BrushConverter]::new().ConvertFromString('#FF6B3E32');$palm.StrokeThickness=.8
    $palm.Width=$drawWidth*.14;$palm.Height=$drawHeight*.13;$palm.Stretch='Fill';$palm.Opacity=0
    [Windows.Controls.Canvas]::SetLeft($palm,$contactX-$palm.Width/2)
    [Windows.Controls.Canvas]::SetTop($palm,$contactY-$palm.Height/2)
    $move=New-Object Windows.Media.TranslateTransform
    $palm.RenderTransform=$move
    $script:InteractionLayer.Children.Add($palm)|Out-Null
    $palm.BeginAnimation([Windows.UIElement]::OpacityProperty,(New-PetKeyframeAnimation -Values @(0,1,1,0) -Times @(.08,.20,.78,1.10)))
    $move.BeginAnimation([Windows.Media.TranslateTransform]::XProperty,(New-PetKeyframeAnimation -Values @(($side*25),0,(-$side*2),($side*25)) -Times @(.08,.46,.57,1.10)))
    $move.BeginAnimation([Windows.Media.TranslateTransform]::YProperty,(New-PetKeyframeAnimation -Values @(8,0,2,8) -Times @(.08,.46,.57,1.10)))
    foreach($offset in @(@(-10,-9),@(8,-12),@(10,6))){
        Add-PetInteractionParticle -Text '✦' -Color '#FFFFD35A' -Left ($contactX+$offset[0]) -Top ($contactY+$offset[1]) -Delay .45 -Size 10
    }
    if ($null -eq $script:InteractionSoundTimer) {
        $script:InteractionSoundTimer=New-Object Windows.Threading.DispatcherTimer
        $script:InteractionSoundTimer.Add_Tick({$script:InteractionSoundTimer.Stop();Play-PetInteractionSound -Kind 'highfive'})
    }
    $script:InteractionSoundTimer.Stop()
    $script:InteractionSoundTimer.Interval=[TimeSpan]::FromMilliseconds(460)
    $script:InteractionSoundTimer.Start()
    Start-PetInteractionResetTimer -ReturnState $ReturnState -Seconds 1.4
}

function Start-PetInteractionResetTimer {
    param([string]$ReturnState, [double]$Seconds)
    if ($null -eq $script:InteractionResetTimer) {
        $script:InteractionResetTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:InteractionResetTimer.Add_Tick({
        $script:InteractionResetTimer.Stop()
        $expectedState = $script:InteractionReturnState
        if ($script:State -eq $expectedState) {
            $script:State = '__interaction-complete'
            Set-PetState -State $expectedState
            # 音乐仍在播放时必须明确恢复循环奔跑，避免同状态优化跳过动画重启。
            if ($expectedState -eq 'run' -and $script:MusicForm -eq 'horse' -and -not $script:PetTranslate.HasAnimatedProperties -and
                $script:PetImage.Visibility -eq [System.Windows.Visibility]::Visible) {
                Start-PetGallop
            }
        }
        })
    }
    $script:InteractionResetTimer.Stop()
    $script:InteractionReturnState = $ReturnState
    $script:InteractionResetTimer.Interval = [TimeSpan]::FromSeconds($Seconds)
    $script:InteractionResetTimer.Start()
}

function Start-PetInteractionAnimation {
    param([ValidateSet('pet','highfive','feed','greet')][string]$Kind)
    if ($script:VisualsSuspended -or $null -eq $script:PetImage) { return }
    $returnState = $script:State
    if ($script:PetImage.Visibility -ne [System.Windows.Visibility]::Visible) { return }
    # 先恢复当前状态的稳定画面，连续点击时不会叠加旧动画或旧精灵。
    $script:State = '__interaction-reset'
    Set-PetState -State $returnState
    Clear-PetAnimations -Target $script:PetScale
    Clear-PetAnimations -Target $script:PetRotate
    Clear-PetAnimations -Target $script:PetTranslate
    $script:PetImage.BeginAnimation([System.Windows.Controls.Image]::SourceProperty, $null)
    # 清除浮动和骑马跳跃后再取眼位，爱心层不会记住动画当时的位移。
    $faceProfile = Get-PetInteractionFaceProfile -State $returnState
    if ($null -ne $script:InteractionLayer) { $script:InteractionLayer.Children.Clear() }
    if ($Kind -eq 'highfive') { Start-PetHighfive -ReturnState $returnState; return }
    Play-PetInteractionSound -Kind $Kind

    if ($Kind -eq 'pet') {
        Set-PetImageSource -Image $script:PetImage -Path (Get-PetThemedAssetPath 'pet_dress.png')
        # 横向压缩、镜像再展开表现原地转身；身体始终保持直立，裙摆同步扩张。
        $sx = New-PetKeyframeAnimation -Values @(1,0.16,-1,-0.16,1,0.16,-1,-0.16,1) -Times @(0,0.18,0.38,0.58,0.78,0.98,1.18,1.38,1.60)
        $sy = New-PetKeyframeAnimation -Values @(1,1.03,0.98,1.04,1,1.03,0.98,1.04,1) -Times @(0,0.18,0.38,0.58,0.78,0.98,1.18,1.38,1.60)
        $rotate = New-PetKeyframeAnimation -Values @(0,-2,0,2,0,-2,0,2,0) -Times @(0,0.18,0.38,0.58,0.78,0.98,1.18,1.38,1.60)
        $bob = New-PetKeyframeAnimation -Values @(0,-2,0,-2,0,-2,0) -Times @(0,0.24,0.50,0.76,1.02,1.30,1.60)
        $script:PetTranslate.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $bob)
        Add-PetInteractionParticle -Text '✦' -Color '#FFFFD35A' -Left 18 -Top 72 -Delay 0.08
        Add-PetInteractionParticle -Text '✦' -Color '#FFFF8DB0' -Left 91 -Top 48 -Delay 0.34
        Add-PetInteractionParticle -Text '♥' -Color '#FFFF5E85' -Left 25 -Top 36 -Delay 0.62
        Start-PetInteractionResetTimer -ReturnState $returnState -Seconds 1.68
    }
    elseif ($Kind -eq 'feed') {
        $sx = New-PetKeyframeAnimation -Values @(1,0.88,1.08,1) -Times @(0,0.10,0.27,0.50)
        $sy = New-PetKeyframeAnimation -Values @(1,1.10,0.94,1) -Times @(0,0.10,0.27,0.50)
        $rotate = New-PetKeyframeAnimation -Values @(0,-4,4,0) -Times @(0,0.12,0.28,0.50)
        foreach ($burst in @(
            @{c='#FFFFC400';x=52;y=72;s=36;d=0.04;dx=-25;dy=-30},
            @{c='#FFFF6A00';x=48;y=68;s=31;d=0.06;dx=28;dy=-24},
            @{c='#FFFFF19A';x=56;y=75;s=28;d=0.08;dx=-8;dy=31},
            @{c='#FFFF3B1F';x=50;y=70;s=24;d=0.10;dx=31;dy=18}
        )) { Add-PetBurstCircle -Color $burst.c -Left $burst.x -Top $burst.y -Size $burst.s -Delay $burst.d -DriftX $burst.dx -DriftY $burst.dy -Duration 0.48 }
        # 大烟团从头到脚铺满窗口中央，短时间内完全遮住桌宠，再向四周散开。
        foreach ($smoke in @(
            @{c='#FFD6D8DE';x=-8;y=12;s=49;d=0.20;dx=-15;dy=-12}, @{c='#FFB8BDC7';x=28;y=8;s=52;d=0.21;dx=-5;dy=-18},
            @{c='#FFE4E6EA';x=68;y=10;s=50;d=0.22;dx=14;dy=-14}, @{c='#FFC3C7CF';x=2;y=45;s=54;d=0.23;dx=-18;dy=-4},
            @{c='#FFDFE1E6';x=39;y=40;s=58;d=0.20;dx=2;dy=-8}, @{c='#FFADB3BE';x=82;y=43;s=48;d=0.24;dx=19;dy=-2},
            @{c='#FFD0D3D9';x=-4;y=82;s=53;d=0.25;dx=-17;dy=7}, @{c='#FFE6E7EB';x=31;y=78;s=60;d=0.22;dx=-3;dy=10},
            @{c='#FFB9BEC8';x=78;y=81;s=52;d=0.24;dx=18;dy=8}, @{c='#FFDCDEE3';x=4;y=118;s=48;d=0.26;dx=-14;dy=18},
            @{c='#FFC5C9D1';x=42;y=112;s=55;d=0.23;dx=2;dy=20}, @{c='#FFE3E5E9';x=82;y=116;s=47;d=0.27;dx=16;dy=18}
        )) { Add-PetBurstCircle -Color $smoke.c -Left $smoke.x -Top $smoke.y -Size $smoke.s -Delay $smoke.d -DriftX $smoke.dx -DriftY $smoke.dy -Duration 0.96 -HoldFraction 0.76 -PeakOpacity 1 -HoldOpacity 1 }
        Add-PetHeartEyes -FaceProfile $faceProfile
        Start-PetInteractionResetTimer -ReturnState $returnState -Seconds 2.16
    }
    else {
        # 同图分层后只摆动左臂，整张人物图保持静止，避免面部和衣服闪烁。
        $wavePath = Get-PetThemedAssetPath 'pet_wave.png'
        Set-PetImageSource -Image $script:PetImage -Path $wavePath
        Set-PetImageSource -Image $script:PetWaveArm -Path $wavePath
        Start-PetWaveArm
        Add-PetInteractionParticle -Text '✦' -Color '#FF78C7FF' -Left 18 -Top 40 -Delay 0.06
        Add-PetInteractionParticle -Text '✦' -Color '#FFFFFFFF' -Left 88 -Top 52 -Delay 0.22
        Start-PetInteractionResetTimer -ReturnState $returnState -Seconds 1.25
    }
    if ($Kind -ne 'greet') {
        $script:PetScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $sx)
        $script:PetScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $sy)
        $script:PetRotate.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $rotate)
    }
}

function Set-PetContextMenuHandlers {
    param([scriptblock]$InteractionHandler, [scriptblock]$GrowthHandler)
    $script:PetInteractionHandler = $InteractionHandler
    $script:PetGrowthHandler = $GrowthHandler
    if ($null -eq $script:Window) { return }
    $menu = New-Object System.Windows.Controls.ContextMenu
    $menu.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei UI')
    $menu.FontSize = 13
    $menu.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFFDF8EE')
    foreach ($spec in @(
        @{header='摸摸'; kind='pet'},
        @{header='击掌'; kind='highfive'},
        @{header='打招呼'; kind='greet'}
    )) {
        $item = New-Object System.Windows.Controls.MenuItem
        $item.Header = [string]$spec.header
        $item.Tag = [string]$spec.kind
        $item.Padding = [System.Windows.Thickness]::new(14,7,28,7)
        $item.Add_Click({ param($sender,$e) if ($script:PetInteractionHandler) { & $script:PetInteractionHandler -Kind ([string]$sender.Tag) | Out-Null } })
        $menu.Items.Add($item) | Out-Null
    }
    $menu.Items.Add((New-Object System.Windows.Controls.Separator)) | Out-Null
    $growth = New-Object System.Windows.Controls.MenuItem
    $growth.Header = '成长与外观…'
    $growth.Padding = [System.Windows.Thickness]::new(14,7,28,7)
    $growth.Add_Click({ if ($script:PetGrowthHandler) { & $script:PetGrowthHandler | Out-Null } })
    $menu.Items.Add($growth) | Out-Null
    $script:Window.ContextMenu = $menu
    $script:Window.Add_ContextMenuOpening({
        param($sender, $e)
        # 在菜单创建前拦截，避免黑胶形态右键时菜单短暂闪现。
        if ($script:State -eq 'run' -and $script:MusicForm -eq 'record') { $e.Handled = $true }
    })
}

# Poll Windows' last-input timestamp.  It changes for keyboard, mouse and touch
# activity anywhere on the desktop, without needing intrusive global hooks.
function Initialize-PetInputWatch {
    if ($script:InputWatchOn) { return }
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PetInputWatch {
    [StructLayout(LayoutKind.Sequential)]
    public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")]
    public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
}
'@ -ErrorAction Stop
        $info = New-Object PetInputWatch+LASTINPUTINFO
        $info.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf([Type][PetInputWatch+LASTINPUTINFO])
        if ([PetInputWatch]::GetLastInputInfo([ref]$info)) {
            $script:LastInputStamp = [long]$info.dwTime
            $script:InputWatchOn = $true
        }
    }
    catch { $script:InputWatchOn = $false }
}

function Get-PetGlobalActivity {
    if (-not $script:InputWatchOn) { return $false }
    try {
        $info = New-Object PetInputWatch+LASTINPUTINFO
        $info.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf([Type][PetInputWatch+LASTINPUTINFO])
        if (-not [PetInputWatch]::GetLastInputInfo([ref]$info)) { return $false }
        $stamp = [long]$info.dwTime
        if ($stamp -ne $script:LastInputStamp) {
            $script:LastInputStamp = $stamp
            return $true
        }
    }
    catch { }
    return $false
}

function Initialize-PetFullscreenWatch {
    if ($script:FullscreenWatchReady) { return $true }
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class PetFullscreenWatch {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left,Top,Right,Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct MONITORINFO { public int Size; public RECT Monitor; public RECT Work; public uint Flags; }
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, uint f);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder n, int c);
    [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr h, ref MONITORINFO i);
    public static bool Covers(int l,int t,int r,int b,int ml,int mt,int mr,int mb) {
        const int e=2; return l<=ml+e && t<=mt+e && r>=mr-e && b>=mb-e;
    }
    public static bool IsForegroundFullscreen(IntPtr ignored) {
        IntPtr h=GetForegroundWindow(); if(h==IntPtr.Zero || h==ignored || IsIconic(h)) return false;
        var name=new StringBuilder(128); GetClassName(h,name,name.Capacity);
        string c=name.ToString(); if(c=="Progman" || c=="WorkerW" || c=="Shell_TrayWnd") return false;
        RECT window; if(!GetWindowRect(h,out window)) return false;
        IntPtr monitor=MonitorFromWindow(h,2); var info=new MONITORINFO(); info.Size=Marshal.SizeOf(typeof(MONITORINFO));
        if(monitor==IntPtr.Zero || !GetMonitorInfo(monitor,ref info)) return false;
        return Covers(window.Left,window.Top,window.Right,window.Bottom,
            info.Monitor.Left,info.Monitor.Top,info.Monitor.Right,info.Monitor.Bottom);
    }
}
'@ -ErrorAction Stop
        $script:FullscreenWatchReady = $true
    } catch { $script:FullscreenWatchReady = $false }
    return $script:FullscreenWatchReady
}

function Update-PetFullscreenVisibility {
    if ($null -eq $script:Window -or -not (Initialize-PetFullscreenWatch)) { return $false }
    try {
        $ownHandle = [System.Windows.Interop.WindowInteropHelper]::new($script:Window).Handle
        $fullscreen = [PetFullscreenWatch]::IsForegroundFullscreen($ownHandle)
        if ($fullscreen -and $script:Window.IsVisible) {
            $script:Window.Hide()
            $script:FullscreenHidden = $true
        }
        elseif (-not $fullscreen -and $script:FullscreenHidden) {
            # 退出全屏后静默恢复，不激活窗口，也不抢走视频或键盘焦点。
            $script:Window.Show()
            $script:Window.Topmost = $script:TopmostPreferred
            $script:FullscreenHidden = $false
        }
        return $fullscreen
    } catch { return $false }
}

function Show-PetBubble {
    param([string]$Text, [double]$Seconds = 6)
    if ($null -eq $script:Bubble) { return }
    $script:BubbleText.Text = $Text
    $script:Bubble.Visibility = [System.Windows.Visibility]::Visible
    if ($null -eq $script:BubbleTimer) {
        $script:BubbleTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:BubbleTimer.Add_Tick({
            $script:BubbleTimer.Stop()
            if ($null -ne $script:Bubble) { $script:Bubble.Visibility = [System.Windows.Visibility]::Collapsed }
        })
    }
    $script:BubbleTimer.Stop()
    $script:BubbleTimer.Interval = [TimeSpan]::FromSeconds($Seconds)
    $script:BubbleTimer.Start()
}

function Set-PetSign {
    param([string]$Text)
    if ($null -eq $script:SignBorder) { return }
    if ([string]::IsNullOrWhiteSpace($Text)) {
        $script:SignBorder.Visibility = [System.Windows.Visibility]::Collapsed
        return
    }
    $script:SignText.Text = $Text
    $script:SignBorder.Visibility = [System.Windows.Visibility]::Visible
}

function Set-PetCountdown {
    param([string]$Text)
    if ($null -eq $script:CountdownText) { return }
    if ([string]::IsNullOrWhiteSpace($Text)) {
        Hide-PetCountdown
        return
    }
    $script:CountdownText.Text = $Text
    $script:CountdownBorder.Visibility = [System.Windows.Visibility]::Visible
}

function Hide-PetCountdown {
    if ($null -eq $script:CountdownBorder) { return }
    $script:CountdownBorder.Visibility = [System.Windows.Visibility]::Collapsed
}

function Set-PetState {
    param([string]$State)
    # 每秒检测不应重新启动动画，否则唱片永远转不完一圈。
    if ($State -eq 'run' -and $script:State -eq 'run') { return }
    Stop-PetInteractionResources
    $script:State = $State
    if ($null -eq $script:Window) { return }
    $mouseUp = $false
    # Default everywhere: clear transforms, restore opacity, hide sign/zzz.
    Clear-PetAnimations -Target $script:PetScale
    Clear-PetAnimations -Target $script:PetRotate
    Clear-PetAnimations -Target $script:PetTranslate
    $script:PetImage.Clip = $null
    if ($null -ne $script:PetWaveArm) {
        $script:PetWaveArm.Visibility = [System.Windows.Visibility]::Collapsed
        $script:PetWaveArm.Clip = $null
        $script:WaveArmRotate.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $null)
    }
    $script:PetImage.Opacity = 1.0
    $script:PetImage.Visibility = 'Visible'
    $script:PetImage.Margin = [System.Windows.Thickness]::new(5)
    [System.Windows.Media.RenderOptions]::SetBitmapScalingMode(
        $script:PetImage, [System.Windows.Media.BitmapScalingMode]::HighQuality
    )
    if ($null -ne $script:InteractionLayer) { $script:InteractionLayer.Children.Clear() }
    if ($null -ne $script:RecordView) {
        $script:RecordView.Visibility = 'Collapsed'
        $script:RecordRotate.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $null)
        $script:RecordDisc.BeginAnimation([System.Windows.Controls.Canvas]::LeftProperty, $null)
    }
    Set-PetSign -Text ''

    switch ($State) {
        'idle' {
            # The supplied waving character is the normal visible standby pose.
            # The white horse is reserved for music-driven running.
            Set-PetImageSource -Image $script:PetImage -Path (Get-PetThemedAssetPath 'pet.png')
            Start-PetBob -Amplitude 3 -Seconds 1.8
        }
        'run' {
            if ($script:MusicForm -eq 'record') {
                $script:PetImage.Visibility = 'Collapsed'
                # 黑胶形态不再持有已隐藏的旧皮肤位图，切回骑马时按当前皮肤重新加载。
                $script:PetImage.Source = $null
                $script:RecordView.Visibility = 'Visible'
                Start-PetRecordEntrance
                # 正角度在屏幕坐标中为顺时针，线性动画保持匀速。
                $spin = New-Object System.Windows.Media.Animation.DoubleAnimation
                $spin.From = 0
                $spin.To = 360
                $spin.Duration = [System.Windows.Duration]::new([TimeSpan]::FromSeconds(8))
                $spin.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
                if (-not $script:VisualsSuspended) { $script:RecordRotate.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $spin) }
                break
            }
            # Keep the clean riding sprite while animation supplies the gallop.
            # The old speed-line bitmap produced visible jagged fringes on transparent edges.
            # 顶部额外留出奔跑上跳空间，避免骑手头顶越过透明窗口被裁掉。
            $script:PetImage.Margin = [System.Windows.Thickness]::new(5,14,5,5)
            Set-PetImageSource -Image $script:PetImage -Path (Get-PetThemedAssetPath 'pet_horse.png')
            Start-PetGallop
        }
        'working' {
            Set-PetImageSource -Image $script:PetImage -Path (Get-PetThemedAssetPath 'pet.png')
            Start-PetBob -Amplitude 2 -Seconds 1.0
        }
        'alert' {
            Set-PetImageSource -Image $script:PetImage -Path (Get-PetThemedAssetPath 'pet.png')
            Start-PetJump -Times 2
        }
        'happy' {
            # 完成倒计时和待办始终显示原版金色太阳，避免主题色改变人物脸部。
            Set-PetImageSource -Image $script:PetImage -Path (Get-PetAssetPath 'sun.png')
            # 像素图在连续旋转时使用邻近采样，避免透明区颜色混入金色外沿。
            [System.Windows.Media.RenderOptions]::SetBitmapScalingMode(
                $script:PetImage, [System.Windows.Media.BitmapScalingMode]::NearestNeighbor
            )
            Start-PetSpinPulse
        }
        'sleep' {
            # Dozing on horseback, eyes closed — not the waving pose.
            Set-PetImageSource -Image $script:PetImage -Path (Get-PetThemedAssetPath 'pet_sleep.png')
            $script:PetImage.Opacity = 0.6
        }
    }
}

function New-PetWindow {
    param(
        [hashtable]$Config
    )

    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="120" Height="160"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ResizeMode="NoResize" Topmost="True" ShowInTaskbar="False">
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <Border x:Name="Bubble" Grid.Row="0" Margin="4,4,4,2"
            Background="#E6FFFFFF" CornerRadius="6" Padding="4,3"
            BorderBrush="#C0FFC93C" BorderThickness="1" Visibility="Collapsed">
      <TextBlock x:Name="BubbleText" TextWrapping="Wrap" FontSize="9"
                 Foreground="#333333" FontFamily="Microsoft YaHei"/>
    </Border>

    <Grid Grid.Row="1">
      <Viewbox x:Name="RecordView" Margin="5" Stretch="Uniform" Visibility="Collapsed"
               ToolTip="双击切换音乐形态 · 按住拖动">
        <Canvas Width="480" Height="340" Background="Transparent">
          <Canvas x:Name="RecordDisc" Width="310" Height="310" Canvas.Left="167" Canvas.Top="15"
                  RenderTransformOrigin="0.5,0.5">
            <Canvas.RenderTransform><RotateTransform x:Name="RecordRotate"/></Canvas.RenderTransform>
            <Ellipse Width="310" Height="310" Stroke="#504541" StrokeThickness="2">
              <Ellipse.Fill>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                  <GradientStop Color="#101012" Offset="0"/>
                  <GradientStop Color="#454044" Offset="0.25"/>
                  <GradientStop Color="#151517" Offset="0.48"/>
                  <GradientStop Color="#373237" Offset="0.75"/>
                  <GradientStop Color="#111113" Offset="1"/>
                </LinearGradientBrush>
              </Ellipse.Fill>
            </Ellipse>
            <Ellipse x:Name="RecordLabel" Width="150" Height="150" Canvas.Left="80" Canvas.Top="80"
                     Stroke="#E8B597" StrokeThickness="8"/>
            <Ellipse Width="16" Height="16" Canvas.Left="147" Canvas.Top="147"
                     Fill="#251C19" Stroke="#BC947E" StrokeThickness="2"/>
          </Canvas>
          <Border Width="330" Height="330" Canvas.Left="0" Canvas.Top="5" CornerRadius="5"
                  BorderBrush="#887D685F" BorderThickness="1">
            <Border.Effect><DropShadowEffect BlurRadius="12" ShadowDepth="4" Opacity="0.4"/></Border.Effect>
            <Border.Background><ImageBrush x:Name="RecordCover" Stretch="UniformToFill"/></Border.Background>
          </Border>
        </Canvas>
      </Viewbox>
      <Image x:Name="PetImage" Stretch="Uniform" Margin="5"
             RenderTransformOrigin="0.5,0.5" HorizontalAlignment="Center" VerticalAlignment="Center">
        <Image.RenderTransform>
          <TransformGroup>
            <ScaleTransform x:Name="PetScale"/>
            <RotateTransform x:Name="PetRotate"/>
            <TranslateTransform x:Name="PetTranslate"/>
          </TransformGroup>
        </Image.RenderTransform>
      </Image>
      <Image x:Name="PetWaveArm" Stretch="Uniform" Margin="5" Visibility="Collapsed"
             IsHitTestVisible="False" HorizontalAlignment="Center" VerticalAlignment="Center">
        <Image.RenderTransform><RotateTransform x:Name="WaveArmRotate"/></Image.RenderTransform>
      </Image>
      <Canvas x:Name="InteractionLayer" IsHitTestVisible="False"/>
      <Border x:Name="SignBorder" HorizontalAlignment="Center" VerticalAlignment="Top"
              Margin="0,3,0,0" Background="#F0FFFFFF" CornerRadius="7" Padding="7,4"
              BorderBrush="#E0FF7A00" BorderThickness="2" Visibility="Collapsed">
        <TextBlock x:Name="SignText" TextWrapping="Wrap" FontSize="10" FontWeight="Bold"
                   Foreground="#B35A00" FontFamily="Microsoft YaHei"/>
      </Border>
      <Border x:Name="CountdownBorder" HorizontalAlignment="Center" VerticalAlignment="Top"
              Margin="0,2,0,0" Background="#E6FFFFFF" CornerRadius="6" Padding="5,2"
              BorderBrush="#D0FF7A00" BorderThickness="1" Visibility="Collapsed">
        <TextBlock x:Name="CountdownText" FontSize="9" FontWeight="Bold"
                   Foreground="#B35A00" FontFamily="Consolas"/>
      </Border>
    </Grid>

  </Grid>
</Window>
'@

    $script:Window = [System.Windows.Markup.XamlReader]::Parse($xaml)
    $script:PetImage = $script:Window.FindName('PetImage')
    $script:PetWaveArm = $script:Window.FindName('PetWaveArm')
    $script:WaveArmRotate = $script:Window.FindName('WaveArmRotate')
    $script:RecordView = $script:Window.FindName('RecordView')
    $script:RecordRotate = $script:Window.FindName('RecordRotate')
    $script:RecordDisc = $script:Window.FindName('RecordDisc')
    $coverPath = Get-PetAssetPath 'music-reference.png'
    if (Test-Path $coverPath) {
        $reference = ConvertTo-PetImageSource -Path $coverPath
        $cover = [System.Windows.Media.Imaging.CroppedBitmap]::new($reference, [System.Windows.Int32Rect]::new(1, 1, 339, 339))
        $cover.Freeze()
    } else { $cover = ConvertTo-PetImageSource -Path (Get-PetAssetPath 'pet.png') }
    $script:Window.FindName('RecordCover').ImageSource = $cover
    $labelBrush = [System.Windows.Media.ImageBrush]::new($cover)
    $labelBrush.Stretch = 'UniformToFill'
    $script:Window.FindName('RecordLabel').Fill = $labelBrush
    $script:DefaultMusicCover = New-PetDefaultMusicCover
    Set-PetMusicCover -Cover $null
    # 同心细纹由矢量绘制，缩放时保持平滑，位于标签后方。
    $disc = $script:Window.FindName('RecordDisc')
    foreach ($inset in 8..36 | Where-Object { $_ % 2 -eq 0 }) {
        $ring = New-Object System.Windows.Shapes.Ellipse
        $ring.Width = $ring.Height = 310 - $inset * 2
        $ring.Stroke = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#387E7375')
        $ring.StrokeThickness = 0.7
        $ring.IsHitTestVisible = $false
        [System.Windows.Controls.Canvas]::SetLeft($ring, $inset)
        [System.Windows.Controls.Canvas]::SetTop($ring, $inset)
        $disc.Children.Insert(1, $ring)
    }
    $script:SignBorder = $script:Window.FindName('SignBorder')
    $script:SignText = $script:Window.FindName('SignText')
    $script:Bubble = $script:Window.FindName('Bubble')
    $script:BubbleText = $script:Window.FindName('BubbleText')
    $script:CountdownText = $script:Window.FindName('CountdownText')
    $script:CountdownBorder = $script:Window.FindName('CountdownBorder')
    $script:PetScale = $script:Window.FindName('PetScale')
    $script:PetRotate = $script:Window.FindName('PetRotate')
    $script:PetTranslate = $script:Window.FindName('PetTranslate')
    $script:InteractionLayer = $script:Window.FindName('InteractionLayer')
    [System.Windows.Media.RenderOptions]::SetBitmapScalingMode(
        $script:PetImage,
        [System.Windows.Media.BitmapScalingMode]::HighQuality
    )

    $script:TopmostPreferred = [bool]$Config.topmost
    $script:Window.Topmost = $script:TopmostPreferred

    # 只暂停不可见的视觉动画；主调度计时器仍负责提醒、倒计时与音乐状态。
    $script:Window.Add_IsVisibleChanged({ param($sender,$e)
        $script:VisualsSuspended = -not $sender.IsVisible
        if ($script:VisualsSuspended) { Stop-PetVisualAnimations }
        else {
            $state=$script:State
            if($state -eq 'music-stopping'){$state='idle'}
            $signWasVisible=$script:SignBorder.Visibility -eq [Windows.Visibility]::Visible
            $signText=$script:SignText.Text
            $script:State='__visibility-resume'
            Set-PetState -State $state
            if($signWasVisible -and $state -eq 'alert'){Set-PetSign -Text $signText}
        }
    })
    $script:Window.Add_Closed({ Stop-PetVisualAnimations; $script:ImageCache.Clear(); $script:ImageCacheBytes=0L })

    # Only allow a real close when the tray requests shutdown; otherwise minimize to the tray.
    $script:Window.Add_Closing({
        param($sender, $e)
        if (-not $script:AllowClose) {
            $e.Cancel = $true
            $sender.Hide()
        }
    })

    # position window: config overrides, else bottom-right of the screen
    $area = [System.Windows.SystemParameters]::WorkArea
    if ($null -ne $Config.windowX -and $null -ne $Config.windowY) {
        $script:Window.Left = [double]$Config.windowX
        $script:Window.Top = [double]$Config.windowY
    }
    else {
        $script:Window.Left = $area.Right - $script:Window.Width - 8
        $script:Window.Top = $area.Bottom - $script:Window.Height - 8
    }

    $script:Window.Add_MouseLeftButtonDown({
        param($sender, $e)
        if ($e.ClickCount -eq 2 -and $script:State -eq 'run') {
            Switch-PetMusicForm
            $e.Handled = $true
            return
        }
        if ($e.ButtonState -eq [System.Windows.Input.MouseButtonState]::Pressed) {
            try { $script:Window.DragMove() } catch { }
        }
    })
    Initialize-PetInputWatch
    # start in idle (riding the horse)
    Set-PetState -State 'idle'

    return $script:Window
}

function Set-PetTopmost {
    param([bool]$Top)
    $script:TopmostPreferred = $Top
    if ($null -eq $script:Window) { return }
    $script:Window.Topmost = $Top
}

function Show-PetWindow {
    if ($null -eq $script:Window) { return }
    $script:Window.Show()
    $script:Window.Visibility = [System.Windows.Visibility]::Visible
    $script:Window.Topmost = $script:TopmostPreferred
    # Make sure the window is not parked off-screen (e.g. after a display change).
    try {
        $area = [System.Windows.SystemParameters]::WorkArea
        if ($script:Window.Left -gt $area.Right - 10 -or $script:Window.Top -gt $area.Bottom - 10 -or $script:Window.Left -lt -200 -or $script:Window.Top -lt -200) {
            $script:Window.Left = $area.Right - $script:Window.Width - 8
            $script:Window.Top = $area.Bottom - $script:Window.Height - 8
        }
    } catch { }
    try { $script:Window.Activate() } catch { }
    # Bring the no-border window to the foreground reliably.
    try {
        Add-Type -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@ -Name PetWin32 -Namespace Pet -ErrorAction SilentlyContinue
        $hwnd = [System.Windows.Interop.WindowInteropHelper]::new($script:Window).Handle
        if ($hwnd -ne [IntPtr]::Zero) {
            [Pet.PetWin32]::ShowWindow($hwnd, 9) | Out-Null   # SW_RESTORE
            [Pet.PetWin32]::SetForegroundWindow($hwnd) | Out-Null
        }
    } catch { }
}

function Toggle-PetWindow {
    if ($null -eq $script:Window) { return }
    try {
        if ($script:Window.IsVisible) {
            $script:Window.Hide()
        }
        else {
            Show-PetWindow
        }
    }
    catch { }
}

# Reposition the window to the saved coordinates (used when config changes).
function Move-PetWindow {
    param([double]$X, [double]$Y)
    if ($null -eq $script:Window) { return }
    $script:Window.Left = $X
    $script:Window.Top = $Y
}

function Get-PetCurrentState {
    return $script:State
}

function Set-PetAllowClose {
    $script:AllowClose = $true
}

Export-ModuleMember -Function Get-PetAssetPath, New-PetWindow, Set-PetState, Show-PetBubble, Set-PetSign, Set-PetTopmost, Move-PetWindow, Show-PetWindow, Toggle-PetWindow, Get-PetCurrentState, ConvertTo-PetImageSource, Set-PetAllowClose, Set-PetCountdown, Hide-PetCountdown, Initialize-PetInputWatch, Get-PetGlobalActivity
Export-ModuleMember -Function Set-PetMusicCover, Stop-PetMusicState
Export-ModuleMember -Function Update-PetFullscreenVisibility
Export-ModuleMember -Function Set-PetSkin, Get-PetThemedAssetPath
Export-ModuleMember -Function Set-PetContextMenuHandlers, Start-PetInteractionAnimation
