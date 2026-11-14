#Requires -Version 5.1

BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    Import-Module -Name (Join-Path -Path $script:root -ChildPath 'WinMediaRefresh.psd1') -Force
    # 全域匯入，讓測試可對 Test-WinMediaAdministrator 建立全域 mock（psd1 只匯出頂層函式）
    Import-Module -Name (Join-Path -Path $script:root -ChildPath 'Modules\WinMediaPath.psm1') -Force
    $script:defaults = Import-PowerShellDataFile -LiteralPath (Join-Path -Path $script:root -ChildPath 'Config\Default.psd1')
}

Describe 'Invoke-WindowsMediaRefresh 前置檢查順序（Step 10a）' -Tag 'Unit' {
    BeforeEach {
        $script:oldOneDrive = $env:OneDrive
        Mock -CommandName Test-WinMediaAdministrator -MockWith { $true }
        Mock -ModuleName WinMediaRefresh -CommandName Test-WinMediaAdministrator -MockWith { $true }
        Mock -ModuleName WinMediaRefresh -CommandName Test-WinMediaDismHost -MockWith { }
    }

    AfterEach {
        if ($null -eq $script:oldOneDrive) { Remove-Item -Path Env:OneDrive -ErrorAction SilentlyContinue }
        else { $env:OneDrive = $script:oldOneDrive }
    }

    It '非 -WhatIf 且母檔不存在時，於管理員檢查通過後丟出「找不到母檔」' {
        $iso = Join-Path -Path $TestDrive -ChildPath 'missing.iso'
        { Invoke-WindowsMediaRefresh -SourceIso $iso -Config $script:defaults -WorkDir (Join-Path -Path $TestDrive -ChildPath 'w') -OutputDir (Join-Path -Path $TestDrive -ChildPath 'out') } |
            Should -Throw '*找不到母檔*'
    }

    It '沒有系統管理員權限時丟出原訊息' {
        Mock -ModuleName WinMediaRefresh -CommandName Test-WinMediaAdministrator -MockWith { $false }
        $iso = Join-Path -Path $TestDrive -ChildPath 'missing.iso'
        { Invoke-WindowsMediaRefresh -SourceIso $iso -Config $script:defaults -WorkDir (Join-Path -Path $TestDrive -ChildPath 'w') -OutputDir (Join-Path -Path $TestDrive -ChildPath 'out') } |
            Should -Throw '*需要系統管理員權限*'
    }

    It '網路 WorkDir 於管理員檢查之前拒絕' {
        Mock -ModuleName WinMediaRefresh -CommandName Test-WinMediaAdministrator -MockWith { $false }
        { Invoke-WindowsMediaRefresh -SourceIso 'D:\x.iso' -Config $script:defaults -WorkDir '\\server\share\w' -OutputDir (Join-Path -Path $TestDrive -ChildPath 'out') } |
            Should -Throw '*WorkDir 不支援網路路徑*'
    }

    It 'WorkDir 位於 OneDrive 內時只警告，流程仍到「找不到母檔」' {
        $env:OneDrive = Join-Path -Path $TestDrive -ChildPath 'OneDrive'
        $iso = Join-Path -Path $TestDrive -ChildPath 'missing.iso'
        $message = $null
        $warnings = $null
        try {
            Invoke-WindowsMediaRefresh -SourceIso $iso -Config $script:defaults -WorkDir (Join-Path -Path $env:OneDrive -ChildPath 'w') -OutputDir (Join-Path -Path $TestDrive -ChildPath 'out') -WarningVariable warnings -WarningAction SilentlyContinue
        }
        catch {
            $message = $_.Exception.Message
        }
        $message | Should -BeLike '*找不到母檔*'
        "$warnings" | Should -BeLike '*OneDrive*'
    }
}
