Set-StrictMode -Version Latest

function Convert-PetNumber {
    param([string]$Text)
    $map = @{
        '一'=1; '两'=2; '二'=2; '三'=3; '四'=4; '五'=5; '六'=6; '七'=7; '八'=8; '九'=9; '十'=10
        '半'=0.5
    }
    $t = $Text.Trim()
    if ($t -eq '') { return $null }
    if ($map.ContainsKey($t)) { return $map[$t] }
    if ($t -match '^\d+\.?\d*$') { return [double]$t }
    if ($t -match '^[一二三四五六七八九十]+$') {
        $total = 0
        foreach ($ch in $t.ToCharArray()) {
            if ($map.ContainsKey([string]$ch)) { $total += $map[[string]$ch] }
        }
        return $total
    }
    return $null
}

function Resolve-PetWeekday {
    param([string]$Text)
    $weekday = @{
        '一'=1; '二'=2; '三'=3; '四'=4; '五'=5; '六'=6; '日'=0; '天'=0
    }
    if ($Text -match '(周|星期|礼拜)([一二三四五六日天])') {
        $ch = $Matches[2]
        if ($weekday.ContainsKey($ch)) { return $weekday[$ch] }
    }
    return $null
}

function Resolve-PetDayOffset {
    param([string]$Text)
    if ($Text -match '大后天') { return 3 }
    if ($Text -match '后天') { return 2 }
    if ($Text -match '明天|明日') { return 1 }
    if ($Text -match '今天|今日|今晚') { return 0 }
    return $null
}

# Extract hour/minute and a PM/AM flag from a Chinese/24h clock expression.
function Resolve-PetClock {
    param([string]$Text)
    $meridian = $null
    if ($Text -match '下午|傍晚|晚上|晚间') { $meridian = 'pm' }
    elseif ($Text -match '上午|早上|早晨|凌晨') { $meridian = 'am' }
    elseif ($Text -match '中午|正午') { $meridian = 'noon' }

    $hour = $null
    $minute = 0
    # "15:30" or "3:30" or "7:30pm"
    if ($Text -match '(?<!\d)(\d{1,2})\s*[:：]\s*(\d{1,2})') {
        $hour = [int]$Matches[1]
        $minute = [int]$Matches[2]
    }
    # "3点半" / "3点30" / "3点30分" / "3点一刻"
    elseif ($Text -match '(?<!\d)(\d{1,2})\s*点\s*(半|一刻|三刻|(\d{1,2})分?)') {
        $hour = [int]$Matches[1]
        $mm = $Matches[2]
        if ($mm -eq '半') { $minute = 30 }
        elseif ($mm -eq '一刻') { $minute = 15 }
        elseif ($mm -eq '三刻') { $minute = 45 }
        elseif ($Matches.Count -ge 4 -and $Matches[3]) { $minute = [int]$Matches[3] }
    }
    # bare "3点" / "3点钟"
    elseif ($Text -match '(?<!\d)(\d{1,2})\s*点\s*钟?') {
        $hour = [int]$Matches[1]
    }

    if ($null -eq $hour) { return $null }
    # normalize 24h
    if ($meridian -eq 'pm') {
        if ($hour -lt 12) { $hour += 12 }
    }
    elseif ($meridian -eq 'am') {
        if ($hour -eq 12) { $hour = 0 }
    }
    elseif ($meridian -eq 'noon') {
        $hour = 12
    }
    else {
        # no meridian: bare hour <= 12 defaults to PM (afternoon/evening)
        if ($hour -le 12) { $hour += 12 }
        if ($hour -ge 24) { $hour -= 24 }
    }
    if ($minute -gt 59) { $minute = 59 }
    return @{ Hour = $hour; Minute = $minute }
}

