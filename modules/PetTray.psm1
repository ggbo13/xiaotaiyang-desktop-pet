Set-StrictMode -Version Latest

Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue

$script:Tray = $null
$script:TrayIcon = $null
$script:RestoreHandler = $null
$script:ListAllHandler = $null
$script:IdleHandler = $null
$script:AutoStartHandler = $null
$script:MuteHandler = $null
$script:ExitHandler = $null
$script:MusicToggleHandler = $null
$script:PlayPauseHandler = $null
$script:NextHandler = $null
$script:PrevHandler = $null
$script:TodoProviderHandler = $null
$script:TodoCompleteHandler = $null
$script:TodoDeleteHandler = $null
$script:TodoAddHandler = $null
$script:TodoMenuItem = $null
$script:CountdownPresetHandler = $null
$script:CountdownCustomHandler = $null
$script:CountdownCancelHandler = $null
$script:ReminderAddHandler = $null
$script:ReminderProviderHandler = $null
$script:ReminderDeleteHandler = $null
$script:ReminderMenuItem = $null
$script:InteractionHandler = $null
$script:GrowthWindowHandler = $null

function Show-PetPrompt {
    param([string]$Title, [string]$Prompt, [string]$DefaultValue = '')
    try {
        Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
        return [Microsoft.VisualBasic.Interaction]::InputBox($Prompt, $Title, $DefaultValue)
    }
    catch { return $null }
}

