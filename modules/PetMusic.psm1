Set-StrictMode -Version Latest

# Music recognition + control via Windows System Media Transport Controls (SMTC).
# This is the same mechanism the Windows taskbar media flyout uses.

Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction SilentlyContinue
Add-Type -AssemblyName PresentationCore -ErrorAction SilentlyContinue

$script:Loaded = $false
$script:Manager = $null
$script:MeterReady = $false
$script:CoverKey = ''
$script:CoverImage = $null
$script:CoverCheckedAt = [datetime]::MinValue
$script:CloudMusicKey = ''
$script:CloudMusicInfo = $null
$script:CloudMusicCheckedAt = [datetime]::MinValue
$script:SessionMeterReady = $false
$script:AudioSourceStates = @{}
$script:AudioSourceOrder = @{}
$script:AudioSourceLastAudible = @{}
$script:AudioSourceCounter = 0
$script:AudioSources = @()
$script:AudioSourcesCheckedAt = [datetime]::MinValue
$script:SelectedAudioSource = $null
$script:LastSelectedAudioSource = $null
$script:SelectedAudioPeak = 0.0
$script:SelectedAudioActive = $false
$script:LocalSoundUntil = [datetime]::MinValue

function Set-PetLocalSoundActive {
    param([double]$Seconds = 2.3)
    # 仅供分应用音量检测失效时使用，避免总音量把桌宠音效当作音乐。
    $until = (Get-Date).AddSeconds($Seconds)
    if ($until -gt $script:LocalSoundUntil) { $script:LocalSoundUntil = $until }
}

function Test-PetLocalSoundActive {
    return (Get-Date) -lt $script:LocalSoundUntil
}

function ConvertFrom-PetWebImage {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $null }
    $response = $null; $stream = $null; $memory = $null
    try {
        $request = [Net.HttpWebRequest]::Create($Url.Replace('http://', 'https://'))
        $request.Timeout = 3500
        $request.ReadWriteTimeout = 3500
        $request.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
        $request.Referer = 'https://music.163.com/'
        $response = $request.GetResponse()
        if ($response.ContentLength -gt 16MB) { return $null }
        $stream = $response.GetResponseStream()
        $memory = [IO.MemoryStream]::new()
        $stream.CopyTo($memory)
        if ($memory.Length -eq 0 -or $memory.Length -gt 16MB) { return $null }
        $memory.Position = 0
        $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
        $bitmap.BeginInit()
        $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bitmap.DecodePixelWidth = 512
        $bitmap.StreamSource = $memory
        $bitmap.EndInit()
        $bitmap.Freeze()
        return $bitmap
    } catch { Write-Verbose "下载网易云封面失败：$_"; return $null }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $response) { $response.Dispose() }
        if ($null -ne $memory) { $memory.Dispose() }
    }
}

