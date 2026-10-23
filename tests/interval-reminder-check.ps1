param([string]$Entry='xiaotaiyang.ps1',[string]$RenderDirectory)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path $PSScriptRoot -Parent
$temp=Join-Path ([IO.Path]::GetTempPath()) ('pet-interval-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
$previousDataDir=$env:XIAOTAIYANG_DATA_DIR
$env:XIAOTAIYANG_DATA_DIR=$temp
$script:Failures=0
function Assert($Value,[string]$Message){if(-not $Value){throw $Message}}
function Check([string]$Name,[scriptblock]$Body){
    try { & $Body; Write-Output "PASS: $Name" }
    catch { $script:Failures++; Write-Output "FAIL: $Name -- $($_.Exception.Message)" }
}
foreach($module in @('PetConfig','PetStore','PetReminder','PetWindow','PetTray','PetTalk','PetMusic','PetAutoStart','PetGrowth')){
    Import-Module (Join-Path $root "modules/$module.psm1") -Force -DisableNameChecking
}
Assert ((Get-PetStorePath) -eq (Join-Path $temp 'todos.json')) '测试必须使用独立存档'
$now=[datetime]'2026-10-23 09:00:00'

# 若请求丢失重复规则，或秒单位误当分钟，本组必须失败。
Check '重复请求保留秒级间隔，原两类仍为一次性' {
    foreach($case in @(@{Seconds=3600;Due='10:00:00'},@{Seconds=4530;Due='10:15:30'},@{Seconds=30;Due='09:00:30'})){
        $request=New-PetReminderRequest -Title '  站起来活动一下  ' -Mode interval -DelaySeconds $case.Seconds -Now $now
        Assert ($request.Title -eq '站起来活动一下' -and $request.DueAt.ToString('HH:mm:ss') -eq $case.Due) '首次提醒或标题错误'
        Assert ($request.Recurrence.Kind -eq 'interval' -and [double]$request.Recurrence.IntervalMinutes -eq ($case.Seconds/60.0)) '重复间隔未保存'
    }
    foreach($request in @((New-PetReminderRequest -Title '开会' -Mode at -At $now.AddHours(2) -Now $now),(New-PetReminderRequest -Title '喝水' -Mode after -DelaySeconds 90 -Now $now))){
        Assert ($null -eq $request.Recurrence) '一次性提醒被变成重复提醒'
    }
}
Check '重复间隔拒绝空值、非有限数和超出七天，边界可保存' {
    foreach($seconds in @(0,-1,[double]::NaN,[double]::PositiveInfinity,604801)){
        $rejected=$false
        try {$null=New-PetReminderRequest -Title '站一下' -Mode interval -DelaySeconds $seconds -Now $now} catch {$rejected=$true}
        Assert $rejected "错误间隔被接受：$seconds"
    }
    $limit=New-PetReminderRequest -Title '每周整理' -Mode interval -DelaySeconds 604800 -Now $now
    Assert ($limit.DueAt -eq [datetime]'2026-10-30 09:00:00' -and $limit.Recurrence.IntervalMinutes -eq 10080) '七天边界错误'
}
Check '菜单间隔文案省略零单位且保留自定义秒数' {
    foreach($case in @(@{Seconds=3600;Text='每1小时'},@{Seconds=4530;Text='每1小时15分钟30秒'},@{Seconds=1800;Text='每30分钟'},@{Seconds=30;Text='每30秒'})){
        Assert ((Format-PetReminderInterval -Seconds $case.Seconds) -eq $case.Text) '间隔文案不准确'
    }
}

# 真正构造、点击和绘制窗口；若模式未接通或默认值污染原模式，本组必须失败。
Check '窗口默认一小时，模式独立保存输入，自定义间隔可提交' {
    $dialog=New-PetReminderDialog
    try {
        $mode=$dialog.Controls.Find('ReminderMode',$true)[0]
        Assert ($mode.Items.Count -eq 3) '缺少每隔一段时间模式'
        $hours=$dialog.Controls.Find('ReminderHours',$true)[0]
        $minutes=$dialog.Controls.Find('ReminderMinutes',$true)[0]
        $seconds=$dialog.Controls.Find('ReminderSeconds',$true)[0]
        $mode.SelectedIndex=1
        Assert ($hours.Value -eq 0 -and $minutes.Value -eq 0 -and $seconds.Value -eq 0) '原多久以后模式默认值改变'
        $minutes.Value=25
        $mode.SelectedIndex=2
        Assert ($hours.Value -eq 1 -and $minutes.Value -eq 0 -and $seconds.Value -eq 0) '重复模式默认不是一小时'
        $minutes.Value=15; $seconds.Value=30
        $mode.SelectedIndex=0; $mode.SelectedIndex=1
        Assert ($hours.Value -eq 0 -and $minutes.Value -eq 25 -and $seconds.Value -eq 0) '重复模式覆盖一次性输入'
        $mode.SelectedIndex=2
        Assert ($hours.Value -eq 1 -and $minutes.Value -eq 15 -and $seconds.Value -eq 30) '切换模式丢失重复输入'
        $dialog.Controls.Find('ReminderTitle',$true)[0].Text='站起来活动一下'
        $save=$dialog.Controls.Find('SaveReminder',$true)[0]
        $click=[Windows.Forms.Button].GetMethod('OnClick',[Reflection.BindingFlags]'Instance,NonPublic')
        $hours.Value=0; $minutes.Value=0; $seconds.Value=0
        $click.Invoke($save,[object[]]@([EventArgs]::Empty)) | Out-Null
        Assert ($null -eq $dialog.Tag -and $dialog.Controls.Find('ReminderError',$true)[0].Text.Length -gt 0) '窗口接受零间隔'
        $hours.Value=1; $minutes.Value=15; $seconds.Value=30
        $dialog.Controls.Find('ReminderError',$true)[0].Text=''
        $dialog.ShowInTaskbar=$false; $dialog.StartPosition='Manual'
        $dialog.Location=New-Object Drawing.Point(-10000,-10000)
        $dialog.Show(); $dialog.PerformLayout(); [Windows.Forms.Application]::DoEvents()
        Assert ($hours.Visible -and $minutes.Visible -and $seconds.Visible) '重复模式没有显示间隔控件'
        Assert ($seconds.Bottom -lt $save.Parent.Top -or $seconds.Parent.Bottom -lt $save.Parent.Top) '间隔控件遮挡按钮'
        $bitmap=New-Object Drawing.Bitmap($dialog.Width,$dialog.Height)
        try {
            $dialog.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$dialog.Width,$dialog.Height)))
            $renderRoot=if($RenderDirectory){$RenderDirectory}else{$temp}
            if(-not (Test-Path -LiteralPath $renderRoot)){New-Item -ItemType Directory -Path $renderRoot | Out-Null}
            $renderPath=Join-Path $renderRoot '重复提醒窗口.png'
            if(Test-Path -LiteralPath $renderPath){throw '渲染图已存在，不覆盖'}
            $bitmap.Save($renderPath)
        } finally {$bitmap.Dispose()}
        $before=Get-Date
        $click.Invoke($save,[object[]]@([EventArgs]::Empty)) | Out-Null
        Assert ($null -ne $dialog.Tag -and $dialog.Tag.Recurrence.Kind -eq 'interval') '有效重复提醒未提交'
        Assert ($dialog.Tag.Recurrence.IntervalMinutes -eq 75.5 -and [Math]::Abs(($dialog.Tag.DueAt-$before).TotalSeconds-4530) -lt 2) '窗口自定义时间丢失'
    } finally {$dialog.Dispose()}
}

