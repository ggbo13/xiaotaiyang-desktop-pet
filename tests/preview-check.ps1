$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'modules/PetGrowth.psm1') -Force
foreach($case in @(@{scale=1.0;width=82;height=140},@{scale=1.5;width=123;height=210},@{scale=2.0;width=164;height=280})){
    $image=& (Get-Module PetGrowth) {param($path,$scale) New-PetPreviewImage -Path $path -MaxWidth 115 -MaxHeight 140 -DisplayScale $scale} (Join-Path $root 'assets/pet.png') $case.scale
    try{
        if($image.Width -ne $case.width -or $image.Height -ne $case.height){throw "缩放$($case.scale)预览尺寸错误：$($image.Width)x$($image.Height)，应为$($case.width)x$($case.height)"}
        if($image.GetPixel(0,0).A -ne 0){throw '缩略图未保留透明背景'}
    }finally{$image.Dispose()}
}
Write-Output 'PREVIEW CHECK PASSED: 100% / 150% / 200%'