function Get-PetCloudMusicMetadata {
    # 新版网易云没有注册 Windows 媒体会话：从窗口标题确定当前歌曲，
    # 再在网易云自己的本地播放列表中读取封面地址。
    if (((Get-Date) - $script:CloudMusicCheckedAt).TotalMilliseconds -lt 900 -and
        @(Get-Process -Name 'cloudmusic' -ErrorAction SilentlyContinue).Count -gt 0) {
        return $script:CloudMusicInfo
    }
    $script:CloudMusicCheckedAt = Get-Date
    try {
        $cloudProcesses = @(Get-Process -Name 'cloudmusic' -ErrorAction SilentlyContinue)
        if ($cloudProcesses.Count -eq 0) {
            # 网易云退出后立刻清掉歌曲和封面，不能污染网页或其他播放器。
            $script:CloudMusicKey = ''
            $script:CloudMusicInfo = $null
            return $null
        }
        $windowTitle = @($cloudProcesses |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_.MainWindowTitle) } |
            Select-Object -ExpandProperty MainWindowTitle -First 1)[0]
        if ([string]::IsNullOrWhiteSpace($windowTitle)) { return $script:CloudMusicInfo }

        $packages = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Packages'
        $package = Get-ChildItem -LiteralPath $packages -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like '1F8B0F94.122165AE0*' } | Select-Object -First 1
        if ($null -eq $package) { return $script:CloudMusicInfo }
        $listPath = Join-Path $package.FullName 'LocalCache\Local\NetEase\CloudMusic\webdata\file\playingList'
        if (-not (Test-Path -LiteralPath $listPath)) { return $script:CloudMusicInfo }
        $store = [IO.File]::ReadAllText($listPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $matches = @($store.list | Where-Object {
            $name = [string]$_.track.name
            $artists = [string]($_.track.artists.name -join '/')
            $windowTitle -eq "$name - $artists" -or $windowTitle.StartsWith("$name - ")
        } | Sort-Object { ([string]$_.track.name).Length } -Descending)
        if ($matches.Count -eq 0) { return $script:CloudMusicInfo }
        $track = $matches[0].track
        $key = "cloudmusic`n$($track.id)`n$($track.name)"
        if ($key -ne $script:CloudMusicKey) {
            $cover = ConvertFrom-PetWebImage -Url ([string]$track.album.picUrl)
            $script:CloudMusicKey = $key
            $script:CloudMusicInfo = @{
                Title = [string]$track.name
                Artist = [string]($track.artists.name -join '/')
                App = 'cloudmusic'
                Cover = $cover
            }
        }
    } catch { Write-Verbose "读取网易云本地播放信息失败：$_" }
    return $script:CloudMusicInfo
}

function Get-PetMediaCover {
    param($Thumbnail, [string]$Key)
    # 切歌立即清空缓存；同一首歌定期重试，以兼容延迟提供封面的播放器。
    if ($Key -ne $script:CoverKey) {
        $script:CoverKey = $Key
        $script:CoverImage = $null
        $script:CoverCheckedAt = [datetime]::MinValue
    }
    if (((Get-Date) - $script:CoverCheckedAt).TotalSeconds -lt 5) { return $script:CoverImage }
    $script:CoverCheckedAt = Get-Date
    $script:CoverImage = $null
    if ($null -eq $Thumbnail) { return $null }
    $stream = $null; $reader = $null; $memory = $null
    try {
        $null = [Windows.Storage.Streams.IRandomAccessStreamWithContentType, Windows.Storage.Streams, ContentType=WindowsRuntime]
        $null = [Windows.Storage.Streams.DataReader, Windows.Storage.Streams, ContentType=WindowsRuntime]
        $stream = Invoke-PetAsync -Operation $Thumbnail.OpenReadAsync() -ResultType ([Windows.Storage.Streams.IRandomAccessStreamWithContentType])
        if ($null -eq $stream) { return $null }
        # 通过反射把 WinRT COM 流交给 .NET，兼容 PowerShell 5.1 的类型投影。
        $adapter = [System.IO.WindowsRuntimeStreamExtensions].GetMethods() | Where-Object {
            $_.Name -eq 'AsStream' -and $_.GetParameters().Count -eq 1 -and
            $_.GetParameters()[0].ParameterType.Name -eq 'IRandomAccessStream'
        } | Select-Object -First 1
        $reader = $adapter.Invoke($null, @($stream))
        if ($reader.Length -eq 0 -or $reader.Length -gt 16MB) { return $null }
        $memory = [IO.MemoryStream]::new()
        $reader.CopyTo($memory)
        $memory.Position = 0
        $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
        $bitmap.BeginInit()
        $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bitmap.DecodePixelWidth = 512
        $bitmap.StreamSource = $memory
        $bitmap.EndInit()
        $bitmap.Freeze()
        $script:CoverImage = $bitmap
    } catch { $script:CoverImage = $null; Write-Verbose "读取歌曲封面失败：$_" }
    finally {
        if ($null -ne $reader) { try { ([IDisposable]$reader).Dispose() } catch { } }
        if ($null -ne $stream) { try { ([IDisposable]$stream).Dispose() } catch { } }
        if ($null -ne $memory) { $memory.Dispose() }
    }
    return $script:CoverImage
}

