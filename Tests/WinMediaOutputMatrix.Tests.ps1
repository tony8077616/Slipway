#Requires -Version 5.1

BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    Import-Module -Name (Join-Path -Path $script:root -ChildPath 'WinMediaRefresh.psd1') -Force
    $script:defaults = Import-PowerShellDataFile -LiteralPath (Join-Path -Path $script:root -ChildPath 'Config\Default.psd1')
}

Describe 'Invoke-WindowsMediaRefresh 輸出形式與工具需求（Step 10b，哨兵於 Assert-WinMediaOutputDir）' -Tag 'Unit' {
    BeforeEach {
        Mock -ModuleName WinMediaRefresh -CommandName Test-WinMediaAdministrator -MockWith { $true }
        Mock -ModuleName WinMediaRefresh -CommandName Test-WinMediaDismHost -MockWith { }
        Mock -ModuleName WinMediaRefresh -CommandName Resolve-WinMediaAdk -MockWith { }
        Mock -ModuleName WinMediaRefresh -CommandName Resolve-WinMediaWimlib -MockWith { 'C:\fake\wimlib-imagex.exe' }
        Mock -ModuleName WinMediaRefresh -CommandName Resolve-WinMediaOscdimg -MockWith { 'C:\fake\oscdimg.exe' }
        Mock -ModuleName WinMediaRefresh -CommandName Resolve-WinMediaDriverSet -MockWith { $null }
        Mock -ModuleName WinMediaRefresh -CommandName Resolve-WinMediaAppxList -MockWith { @() }
        Mock -ModuleName WinMediaRefresh -CommandName Resolve-WinMediaLangFodSet -MockWith { $null }
        Mock -ModuleName WinMediaRefresh -CommandName Resolve-WinMediaStoreAppSet -MockWith { $null }
        Mock -ModuleName WinMediaRefresh -CommandName Assert-WinMediaOutputDir -MockWith { throw 'SENTINEL' }
    }

    BeforeAll {
        function Get-MatrixConfig {
            param([string]$Format, [string]$Form)
            $cfg = $script:defaults.Clone()
            $cfg.OutputFormat = $Format
            $cfg.OutputForm = $Form
            $cfg.DefenderExclusions = $false
            $cfg.PackageDir = Join-Path -Path $TestDrive -ChildPath 'pkg'
            New-Item -ItemType Directory -Path $cfg.PackageDir -Force | Out-Null
            return $cfg
        }
    }

    It 'OutputFormat=<Format> OutputForm=[<Form>] 呼叫 oscdimg <Oscdimg> 次、wimlib <Wimlib> 次' -ForEach @(
        @{ Format = 'WIM'; Form = ''; Oscdimg = 1; Wimlib = 1 }
        @{ Format = 'WIM'; Form = 'Iso'; Oscdimg = 1; Wimlib = 1 }
        @{ Format = 'WIM'; Form = 'Folder'; Oscdimg = 0; Wimlib = 1 }
        @{ Format = 'WIM'; Form = 'Image'; Oscdimg = 0; Wimlib = 1 }
        @{ Format = 'ESD'; Form = ''; Oscdimg = 1; Wimlib = 2 }
        @{ Format = 'ESD'; Form = 'Iso'; Oscdimg = 1; Wimlib = 2 }
        @{ Format = 'ESD'; Form = 'Folder'; Oscdimg = 0; Wimlib = 2 }
        @{ Format = 'ESD'; Form = 'Image'; Oscdimg = 0; Wimlib = 2 }
    ) {
        $cfg = Get-MatrixConfig -Format $Format -Form $Form
        $iso = Join-Path -Path $TestDrive -ChildPath 'source.iso'
        New-Item -ItemType File -Path $iso -Force | Out-Null
        { Invoke-WindowsMediaRefresh -SourceIso $iso -Config $cfg -WorkDir (Join-Path -Path $TestDrive -ChildPath 'w') -OutputDir (Join-Path -Path $TestDrive -ChildPath 'out') } | Should -Throw '*SENTINEL*'
        Should -Invoke -ModuleName WinMediaRefresh -CommandName Resolve-WinMediaOscdimg -Times $Oscdimg -Exactly
        Should -Invoke -ModuleName WinMediaRefresh -CommandName Resolve-WinMediaWimlib -Times $Wimlib -Exactly
    }

    It '參數 -OutputForm Folder 覆寫空白的設定檔值，不呼叫 oscdimg' {
        $cfg = Get-MatrixConfig -Format 'WIM' -Form ''
        $iso = Join-Path -Path $TestDrive -ChildPath 'source.iso'
        New-Item -ItemType File -Path $iso -Force | Out-Null
        { Invoke-WindowsMediaRefresh -SourceIso $iso -Config $cfg -OutputForm 'Folder' -WorkDir (Join-Path -Path $TestDrive -ChildPath 'w') -OutputDir (Join-Path -Path $TestDrive -ChildPath 'out') } | Should -Throw '*SENTINEL*'
        Should -Invoke -ModuleName WinMediaRefresh -CommandName Resolve-WinMediaOscdimg -Times 0 -Exactly
    }
}