# Build a DateTime from a date-word/day and clock. Returns absolute DateTime or $null.
function Resolve-PetDateTime {
    param(
        [string]$Text,
        [datetime]$Now,
        [object]$Clock
    )
    if ($null -eq $Clock) { return $null }
    $date = $Now.Date
    $offset = Resolve-PetDayOffset -Text $Text
    if ($null -ne $offset) {
        $date = $date.AddDays($offset)
    }
    else {
        $wd = Resolve-PetWeekday -Text $Text
        if ($null -ne $wd) {
            $days = (($wd - $date.DayOfWeek) % 7 + 7) % 7
            $date = $date.AddDays($days)
            if ($Text -match '下(周|星期)') {
                $date = $date.AddDays(7)
            }
        }
        elseif ($Text -match '(\d{1,2})\s*月\s*(\d{1,2})\s*[号日]') {
            $mo = [int]$Matches[1]
            $da = [int]$Matches[2]
            try {
                $date = Get-Date -Year $Now.Year -Month $mo -Day $da
                if ($date -lt $Now.Date) { $date = $date.AddYears(1) }
            }
            catch { return $null }
        }
    }
    $result = $date.AddHours($Clock.Hour).AddMinutes($Clock.Minute)
    # valid on that day only
    return $result
}

function ConvertTo-PetMinutes {
    param([string]$Text)
    if ($Text -notmatch '(半|(\d+(\.\d+)?))\s*个?\s*(小时|钟头|分钟|分|秒)') {
        return $null
    }
    $num = Convert-PetNumber -Text $Matches[1]
    if ($null -eq $num) { return $null }
    $unit = $Matches[4]
    if ($unit -eq '小时' -or $unit -eq '钟头') { return [math]::Round($num * 60) }
    if ($unit -eq '分钟' -or $unit -eq '分') { return [math]::Round($num) }
    if ($unit -eq '秒') { return [math]::Round($num / 60, 2) }
    return $null
}

# Parse a compound duration to total seconds. Supports:
#   半小时 / XX秒 / XX分钟 / XX小时 / XX小时XX分钟 / XX分钟XX秒 / XX小时XX分钟XX秒
function ConvertTo-PetSeconds {
    param([string]$Text)
    if ($Text -match '半小时') { return 1800 }
    if ($Text -notmatch '(\d+(\.\d+)?|半)\s*个?\s*(小时|钟头|分钟|分|秒)') {
        return $null
    }
    $total = 0.0
    $text = $Text -replace '半小时', '30分钟'
    foreach ($m in [regex]::Matches($text, '(\d+(\.\d+)?|半)\s*个?\s*(小时|钟头|分钟|分|秒)')) {
        $num = Convert-PetNumber -Text $m.Groups[1].Value
        if ($null -eq $num) { $num = 0 }
        $unit = $m.Groups[3].Value
        if ($unit -eq '小时' -or $unit -eq '钟头') { $total += $num * 3600 }
        elseif ($unit -eq '分钟' -or $unit -eq '分') { $total += $num * 60 }
        elseif ($unit -eq '秒') { $total += $num }
    }
    if ($total -le 0) { return $null }
    return [math]::Round($total)
}

