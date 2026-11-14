#Requires -Version 5.1

# Q3 項目 3 RED：平行暫存空間估算（每個目標索引一份 idx WIM ＋ 一份 merged.wim）。純函式，不碰檔案系統。
# 函式只被 dot-source 進根模組、未匯出，故於模組範圍內執行。

BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    Import-Module -Name (Join-Path -Path $script:root -ChildPath 'WinMediaRefresh.psd1') -Force

    function Invoke-Staging {
        param([int[]]$Targets, [double]$InstallWimGB)
        & (Get-Module -Name WinMediaRefresh) {
            param($t, $g)
            Get-WinMediaParallelStagingGB -Targets $t -InstallWimGB $g
        } $Targets $InstallWimGB
    }
}

Describe 'Parallel staging estimate' -Tag 'Unit' {
    It '每個目標索引一份 idx WIM，加上一份 merged.wim，共 (Targets + 1) 份 install.wim' {
        Invoke-Staging -Targets @(2, 3) -InstallWimGB 4 | Should -Be 12
    }

    It '單一目標仍需 idx WIM 與 merged.wim 兩份' {
        Invoke-Staging -Targets @(5) -InstallWimGB 4 | Should -Be 8
    }

    It 'install.wim 大小為 0 時估算為 0' {
        Invoke-Staging -Targets @(2, 3) -InstallWimGB 0 | Should -Be 0
    }

    It 'Targets 為空時丟出錯誤' {
        { Invoke-Staging -Targets @() -InstallWimGB 4 } | Should -Throw
    }
}
