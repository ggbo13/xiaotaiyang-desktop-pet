Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'PetPaths.psm1') -Force -Scope Local
$script:DataRoot = Get-PetDataRoot -ApplicationRoot (Split-Path $PSScriptRoot -Parent)
$script:StorePath = Join-Path $script:DataRoot 'todos.json'

function Get-PetStorePath {
    return $script:StorePath
}

# Recursively convert PSCustomObject (from ConvertFrom-Json) into a hashtable,
# so downstream hashtable semantics (ContainsKey, index access) work on PS 5.1.
function ConvertTo-PetHashtable {
    param([object]$InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in $InputObject.Keys) {
            $h[$k] = ConvertTo-PetHashtable -InputObject $InputObject[$k]
        }
        return $h
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        # keep single-element arrays as arrays (the unary comma preserves an array)
        return ,@($InputObject | ForEach-Object { ConvertTo-PetHashtable -InputObject $_ })
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($prop in $InputObject.PSObject.Properties) {
            $h[$prop.Name] = ConvertTo-PetHashtable -InputObject $prop.Value
        }
        return $h
    }
    return $InputObject
}

function Get-PetStore {
    param([string]$Path = $script:StorePath)
    if (-not (Test-Path $Path)) {
        return @{ items = @(); growth = $null }
    }
    try {
        $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        $data = ConvertTo-PetHashtable -InputObject ($raw | ConvertFrom-Json)
        if (-not $data.ContainsKey('items')) { $data['items'] = @() }
        # Older versions saved reminders as timed todos. Normalize in memory;
        # the next normal save persists the type without changing their schedule.
        foreach ($item in @($data['items'])) {
            if ($item -isnot [System.Collections.IDictionary]) { continue }
            if (-not $item['type']) { $item['type'] = 'todo' }
            if ($item['type'] -eq 'todo' -and $item['dueAt']) {
                $item['type'] = 'reminder'
            }
        }
        return $data
    }
    catch {
        return @{ items = @(); growth = $null }
    }
}

function Write-PetStore {
    param(
        [hashtable]$Store,
        [string]$Path = $script:StorePath
    )
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $json = $Store | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($true)))
}

function New-PetItemId {
    return [guid]::NewGuid().ToString('N')
}

function Add-PetItem {
    param(
        [hashtable]$Store,
        [hashtable]$Item
    )
    $Item['id'] = New-PetItemId
    $Item['createdAt'] = (Get-Date).ToString('o')
    if (-not $Item.ContainsKey('completed')) { $Item['completed'] = $false }
    if (-not $Item.ContainsKey('lastFiredAt')) { $Item['lastFiredAt'] = $null }
    if (-not $Item.ContainsKey('type')) { $Item['type'] = 'todo' }
    if (-not $Item.ContainsKey('duration')) { $Item['duration'] = $null }
    if (-not $Item.ContainsKey('durationSeconds')) { $Item['durationSeconds'] = $null }
    if (-not $Item.ContainsKey('recurrence')) { $Item['recurrence'] = $null }
    $Store['items'] = @($Store['items']) + $Item
    return $Item
}

function Remove-PetItem {
    param(
        [hashtable]$Store,
        [string]$Id
    )
    $Store['items'] = @($Store['items'] | Where-Object { $_.id -ne $Id })
}

function Set-PetItemCompleted {
    param(
        [hashtable]$Store,
        [string]$Id,
        [bool]$Completed = $true
    )
    foreach ($it in @($Store['items'])) {
        if ($it.id -eq $Id) { $it['completed'] = $Completed }
    }
}

function Find-PetItemsByTarget {
    param(
        [hashtable]$Store,
        [string]$Target
    )
    $needle = $Target.Trim().ToLowerInvariant()
    $matches = @($Store['items'] | Where-Object {
        (-not $_.completed) -and (
            $_.title -and $_.title.ToLowerInvariant() -like "*$needle*"
        )
    })
    return ,$matches
}

function Get-PetActiveCountdown {
    param([hashtable]$Store)
    $found = @($Store['items'] | Where-Object { $_.type -eq 'countdown' -and -not $_.completed })
    if ($found.Count -gt 0) { return $found[0] }
    return $null
}

function Remove-PetCountdown {
    param([hashtable]$Store)
    $Store['items'] = @($Store['items'] | Where-Object { $_.type -ne 'countdown' -or $_.completed })
}

function Get-PetCountdownRemaining {
    param([object]$Item)
    if ($null -eq $Item -or -not $Item.dueAt) { return 0 }
    try {
        $due = [datetime]::Parse($Item.dueAt)
        $span = $due - (Get-Date)
        if ($span.TotalSeconds -le 0) { return 0 }
        return [math]::Ceiling($span.TotalSeconds)
    }
    catch {
        return 0
    }
}

function Format-PetCountdownDuration {
    param([double]$Seconds)
    $total = [long][Math]::Round([Math]::Max(0, $Seconds))
    $hours = [long][Math]::Floor($total / 3600)
    $minutes = [long][Math]::Floor(($total % 3600) / 60)
    $secondsLeft = [long]($total % 60)
    # 有小时就读全三项；没有小时则省略未设置的前导单位。
    if ($hours -gt 0) { return "${hours}小时${minutes}分钟${secondsLeft}秒" }
    if ($minutes -gt 0) {
        if ($secondsLeft -gt 0) { return "${minutes}分钟${secondsLeft}秒" }
        return "${minutes}分钟"
    }
    return "${secondsLeft}秒"
}