# A minimal mouse-wheel timer editor: hover a field and scroll to adjust it.
function Show-PetCountdownDialog {
    $form = $null
    try {
        $form = New-Object System.Windows.Forms.Form
        $form.Text = '自定义倒计时'
        $form.ClientSize = New-Object System.Drawing.Size(370, 142)
        $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
        $form.MaximizeBox = $false
        $form.MinimizeBox = $false
        $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $form.BackColor = [System.Drawing.Color]::FromArgb(248, 249, 252)

        $hour = New-Object System.Windows.Forms.TextBox
        $hour.Name = 'HourField'; $hour.Text = '00'; $hour.MaxLength = 3; $hour.Tag = 168
        $minute = New-Object System.Windows.Forms.TextBox
        $minute.Name = 'MinuteField'; $minute.Text = '00'; $minute.MaxLength = 2; $minute.Tag = 59
        $second = New-Object System.Windows.Forms.TextBox
        $second.Name = 'SecondField'; $second.Text = '00'; $second.MaxLength = 2; $second.Tag = 59
        foreach ($box in @($hour, $minute, $second)) {
            $box.TextAlign = [System.Windows.Forms.HorizontalAlignment]::Center
            $box.Font = New-Object System.Drawing.Font('Consolas', 29, [System.Drawing.FontStyle]::Regular)
            $box.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
            $box.BackColor = [System.Drawing.Color]::FromArgb(255, 253, 247)
            $box.ForeColor = [System.Drawing.Color]::FromArgb(54, 42, 27)
            $box.ReadOnly = $true
            $box.Cursor = [System.Windows.Forms.Cursors]::SizeNS
        }
        $hour.Location = New-Object System.Drawing.Point(34, 18); $hour.Size = New-Object System.Drawing.Size(78, 54)
        $minute.Location = New-Object System.Drawing.Point(146, 18); $minute.Size = New-Object System.Drawing.Size(78, 54)
        $second.Location = New-Object System.Drawing.Point(258, 18); $second.Size = New-Object System.Drawing.Size(78, 54)
        $colon1 = New-Object System.Windows.Forms.Label
        $colon1.Text = ':'; $colon1.Font = New-Object System.Drawing.Font('Consolas', 27, [System.Drawing.FontStyle]::Bold)
        $colon1.Size = New-Object System.Drawing.Size(18, 54); $colon1.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
        $colon1.Location = New-Object System.Drawing.Point(120, 18)
        $colon2 = New-Object System.Windows.Forms.Label
        $colon2.Text = ':'; $colon2.Font = New-Object System.Drawing.Font('Consolas', 27, [System.Drawing.FontStyle]::Bold)
        $colon2.Size = New-Object System.Drawing.Size(18, 54); $colon2.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
        $colon2.Location = New-Object System.Drawing.Point(232, 18)

        $wheelHandler = {
            param($sender, $e)
            $value = 0
            [void][int]::TryParse($sender.Text, [ref]$value)
            $delta = if ($e.Delta -gt 0) { 1 } else { -1 }
            $value = [Math]::Max(0, [Math]::Min([int]$sender.Tag, $value + $delta))
            $sender.Text = '{0:D2}' -f $value
            $e.Handled = $true
        }
        foreach ($box in @($hour, $minute, $second)) {
            $box.Add_MouseEnter({ param($sender, $e) $sender.Focus() })
            $box.Add_MouseWheel($wheelHandler)
        }

        $start = New-Object System.Windows.Forms.Button
        $start.Text = '开始'
        $start.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $start.BackColor = [System.Drawing.Color]::FromArgb(255, 201, 60)
        $start.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $start.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(218, 163, 20)
        $start.Location = New-Object System.Drawing.Point(104, 96)
        $start.Size = New-Object System.Drawing.Size(78, 30)

        $cancel = New-Object System.Windows.Forms.Button
        $cancel.Text = '取消'
        $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $cancel.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $cancel.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(165, 170, 180)
        $cancel.Location = New-Object System.Drawing.Point(190, 96)
        $cancel.Size = New-Object System.Drawing.Size(78, 30)

        $form.Controls.AddRange([System.Windows.Forms.Control[]]@($hour, $minute, $second, $colon1, $colon2, $start, $cancel))
        $form.AcceptButton = $start
        $form.CancelButton = $cancel
        $form.Add_Shown({ $hour.Focus(); $hour.SelectAll() })
        if ($form.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return $null }

        $h = 0; $m = 0; $s = 0
        if (-not [int]::TryParse($hour.Text.Trim(), [ref]$h) -or -not [int]::TryParse($minute.Text.Trim(), [ref]$m) -or -not [int]::TryParse($second.Text.Trim(), [ref]$s) -or $h -lt 0 -or $h -gt 168 -or $m -lt 0 -or $m -gt 59 -or $s -lt 0 -or $s -gt 59) {
            [System.Windows.Forms.MessageBox]::Show('请正确填写时、分、秒：小时 0–168，分钟和秒 0–59。', '小太阳桌宠') | Out-Null
            return $null
        }
        $seconds = ([double]$h * 3600) + ([double]$m * 60) + [double]$s
        if ($seconds -le 0 -or $seconds -gt 604800) {
            [System.Windows.Forms.MessageBox]::Show('倒计时需大于 0，且不超过 7 天。', '小太阳桌宠') | Out-Null
            return $null
        }
        return $seconds
    }
    catch { return $null }
    finally {
        if ($form) { $form.Dispose() }
    }
}

# Build a small icon from one of the project images for the NotifyIcon.
function New-PetTrayIcon {
    param([string]$ImagePath)
    if (-not (Test-Path $ImagePath)) {
        return [System.Drawing.SystemIcons]::Application
    }
    try {
        $bmp = New-Object System.Drawing.Bitmap $ImagePath
        $hicon = $bmp.GetHicon()
        $script:TrayIcon = [System.Drawing.Icon]::FromHandle($hicon)
        return $script:TrayIcon
    }
    catch {
        return [System.Drawing.SystemIcons]::Application
    }
}

