#Requires -Version 5.1

BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    Import-Module -Name (Join-Path -Path $script:root -ChildPath 'Modules\WinMediaBootFiles.psm1') -Force
}

Describe 'Test-WinMediaKernelConsistency（步驟 9 守衛，Microsoft「用最近版本」規則）' -Tag 'Unit' {
    It '開機索引與安裝映像同版時通過（26H2 9711）' {
        { Test-WinMediaKernelConsistency -BootKernel '10.0.26100.9711' -WinreKernel '10.0.26100.9711' -WinreBaseKernel '10.0.26100.9444' -InstallKernel '10.0.26100.9711' -BootIndex 1 } | Should -Not -Throw
    }

    It 'WinRE 已更新（基準 9444 → 9711）且開機索引等於 WinRE、低於安裝映像：通過，不發警告（9807）' {
        Test-WinMediaKernelConsistency -BootKernel '10.0.26100.9711' -WinreKernel '10.0.26100.9711' -WinreBaseKernel '10.0.26100.9444' -InstallKernel '10.0.26100.9807' -BootIndex 1 -WarningVariable w -WarningAction SilentlyContinue
        $w | Should -BeNullOrEmpty
    }

    It 'WinRE 未更新（基準與套用後同為 9444，SafeOS 未生效）即使開機索引等於 WinRE 也中止' {
        { Test-WinMediaKernelConsistency -BootKernel '10.0.26100.9444' -WinreKernel '10.0.26100.9444' -WinreBaseKernel '10.0.26100.9444' -InstallKernel '10.0.26100.9807' -BootIndex 1 } | Should -Throw '*索引 1*'
    }

    It '開機索引既不等於 WinRE 也不等於安裝映像時中止' {
        { Test-WinMediaKernelConsistency -BootKernel '10.0.26100.9444' -WinreKernel '10.0.26100.9711' -WinreBaseKernel '10.0.26100.9444' -InstallKernel '10.0.26100.9807' -BootIndex 2 } | Should -Throw '*索引 2*'
    }

    It '錯誤訊息列出 WinRE 基準版本' {
        { Test-WinMediaKernelConsistency -BootKernel '10.0.26100.9444' -WinreKernel '10.0.26100.9711' -WinreBaseKernel '10.0.26100.9444' -InstallKernel '10.0.26100.9807' -BootIndex 1 } | Should -Throw '*WinRE 基準 10.0.26100.9444*'
    }

    It '空版本字串在參數繫結時即拒絕' {
        { Test-WinMediaKernelConsistency -BootKernel '' -WinreKernel '10.0.26100.9711' -WinreBaseKernel '10.0.26100.9444' -InstallKernel '10.0.26100.9711' -BootIndex 1 } | Should -Throw
    }
}
