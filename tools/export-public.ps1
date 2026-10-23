param([Parameter(Mandatory)][string]$Destination)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ReleaseSupport.psm1') -Force
New-PetPublicSnapshot -ProjectRoot (Split-Path $PSScriptRoot -Parent) -Destination $Destination
