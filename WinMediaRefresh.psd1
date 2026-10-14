@{
    RootModule        = 'WinMediaRefresh.psm1'
    ModuleVersion     = '0.5.0'
    GUID              = '6b1f0c2e-3d4a-4e8b-9a7c-2f5d8e1b4c10'
    Author            = 'MongWu'
    Description       = '以更新包更新原版 Windows 10 21H2 LTSC / Windows 11 安裝 ISO，支援 ESD/WIM 與虛擬版本（§1–§5）。'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Invoke-WindowsMediaRefresh',
        'Export-WinMediaEsd',
        'Add-WinMediaVirtualEdition',
        'Get-WinMediaPackageCategory'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags = @('Windows', 'ISO', 'DISM', 'LTSC', 'Servicing')
        }
    }
}