function Get-PetCleanTitle {
    param(
        [string]$Text,
        [string]$Phrase
    )
    $t = $Phrase
    # strip leading prompting verbs
    $t = $t -replace '^(请|帮我|麻烦|给我|记得|提醒我|提醒|记一下|帮我记一下|记录一下|备注|我要|想)\s*', ''
    $t = $t -replace '(提醒我|提醒一下|提醒|记一下|帮我记|记录一下|备注|设置|安排|定一个|设一个)\s*', ''
    # strip countdown wrappers and articles
    $t = $t -replace '设置|设定|定一个|设一个|开始|来个|来一个|一个|倒计时|番茄钟', ''
    $t = $t -replace '的',''
    # strip recurrence words (entire phrase, incl. leading 每/隔)
    $t = $t -replace '每\s*天|每\s*日', ''
    $t = $t -replace '每\s*(周|星期|礼拜)\s*[一二三四五六日天]', ''
    $t = $t -replace '每\s*月\s*\d{1,2}\s*[号日]', ''
    $t = $t -replace '每\s*隔\s*(\d+(\.\d+)?|半)\s*(小时|分钟|分|天)', ''
    $t = $t -replace '每\s*(\d+(\.\d+)?)\s*(小时|分钟|分|天)', ''
    # strip relative day words
    $t = $t -replace '(大后天|后天|明天|明日|今天|今日|今晚)\s*', ''
    # strip plain weekday (won't touch recurring since already stripped)
    $t = $t -replace '(周|星期|礼拜)\s*[一二三四五六日天]', ''
    # strip month-day
    $t = $t -replace '\d{1,2}\s*月\s*\d{1,2}\s*[号日]?\s*', ''
    # strip meridian words
    $t = $t -replace '(上午|早上|早晨|凌晨|中午|正午|下午|傍晚|晚上|晚间|今晚)\s*', ''
    # strip explicit clock (点/military colon)
    $t = $t -replace '(\d{1,2})\s*[点时:：]\s*(\d{1,2}\s*分?|半|一刻|三刻)?\s*', ''
    $t = $t -replace '\d{1,2}\s*点\s*钟?\s*', ''
    # strip "N分钟后" / "N小时" / "N分钟" leftover
    $t = $t -replace '(\d+(\.\d+)?|半)\s*个?\s*(小时|钟头|分钟|分|秒钟|秒)\s*后', ''
    $t = $t -replace '(\d+(\.\d+)?|半)\s*个?\s*(小时|钟头|分钟|分|秒钟|秒)', ''
    $t = $t -replace '[钟]', ''
    $t = $t -replace '[，。,.！!？?：:、\s]+', ''
    $t = $t.Trim()
    return $t
}

function Resolve-PetRecurrence {
    param(
        [string]$Text,
        [object]$Clock,
        [datetime]$Now
    )
    # interval "每隔N分钟/小时"
    if ($Text -match '每隔\s*(半|(\d+(\.\d+)?))\s*(小时|分钟|天)') {
        $num = Convert-PetNumber -Text $Matches[1]
        $unit = $Matches[3]
        if ($unit -eq '小时') { $mins = [math]::Round($num * 60) }
        elseif ($unit -eq '天') { $mins = [math]::Round($num * 1440) }
        else { $mins = [math]::Round($num) }
        return @{ Kind = 'interval'; IntervalMinutes = $mins }
    }
    if ($Text -match '每天|每日') {
        return @{ Kind = 'daily'; Hour = $Clock.Hour; Minute = $Clock.Minute }
    }
    $wd = Resolve-PetWeekday -Text $Text
    if ($Text -match '每(周|星期|礼拜)' -and $null -ne $wd) {
        return @{ Kind = 'weekly'; DayOfWeek = $wd; Hour = $Clock.Hour; Minute = $Clock.Minute }
    }
    if ($Text -match '每\s*月\s*(\d{1,2})\s*[号日]') {
        $day = [int]$Matches[1]
        return @{ Kind = 'monthly'; DayOfMonth = $day; Hour = $Clock.Hour; Minute = $Clock.Minute }
    }
    return $null
}

