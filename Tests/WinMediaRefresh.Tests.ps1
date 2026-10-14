#Requires -Version 5.1

Import-Module -Name (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'WinMediaRefresh.psd1') -Force

Describe 'Test-WinMediaVirtualEdition（§2.7.1、§2.7.7、§2.7.8）' -Tag 'Unit' {
    InModuleScope WinMediaRefresh {
        It '沒有要求的版本時回傳空陣列' {
            @(Test-WinMediaVirtualEdition -Build 22621 -SourceEditionIds @('EnterpriseS') -RequestedEditions @()).Count | Should -Be 0
        }

        It '來源不含 EnterpriseS 時中止' {
            { Test-WinMediaVirtualEdition -Build 22621 -SourceEditionIds @('Professional') -RequestedEditions @('IoTEnterpriseS') } |
                Should -Throw '*EnterpriseS*'
        }

        It '未要求虛擬版本時，即使來源不是 EnterpriseS 也不中止' {
            { Test-WinMediaVirtualEdition -Build 22621 -SourceEditionIds @('Professional') -RequestedEditions @() } | Should -Not -Throw
        }

        It 'build 低於 17063 時中止' {
            { Test-WinMediaVirtualEdition -Build 17062 -SourceEditionIds @('EnterpriseS') -RequestedEditions @('IoTEnterpriseS') } |
                Should -Throw '*17063*'
        }

        It 'IoTEnterpriseS 的 build 門檻為 19041' {
            { Test-WinMediaVirtualEdition -Build 19040 -SourceEditionIds @('EnterpriseS') -RequestedEditions @('IoTEnterpriseS') } |
                Should -Throw '*19041*'
        }

        It 'IoTEnterpriseS 缺 SPP 檔時中止，不靜默略過' {
            { Test-WinMediaVirtualEdition -Build 22621 -SourceEditionIds @('EnterpriseS') -RequestedEditions @('IoTEnterpriseS') -IoTEnterpriseSSppPresent $false } |
                Should -Throw '*xrm-ms*'
        }

        It '合法 token 原樣回傳' {
            $result = Test-WinMediaVirtualEdition -Build 22621 -SourceEditionIds @('EnterpriseS') -RequestedEditions @('IoTEnterpriseS')
            $result | Should -Be @('IoTEnterpriseS')
        }

        It '未知 token 中止' {
            { Test-WinMediaVirtualEdition -Build 22621 -SourceEditionIds @('EnterpriseS') -RequestedEditions @('NoSuchEdition') } |
                Should -Throw '*未知*'
        }
    }
}

Describe 'Protect-WinMediaLogValue（§4.1）' -Tag 'Unit' {
    InModuleScope WinMediaRefresh {
        It '遮蔽 --proxy-user 後的值' {
            Protect-WinMediaLogValue -Value 'curl --proxy-user bob:hunter2 http://x' | Should -Be 'curl --proxy-user *** http://x'
        }

        It '遮蔽 -u 後的值' {
            Protect-WinMediaLogValue -Value 'tool -u alice:pw' | Should -Be 'tool -u ***'
        }

        It '遮蔽 key=value 形式的 password' {
            Protect-WinMediaLogValue -Value 'password=abc123 other=1' | Should -Be 'password=*** other=1'
        }

        It '空字串原樣回傳' {
            Protect-WinMediaLogValue -Value '' | Should -Be ''
        }
    }
}