function New-PetTray {
    param(
        [string]$IconPath,
        [scriptblock]$RestoreHandler,
        [scriptblock]$ListAllHandler,
        [scriptblock]$IdleHandler,
        [scriptblock]$AutoStartHandler,
        [scriptblock]$MuteHandler,
        [scriptblock]$ExitHandler,
        [scriptblock]$MusicToggleHandler,
        [scriptblock]$PlayPauseHandler,
        [scriptblock]$NextHandler,
        [scriptblock]$PrevHandler,
        [scriptblock]$TodoProviderHandler,
        [scriptblock]$TodoCompleteHandler,
        [scriptblock]$TodoDeleteHandler,
        [scriptblock]$TodoAddHandler,
        [scriptblock]$CountdownPresetHandler,
        [scriptblock]$CountdownCustomHandler,
        [scriptblock]$CountdownCancelHandler,
        [scriptblock]$ReminderAddHandler,
        [scriptblock]$ReminderProviderHandler,
        [scriptblock]$ReminderDeleteHandler,
        [scriptblock]$InteractionHandler,
        [scriptblock]$GrowthWindowHandler
    )
    $script:Tray = New-Object System.Windows.Forms.NotifyIcon
    $script:Tray.Icon = New-PetTrayIcon -ImagePath $IconPath
    $script:Tray.Text = "小太阳桌宠"
    # Set the preset handler BEFORE building subitems so closures capture it.
    $script:CountdownPresetHandler = $CountdownPresetHandler
    $script:CountdownCustomHandler = $CountdownCustomHandler
    $script:CountdownCancelHandler = $CountdownCancelHandler
    $script:ReminderAddHandler = $ReminderAddHandler
    $script:ReminderProviderHandler = $ReminderProviderHandler
    $script:ReminderDeleteHandler = $ReminderDeleteHandler
    $script:InteractionHandler = $InteractionHandler
    $script:GrowthWindowHandler = $GrowthWindowHandler
    $handler = $script:CountdownPresetHandler

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $restore = New-Object System.Windows.Forms.ToolStripMenuItem "显示小太阳"
    $listAll = New-Object System.Windows.Forms.ToolStripMenuItem "我的待办"
    $listAll.DropDownItems.Add("加载中…") | Out-Null
    $reminders = New-Object System.Windows.Forms.ToolStripMenuItem '提醒'
    $script:ReminderMenuItem = $reminders
    $growthWindow = New-Object System.Windows.Forms.ToolStripMenuItem '成长与外观…'
    $growthWindow.Add_Click({ if ($script:GrowthWindowHandler) { & $script:GrowthWindowHandler | Out-Null } })
    $idle = New-Object System.Windows.Forms.ToolStripMenuItem "打盹"
    $autoStart = New-Object System.Windows.Forms.ToolStripMenuItem "开机启动"
    $mute = New-Object System.Windows.Forms.ToolStripMenuItem "开启语音"
    $musicToggle = New-Object System.Windows.Forms.ToolStripMenuItem "音乐识别"
    $countdown = New-Object System.Windows.Forms.ToolStripMenuItem "倒计时"
    $cdPresets = @(5, 10, 25, 30, 60)
    foreach ($mins in $cdPresets) {
        $label = if ($mins -ge 60) { "{0}小时" -f ($mins / 60) } else { "{0}分钟" -f $mins }
        $sub = New-Object System.Windows.Forms.ToolStripMenuItem $label
        $sub.CheckOnClick = $false
        $capturedMins = $mins
        $sub.Add_Click(({
            if ($handler) { & $handler -Minutes $capturedMins }
        }).GetNewClosure())
        $countdown.DropDownItems.Add($sub) | Out-Null
    }
    $countdown.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
    $customCountdown = New-Object System.Windows.Forms.ToolStripMenuItem '自定义…'
    $customCountdown.Add_Click({
        $seconds = Show-PetCountdownDialog
        if ($null -ne $seconds -and $script:CountdownCustomHandler) { & $script:CountdownCustomHandler -Seconds $seconds | Out-Null }
    })
    $countdown.DropDownItems.Add($customCountdown) | Out-Null
    $countdown.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
    $cancelCountdown = New-Object System.Windows.Forms.ToolStripMenuItem '取消当前倒计时'
    $cancelCountdown.Add_Click({
        if ($script:CountdownCancelHandler) { & $script:CountdownCancelHandler | Out-Null }
    })
    $countdown.DropDownItems.Add($cancelCountdown) | Out-Null
    $seperator1 = New-Object System.Windows.Forms.ToolStripSeparator
    $playPause = New-Object System.Windows.Forms.ToolStripMenuItem "播放 / 暂停"
    $next = New-Object System.Windows.Forms.ToolStripMenuItem "下一首"
    $prev = New-Object System.Windows.Forms.ToolStripMenuItem "上一首"
    $quit = New-Object System.Windows.Forms.ToolStripMenuItem "退出"

    $script:RestoreHandler = $RestoreHandler
    $script:ListAllHandler = $ListAllHandler
    $script:IdleHandler = $IdleHandler
    $script:AutoStartHandler = $AutoStartHandler
    $script:MuteHandler = $MuteHandler
    $script:ExitHandler = $ExitHandler
    $script:MusicToggleHandler = $MusicToggleHandler
    $script:PlayPauseHandler = $PlayPauseHandler
    $script:NextHandler = $NextHandler
    $script:PrevHandler = $PrevHandler
    $script:TodoProviderHandler = $TodoProviderHandler
    $script:TodoCompleteHandler = $TodoCompleteHandler
    $script:TodoDeleteHandler = $TodoDeleteHandler
    $script:TodoAddHandler = $TodoAddHandler
    $script:TodoMenuItem = $listAll

    $restore.Add_Click({ if ($script:RestoreHandler) { & $script:RestoreHandler | Out-Null } })
    $idle.Add_Click({ if ($script:IdleHandler) { & $script:IdleHandler | Out-Null } })
    $autoStart.Add_Click({ if ($script:AutoStartHandler) { & $script:AutoStartHandler | Out-Null } })
    $mute.Add_Click({ if ($script:MuteHandler) { & $script:MuteHandler | Out-Null } })
    $musicToggle.Add_Click({ if ($script:MusicToggleHandler) { & $script:MusicToggleHandler | Out-Null } })
    $playPause.Add_Click({ if ($script:PlayPauseHandler) { & $script:PlayPauseHandler | Out-Null } })
    $next.Add_Click({ if ($script:NextHandler) { & $script:NextHandler | Out-Null } })
    $prev.Add_Click({ if ($script:PrevHandler) { & $script:PrevHandler | Out-Null } })
    $quit.Add_Click({ if ($script:ExitHandler) { & $script:ExitHandler | Out-Null } })

    # Rebuild the "我的待办" submenu each time it opens.
    $listAll.Add_DropDownOpening({ Update-PetTodoMenu })
    $reminders.Add_DropDownOpening({ Update-PetReminderMenu })
    Update-PetReminderMenu

    $menu.Items.AddRange([System.Windows.Forms.ToolStripItem[]]@(
        $restore, $listAll, $reminders, $growthWindow, $idle,
        $autoStart, $mute, $musicToggle, $countdown, $seperator1,
        $playPause, $next, $prev, $quit
    ))
    $script:Tray.ContextMenuStrip = $menu
    # 互动只出现在桌宠本体的右键菜单；托盘保留管理类入口。
    try { Set-PetContextMenuHandlers -InteractionHandler $InteractionHandler -GrowthHandler $GrowthWindowHandler } catch { }

    $script:Tray.Add_MouseDoubleClick({
        if ($script:RestoreHandler) { & $script:RestoreHandler | Out-Null }
    })
    $script:Tray.Visible = $true
    return $script:Tray
}