function Invoke-PetAsync {
    param($Operation, [Type]$ResultType)
    try {
        $asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() |
            Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.IsGenericMethod } |
            Select-Object -First 1)
        if ($null -eq $asTask) { return $null }
        $asTaskGeneric = $asTask.MakeGenericMethod($ResultType)
        $task = $asTaskGeneric.Invoke($null, @($Operation))
        if (-not $task.Wait(1500)) { return $null }
        return $task.Result
    }
    catch {
        return $null
    }
}

function Initialize-PetMusic {
    try {
        if ($script:Loaded) { return $true }
        $null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]
        $null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionPlaybackStatus, Windows.Media.Control, ContentType = WindowsRuntime]
        $req = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()
        $script:Manager = Invoke-PetAsync -Operation $req -ResultType ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])
        $script:Loaded = ($null -ne $script:Manager)
    }
    catch {
        $script:Manager = $null
        $script:Loaded = $false
    }
    return $script:Loaded
}

function Test-PetMusicAvailable {
    return $script:Loaded
}

function Initialize-PetAudioSessions {
    if ($script:SessionMeterReady) { return $true }
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
public static class PetAudioSessions {
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumerator { }
    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
    interface IMMDeviceEnumerator { int EnumAudioEndpoints(int f,uint s,out IntPtr d); int GetDefaultAudioEndpoint(int f,int r,out IMMDevice d); }
    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("D666063F-1587-4E43-81F1-B948E807363F")]
    interface IMMDevice { int Activate(ref Guid id,uint c,IntPtr p,[MarshalAs(UnmanagedType.IUnknown)] out object o); }
    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F")]
    interface IAudioSessionManager2 {
        int GetAudioSessionControl(ref Guid g,uint f,out IntPtr c); int GetSimpleAudioVolume(ref Guid g,uint f,out IntPtr v);
        int GetSessionEnumerator(out IAudioSessionEnumerator e);
    }
    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8")]
    interface IAudioSessionEnumerator { int GetCount(out int c); int GetSession(int i,out IAudioSessionControl c); }
    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("F4B1A599-7266-4319-A8CA-E70ACB11E8CD")]
    interface IAudioSessionControl {
        int GetState(out int s); int GetDisplayName(out IntPtr n); int SetDisplayName(string n,ref Guid e);
        int GetIconPath(out IntPtr p); int SetIconPath(string p,ref Guid e); int GetGroupingParam(out Guid g);
        int SetGroupingParam(ref Guid g,ref Guid e); int RegisterAudioSessionNotification(IntPtr n); int UnregisterAudioSessionNotification(IntPtr n);
    }
    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("BFB7FF88-7239-4FC9-8FA2-07C950BE9C6D")]
    interface IAudioSessionControl2 {
        int GetState(out int s); int GetDisplayName(out IntPtr n); int SetDisplayName(string n,ref Guid e);
        int GetIconPath(out IntPtr p); int SetIconPath(string p,ref Guid e); int GetGroupingParam(out Guid g);
        int SetGroupingParam(ref Guid g,ref Guid e); int RegisterAudioSessionNotification(IntPtr n); int UnregisterAudioSessionNotification(IntPtr n);
        int GetSessionIdentifier(out IntPtr i); int GetSessionInstanceIdentifier(out IntPtr i); int GetProcessId(out uint id);
    }
    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064")]
    interface IAudioMeterInformation { int GetPeakValue(out float p); }
    public sealed class Item { public int ProcessId; public string ProcessName; public float Peak; }
    public static Item[] Read() {
        var result=new List<Item>(); object managerObject=null; IAudioSessionEnumerator en=null;
        try {
            var de=(IMMDeviceEnumerator)(object)new MMDeviceEnumerator(); IMMDevice device;
            Marshal.ThrowExceptionForHR(de.GetDefaultAudioEndpoint(0,1,out device));
            Guid id=typeof(IAudioSessionManager2).GUID; device.Activate(ref id,1,IntPtr.Zero,out managerObject);
            var manager=(IAudioSessionManager2)managerObject; manager.GetSessionEnumerator(out en); int count; en.GetCount(out count);
            for(int i=0;i<count;i++) { IAudioSessionControl control=null;
                try { en.GetSession(i,out control); var c2=(IAudioSessionControl2)control; uint pid; c2.GetProcessId(out pid); if(pid==0) continue;
                    float peak; ((IAudioMeterInformation)control).GetPeakValue(out peak); string name="";
                    try { name=Process.GetProcessById((int)pid).ProcessName.ToLowerInvariant(); } catch { }
                    result.Add(new Item{ProcessId=(int)pid,ProcessName=name,Peak=peak});
                } catch { } finally { if(control!=null) Marshal.ReleaseComObject(control); }
            }
        } catch { } finally { if(en!=null) Marshal.ReleaseComObject(en); if(managerObject!=null) Marshal.ReleaseComObject(managerObject); }
        return result.ToArray();
    }
}
'@ -ErrorAction Stop
        $script:SessionMeterReady = $true
    } catch { $script:SessionMeterReady = $false }
    return $script:SessionMeterReady
}

