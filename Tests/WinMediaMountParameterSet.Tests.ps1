#Requires -Version 5.1

# Q3 項目 5（僅測試）：Mount-WindowsImage 的參數集必須能同時接受 Get-WinMediaMountSwitch 產生的開關。
# 只讀取命令的參數中繼資料，不呼叫 DISM、不掛載映像。Windows PowerShell 5.1 以外會略過。

BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    Import-Module -Name (Join-Path -Path $script:root -ChildPath 'Modules\WinMediaPath.psm1') -Force
    $script:isDesktop = $PSVersionTable.PSEdition -eq 'Desktop'
    $script:dismCmd = $null
    if ($script:isDesktop) {
        Import-Module -Name DISM -ErrorAction SilentlyContinue
        $script:dismCmd = Get-Command -Name Mount-WindowsImage -ErrorAction SilentlyContinue
    }
}

Describe 'Mount-WindowsImage parameter sets accept the mount switches (metadata only)' -Tag 'Unit' {
    It '在 Windows PowerShell 5.1 取得 Mount-WindowsImage 的參數中繼資料' {
        if (-not $script:isDesktop) { Set-ItResult -Skipped -Because '需要 Windows PowerShell 5.1（DISM 模組）'; return }
        $script:dismCmd | Should -Not -BeNullOrEmpty
    }

    It '<Case> 的開關能落在同一個 Mount-WindowsImage 參數集內' -ForEach @(
        @{ Case = 'Optimize'; Config = @{ MountOptimize = $true; MountCheckIntegrity = $false }; Keys = @('Optimize') }
        @{ Case = 'CheckIntegrity'; Config = @{ MountOptimize = $false; MountCheckIntegrity = $true }; Keys = @('CheckIntegrity') }
        @{ Case = 'both'; Config = @{ MountOptimize = $true; MountCheckIntegrity = $true }; Keys = @('Optimize', 'CheckIntegrity') }
    ) {
        if (-not $script:isDesktop -or -not $script:dismCmd) { Set-ItResult -Skipped -Because '需要 Windows PowerShell 5.1（DISM 模組）'; return }
        $switches = Get-WinMediaMountSwitch -Config $Config
        foreach ($key in $Keys) { $switches.ContainsKey($key) | Should -BeTrue -Because "switch $key expected" }
        $fit = @($script:dismCmd.ParameterSets | Where-Object {
            $names = @($_.Parameters.Name)
            @($Keys | Where-Object { $names -notcontains $_ }).Count -eq 0
        })
        $fit.Count | Should -BeGreaterThan 0 -Because "no Mount-WindowsImage parameter set accepts: $($Keys -join ', ')"
    }
}
