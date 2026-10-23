$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$projectRoot=Split-Path $PSScriptRoot -Parent
$script:Failures=0
function Check([string]$Name,[scriptblock]$Body){try{& $Body;Write-Output "PASS: $Name"}catch{$script:Failures++;Write-Output "FAIL: $Name -- $($_.Exception.Message)"}}
function Assert($Value,[string]$Message){if(-not $Value){throw $Message}}
Import-Module (Join-Path $projectRoot 'modules/PetAutoStart.psm1') -Force
Check '自启检查区分已安装目标与旧便携路径，不写真实注册表' {
    & (Get-Module PetAutoStart) {
        $script:ProbeRunValue=Get-PetAutoStartCommand -EntryScript 'D:\旧桌宠\xiaotaiyang.ps1'
        function script:Get-ItemProperty {param($Path,$Name,$ErrorAction) return [pscustomobject]@{'小太阳桌宠'=$script:ProbeRunValue}}
        $entry='D:\应用 目录\xiaotaiyang.ps1'
        if(Test-PetAutoStart -EntryScript $entry){throw '旧路径被当成当前安装路径'}
        $script:ProbeRunValue=Get-PetAutoStartCommand -EntryScript $entry
        if(-not (Test-PetAutoStart -EntryScript $entry)){throw '正确目标未被识别'}
        if(-not (Test-PetAutoStart)){throw '无参数兼容检查失效'}
    }
}
Check '安装版两个启动入口统一自启路径，并验证当前自启目标' {
    $fixture=Join-Path ([IO.Path]::GetTempPath()) ('桌宠 安装入口 '+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $fixture | Out-Null
    [IO.File]::WriteAllText((Join-Path $fixture 'installed-mode.flag'),'installed')
    foreach($entry in @('xiaotaiyang.ps1','小太阳.ps1')){
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot $entry),[ref]$tokens,[ref]$errors)
        $assignment=$ast.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$script:EntryScript'} | Select-Object -First 1
        $script:Root=$fixture
        $probeCurrentEntry=Join-Path $fixture $entry
        $parts=@($assignment.Extent.Text.Replace('$MyInvocation.MyCommand.Path','$probeCurrentEntry'))
        $parts+=@($ast.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.IfStatementAst] -and $_.Extent.Text -match '^if\(Test-Path.*installed-mode.flag'} | ForEach-Object {$_.Extent.Text})
        . ([scriptblock]::Create($parts -join "`n"))
        Assert ($script:EntryScript -eq (Join-Path $fixture 'xiaotaiyang.ps1')) "入口未规范化：$entry"
        Assert ($ast.Extent.Text.Contains('Test-PetAutoStart -EntryScript $script:EntryScript')) "启动未验证已注册目标：$entry"
    }
}
Check '目录页和写入前共用注册安装位置校验' {
    $source=Get-Content -LiteralPath (Join-Path $projectRoot 'tools/installer.nsi') -Raw
    $directory=[regex]::Match($source,'(?s)Function CheckInstallDirectory\s+(.*?)FunctionEnd').Groups[1].Value
    Assert ($directory.Contains('ReadRegStr') -and $directory.Contains('InstallLocation')) '共用校验缺少注册安装位置'
    $section=[regex]::Match($source,'(?s)Section "安装小太阳桌宠"\s+(.*?)!include').Groups[1].Value
    Assert ($section.Contains('Call CheckInstallDirectory') -and $section.Contains('Abort')) '实际写入前未拒绝错误目录'
}
Check '卸载兼容两个安装入口，仍只匹配本目录' {
    $source=Get-Content -LiteralPath (Join-Path $projectRoot 'tools/installer.nsi') -Raw
    Assert ($source.Contains('$INSTDIR\xiaotaiyang.ps1') -and $source.Contains('$INSTDIR\小太阳.ps1')) '缺少中文入口自启清理兼容'
}
Write-Output "INSTALLATION POLICY: failures=$script:Failures"
if($script:Failures){exit 1}