function Get-PetAudibleSources {
    param([object[]]$RawSources)
    if (-not $PSBoundParameters.ContainsKey('RawSources')) {
        if (((Get-Date) - $script:AudioSourcesCheckedAt).TotalMilliseconds -lt 250) { return $script:AudioSources }
        $script:AudioSourcesCheckedAt = Get-Date
        if (-not (Initialize-PetAudioSessions)) { return @() }
        $RawSources = @([PetAudioSessions]::Read() | Where-Object { $_.ProcessId -ne $PID } | Group-Object ProcessName | ForEach-Object {
            [pscustomobject]@{ Name=$_.Name; Peak=[double](($_.Group | Measure-Object Peak -Maximum).Maximum) }
        })
    }
    # 桌宠音效和语音在当前进程播放，不能成为音乐来源。
    $grouped = @($RawSources | Where-Object {
        -not ($_.PSObject.Properties['ProcessId'] -and [int]$_.ProcessId -eq $PID)
    })
    $seen = @{}
    $now = Get-Date
    foreach ($source in $grouped) {
        if ([string]::IsNullOrWhiteSpace($source.Name)) { continue }
        $seen[$source.Name] = $true
        $rawAudible = $source.Peak -gt 0.015
        $wasActive = $script:AudioSourceStates.ContainsKey($source.Name) -and $script:AudioSourceStates[$source.Name]
        if ($rawAudible) { $script:AudioSourceLastAudible[$source.Name] = $now }
        $active = $rawAudible -or ($script:AudioSourceLastAudible.ContainsKey($source.Name) -and
            ($now - $script:AudioSourceLastAudible[$source.Name]).TotalSeconds -lt 1.5)
        if ($active -and -not $wasActive) {
            $script:AudioSourceCounter++
            $script:AudioSourceOrder[$source.Name] = $script:AudioSourceCounter
        }
        $script:AudioSourceStates[$source.Name] = $active
    }
    foreach ($name in @($script:AudioSourceStates.Keys)) {
        if (-not $seen.ContainsKey($name)) {
            $script:AudioSourceStates[$name] = $script:AudioSourceLastAudible.ContainsKey($name) -and
                ($now - $script:AudioSourceLastAudible[$name]).TotalSeconds -lt 1.5
            if ($script:AudioSourceStates[$name]) {
                $grouped += [pscustomobject]@{ Name=$name; Peak=0.0 }
            }
        }
    }
    $script:AudioSources = @($grouped | Where-Object {
        $script:AudioSourceStates.ContainsKey($_.Name) -and $script:AudioSourceStates[$_.Name]
    } | Sort-Object {
        if ($script:AudioSourceOrder.ContainsKey($_.Name)) { $script:AudioSourceOrder[$_.Name] } else { 0 }
    })
    return $script:AudioSources
}

function ConvertTo-PetSourceToken {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    return ($Value.ToLowerInvariant() -replace '[^a-z0-9]', '')
}