function Get-PetDueSpeechText {
    param([object[]]$Items)
    $parts = @($Items | ForEach-Object {
        $item = $_
        if ($item.type -ne 'countdown') { return [string]$item.title }
        $duration = $null
        if ($null -ne $item.durationSeconds) {
            $duration = [double]$item.durationSeconds
        }
        elseif ([string]$item.title -match '(\d{1,3}):(\d{2}):(\d{2})') {
            # 兼容旧记录中只保存了数字时分秒标题的倒计时。
            $duration = [double]([int]$Matches[1] * 3600 + [int]$Matches[2] * 60 + [int]$Matches[3])
        }
        if ($null -eq $duration) { return [string]$item.title }
        return ('{0}倒计时结束了' -f (Format-PetCountdownDuration -Seconds $duration))
    })
    return ('到时间啦，{0}。' -f ($parts -join '、'))
}

# Compute the next occurrence of a recurring item strictly after $now (or at $after if supplied).
function Resolve-PetNextOccurrence {
    param(
        [hashtable]$Recur,
        [datetime]$Now,
        [object]$After = $null
    )
    $start = if ($After) { $After } else { $Now }
    $base = $start
    $kind = $Recur.Kind
    if ($kind -eq 'interval') {
        return $Now.AddMinutes([double]$Recur.IntervalMinutes)
    }
    if ($kind -eq 'daily') {
        $cand = $Now.Date.AddHours([double]$Recur.Hour).AddMinutes([double]$Recur.Minute)
        if ($cand -le $Now) { $cand = $cand.AddDays(1) }
        return $cand
    }
    if ($kind -eq 'weekly') {
        $wd = [int]$Recur.DayOfWeek
        $cand = $Now.Date.AddHours([double]$Recur.Hour).AddMinutes([double]$Recur.Minute)
        $diff = (($wd - [int]$cand.DayOfWeek) % 7 + 7) % 7
        $cand = $cand.AddDays($diff)
        if ($cand -le $Now) { $cand = $cand.AddDays(7) }
        return $cand
    }
    if ($kind -eq 'monthly') {
        $day = [int]$Recur.DayOfMonth
        $cand = $Now.Date.AddHours([double]$Recur.Hour).AddMinutes([double]$Recur.Minute)
        # build this month's candidate; clamp to last day for short months
        $month = $cand.Month
        $year = $cand.Year
        $lastDay = [datetime]::DaysInMonth($year, $month)
        $d = [Math]::Min($day, $lastDay)
        try { $cand = Get-Date -Year $year -Month $month -Day $d -Hour $cand.Hour -Minute $cand.Minute -Second 0 }
        catch { return $null }
        if ($cand -le $Now) {
            $next = $cand.AddMonths(1)
            $nLast = [datetime]::DaysInMonth($next.Year, $next.Month)
            $nd = [Math]::Min($day, $nLast)
            try { $cand = Get-Date -Year $next.Year -Month $next.Month -Day $nd -Hour $cand.Hour -Minute $cand.Minute -Second 0 }
            catch { return $null }
        }
        return $cand
    }
    return $null
}

# Return items that are due (uncompleted, dueAt <= now, and not already fired for this dueAt).
# Also advances recurring items and marks fired single items, mutating $Store.
function Get-PetDueAndAdvance {
    param(
        [hashtable]$Store,
        [datetime]$Now
    )
    $due = [System.Collections.ArrayList]@()
    foreach ($it in @($Store['items'])) {
        if ($it.completed) { continue }
        $dueAt = $null
        if ($it.dueAt) { $dueAt = [datetime]::Parse($it.dueAt) }
        if ($null -eq $dueAt) { continue }
        if ($dueAt -gt $Now) { continue }
        # avoid double-firing (single item already reminded for this dueAt)
        $last = $null
        if ($it.lastFiredAt) { $last = [datetime]::Parse($it.lastFiredAt) }
        if ($null -ne $last -and $last -ge $dueAt) { continue }

        $null = $due.Add($it)
        $it['lastFiredAt'] = $Now.ToString('o')
        if ($it.recurrence) {
            $next = Resolve-PetNextOccurrence -Recur $it.recurrence -Now $Now
            if ($null -ne $next) {
                $it['dueAt'] = $next.ToString('o')
            }
            else {
                $it['completed'] = $true
            }
        }
        else {
            # single fire: mark complete after reminding
            $it['completed'] = $true
        }
    }
    return ,$due.ToArray()
}

function Invoke-PetCatchUp {
    param(
        [hashtable]$Store,
        [datetime]$Now
    )
    # Called on startup: if items were due while the app was closed, reschedule recurring ones
    # to the next occurrence and collect one-off missed items for a summary.
    $missed = [System.Collections.ArrayList]@()
    foreach ($it in @($Store['items'])) {
        if ($it.completed) { continue }
        $dueAt = $null
        if ($it.dueAt) { $dueAt = [datetime]::Parse($it.dueAt) }
        if ($null -eq $dueAt -or $dueAt -gt $Now) { continue }
        if ($it.recurrence) {
            $next = Resolve-PetNextOccurrence -Recur $it.recurrence -Now $Now
            if ($null -ne $next) {
                $it['dueAt'] = $next.ToString('o')
                $it['lastFiredAt'] = $Now.ToString('o')
                $null = $missed.Add($it)
            }
        }
        else {
            $null = $missed.Add($it)
            $it['completed'] = $true
            $it['lastFiredAt'] = $Now.ToString('o')
        }
    }
    return ,$missed.ToArray()
}

Export-ModuleMember -Function Get-PetStorePath, Get-PetStore, Write-PetStore, Add-PetItem, Remove-PetItem, Set-PetItemCompleted, Find-PetItemsByTarget, Resolve-PetNextOccurrence, Get-PetDueAndAdvance, Invoke-PetCatchUp, ConvertTo-PetHashtable, Get-PetActiveCountdown, Remove-PetCountdown, Get-PetCountdownRemaining, Format-PetCountdownDuration, Get-PetDueSpeechText