Describe 'Config/Default.psd1 設定鍵（§3.1）' -Tag 'Unit' {
    BeforeAll {
        $script:config = Import-PowerShellDataFile -LiteralPath (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Config\Default.psd1')
    }

    It '包含 §3.1 所列的全部鍵' {
        $required = 'PackageDir', 'WorkDir', 'MountDir', 'OutputDir', 'Languages', 'Indexes', 'ResetBase', 'OutputFormat',
            'Wimlib', 'DismProvider', 'AdkRoot', 'VirtualEditions', 'DeleteSourceEdition', 'LogLevel', 'DebugTrace'
        foreach ($key in $required) {
            $script:config.ContainsKey($key) | Should -BeTrue -Because "缺少鍵 $key"
        }
    }

    It 'OutputFormat 只允許 WIM 或 ESD' {
        $script:config.OutputFormat | Should -BeIn @('WIM', 'ESD')
    }

    It 'DismProvider 只允許 Inbox 或 ADK' {
        $script:config.DismProvider | Should -BeIn @('Inbox', 'ADK')
    }

    It 'WorkDir 預設留空，由入口腳本依執行位置決定' {
        $script:config.WorkDir | Should -BeNullOrEmpty
    }

    It 'OutputDir 預設留空，由入口腳本依執行位置決定' {
        $script:config.OutputDir | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-WinMediaMountDir（Convert-UUP.cmd:4648–4654）' -Tag 'Unit' {
    InModuleScope WinMediaRefresh {
        It '指定 MountDir 時原樣使用（去除尾端反斜線）' {
            Resolve-WinMediaMountDir -WorkDir 'C:\WinMediaWork' -MountDir 'E:\Mnt\' | Should -Be 'E:\Mnt'
        }

        It '未指定且工作目錄在系統碟時，預設為系統碟根目錄\MountUUP' {
            Resolve-WinMediaMountDir -WorkDir (Join-Path -Path $env:SystemDrive -ChildPath 'WinMediaWork') -MountDir '' |
                Should -Be (Join-Path -Path ($env:SystemDrive + '\') -ChildPath 'MountUUP')
        }

        It '工作目錄所在磁碟為 NTFS 時，預設為該磁碟根目錄\MountUUP' {
            $other = if ($env:SystemDrive -ieq 'Z:') { 'Y:' } else { 'Z:' }
            Mock -ModuleName WinMediaRefresh Get-Volume { [pscustomobject]@{ FileSystem = 'NTFS' } }
            Resolve-WinMediaMountDir -WorkDir "$other\WinMediaWork" -MountDir '' | Should -Be "$other\MountUUP"
        }

        It '工作目錄所在磁碟非 NTFS 時，回退到系統碟\MountUUP' {
            $other = if ($env:SystemDrive -ieq 'Z:') { 'Y:' } else { 'Z:' }
            Mock -ModuleName WinMediaRefresh Get-Volume { [pscustomobject]@{ FileSystem = 'FAT32' } }
            Resolve-WinMediaMountDir -WorkDir "$other\WinMediaWork" -MountDir '' | Should -Be ($env:SystemDrive + '\MountUUP')
        }

        It '拒絕磁碟根目錄作為掛載目錄' {
            { Resolve-WinMediaMountDir -WorkDir 'C:\WinMediaWork' -MountDir 'C:\' } | Should -Throw '*磁碟根目錄*'
        }

        It '拒絕相對路徑作為掛載目錄' {
            { Resolve-WinMediaMountDir -WorkDir 'C:\WinMediaWork' -MountDir 'mnt' } | Should -Throw '*絕對路徑*'
        }
    }
}

Describe 'Invoke-WindowsMediaRefresh -WhatIf' -Tag 'Unit' {
    BeforeAll {
        $script:config = Import-PowerShellDataFile -LiteralPath (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Config\Default.psd1')
        $script:config.LogDir = Join-Path -Path $env:TEMP -ChildPath 'WinMediaRefreshTests'
        $script:config.OperationLog = Join-Path -Path $script:config.LogDir -ChildPath 'OperationLog.txt'
    }

    It 'WorkDir 為空或相對路徑時中止，不進入後續步驟' {
        { Invoke-WindowsMediaRefresh -SourceIso 'D:\nonexistent.iso' -Config $script:config -Confirm:$false } |
            Should -Throw '*WorkDir 必須為絕對路徑*'
        $relative = $script:config.Clone()
        $relative.WorkDir = 'work'
        { Invoke-WindowsMediaRefresh -SourceIso 'D:\nonexistent.iso' -Config $relative -Confirm:$false } |
            Should -Throw '*WorkDir 必須為絕對路徑*'
    }

    It '回傳步驟清單且不呼叫 DISM Cmdlet' {
        Mock -ModuleName WinMediaRefresh Mount-WindowsImage { }
        Mock -ModuleName WinMediaRefresh Dismount-WindowsImage { }
        Mock -ModuleName WinMediaRefresh Add-WindowsPackage { }
        Mock -ModuleName WinMediaRefresh Mount-DiskImage { }

        $steps = Invoke-WindowsMediaRefresh -SourceIso 'D:\nonexistent.iso' -Config $script:config -WhatIf

        @($steps).Count | Should -BeGreaterThan 10
        Should -Invoke -ModuleName WinMediaRefresh Mount-WindowsImage -Times 0 -Exactly
        Should -Invoke -ModuleName WinMediaRefresh Add-WindowsPackage -Times 0 -Exactly
        Should -Invoke -ModuleName WinMediaRefresh Mount-DiskImage -Times 0 -Exactly
    }
}