# 使用存档与调度的真实实现，证明漏过多轮后不积压，也不影响待办和一次性提醒。
Check '重复调度仅触发一次并推进，写入重读后持续生效' {
    $store=@{items=@()}
    $repeat=Add-PetItem -Store $store -Item @{title='站起来';type='reminder';dueAt='2026-10-23T10:00:00';recurrence=@{Kind='interval';IntervalMinutes=60}}
    $todo=Add-PetItem -Store $store -Item @{title='保留待办';type='todo';dueAt=$null}
    $one=Add-PetItem -Store $store -Item @{title='一次性提醒';type='reminder';dueAt='2026-10-23T10:00:00'}
    Assert ((Get-PetDueAndAdvance -Store $store -Now $now).Count -eq 0) '提前触发'
    $due=Get-PetDueAndAdvance -Store $store -Now ([datetime]'2026-10-23 10:00:00')
    Assert ($due.Count -eq 2 -and -not $repeat.completed -and $repeat.dueAt -eq '2026-10-23T11:00:00.0000000' -and $one.completed) '重复规则没有推进或误改一次性提醒'
    Assert ((Get-PetDueAndAdvance -Store $store -Now ([datetime]'2026-10-23 10:00:01')).Count -eq 0) '同一轮重复触发'
    Write-PetStore -Store $store
    $reloaded=Get-PetStore
    $next=Get-PetDueAndAdvance -Store $reloaded -Now ([datetime]'2026-10-23 11:00:00')
    Assert ($next.Count -eq 1 -and $next[0].id -eq $repeat.id) '重新读取后重复提醒不生效'
    Assert (@($reloaded.items | Where-Object {$_.id -eq $todo.id -and -not $_.completed}).Count -eq 1) '重复提醒改了待办'
    $late=Get-PetDueAndAdvance -Store $reloaded -Now ([datetime]'2026-10-23 15:30:00')
    Assert ($late.Count -eq 1 -and $late[0].dueAt -eq '2026-10-23T16:30:00.0000000') '休眠错过多轮未合并，或未从本次提醒重新计时'
    Assert ((Get-PetDueAndAdvance -Store $reloaded -Now ([datetime]'2026-10-23 15:30:01')).Count -eq 0) '休眠恢复后连续补发'
}
Check '启动错过多轮最多补一次，再重新计时' {
    $store=@{items=@()}
    $repeat=Add-PetItem -Store $store -Item @{title='站起来';type='reminder';dueAt='2026-10-22T09:00:00';recurrence=@{Kind='interval';IntervalMinutes=60}}
    $missed=Invoke-PetCatchUp -Store $store -Now $now
    Assert ($missed.Count -eq 1 -and -not $repeat.completed -and $repeat.dueAt -eq '2026-10-23T10:00:00.0000000') '启动未合并漏发提醒'
    Write-PetStore -Store $store
    $reloaded=Get-PetStore
    Assert ((Invoke-PetCatchUp -Store $reloaded -Now $now).Count -eq 0) '重新启动重复补发'
    Assert ((Get-PetDueAndAdvance -Store $reloaded -Now ([datetime]'2026-10-23 10:00:00')).Count -eq 1) '补发后未继续下一轮'
}