function Test-PetSourceSessionMatch {
    param([string]$SourceName, [string]$SessionId)
    $source = ConvertTo-PetSourceToken -Value $SourceName
    $session = ConvertTo-PetSourceToken -Value $SessionId
    if ($source.Length -lt 3 -or $session.Length -lt 3) { return $false }
    return $session.Contains($source) -or $source.Contains($session)
}

function Select-PetMediaSession {
    param([object[]]$Sessions, [object[]]$Sources, $CurrentSession)
    # 有明确发声来源时，只允许使用同一应用的媒体会话，防止借用暂停播放器的旧封面。
    foreach ($source in @($Sources)) {
        $match = @($Sessions | Where-Object {
            Test-PetSourceSessionMatch -SourceName ([string]$source.Name) -SessionId ([string]$_.SourceAppUserModelId)
        } | Select-Object -First 1)
        if ($match.Count -gt 0) { return $match[0] }
    }
    if (@($Sources).Count -gt 0) { return $null }
    $playing = @($Sessions | Where-Object {
        try { $_.GetPlaybackInfo().PlaybackStatus.ToString() -eq 'Playing' } catch { $false }
    })
    if ($playing.Count -gt 0) { return $playing[0] }
    return $CurrentSession
}

function Get-PetActiveMediaSession {
    if (-not $script:Loaded -or $null -eq $script:Manager) { return $null }
    try {
        # 分应用检测音量；先开始发声的来源保持封面，直到它连续静音 1.5 秒。
        $sessions = @($script:Manager.GetSessions())
        $sources = @(Get-PetAudibleSources)
        $script:SelectedAudioSource = if ($sources.Count -gt 0) { $sources[0].Name } else { $null }
        $script:SelectedAudioPeak = if ($sources.Count -gt 0) { $sources[0].Peak } else { 0.0 }
        $script:SelectedAudioActive = ($sources.Count -gt 0)
        if ($null -ne $script:SelectedAudioSource) { $script:LastSelectedAudioSource = $script:SelectedAudioSource }
        if ($script:SelectedAudioSource -eq 'cloudmusic') { return $null }
        $current = $null
        try { $current = $script:Manager.GetCurrentSession() } catch { }
        return Select-PetMediaSession -Sessions $sessions -Sources $sources -CurrentSession $current
    } catch { }
    if ($script:SelectedAudioActive) { return $null }
    try { return $script:Manager.GetCurrentSession() } catch { return $null }
}

# Returns a hashtable: @{ Available; Playing; HasSession; Title; Artist; App}
function Get-PetMusicStatus {
    $result = @{
        Available = $script:Loaded
        Playing = $false
        HasSession = $false
        Title = $null
        Artist = $null
        App = $null
        Cover = $null
    }
    if (-not $script:Loaded -or $null -eq $script:Manager) {
        return $result
    }
    try {
        $session = Get-PetActiveMediaSession
        if ($null -eq $session) {
            # 能识别到具体发声应用、但它没有媒体会话时，也要标记来源变化；
            # 界面据此换成默认封面，不能继续沿用上一播放器的封面。
            if ($null -ne $script:SelectedAudioSource) {
                $result.App = $script:SelectedAudioSource
                $result.Playing = $script:SelectedAudioActive
            }
            $cloud = if ($script:SelectedAudioSource -eq 'cloudmusic') { Get-PetCloudMusicMetadata } else { $null }
            if ($cloud) {
                $result.Title = $cloud.Title; $result.Artist = $cloud.Artist
                $result.App = $cloud.App; $result.Cover = $cloud.Cover
            }
            return $result
        }
        $result.HasSession = $true
        $info = $session.GetPlaybackInfo()
        $status = $info.PlaybackStatus
        # Playing => music is actually playing. Paused/Stopped/Closed => not.
        $result.Playing = ($status -eq [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionPlaybackStatus]::Playing)
        if ($session.SourceAppUserModelId) { $result.App = $session.SourceAppUserModelId }
        # Hills Lite 等播放器的媒体状态偶尔跳成暂停；应用仍在持续发声时按实际音频判断。
        if (-not $result.Playing -and $script:SelectedAudioActive) {
            $result.Playing = $true
            if ($script:SelectedAudioSource) { $result.App = $script:SelectedAudioSource }
        }
        # 暂停的旧媒体会话只用于播放控制，不读取其元数据和封面，避免污染下一声音来源。
        if ($result.Playing) {
            try {
                $props = Invoke-PetAsync -Operation $session.TryGetMediaPropertiesAsync() -ResultType ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
                if ($props) {
                    if ($props.Title) { $result.Title = $props.Title }
                    if ($props.Artist) { $result.Artist = $props.Artist }
                    $key = "$($result.App)`n$($result.Title)`n$($result.Artist)`n$($props.AlbumTitle)"
                    $result.Cover = Get-PetMediaCover -Thumbnail $props.Thumbnail -Key $key
                }
            }
            catch { }
        }
        # 若 Windows 只有一个暂停的旧会话，仍让正在响的网易云走音量检测。
        if (-not $result.Playing) {
            $cloud = if ($script:SelectedAudioSource -eq 'cloudmusic') { Get-PetCloudMusicMetadata } else { $null }
            if ($cloud) {
                $result.HasSession = $false
                $result.Title = $cloud.Title; $result.Artist = $cloud.Artist
                $result.App = $cloud.App; $result.Cover = $cloud.Cover
            }
        }
    }
    catch { }
    return $result
}

