#Requires -Version 5.1

BeforeAll {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\PSModules\Imaging\WinMediaImage.psm1') -Force
    $script:config = @{ DismProvider = 'Inbox'; LogLevel = 'Info'; OperationLog = ''; DebugTrace = 0; LogFile = (Join-Path -Path $TestDrive -ChildPath 'mountpoint.log') }
}

Describe '掛載點目錄生命週期（由建立者負責清除）' -Tag 'Unit' {
    BeforeEach {
        Mock -ModuleName WinMediaImage Invoke-WinMediaDism { }
    }

    It 'Action 成功後移除本次建立的空掛載點' {
        $mp = Join-Path -Path $TestDrive -ChildPath 'mp-ok'
        Mount-WinMediaImage -ImagePath 'x.wim' -Index 1 -MountPath $mp -Action { 'ok' } -Config $script:config | Should -Be 'ok'
        Test-Path -LiteralPath $mp | Should -BeFalse
    }

    It 'Action 拋出例外時仍移除本次建立的空掛載點' {
        $mp = Join-Path -Path $TestDrive -ChildPath 'mp-fail'
        { Mount-WinMediaImage -ImagePath 'x.wim' -Index 1 -MountPath $mp -Action { throw '模擬失敗' } -Config $script:config } | Should -Throw '*模擬失敗*'
        Test-Path -LiteralPath $mp | Should -BeFalse
    }

    It '掛載點事先存在時保留（不是本次建立）' {
        $mp = Join-Path -Path $TestDrive -ChildPath 'mp-existing'
        [IO.Directory]::CreateDirectory($mp) | Out-Null
        Mount-WinMediaImage -ImagePath 'x.wim' -Index 1 -MountPath $mp -Action { 'ok' } -Config $script:config | Out-Null
        Test-Path -LiteralPath $mp | Should -BeTrue
    }

    It '掛載失敗時移除本次建立的空掛載點並向上拋出' {
        Mock -ModuleName WinMediaImage Invoke-WinMediaDism { throw '掛載失敗' }
        $mp = Join-Path -Path $TestDrive -ChildPath 'mp-mountfail'
        { Mount-WinMediaImage -ImagePath 'x.wim' -Index 1 -MountPath $mp -Action { 'ok' } -Config $script:config } | Should -Throw '*掛載失敗*'
        Test-Path -LiteralPath $mp | Should -BeFalse
    }

    It '清理失敗不取代操作結果：仍回傳 Action 的值並記錄警告' {
        Mock -ModuleName WinMediaImage Remove-Item { throw '檔案被占用' }
        $mp = Join-Path -Path $TestDrive -ChildPath 'mp-removefail'
        Mount-WinMediaImage -ImagePath 'x.wim' -Index 1 -MountPath $mp -Action { 'ok' } -Config $script:config | Should -Be 'ok'
        (Get-Content -LiteralPath $script:config.LogFile -Raw -Encoding UTF8) | Should -Match '清理空掛載點.*失敗'
    }

    It '卸載失敗時保留掛載點（可能仍被占用，不得刪除）' {
        $script:dismState = @{ Calls = 0 }
        Mock -ModuleName WinMediaImage Invoke-WinMediaDism {
            $script:dismState.Calls++
            if ($script:dismState.Calls -gt 1) { throw '卸載失敗' }
        }
        $mp = Join-Path -Path $TestDrive -ChildPath 'mp-dismountfail'
        { Mount-WinMediaImage -ImagePath 'x.wim' -Index 1 -MountPath $mp -Action { 'ok' } -Config $script:config } | Should -Throw '*卸載失敗*'
        Test-Path -LiteralPath $mp | Should -BeTrue
    }
}
