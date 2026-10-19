#Requires -Version 5.1

BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    Import-Module -Name (Join-Path -Path $script:root -ChildPath 'Modules\WinMediaBootFiles.psm1') -Force
}

Describe 'Test-WinMediaKernelConsistency（步驟 9 守衛，Microsoft「用最近版本」規則）' -Tag 'Unit' {
    It '開機索引與安裝映像同版時通過（26H2 9711）' {
        { Test-WinMediaKernelConsistency -BootKernel '10.0.26100.9711' -WinreKernel '10.0.26100.9711' -InstallKernel '10.0.26100.9711' -SafeOsApplied $true -BootIndex 1 } | Should -Not -Throw
    }

    It '已套用 SafeOS DU、開機索引等於 WinRE 且低於安裝映像：通過且不發警告（9807）' {
        $warnings = $null
        { Test-WinMediaKernelConsistency -BootKernel '10.0.26100.9711' -WinreKernel '10.0.26100.9711' -InstallKernel '10.0.26100.9807' -SafeOsApplied $true -BootIndex 1 -WarningVariable warnings -WarningAction Continue } | Should -Not -Throw
        $warnings | Should -BeNullOrEmpty
    }

    It '未套用 SafeOS DU 時即使開機索引等於 WinRE 也中止（9444 缺輸入）' {
        { Test-WinMediaKernelConsistency -BootKernel '10.0.26100.9444' -WinreKernel '10.0.26100.9444' -InstallKernel '10.0.26100.9807' -SafeOsApplied $false -BootIndex 1 } | Should -Throw '*索引 1*'
    }

    It '開機索引既不等於 WinRE 也不等於安裝映像時中止' {
        { Test-WinMediaKernelConsistency -BootKernel '10.0.26100.9444' -WinreKernel '10.0.26100.9711' -InstallKernel '10.0.26100.9807' -SafeOsApplied $true -BootIndex 2 } | Should -Throw '*索引 2*'
    }

    It '錯誤訊息列出開機、WinRE、安裝三個版本' {
        { Test-WinMediaKernelConsistency -BootKernel '10.0.26100.9444' -WinreKernel '10.0.26100.9711' -InstallKernel '10.0.26100.9807' -SafeOsApplied $true -BootIndex 1 } |
            Should -Throw '*10.0.26100.9444*10.0.26100.9711*10.0.26100.9807*'
    }
}