# control: 'toggle' | 'play' | 'pause' | 'next' | 'prev'
function Get-PetMediaCommandCode {
    param([string]$Control)
    switch ($Control) {
        'toggle' { return 14 }
        'play'   { return 46 }
        'pause'  { return 47 }
        'next'   { return 11 }
        'prev'   { return 12 }
        default  { return 0 }
    }
}

function Invoke-PetCloudMusicCommand {
    param([string]$Control)
    $code = Get-PetMediaCommandCode -Control $Control
    if ($code -eq 0) { return $false }
    try {
        if (-not ('PetMediaKeys' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PetMediaKeys {
    [DllImport("user32.dll", SetLastError=true)] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
    public static void Press(byte key) { keybd_event(key,0,0,UIntPtr.Zero); keybd_event(key,0,2,UIntPtr.Zero); }
    public static void CloudMusicHotkey(byte key) {
        keybd_event(0x11,0,0,UIntPtr.Zero); keybd_event(0x12,0,0,UIntPtr.Zero);
        keybd_event(key,0,0,UIntPtr.Zero); keybd_event(key,0,2,UIntPtr.Zero);
        keybd_event(0x12,0,2,UIntPtr.Zero); keybd_event(0x11,0,2,UIntPtr.Zero);
    }
}
'@ -ErrorAction Stop
        }
        $cloud = @(Get-Process -Name 'cloudmusic' -ErrorAction SilentlyContinue)
        $window = @($cloud | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } | Select-Object -First 1)
        if ($window.Count -gt 0 -and $false) {
            # WM_APPCOMMAND 直接发给网易云窗口，不会误控制暂停着的网页或酷狗。
            $message = [IntPtr]::new([int64]($code -shl 16))
            if ([PetMediaKeys]::PostMessage($window[0].MainWindowHandle, 0x0319, $window[0].MainWindowHandle, $message)) {
                return $true
            }
        }
        # 网易云 3.x 不响应 WM_APPCOMMAND，使用其默认全局快捷键：
        # Ctrl+Alt+P 播放/暂停，Ctrl+Alt+左右键切歌。
        $key = switch ($Control) { 'next' { 0x27 } 'prev' { 0x25 } default { 0x50 } }
        [PetMediaKeys]::CloudMusicHotkey([byte]$key)
        return $true
    } catch { return $false }
}

