Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

function New-PetReminderRequest {
    param(
        [string]$Title,
        [ValidateSet('at','after','interval')][string]$Mode,
        [datetime]$At = [datetime]::MinValue,
        [double]$DelaySeconds = 0,
        [datetime]$Now = (Get-Date)
    )
    if ([string]::IsNullOrWhiteSpace($Title)) { throw '请填写要提醒的事情。' }
    if ($Title.Trim().Length -gt 120) { throw '提醒内容请控制在 120 字以内。' }
    if ($Mode -in @('after','interval')) {
        if ([double]::IsNaN($DelaySeconds) -or [double]::IsInfinity($DelaySeconds) -or $DelaySeconds -le 0 -or $DelaySeconds -gt 604800) {
            throw '请设置大于零、且不超过 7 天的时间间隔。'
        }
        $due = $Now.AddSeconds($DelaySeconds)
    }
    else {
        if ($At -le $Now) { throw '指定时间必须晚于当前时间，请检查日期和时间。' }
        $due = $At
    }
    $recurrence = if ($Mode -eq 'interval') { @{ Kind='interval'; IntervalMinutes=$DelaySeconds / 60.0 } } else { $null }
    return [pscustomobject]@{ Title=$Title.Trim(); DueAt=$due; Recurrence=$recurrence }
}

function Format-PetReminderInterval {
    param([double]$Seconds)
    $total=[long][Math]::Round($Seconds)
    $hours=[long][Math]::Floor($total / 3600)
    $minutes=[long][Math]::Floor(($total % 3600) / 60)
    $secondsLeft=$total % 60
    $parts=@()
    if($hours -gt 0){$parts+="${hours}小时"}
    if($minutes -gt 0){$parts+="${minutes}分钟"}
    if($secondsLeft -gt 0 -or $parts.Count -eq 0){$parts+="${secondsLeft}秒"}
    return ('每'+($parts -join ''))
}

