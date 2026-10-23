# Table-driven tests for the intent parser. Exit code non-zero on any failure.
Set-StrictMode -Version Latest

$root = Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent
Import-Module (Join-Path $root "modules\PetIntent.psm1") -Force

$Now = Get-Date '2026-08-24 09:00:00'

$cases = @(
    @{ Text='倒计时90秒'; Action='start_countdown'; Check={ param($p) $p.seconds -eq 90 } }
    @{ Text='倒计时45分钟'; Action='start_countdown'; Check={ param($p) $p.seconds -eq 2700 } }
    @{ Text='倒计时2小时'; Action='start_countdown'; Check={ param($p) $p.seconds -eq 7200 } }
    @{ Text='倒计时半小时'; Action='start_countdown'; Check={ param($p) $p.seconds -eq 1800 } }
    @{ Text='倒计时1小时30分钟'; Action='start_countdown'; Check={ param($p) $p.seconds -eq 5400 } }
    @{ Text='倒计时1小时30分钟45秒'; Action='start_countdown'; Check={ param($p) $p.seconds -eq 5445 } }
    @{ Text='倒计时25分钟'; Action='start_countdown'; Check={ param($p) $p.seconds -eq 1500 -and "$($p.label)" -eq '25分钟' } }
    @{ Text='删除倒计时'; Action='delete_countdown'; Check={ param($p) $true } }
    @{ Text='添加买牛奶到待办'; Action='add_reminder'; Check={ param($p) "$($p.title)" -eq '买牛奶' -and $null -eq $p.dueAt -and $null -eq $p.recurrence } }
    @{ Text='删除待办买牛奶'; Action='delete'; Check={ param($p) "$($p.target)" -eq '买牛奶' } }
    @{ Text='14:30提醒我周报'; Action='add_reminder'; Check={ param($p) "$($p.title)" -eq '周报' -and ([datetime]::Parse($p.dueAt)).Date -eq $Now.Date -and $null -eq $p.recurrence } }
    @{ Text='09:05提醒我开会'; Action='add_reminder'; Check={ param($p) "$($p.title)" -eq '开会' -and ([datetime]::Parse($p.dueAt)).Hour -eq 9 -and ([datetime]::Parse($p.dueAt)).Minute -eq 5 } }
    @{ Text='列出所有待办'; Action='list_all'; Check={ param($p) $true } }
    @{ Text='这周的任务有哪些？'; Action='list_week'; Check={ param($p) $true } }
    @{ Text='你好呀'; Action='chat'; Check={ param($p) "$($p.text)" -eq '你好呀' } }
)

$fail = 0
foreach ($c in $cases) {
    $r = Invoke-PetParse -Text $c.Text -Now $Now
    $pass = ($null -ne $r) -and ($r.action -eq $c.Action) -and (& $c.Check $r.params)
    if ($pass) {
        Write-Output ("PASS  {0,-24} -> {1}" -f $c.Text, $c.Action)
    }
    else {
        $fail++
        $p = if ($r) { $r.params | ConvertTo-Json -Compress -Depth 6 } else { '<null>' }
        Write-Output ("FAIL  {0,-24} expected={1} got={2} params={3}" -f $c.Text, $c.Action, $r.action, $p)
    }
}

Write-Output ""
if ($fail -eq 0) {
    Write-Output "ALL PASS ($($cases.Count) cases)"
}
else {
    Write-Output "FAILED: $fail case(s)"
}
if ($fail -ne 0) { exit 1 }