function Set-PetTrayToggle {
    param(
        [string]$Name,
        [bool]$Checked
    )
    if ($null -eq $script:Tray -or $null -eq $script:Tray.ContextMenuStrip) { return }
    foreach ($item in $script:Tray.ContextMenuStrip.Items) {
        if ($item.Text -eq $Name) {
            # state is conveyed by a check mark
            $item.Checked = $Checked
            return
        }
    }
}

function Update-PetTodoMenu {
    if ($null -eq $script:TodoMenuItem) { return }
    $menu = $script:TodoMenuItem
    $menu.DropDownItems.Clear() | Out-Null
    # GetNewClosure does not capture module-level $script: variables, so copy
    # handlers locally before creating each menu action.
    $completeHandler = $script:TodoCompleteHandler
    $deleteHandler = $script:TodoDeleteHandler
    $addHandler = $script:TodoAddHandler
    $add = New-Object System.Windows.Forms.ToolStripMenuItem '＋ 添加待办…'
    $add.Add_Click({
        $title = Show-PetPrompt -Title '添加待办' -Prompt '请输入待办内容：'
        if (-not [string]::IsNullOrWhiteSpace($title) -and $script:TodoAddHandler) {
            & $script:TodoAddHandler -Title $title.Trim() | Out-Null
        }
    })
    $menu.DropDownItems.Add($add) | Out-Null
    $menu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
    $todos = @()
    if ($script:TodoProviderHandler) {
        $todos = @(& $script:TodoProviderHandler)
    }
    if ($todos.Count -eq 0) {
        $empty = New-Object System.Windows.Forms.ToolStripMenuItem "暂无待办（可从上方添加）"
        $empty.Enabled = $false
        $menu.DropDownItems.Add($empty) | Out-Null
        return
    }
    foreach ($t in $todos) {
        $title = [string]$t.title
        $itemId = [string]$t.id
        $done = [bool]$t.completed
        $overdue = $false
        if ($t.dueAt) {
            try {
                $due = [datetime]::Parse($t.dueAt)
                if (-not $done -and $due -lt (Get-Date)) {
                    $overdue = $true
                    $title = "$title  (已过期)"
                }
                else {
                    $title = "$title  ({0:MM-dd HH:mm:ss})" -f $due
                }
            }
            catch { }
        }
        $item = New-Object System.Windows.Forms.ToolStripMenuItem $title
        $item.CheckOnClick = $false
        if ($done) {
            # Show a check and strike through done items (kept visible so the
            # user can un-check again).
            $item.Text = "√ " + $title
            $item.Font = New-Object System.Drawing.Font($item.Font, [System.Drawing.FontStyle]::Strikeout)
            $item.ForeColor = [System.Drawing.Color]::Gray
        }
        elseif ($overdue) {
            $item.ForeColor = [System.Drawing.Color]::Gray
        }
        # Each item is a submenu: completion is reversible, deletion is a
        # deliberate second action so accidental clicks never lose a task.
        $captured = $itemId
        $completeText = if ($done) { '恢复为未完成' } else { '标记为完成' }
        $complete = New-Object System.Windows.Forms.ToolStripMenuItem $completeText
        $complete.Add_Click(({
            if ($completeHandler) { & $completeHandler -Id $captured | Out-Null }
        }).GetNewClosure())
        $delete = New-Object System.Windows.Forms.ToolStripMenuItem '删除此待办'
        $delete.ForeColor = [System.Drawing.Color]::Firebrick
        $delete.Add_Click(({
            if ($deleteHandler) { & $deleteHandler -Id $captured | Out-Null }
        }).GetNewClosure())
        $item.DropDownItems.AddRange([System.Windows.Forms.ToolStripItem[]]@($complete, (New-Object System.Windows.Forms.ToolStripSeparator), $delete))
        $menu.DropDownItems.Add($item) | Out-Null
    }
}

