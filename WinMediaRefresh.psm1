Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:ModuleRoot = $PSScriptRoot

# 獨立模組：通用層放在 PSModules（可供其他專案使用）
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'PSModules\Common\WinMediaLog.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'PSModules\Common\WinMediaOperation.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'PSModules\Common\WinMediaProcess.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'PSModules\Common\PathSanitize.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'PSModules\Imaging\WinMediaAdk.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'PSModules\Imaging\WinMediaDism.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'PSModules\Imaging\WinMediaWimlib.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'PSModules\Imaging\WinMediaEsd.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'PSModules\Imaging\WinMediaImage.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'PSModules\Imaging\WinMediaVirtualEdition.psm1') -Force

# 專案專屬功能：每個功能一個模組，位於 Modules\
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Modules\WinMediaPath.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Modules\WinMediaDriver.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Modules\WinMediaLxp.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Modules\WinMediaAppx.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Modules\WinMediaPackage.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Modules\WinMediaUpdate.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Modules\WinMediaLangFod.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Modules\WinMediaStoreApps.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Modules\WinMediaIndexInfo.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Modules\WinMediaBootFiles.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Modules\WinMediaDefender.psm1') -Force

# 組合點：主流程組合上述所有模組，因此留在根模組內
. (Join-Path -Path $PSScriptRoot -ChildPath 'Public\Invoke-WindowsMediaRefresh.ps1')

Export-ModuleMember -Function @(
    'Invoke-WindowsMediaRefresh',
    'Export-WinMediaEsd',
    'Add-WinMediaVirtualEdition',
    'Get-WinMediaPackageCategory',
    'Save-WinMediaUpdate'
)
