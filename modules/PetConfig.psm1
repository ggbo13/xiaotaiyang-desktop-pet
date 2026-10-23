Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'PetPaths.psm1') -Force -Scope Local
$script:DataRoot = Get-PetDataRoot -ApplicationRoot (Split-Path $PSScriptRoot -Parent)
$script:ConfigPath = Join-Path $script:DataRoot 'config.json'

function Get-PetConfigPath {
    return $script:ConfigPath
}

function Get-PetDefaultConfig {
    return [ordered]@{
        topmost         = $true
        voice           = $true
        idleChatter     = $true
        chatterEveryMin = 6
        sleepAfterMin   = 3
        volume          = 90
        rate            = 0
        windowX         = $null
        windowY         = $null
        autoStart       = $true
        music           = $true
        skinId          = 'original'
    }
}

function Read-PetConfig {
    param([string]$Path = $script:ConfigPath)
    $defaults = Get-PetDefaultConfig
    if (-not (Test-Path $Path)) {
        return $defaults
    }
    try {
        $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        $loaded = $raw | ConvertFrom-Json
    }
    catch {
        return $defaults
    }
    # ConvertFrom-Json returns a PSCustomObject in PS 5.1; normalize to a hashtable.
    if ($loaded -is [System.Management.Automation.PSCustomObject]) {
        $normalized = @{}
        foreach ($prop in $loaded.PSObject.Properties) {
            $normalized[$prop.Name] = $prop.Value
        }
        $loaded = $normalized
    }
    foreach ($key in @($defaults.Keys)) {
        if (-not $loaded.ContainsKey($key)) {
            $loaded[$key] = $defaults[$key]
        }
    }
    return $loaded
}

function Write-PetConfig {
    param(
        [hashtable]$Config,
        [string]$Path = $script:ConfigPath
    )
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $json = $Config | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($true)))
}

Export-ModuleMember -Function Get-PetConfigPath, Get-PetDefaultConfig, Read-PetConfig, Write-PetConfig
