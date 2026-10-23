$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'modules/PetWindow.psm1') -Force
$window = New-PetWindow -Config @{topmost=$false;windowX=0;windowY=0}
$window.Show()
function Assert($value, $message) { if (-not $value) { throw $message } }
try {
    Set-PetState run
    Assert ($window.FindName('RecordView').Visibility -eq 'Collapsed') '默认音乐形态应为骑白马'
    Assert ($window.FindName('PetImage').Visibility -eq 'Visible') '默认骑马形态未显示'
    & (Get-Module PetWindow) { Switch-PetMusicForm }
    Assert ($window.FindName('RecordView').Visibility -eq 'Visible') '唱片未显示'
    Assert ($window.FindName('PetImage').Visibility -eq 'Collapsed') '原形态没有隐藏'
    Assert ($window.FindName('RecordRotate').HasAnimatedProperties) '未启动旋转'
    Assert ($window.FindName('RecordDisc').HasAnimatedProperties) '唱片没有从封面后滑出'
    # 实际触发窗口双击事件，验证与拖动处理之间没有冲突。
    $event = [System.Windows.Input.MouseButtonEventArgs]::new([System.Windows.Input.Mouse]::PrimaryDevice, 0, [System.Windows.Input.MouseButton]::Left)
    $event.RoutedEvent = [System.Windows.UIElement]::MouseLeftButtonDownEvent
    $field = [System.Windows.Input.MouseButtonEventArgs].GetField('_count', [Reflection.BindingFlags]'Instance,NonPublic')
    $field.SetValue($event, 2)
    $window.RaiseEvent($event)
    Assert ($window.FindName('RecordView').Visibility -eq 'Collapsed') '双击没有切回骑马'
    Assert (-not $window.FindName('RecordRotate').HasAnimatedProperties) '隐藏后仍旋转'
    $event.Handled = $false
    $window.RaiseEvent($event)
    Assert ($window.FindName('RecordView').Visibility -eq 'Visible') '双击没有切回唱片'
    Stop-PetMusicState
    Assert (-not $window.FindName('RecordRotate').HasAnimatedProperties) '停止后动画未释放'
    Assert ((Get-PetCurrentState) -eq 'music-stopping') '停止后没有进入收回过渡'
    Assert ($window.FindName('RecordDisc').HasAnimatedProperties) '停止后唱片没有向左收回'
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $wait = New-Object System.Windows.Threading.DispatcherTimer
    $wait.Interval = [TimeSpan]::FromMilliseconds(650)
    $wait.Add_Tick({ $wait.Stop(); $frame.Continue = $false })
    $wait.Start()
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    Assert ($window.FindName('RecordView').Visibility -eq 'Collapsed') '收回完成后唱片未隐藏'
    Assert ($window.FindName('PetImage').Visibility -eq 'Visible') '收回完成后默认桌宠未恢复'
    Assert ((Get-PetCurrentState) -eq 'idle') '收回完成后未回到默认状态'
    Set-PetState run
    Assert ($window.FindName('RecordView').Visibility -eq 'Visible') '恢复播放没有保留所选形态'
    # 导出放大预览，检查比例、封面和矢量边缘。
    $window.Width=480; $window.Height=360
    $window.Content.Measure([System.Windows.Size]::new(480,360))
    $window.Content.Arrange([System.Windows.Rect]::new(0,0,480,360))
    $window.Content.UpdateLayout()
    $bitmap=[System.Windows.Media.Imaging.RenderTargetBitmap]::new(480,360,96,96,[System.Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($window.Content)
    $encoder=New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $path=Join-Path ([IO.Path]::GetTempPath()) ('pet-record-preview-'+[guid]::NewGuid().ToString('N')+'.png')
    $stream=[IO.File]::Create($path)
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
    Write-Output "PASS: 音乐形态、双击往返、停止恢复、动画释放；预览：$path"
} finally { Set-PetAllowClose; $window.Close() }
