BeforeAll {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\Modules\WinMediaPackage.psm1') -Force
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\Modules\WinMediaUpdate.psm1') -Force
    $script:logCfg = @{
        LogLevel     = 'Info'
        LogFile      = (Join-Path -Path $TestDrive -ChildPath 'run.log')
        DebugTrace   = $false
        OperationLog = (Join-Path -Path $TestDrive -ChildPath 'op.log')
    }
}

Describe 'Resolve-WinMediaCumulativeSet 缺版本時整組改依 KB 編號' -Tag 'Unit' {
    It '目標 LCU 讀不到版本、另一包有版本：仍以較大 KB 為目標，不因缺值把它降為 checkpoint' {
        $paths = @('C:\pkg\Windows11.0-KB5127936-x64.msu', 'C:\pkg\Windows11.0-KB5043080-x64.msu')
        $versions = @{ 'C:\pkg\Windows11.0-KB5043080-x64.msu' = [version]'26100.1742.1.10' }
        $result = Resolve-WinMediaCumulativeSet -Paths $paths -Config $script:logCfg -Versions $versions
        $result.Target | Should -Be 'C:\pkg\Windows11.0-KB5127936-x64.msu'
    }

    It '兩包都有版本時依版本排序：版本較新者為目標' {
        $paths = @('C:\pkg\Windows11.0-KB5999999-x64.msu', 'C:\pkg\Windows11.0-KB5127936-x64.msu')
        $versions = @{
            'C:\pkg\Windows11.0-KB5999999-x64.msu' = [version]'26100.9000.1.1'
            'C:\pkg\Windows11.0-KB5127936-x64.msu' = [version]'26100.9818.1.42'
        }
        $result = Resolve-WinMediaCumulativeSet -Paths $paths -Config $script:logCfg -Versions $versions
        $result.Target | Should -Be 'C:\pkg\Windows11.0-KB5127936-x64.msu'
    }
}

Describe 'Select-WinMediaNewestPackage 混合缺值' -Tag 'Unit' {
    It '排第一的目標沒有版本、另一包有版本：回傳排第一者' {
        $paths = @('C:\pkg\target.msu', 'C:\pkg\other.msu')
        $versions = @{ 'C:\pkg\other.msu' = [version]'26100.9815.1.3' }
        Select-WinMediaNewestPackage -Paths $paths -Versions $versions | Should -Be 'C:\pkg\target.msu'
    }
}

Describe 'Get-WinMediaPackageCategory 略過 AggregatedMetadata 中繼資料' -Tag 'Unit' {
    It '只有 AggregatedMetadata.cab 時不分類、不展開，所有類別皆為空' {
        $pkgDir = Join-Path -Path $TestDrive -ChildPath 'pkg'
        $expandDir = Join-Path -Path $TestDrive -ChildPath 'expand'
        New-Item -ItemType Directory -Path $pkgDir -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path -Path $pkgDir -ChildPath '6c7bf258-2632-47dd-83ee-c23945978da1.AggregatedMetadata.cab'), 'not-a-cab')
        $result = Get-WinMediaPackageCategory -PackageDir $pkgDir -ExpandDir $expandDir -Config $script:logCfg
        @($result.LCU).Count | Should -Be 0
        @($result.Unclassified).Count | Should -Be 0
        @($result.SSU).Count | Should -Be 0
    }
}
