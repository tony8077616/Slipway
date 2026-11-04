#Requires -Version 5.1

BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    Import-Module -Name (Join-Path -Path $script:root -ChildPath 'WinMediaRefresh.psd1') -Force
    Import-Module -Name (Join-Path -Path $script:root -ChildPath 'Modules\WinMediaPath.psm1') -Force
    $script:defaults = Import-PowerShellDataFile -LiteralPath (Join-Path -Path $script:root -ChildPath 'Config\Default.psd1')
}

Describe 'Config/Default.psd1 新增鍵的預設值' -Tag 'Unit' {
    It '包含 Step 8 的新鍵，且預設值正確' {
        $script:defaults.OutputForm | Should -Be ''
        $script:defaults.ScratchDirectory | Should -Be ''
        $script:defaults.MountOptimize | Should -BeFalse
        $script:defaults.MountCheckIntegrity | Should -BeFalse
        $script:defaults.MountParallelCount | Should -Be 1
        $script:defaults.MountSpaceEstimateGB | Should -Be 30
        $script:defaults.OptimizationTarget | Should -Be ''
    }
}

Describe 'Resolve-WinMediaMountOption' -Tag 'Unit' {
    It '缺少新鍵的設定補上預設值（舊設定檔相容）' {
        $cfg = Resolve-WinMediaMountOption -Config @{ OutputFormat = 'WIM' }
        $cfg.OutputForm | Should -Be ''
        $cfg.MountParallelCount | Should -Be 1
        $cfg.MountSpaceEstimateGB | Should -Be 30
        $cfg.MountOptimize | Should -BeFalse
    }

    It '既有的值不被覆寫' {
        $cfg = Resolve-WinMediaMountOption -Config @{ OutputForm = 'Folder'; MountParallelCount = 2 }
        $cfg.OutputForm | Should -Be 'Folder'
        $cfg.MountParallelCount | Should -Be 2
    }

    It 'OutputForm 只允許 Iso、Folder、Image 或空白' {
        { Resolve-WinMediaMountOption -Config @{ OutputForm = 'Dvd' } } | Should -Throw '*OutputForm*'
    }

    It 'MountParallelCount 小於 1 或非整數時丟出' {
        { Resolve-WinMediaMountOption -Config @{ MountParallelCount = 0 } } | Should -Throw '*MountParallelCount*'
        { Resolve-WinMediaMountOption -Config @{ MountParallelCount = 1.5 } } | Should -Throw '*MountParallelCount*'
    }

    It 'MountSpaceEstimateGB 必須大於 0' {
        { Resolve-WinMediaMountOption -Config @{ MountSpaceEstimateGB = 0 } } | Should -Throw '*MountSpaceEstimateGB*'
    }
}

Describe 'Invoke-WindowsMediaRefresh -OutputForm 參數' -Tag 'Unit' {
    It '參數存在，且 ValidateSet 只允許 Iso、Folder、Image' {
        $param = (Get-Command -Name Invoke-WindowsMediaRefresh).Parameters['OutputForm']
        $param | Should -Not -BeNullOrEmpty
        $validate = @($param.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] })
        $validate.Count | Should -Be 1
        @($validate[0].ValidValues) | Should -Be @('Iso', 'Folder', 'Image')
    }
}
