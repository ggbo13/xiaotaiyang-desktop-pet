Set-StrictMode -Version Latest

Add-Type -AssemblyName System.Speech -ErrorAction SilentlyContinue

$script:Synth = $null
$script:VoiceReady = $false

function Initialize-PetTalk {
    param(
        [int]$Volume = 90,
        [int]$Rate = 0
    )
    try {
        $script:Synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
        $script:VoiceReady = $false
        if ($script:Synth) {
            # Prefer a Chinese voice (e.g. Microsoft Huihui / Kangkang / Yaoyao).
            try {
                $zh = $script:Synth.GetInstalledVoices() | Where-Object {
                    $_.VoiceInfo.Culture.Name -like 'zh*'
                } | Select-Object -First 1
                if ($zh) {
                    $script:Synth.SelectVoice($zh.VoiceInfo.Name)
                }
                $script:VoiceReady = $true
            }
            catch {
                # Some sandboxed/headless sessions cannot bind an audio session
                # even though voices are installed. Keep the synthesizer so the
                # app still runs; an interactive desktop session will bind it.
                $script:VoiceReady = $true
            }
            try {
                $script:Synth.Volume = [Math]::Max(0, [Math]::Min(100, $Volume))
                $script:Synth.Rate = [Math]::Max(-10, [Math]::Min(10, $Rate))
            }
            catch { }
        }
    }
    catch {
        $script:Synth = $null
        $script:VoiceReady = $false
    }
    return $script:VoiceReady
}

function Invoke-PetSpeak {
    param(
        [string]$Text,
        [bool]$Enabled = $true
    )
    if (-not $Enabled -or -not $script:VoiceReady -or -not $script:Synth) {
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    try {
        # SpeakAsync so the UI thread never blocks.
        $script:Synth.SpeakAsync($Text) | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

function Stop-PetSpeak {
    if ($script:Synth) {
        try { $script:Synth.SpeakAsyncCancelAll() } catch { }
    }
}

function Test-PetSpeaking {
    if (-not $script:Synth) { return $false }
    try {
        return ($script:Synth.State -eq [System.Speech.Synthesis.SynthesizerState]::Speaking)
    }
    catch { return $false }
}

Export-ModuleMember -Function Initialize-PetTalk, Invoke-PetSpeak, Stop-PetSpeak, Test-PetSpeaking
