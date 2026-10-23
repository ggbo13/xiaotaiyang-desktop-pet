$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$files=@(Get-ChildItem -LiteralPath (Join-Path $root 'modules'),(Join-Path $root 'tools'),(Join-Path $root 'tests') -File | Where-Object {$_.Extension -in @('.ps1','.psm1')})
$files+=Get-Item -LiteralPath (Join-Path $root 'xiaotaiyang.ps1'),(Join-Path $root '小太阳.ps1')
foreach($file in $files){
    $tokens=$null;$errors=$null
    $null=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    if($errors){throw ("语法检查失败：{0}：{1}" -f $file.Name,($errors.Message -join '; '))}
}
Write-Output "RELEASE SYNTAX PASSED: $($files.Count) files"