$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root $Entry),[ref]$tokens,[ref]$errors)
Assert ($errors.Count -eq 0) '入口解析失败'
foreach($node in $ast.EndBlock.Statements){
    if($node -is [Management.Automation.Language.FunctionDefinitionAst]){. ([scriptblock]::Create($node.Extent.Text))}
}
$script:Config=@{topmost=$false;windowX=-1000;windowY=-1000;music=$false;voice=$false;autoStart=$false;idleChatter=$false;sleepAfterMin=3;skinId='original'}
$script:Store=@{items=@()}; $null=Initialize-PetGrowth -Store $script:Store
$script:LastInteraction=Get-Date; $script:LastGrowthPersist=Get-Date
$script:ShuttingDown=$false; $script:AlertLock=$false; $script:AlertUntil=[datetime]::MinValue
$script:ManualSleep=$false; $script:MusicReady=$false; $script:IdleChatterCount=0
$script:PeakStreak=0; $script:MusicSilenceSince=$null; $script:DisplayedMusicKey=''
function Get-PetGlobalActivity {return $false}
function Test-PetMusicPlaying {return $false}
# 系统通知与扬声器是外部边界；提醒内容、保存、菜单和推进逻辑仍执行生产实现。
function Show-PetTrayNotification {param($Title,$Text) $script:Notices+=,$Text}
function Invoke-PetSpeak {param($Text,$Enabled)}
$script:Notices=@()
$script:Window=New-PetWindow -Config $script:Config
$trayNode=$ast.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$script:Tray'} | Select-Object -First 1
. ([scriptblock]::Create($trayNode.Extent.Text))
try {
    Check '真实提醒菜单保存重复规则，显示间隔和下次时间，不进入待办' {
        $menu=$script:Tray.ContextMenuStrip.Items | Where-Object Text -eq '提醒' | Select-Object -First 1
        # 用完整请求替代模态等待，实际执行菜单的点击与入口保存回调。
        $request=[pscustomobject]@{Title='站起来活动一下';DueAt=(Get-Date).AddHours(1);Recurrence=@{Kind='interval';IntervalMinutes=60}}
        & (Get-Module PetTray) {
            param($response,$addItem)
            $script:IntervalTestResponse=$response
            function script:Show-PetReminderDialog {return $script:IntervalTestResponse}
            $addItem.PerformClick()
        } $request $menu.DropDownItems[0]
        $script:Store=Get-PetStore
        Assert ($script:Store.items.Count -eq 1 -and $script:Store.items[0].recurrence.Kind -eq 'interval') '菜单或入口丢失重复规则'
        Assert ([Math]::Abs(([datetime]::Parse($script:Store.items[0].dueAt)-(Get-Date)).TotalSeconds-3600) -lt 3) '首次提醒不是一小时后'
        Update-PetReminderMenu; Update-PetTodoMenu
        $entry=@($menu.DropDownItems | Where-Object {$_.Tag})[0]
        Assert ($entry.Text.Contains('每1小时') -and $entry.ToolTipText.Contains('下次')) '菜单没有间隔或下次提醒时间'
        $todoMenu=$script:Tray.ContextMenuStrip.Items | Where-Object Text -eq '我的待办' | Select-Object -First 1
        Assert (@($todoMenu.DropDownItems | Where-Object {$_.Tag -eq $script:Store.items[0].id}).Count -eq 0) '重复提醒混入待办'
        $script:SavedRepeatId=$script:Store.items[0].id
    }
    Check '实际触发后保存下一轮且不增加亲密度' {
        $repeat=@($script:Store.items | Where-Object {$_.recurrence})[0]
        $repeat.dueAt=(Get-Date).AddHours(-4).ToString('o')
        $points=$script:Store.growth.intimacy
        $script:LastInteraction=(Get-Date).AddMinutes(-3)
        $before=Get-Date
        Invoke-PetTick
        Assert ($script:Notices.Count -eq 1 -and $script:Notices[0] -eq '站起来活动一下') '没有发送一次实际提醒'
        Assert ((Get-PetCurrentState) -eq 'alert' -and -not $repeat.completed) '重复提醒未显示或变成已完成'
        Assert ([Math]::Abs(([datetime]::Parse($repeat.dueAt)-$before).TotalSeconds-3600) -lt 3) '未从触发时重新计算下一轮'
        Assert ($script:Store.growth.intimacy -eq $points) '自动提醒刷取了亲密度'
        $saved=Get-PetStore
        Assert ($saved.items[0].dueAt -eq $repeat.dueAt -and $saved.items[0].recurrence.IntervalMinutes -eq 60) '下一轮没有持久保存'
        Invoke-PetTick
        Assert ($script:Notices.Count -eq 1) '下一秒再次弹提醒'
    }
} finally {
    Stop-PetTray; Set-PetAllowClose; $script:Window.Close()
    $env:XIAOTAIYANG_DATA_DIR=$previousDataDir
}
Write-Output "INTERVAL REMINDER: $Entry failures=$script:Failures; renders/data=$temp"
if($script:Failures){exit 1}