function Invoke-PetMediaCommand {
    param([string]$Control)
    if ($script:LastSelectedAudioSource -eq 'cloudmusic' -and
        @(Get-Process -Name 'cloudmusic' -ErrorAction SilentlyContinue).Count -gt 0) {
        return Invoke-PetCloudMusicCommand -Control $Control
    }
    if (-not $script:Loaded -or $null -eq $script:Manager) { return $false }
    try {
        $session = Get-PetActiveMediaSession
        if ($script:LastSelectedAudioSource -eq 'cloudmusic' -and
            @(Get-Process -Name 'cloudmusic' -ErrorAction SilentlyContinue).Count -gt 0) {
            return Invoke-PetCloudMusicCommand -Control $Control
        }
        if ($null -eq $session) { return $false }
        switch ($Control) {
            'play' {
                return [bool](Invoke-PetAsync -Operation $session.TryPlayAsync() -ResultType ([bool]))
            }
            'pause' {
                return [bool](Invoke-PetAsync -Operation $session.TryPauseAsync() -ResultType ([bool]))
            }
            'toggle' {
                return [bool](Invoke-PetAsync -Operation $session.TryTogglePlayPauseAsync() -ResultType ([bool]))
            }
            'next' {
                return [bool](Invoke-PetAsync -Operation $session.TrySkipNextAsync() -ResultType ([bool]))
            }
            'prev' {
                return [bool](Invoke-PetAsync -Operation $session.TrySkipPreviousAsync() -ResultType ([bool]))
            }
            default { return $false }
        }
    }
    catch {
        return $false
    }
}

# Fallback for players which do not expose a Windows media session.  The meter
# reads the default speaker output, so a sustained non-zero value still counts
# as music even when SMTC cannot identify the player.
function Get-PetAudioPeak {
    $localSoundActive = (Get-Date) -lt $script:LocalSoundUntil
    if ($localSoundActive -and -not $script:SessionMeterReady) { return 0.0 }
    $sources = @(Get-PetAudibleSources)
    if ($sources.Count -gt 0) {
        $selected = @($sources | Where-Object { $_.Name -eq $script:SelectedAudioSource } | Select-Object -First 1)
        $peak = if ($selected.Count -gt 0) { [double]$selected[0].Peak } else { [double]$sources[0].Peak }
        # 来源仍处于 1.5 秒连续性窗口时保持“正在播放”，避免对白间隙造成状态闪烁。
        if ($peak -le 0.015) { return 0.016 }
        return $peak
    }
    # 分应用检测可用时，空列表就表示没有外部声音；扬声器总音量包含桌宠自己的音效。
    if ($script:SessionMeterReady) { return 0.0 }
    if ($localSoundActive) { return 0.0 }
    if (-not $script:MeterReady) {
        try {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PetAudioMeter {
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] public class MMDeviceEnumeratorClass { }
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
    public interface IMMDeviceEnumerator { int EnumAudioEndpoints(int f, uint s, [MarshalAs(UnmanagedType.IUnknown)] out object d); int GetDefaultAudioEndpoint(int f, int r, out IMMDevice d); }
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("D666063F-1587-4E43-81F1-B948E807363F")]
    public interface IMMDevice { int Activate(ref Guid iid, uint c, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o); }
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064")]
    public interface IAudioMeterInformation { int GetPeakValue(out float peak); }
    public static object Meter;
    public static double Peak() {
        try {
            if (Meter == null) { var e=(IMMDeviceEnumerator)(object)new MMDeviceEnumeratorClass(); IMMDevice d; e.GetDefaultAudioEndpoint(0,1,out d); Guid id=typeof(IAudioMeterInformation).GUID; object o; d.Activate(ref id,1,IntPtr.Zero,out o); Meter=o; }
            float peak; ((IAudioMeterInformation)Meter).GetPeakValue(out peak); return peak;
        } catch { return -1; }
    }
}
'@ -ErrorAction Stop
            $script:MeterReady = $true
        }
        catch { return -1 }
    }
    return [PetAudioMeter]::Peak()
}

Export-ModuleMember -Function Initialize-PetMusic, Test-PetMusicAvailable, Get-PetMusicStatus, Invoke-PetMediaCommand, Get-PetAudioPeak, Set-PetLocalSoundActive, Test-PetLocalSoundActive
