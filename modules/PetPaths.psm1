Set-StrictMode -Version Latest

function Get-PetDataRoot {
    param([Parameter(Mandatory)][string]$ApplicationRoot)
    # 保留现有测试和用户显式覆盖，其次才根据安装标记选择持久数据目录。
    if(-not [string]::IsNullOrWhiteSpace($env:XIAOTAIYANG_DATA_DIR)){return $env:XIAOTAIYANG_DATA_DIR}
    if(Test-Path -LiteralPath (Join-Path $ApplicationRoot 'installed-mode.flag') -PathType Leaf){
        $localData=[Environment]::GetFolderPath('LocalApplicationData')
        if([string]::IsNullOrWhiteSpace($localData)){throw '无法确定当前用户的数据目录。'}
        return (Join-Path $localData 'XiaoTaiYangDesktopPet/data')
    }
    return (Join-Path $ApplicationRoot 'data')
}

Export-ModuleMember -Function Get-PetDataRoot