function Update-PetReminderMenu {
    if ($null -eq $script:ReminderMenuItem) { return }
    $menu = $script:ReminderMenuItem
    $menu.DropDownItems.Clear() | Out-Null
    $menu.DropDown.ShowItemToolTips = $true
    $add = New-Object System.Windows.Forms.ToolStripMenuItem '添加提醒…'
    $add.Add_Click({
        $request = Show-PetReminderDialog
        if ($null -ne $request -and $script:ReminderAddHandler) {
            try { & $script:ReminderAddHandler -Title $request.Title -DueAt $request.DueAt -Recurrence $request.Recurrence | Out-Null }
            catch { [System.Windows.Forms.MessageBox]::Show('提醒未能保存：' + $_.Exception.Message, '小太阳桌宠') | Out-Null }
        }
    })
    $menu.DropDownItems.Add($add) | Out-Null
    $menu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
    $reminders = @()
    if ($script:ReminderProviderHandler) { $reminders = @(& $script:ReminderProviderHandler) }
    if ($reminders.Count -eq 0) {
        $empty = New-Object System.Windows.Forms.ToolStripMenuItem '暂无提醒（可从上方添加）'
        $empty.Enabled = $false
        $menu.DropDownItems.Add($empty) | Out-Null
        return
    }
    $deleteHandler = $script:ReminderDeleteHandler
    foreach ($reminder in $reminders) {
        $title = [string]$reminder.title
        $shortTitle = if ($title.Length -gt 32) { $title.Substring(0, 32) + '…' } else { $title }
        $status = if ($reminder.completed) { '已提醒' } else { '待提醒' }
        $dueText = ''
        if ($reminder.dueAt) {
            try { $dueText = ([datetime]::Parse($reminder.dueAt)).ToString('yyyy-MM-dd HH:mm:ss') } catch { }
        }
        $label = '删除提醒｜[{0}] {1}  {2}' -f $status, $dueText, $shortTitle.Replace('&', '&&')
        $intervalText=''
        # 早期存档没有重复字段，按一次性提醒展示，不补写或改动旧数据。
        $recurrence=if($reminder -is [System.Collections.IDictionary]){$reminder['recurrence']}elseif($reminder.PSObject.Properties['recurrence']){$reminder.recurrence}
        if(-not $reminder.completed -and $recurrence -and $recurrence.Kind -eq 'interval'){
            $intervalText=Format-PetReminderInterval -Seconds ([double]$recurrence.IntervalMinutes * 60)
            $label='删除提醒｜[{0}] 下次 {1}  {2}' -f $intervalText,$dueText,$shortTitle.Replace('&','&&')
        }
        $item = New-Object System.Windows.Forms.ToolStripMenuItem $label
        $item.Tag = [string]$reminder.id
        $item.ToolTipText = "{0}`n{1} {2}`n点击删除此提醒" -f $title, $status, $dueText
        if($intervalText){$item.ToolTipText="{0}`n{1} · 下次 {2}`n点击删除此提醒" -f $title,$intervalText,$dueText}
        $item.ForeColor = if ($reminder.completed) {
            [System.Drawing.Color]::Gray
        } else {
            [System.Drawing.Color]::Firebrick
        }
        $capturedId = [string]$reminder.id
        # 删除操作直接放在提醒二级菜单，不再创建会向左展开的第三级菜单。
        $item.Add_Click(({
            if ($deleteHandler) {
                try { & $deleteHandler -Id $capturedId | Out-Null }
                catch { [System.Windows.Forms.MessageBox]::Show('提醒未能删除：' + $_.Exception.Message, '小太阳桌宠') | Out-Null }
            }
        }).GetNewClosure())
        $menu.DropDownItems.Add($item) | Out-Null
    }
}

function Show-PetTrayNotification {
    param([string]$Title, [string]$Text)
    if ($null -eq $script:Tray) { return }
    try {
        $script:Tray.ShowBalloonTip(10000, $Title, $Text, [System.Windows.Forms.ToolTipIcon]::Info)
    } catch { }
}

function Stop-PetTray {
    if ($script:Tray) {
        try { $script:Tray.Visible = $false } catch { }
        try { $script:Tray.Dispose() } catch { }
        $script:Tray = $null
    }
}

Export-ModuleMember -Function New-PetTray, Stop-PetTray, Set-PetTrayToggle, Update-PetTodoMenu, Update-PetReminderMenu, Show-PetTrayNotification
