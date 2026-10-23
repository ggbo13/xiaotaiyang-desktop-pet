Set-StrictMode -Version Latest

$script:RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$script:RunName = '小太阳桌宠'

function Get-PetAutoStartCommand {
    param([string]$EntryScript)
    # 开机启动与两个手动入口使用同一运行时，避免 PowerShell 7 丢失媒体信息。
    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $windowsPowerShell) {
        return '"{0}" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -STA -File "{1}"' -f $windowsPowerShell, $EntryScript
    }
    $pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($null -ne $pwshCmd) {
        $pwshPath = $null
        try { $pwshPath = $pwshCmd.Source } catch { $pwshPath = $null }
        if (-not [string]::IsNullOrWhiteSpace($pwshPath) -and (Test-Path $pwshPath)) {
            return '"{0}" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -STA -File "{1}"' -f $pwshPath, $EntryScript
        }
    }
    $cmd = 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -STA -File "{0}"' -f $EntryScript
    return $cmd.Trim()
}

function Test-PetAutoStart {
    param([string]$EntryScript)
    try {
        $item = Get-ItemProperty -Path $script:RunKey -Name $script:RunName -ErrorAction SilentlyContinue
        if ($null -eq $item) { return $false }
        $v = $item.$script:RunName
        if(-not [string]::IsNullOrWhiteSpace($EntryScript)){
            return $v -eq (Get-PetAutoStartCommand -EntryScript $EntryScript)
        }
        return -not [string]::IsNullOrWhiteSpace($v)
    }
    catch {
        return $false
    }
}

function Enable-PetAutoStart {
    param([string]$EntryScript)
    $cmd = Get-PetAutoStartCommand -EntryScript $EntryScript
    if (-not (Test-Path $script:RunKey)) {
        New-Item -Path $script:RunKey -Force | Out-Null
    }
    Set-ItemProperty -Path $script:RunKey -Name $script:RunName -Value $cmd
    return $cmd
}

function Disable-PetAutoStart {
    Remove-ItemProperty -Path $script:RunKey -Name $script:RunName -ErrorAction SilentlyContinue
}

function Set-PetAutoStart {
    param(
        [bool]$Enable,
        [string]$EntryScript
    )
    if ($Enable) { return Enable-PetAutoStart -EntryScript $EntryScript }
    Disable-PetAutoStart
    return $null
}

Export-ModuleMember -Function Get-PetAutoStartCommand, Test-PetAutoStart, Enable-PetAutoStart, Disable-PetAutoStart, Set-PetAutoStart