function Invoke-PetParse {
    param(
        [string]$Text,
        [datetime]$Now = (Get-Date)
    )
    $raw = ($Text -replace '\s+', ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [pscustomobject]@{ action = 'chat'; params = @{ text = '我在喵～想让我干嘛？' } }
    }

    # --- MUSIC CONTROL ---
    if ($raw -match '音乐|歌曲|播放器|歌' -or $raw -match '^(下一首|上一首|播放|暂停|停止|切歌|上曲|下曲)') {
        if ($raw -match '播放') { return [pscustomobject]@{ action = 'music_play'; params = @{} } }
        if ($raw -match '暂停|停止') { return [pscustomobject]@{ action = 'music_pause'; params = @{} } }
        if ($raw -match '下一首|切歌|下曲') { return [pscustomobject]@{ action = 'music_next'; params = @{} } }
        if ($raw -match '上一首|上曲|前一首') { return [pscustomobject]@{ action = 'music_prev'; params = @{} } }
        return [pscustomobject]@{ action = 'music_toggle'; params = @{} }
    }

    # --- DELETE COUNTDOWN ---
    if ($raw -match '^删除倒计时') {
        return [pscustomobject]@{ action = 'delete_countdown'; params = @{} }
    }

    # --- QUERIES (week / all only; today removed) ---
    $isQuery = $raw -match '这周|本周|下周|所有|全部|待办|安排|日程|任务|有什么|做什么|要做什么|还有'
    if ($isQuery -and $raw -notmatch '提醒|记一下|设置|倒计时|添加|删除') {
        $action = 'list_all'
        if ($raw -match '这周|本周|下周') { $action = 'list_week' }
        if (($action -eq 'list_all') -and ($raw -match '所有|全部|列出')) { $action = 'list_all' }
        return [pscustomobject]@{ action = $action; params = @{} }
    }

    # --- ADD TODO: 添加SS到待办 ---
    if ($raw -match '^添加(.+)到待办') {
        $title = $Matches[1].Trim()
        $title = $title -replace '[，。,.！!？?：:、]+\s*', ''
        if ([string]::IsNullOrWhiteSpace($title)) { $title = '待办事项' }
        return [pscustomobject]@{ action = 'add_reminder'; params = @{ title = $title; dueAt = $null; recurrence = $null } }
    }

    # --- DELETE TODO: 删除待办SS ---
    if ($raw -match '^删除待办(.+)') {
        $target = $Matches[1].Trim()
        $target = $target -replace '[，。,.！!？?：:、]+\s*', ''
        return [pscustomobject]@{ action = 'delete'; params = @{ target = $target } }
    }

    # --- COUNTDOWN: 倒计时<duration> ---
    if ($raw -match '^倒计时') {
        $sec = ConvertTo-PetSeconds -Text $raw
        if ($null -eq $sec) { $sec = 1500 }   # sensible default = 25 min
        # label = whatever follows the countdown keyword (strip units)
        $label = ($raw -replace '^倒计时\s*', '') -replace '[，。,.！!？?：:、]+', ''
        if ([string]::IsNullOrWhiteSpace($label)) { $label = '倒计时' }
        return [pscustomobject]@{ action = 'start_countdown'; params = @{ seconds = $sec; label = $label } }
    }

    # --- REMINDER: HH:MM提醒我SS (24h, strict) ---
    if ($raw -match '^(\d{1,2}):(\d{2})\s*提醒我\s*(.+)$') {
        $hour = [int]$Matches[1]
        $minute = [int]$Matches[2]
        $title = $Matches[3].Trim() -replace '[，。,.！!？?：:、\s]+', ''
        if ($hour -gt 23 -or $minute -gt 59) {
            return [pscustomobject]@{ action = 'chat'; params = @{ text = $raw } }
        }
        if ([string]::IsNullOrWhiteSpace($title)) { $title = '提醒事项' }
        $due = $Now.Date.AddHours($hour).AddMinutes($minute)
        if ($due -lt $Now) { $due = $due.AddDays(1) }
        return [pscustomobject]@{ action = 'add_reminder'; params = @{ title = $title; dueAt = $due.ToString('o'); recurrence = $null } }
    }

    # --- COUNTDOWN fallback: <duration>后/定时 (kept minimal) ---
    if ($raw -match '倒计时|番茄钟') {
        $sec = ConvertTo-PetSeconds -Text $raw
        if ($null -eq $sec) { $sec = 1500 }
        return [pscustomobject]@{ action = 'start_countdown'; params = @{ seconds = $sec; label = '番茄钟' } }
    }

    # --- CHAT FALLBACK ---
    return [pscustomobject]@{ action = 'chat'; params = @{ text = $raw } }
}

Export-ModuleMember -Function Invoke-PetParse, ConvertTo-PetMinutes, ConvertTo-PetSeconds, Resolve-PetClock, Convert-PetNumber