function New-PetReminderDialog {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = '添加提醒'
    $form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Font
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox=$false; $form.MinimizeBox=$false
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.BackColor = [System.Drawing.Color]::FromArgb(248,249,252)
    $form.AutoSize=$true
    $form.AutoSizeMode=[System.Windows.Forms.AutoSizeMode]::GrowAndShrink

    $layout=New-Object System.Windows.Forms.TableLayoutPanel
    $layout.Padding=New-Object System.Windows.Forms.Padding(22)
    $layout.AutoSize=$true; $layout.ColumnCount=1
    $layout.Dock=[System.Windows.Forms.DockStyle]::Fill
    $layout.MinimumSize=New-Object System.Drawing.Size(450,0)

    $label=New-Object System.Windows.Forms.Label
    $label.Text='提醒我做什么'; $label.AutoSize=$true
    $label.Margin=New-Object System.Windows.Forms.Padding(0,0,0,8)
    $title=New-Object System.Windows.Forms.TextBox
    $title.Name='ReminderTitle'; $title.MaxLength=120; $title.Dock='Fill'
    $title.Margin=New-Object System.Windows.Forms.Padding(0,0,0,16)

    $mode=New-Object System.Windows.Forms.ComboBox
    $mode.Name='ReminderMode'; $mode.DropDownStyle='DropDownList'
    $mode.Items.AddRange([object[]]@('指定日期和时间','多久以后','每隔一段时间'))
    $mode.SelectedIndex=0; $mode.Dock='Fill'
    $mode.Margin=New-Object System.Windows.Forms.Padding(0,0,0,12)

    $atPanel=New-Object System.Windows.Forms.FlowLayoutPanel
    $atPanel.AutoSize=$true; $atPanel.WrapContents=$false; $atPanel.Dock='Fill'
    $atPanel.Margin=New-Object System.Windows.Forms.Padding(0,0,0,8)
    $date=New-Object System.Windows.Forms.DateTimePicker
    $date.Name='ReminderDate'; $date.Format='Custom'; $date.CustomFormat='yyyy-MM-dd'
    $date.Width=190; $date.Margin=New-Object System.Windows.Forms.Padding(0,0,12,0)
    $time=New-Object System.Windows.Forms.DateTimePicker
    $time.Name='ReminderTime'; $time.Format='Custom'; $time.CustomFormat='HH:mm:ss'
    $time.ShowUpDown=$true; $time.Width=185; $time.Margin=New-Object System.Windows.Forms.Padding(0)
    $initial=(Get-Date).AddMinutes(5); $date.Value=$initial; $time.Value=$initial
    $atPanel.Controls.AddRange([System.Windows.Forms.Control[]]@($date,$time))

    $afterPanel=New-Object System.Windows.Forms.TableLayoutPanel
    $afterPanel.AutoSize=$true; $afterPanel.ColumnCount=3; $afterPanel.Dock='Fill'
    $afterPanel.Margin=New-Object System.Windows.Forms.Padding(0,0,0,8)
    $fields=@()
    foreach ($unit in @('小时','分钟','秒')) {
        $index=$fields.Count
        $null=$afterPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent,33.333)))
        $unitLabel=New-Object System.Windows.Forms.Label
        $unitLabel.Text=$unit; $unitLabel.AutoSize=$true
        $field=New-Object System.Windows.Forms.NumericUpDown
        $field.Name=@('ReminderHours','ReminderMinutes','ReminderSeconds')[$index]
        $field.Maximum=if ($index -eq 0) {168} else {59}
        $field.Font=New-Object System.Drawing.Font('Consolas',18)
        $field.TextAlign='Center'; $field.Dock='Fill'; $field.Value=0
        $afterPanel.Controls.Add($unitLabel,$index,0)
        $afterPanel.Controls.Add($field,$index,1)
        $fields+=,$field
    }
    $afterPanel.Visible=$false
    $errorLabel=New-Object System.Windows.Forms.Label
    $errorLabel.Name='ReminderError'; $errorLabel.AutoSize=$true
    $errorLabel.MaximumSize=New-Object System.Drawing.Size(400,0)
    $errorLabel.ForeColor=[System.Drawing.Color]::Firebrick
    $errorLabel.Margin=New-Object System.Windows.Forms.Padding(0,4,0,4)

    $actions=New-Object System.Windows.Forms.FlowLayoutPanel
    $actions.AutoSize=$true; $actions.FlowDirection='RightToLeft'; $actions.Dock='Fill'
    $actions.Margin=New-Object System.Windows.Forms.Padding(0,12,0,0)
    $cancel=New-Object System.Windows.Forms.Button
    $cancel.Text='取消'; $cancel.AutoSize=$true; $cancel.DialogResult='Cancel'
    $save=New-Object System.Windows.Forms.Button
    $save.Name='SaveReminder'; $save.Text='添加提醒'; $save.AutoSize=$true
    $save.BackColor=[System.Drawing.Color]::FromArgb(255,201,60)
    $save.FlatStyle='Flat'; $save.Padding=New-Object System.Windows.Forms.Padding(10,3,10,3)
    $cancel.Padding=$save.Padding
    $actions.Controls.AddRange([System.Windows.Forms.Control[]]@($cancel,$save))
    foreach ($control in @($label,$title,$mode,$atPanel,$afterPanel,$errorLabel,$actions)) {
        $layout.Controls.Add($control)
    }
    $form.Controls.Add($layout)
    $form.AcceptButton=$save; $form.CancelButton=$cancel
    # 两种时长共用控件，但各自保留输入，重复提醒首次默认一小时。
    $durationState=@{ Index=0; After=@(0,0,0); Interval=@(1,0,0) }
    $mode.Add_SelectedIndexChanged(({
        if($durationState.Index -in @(1,2)){
            $previousKey=if($durationState.Index -eq 1){'After'}else{'Interval'}
            $durationState[$previousKey]=@($fields | ForEach-Object {$_.Value})
        }
        $durationState.Index=$mode.SelectedIndex
        if($mode.SelectedIndex -in @(1,2)){
            $nextKey=if($mode.SelectedIndex -eq 1){'After'}else{'Interval'}
            for($i=0;$i -lt $fields.Count;$i++){$fields[$i].Value=$durationState[$nextKey][$i]}
        }
        $atPanel.Visible=($mode.SelectedIndex -eq 0)
        $afterPanel.Visible=($mode.SelectedIndex -in @(1,2))
        $errorLabel.Text=''
    }).GetNewClosure())
    $save.Add_Click(({
        try {
            if ($mode.SelectedIndex -eq 0) {
                $at=$date.Value.Date.Add($time.Value.TimeOfDay)
                $request=New-PetReminderRequest -Title $title.Text -Mode at -At $at
            }
            else {
                $seconds=[double]$fields[0].Value*3600 + [double]$fields[1].Value*60 + [double]$fields[2].Value
                $requestMode=if($mode.SelectedIndex -eq 2){'interval'}else{'after'}
                $request=New-PetReminderRequest -Title $title.Text -Mode $requestMode -DelaySeconds $seconds
            }
            $form.Tag=$request
            $form.DialogResult=[System.Windows.Forms.DialogResult]::OK
        }
        catch { $errorLabel.Text=$_.Exception.Message }
    }).GetNewClosure())
    $form.Add_Shown(({ [void]$title.Focus() }).GetNewClosure())
    return $form
}

function Show-PetReminderDialog {
    $form=New-PetReminderDialog
    try {
        if ($form.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $form.Tag }
        return $null
    }
    finally { $form.Dispose() }
}

Export-ModuleMember -Function New-PetReminderRequest, New-PetReminderDialog, Show-PetReminderDialog, Format-PetReminderInterval
