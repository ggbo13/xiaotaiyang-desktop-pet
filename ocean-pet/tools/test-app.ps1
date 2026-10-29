param([Parameter(Mandatory)][string]$AppDirectory)
$ErrorActionPreference='Stop'
$exe=Join-Path $AppDirectory 'OceanMaid.exe'
$testDir=Join-Path $AppDirectory ('verification-'+[guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $testDir | Out-Null
foreach($kind in @('core','desktop')){
    $report=Join-Path $testDir ($kind+'.json')
    $arguments=@(if($kind -eq 'core'){'--self-test'}else{'--smoke';'--data-dir';(Join-Path $testDir 'isolated-data')})
    $arguments+=@('--report',$report)
    & $exe @arguments | Out-Null
    if($LASTEXITCODE -ne 0){throw ([IO.File]::ReadAllText($report))}
    $result=Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
    if(-not $result.passed){throw '测试报告未通过。'}
    Write-Host ($kind+': '+($result.checks -join '；'))
}
Write-Output $testDir
