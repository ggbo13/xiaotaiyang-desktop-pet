$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'modules/PetWindow.psm1') -Force
Import-Module (Join-Path $root 'modules/PetMusic.psm1') -Force
$window = New-PetWindow -Config @{topmost=$false;windowX=0;windowY=0}
try {
    $image = & (Get-Module PetMusic) {
        param($path)
        $VerbosePreference = 'Continue'
        # 使用内存中的真实 WinRT 缩略图，避免沙箱文件代理拒绝访问项目目录。
        $null = [Windows.Storage.Streams.InMemoryRandomAccessStream, Windows.Storage.Streams, ContentType=WindowsRuntime]
        $null = [Windows.Storage.Streams.DataWriter, Windows.Storage.Streams, ContentType=WindowsRuntime]
        $null = [Windows.Storage.Streams.RandomAccessStreamReference, Windows.Storage.Streams, ContentType=WindowsRuntime]
        $fixture = [Windows.Storage.Streams.InMemoryRandomAccessStream]::new()
        $writer = [Windows.Storage.Streams.DataWriter]::new($fixture.GetOutputStreamAt(0))
        $writer.WriteBytes([IO.File]::ReadAllBytes($path))
        $null = Invoke-PetAsync -Operation $writer.StoreAsync() -ResultType ([uint32])
        $fixture.Seek(0)
        $reference = [Windows.Storage.Streams.RandomAccessStreamReference]::CreateFromStream($fixture)
        $cover = Get-PetMediaCover -Thumbnail $reference -Key 'track-a'
        if ($null -eq $cover -or -not $cover.IsFrozen) { throw 'WinRT cover decode failed' }
        $cached = Get-PetMediaCover -Thumbnail $reference -Key 'track-a'
        if (-not [object]::ReferenceEquals($cover, $cached)) { throw 'Cache failed' }
        $empty = Get-PetMediaCover -Thumbnail $null -Key 'track-b'
        if ($null -ne $empty) { throw 'Stale cover after track change' }
        $writer.Dispose(); $fixture.Dispose()
        return $cover
    } (Join-Path $root 'assets/pet.png')
    Set-PetMusicCover -Cover $image
    if (-not [object]::ReferenceEquals($window.FindName('RecordCover').ImageSource, $image)) { throw 'Cover not updated' }
    if (-not [object]::ReferenceEquals($window.FindName('RecordLabel').Fill.ImageSource, $image)) { throw 'Label not updated' }
    Set-PetMusicCover -Cover $null
    if ([object]::ReferenceEquals($window.FindName('RecordCover').ImageSource, $image)) { throw 'Fallback not applied' }
    if ($window.FindName('RecordCover').ImageSource.Drawing.Children[0].Brush.ToString() -ne '#FFFFFFFF') { throw 'Fallback is not white' }
    & (Get-Module PetMusic) {
        if ((Get-PetMediaCommandCode 'toggle') -ne 14 -or (Get-PetMediaCommandCode 'next') -ne 11 -or
            (Get-PetMediaCommandCode 'prev') -ne 12) { throw 'CloudMusic media command mapping failed' }
        $spotify=[pscustomobject]@{SourceAppUserModelId='SpotifyAB.SpotifyMusic_zpdnekdrzrea0!Spotify'}
        $spotify | Add-Member ScriptMethod GetPlaybackInfo { return [pscustomobject]@{PlaybackStatus='Paused'} }
        $hills=[pscustomobject]@{SourceAppUserModelId='HillsLite.VideoPlayer_abc!App'}
        $hills | Add-Member ScriptMethod GetPlaybackInfo { return [pscustomobject]@{PlaybackStatus='Playing'} }
        $hillsSource=[pscustomobject]@{Name='hillslite';Peak=0.2}
        if ($null -ne (Select-PetMediaSession -Sessions @($spotify) -Sources @($hillsSource) -CurrentSession $spotify)) {
            throw 'Audible Hills source borrowed paused Spotify cover'
        }
        if (-not [object]::ReferenceEquals((Select-PetMediaSession -Sessions @($spotify,$hills) -Sources @($hillsSource) -CurrentSession $spotify),$hills)) {
            throw 'Hills source did not select its matching media session'
        }
        if (-not [object]::ReferenceEquals((Select-PetMediaSession -Sessions @($spotify) -Sources @() -CurrentSession $spotify),$spotify)) {
            throw 'Current session fallback failed without an audible source'
        }
        $script:AudioSourceStates=@{}; $script:AudioSourceOrder=@{}; $script:AudioSourceLastAudible=@{}; $script:AudioSourceCounter=0
        $selfOnly=@(Get-PetAudibleSources -RawSources @([pscustomobject]@{Name='powershell';ProcessId=$PID;Peak=0.8}))
        if ($selfOnly.Count -ne 0) { throw 'Pet sound was mistaken for music' }
        $script:SessionMeterReady=$false
        Set-PetLocalSoundActive -Seconds 2.3
        if (-not (Test-PetLocalSoundActive)) { throw 'Local sound guard was not activated' }
        $localPeak = Get-PetAudioPeak
        if ($localPeak -ne 0) { throw "Master-volume fallback detected pet sound: $localPeak" }
        $script:LocalSoundUntil=[datetime]::MinValue
        $external=@(Get-PetAudibleSources -RawSources @(
            [pscustomobject]@{Name='powershell';ProcessId=$PID;Peak=0.8},
            [pscustomobject]@{Name='cloudmusic';ProcessId=([int]$PID+1);Peak=0.2}))
        if ($external.Count -ne 1 -or $external[0].Name -ne 'cloudmusic') { throw 'Pet sound masked an external music source' }
        $script:AudioSourceStates=@{}; $script:AudioSourceOrder=@{}; $script:AudioSourceLastAudible=@{}; $script:AudioSourceCounter=0
        $first=@(Get-PetAudibleSources -RawSources @([pscustomobject]@{Name='cloudmusic';Peak=0.2}))
        if ($first[0].Name -ne 'cloudmusic') { throw 'First source selection failed' }
        $later=@(Get-PetAudibleSources -RawSources @(
            [pscustomobject]@{Name='cloudmusic';Peak=0.2}, [pscustomobject]@{Name='kugou';Peak=0.3}))
        if ($later[0].Name -ne 'cloudmusic') { throw 'Later source incorrectly took priority' }
        $same=@(Get-PetAudibleSources -RawSources @(
            [pscustomobject]@{Name='cloudmusic';Peak=0.4}, [pscustomobject]@{Name='kugou';Peak=0.2}))
        if ($same[0].Name -ne 'cloudmusic') { throw 'Volume change incorrectly stole priority' }
        $gap=@(Get-PetAudibleSources -RawSources @(
            [pscustomobject]@{Name='cloudmusic';Peak=0.0}, [pscustomobject]@{Name='kugou';Peak=0.2}))
        if ($gap[0].Name -ne 'cloudmusic') { throw 'Short silence did not retain first source' }
        $script:AudioSourceLastAudible['cloudmusic']=(Get-Date).AddSeconds(-1.6)
        $back=@(Get-PetAudibleSources -RawSources @(
            [pscustomobject]@{Name='cloudmusic';Peak=0.0}, [pscustomobject]@{Name='kugou';Peak=0.2}))
        if ($back[0].Name -ne 'kugou') { throw 'Next source was not selected after first stopped' }
    }
    $available = Initialize-PetMusic
    $status = Get-PetMusicStatus
    Write-Output "PASS: cover, first-source priority and CloudMusic command mapping. Live session=$($status.HasSession); live cover=$($null -ne $status.Cover)"
} finally { Set-PetAllowClose; $window.Close() }

function Test-PetEntrySoundGuard {
    param([string]$Entry)
    $tokens=$null; $errors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root $Entry),[ref]$tokens,[ref]$errors)
    if ($errors.Count -gt 0) { throw "$Entry syntax error" }
    $definition=$ast.EndBlock.Statements | Where-Object {
        $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq 'Test-PetMusicPlaying'
    } | Select-Object -First 1
    if ($null -eq $definition) { throw "$Entry music detector missing" }
    . ([scriptblock]::Create($definition.Extent.Text))
    function Test-PetSpeaking { return $false }
    function Test-PetLocalSoundActive { return $script:TestSoundGuard }
    function Get-PetMusicStatus {
        $script:TestMediaCalls++
        return @{ Playing=$script:TestSimulatedPlaying; HasSession=$true; App='test'; Cover=$null }
    }
    function Update-PetDetectedMusicCover { param($MediaStatus) }
    $script:MusicReady=$true; $script:PeakStreak=0; $script:LastMusicDetected=$false
    $script:TestMediaCalls=0; $script:TestSimulatedPlaying=$true; $script:TestSoundGuard=$true
    if (Test-PetMusicPlaying) { throw "$Entry local sound started playback" }
    if ($script:TestMediaCalls -ne 0) { throw "$Entry checked media during local sound" }
    $script:TestSoundGuard=$false
    if (-not (Test-PetMusicPlaying)) { throw "$Entry real playback was missed" }
    $script:TestSoundGuard=$true
    if (-not (Test-PetMusicPlaying)) { throw "$Entry interrupted existing playback" }
    $script:TestSoundGuard=$false; $script:TestSimulatedPlaying=$false
    if (Test-PetMusicPlaying) { throw "$Entry kept playback after the real session paused" }
}
$secondEntry = Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File |
    Where-Object { $_.Name -ne 'xiaotaiyang.ps1' } | Select-Object -First 1 -ExpandProperty Name
if (-not $secondEntry) { throw 'Second entry script missing' }
foreach ($entry in @('xiaotaiyang.ps1',$secondEntry)) { Test-PetEntrySoundGuard -Entry $entry }
Write-Output 'PASS: local interaction sound cannot promote a media session in either entry'
