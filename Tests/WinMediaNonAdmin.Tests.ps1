#Requires -Version 5.1

# 待處理項目（測試）：非系統管理員時，Invoke-WindowsMediaRefresh 在管理員檢查（L129）即丟出中文訊息，
# 之後的副作用命令（工作目錄、掛載、Defender 排除、行程）一律不會被呼叫。
# 全部路徑指向 TestDrive；tripwire 一旦被呼叫即丟錯，因此誤呼叫會使測試失敗。

BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    Import-Module -Name (Join-Path -Path $script:root -ChildPath 'WinMediaRefresh.psd1') -Force

    function Invoke-InModule {
        param([scriptblock]$Script, [object[]]$ArgList = @())
        & (Get-Module -Name WinMediaRefresh) $Script @ArgList
    }

    function Get-NonAdminTestConfig {
        param([string]$Root)
        $cfg = Import-PowerShellDataFile -LiteralPath (Join-Path -Path $script:root -ChildPath 'Config\Default.psd1')
        $cfg.WorkDir = Join-Path -Path $Root -ChildPath 'work'
        $cfg.MountDir = Join-Path -Path $Root -ChildPath 'mnt'
        $cfg.OutputDir = Join-Path -Path $Root -ChildPath 'out'
        $cfg.LogDir = Join-Path -Path $Root -ChildPath 'logs'
        $cfg.LogFile = Join-Path -Path $Root -ChildPath 'logs\main.log'
        $cfg.OperationLog = Join-Path -Path $Root -ChildPath 'logs\OperationLog.txt'
        $cfg.PackageDir = Join-Path -Path $Root -ChildPath 'packages'
        $cfg.ScratchDirectory = ''
        $cfg.DefenderExclusions = $false
        $cfg
    }
}

Describe 'Invoke-WindowsMediaRefresh: non-admin throws before any side effect (runtime)' -Tag 'Unit' {
    BeforeEach {
        $script:root2 = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        $script:iso = Join-Path -Path $script:root2 -ChildPath 'src.iso'
        New-Item -ItemType Directory -Path $script:root2 -Force | Out-Null
        New-Item -ItemType File -Path $script:iso -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path -Path $script:root2 -ChildPath 'packages') -Force | Out-Null
        Mock -ModuleName WinMediaRefresh Test-WinMediaAdministrator { $false }
        Mock -ModuleName WinMediaRefresh Initialize-WinMediaWorkRoot { throw 'tripwire: Initialize-WinMediaWorkRoot' }
        Mock -ModuleName WinMediaRefresh Mount-WinMediaSourceIso { throw 'tripwire: Mount-WinMediaSourceIso' }
        Mock -ModuleName WinMediaRefresh Add-WinMediaDefenderExclusion { throw 'tripwire: Add-WinMediaDefenderExclusion' }
        Mock -ModuleName WinMediaRefresh Start-Process { throw 'tripwire: Start-Process' }
        Mock -ModuleName WinMediaRefresh Write-Warning { }
        Mock -ModuleName WinMediaRefresh Assert-WinMediaLocalPath { }
        Mock -ModuleName WinMediaRefresh Resolve-WinMediaLogLocation { param($Config) @{ LogDir = $Config.LogDir; OperationLog = $Config.OperationLog } }
    }

    It 'tripwires resolve as mocks (Alias) in the WinMediaRefresh scope before the call' {
        foreach ($n in 'Test-WinMediaAdministrator', 'Initialize-WinMediaWorkRoot', 'Mount-WinMediaSourceIso', 'Add-WinMediaDefenderExclusion', 'Start-Process', 'Assert-WinMediaLocalPath', 'Resolve-WinMediaLogLocation') {
            $type = Invoke-InModule { param($x) (Get-Command -Name $x -ErrorAction Stop).CommandType } @($n)
            $type | Should -Be 'Alias' -Because "mock not live in WinMediaRefresh scope: $n"
        }
    }

    It '非管理員時丟出中文訊息，且 L129 之後的副作用命令都未被呼叫' {
        $cfg = Get-NonAdminTestConfig -Root $script:root2
        { Invoke-WindowsMediaRefresh -SourceIso $script:iso -Config $cfg } | Should -Throw '*需要系統管理員權限*'
        Should -Invoke -ModuleName WinMediaRefresh Test-WinMediaAdministrator -Times 1 -Exactly
        Should -Invoke -ModuleName WinMediaRefresh Initialize-WinMediaWorkRoot -Times 0 -Exactly
        Should -Invoke -ModuleName WinMediaRefresh Mount-WinMediaSourceIso -Times 0 -Exactly
        Should -Invoke -ModuleName WinMediaRefresh Add-WinMediaDefenderExclusion -Times 0 -Exactly
        Should -Invoke -ModuleName WinMediaRefresh Start-Process -Times 0 -Exactly
    }

    It '根目錄相對的 WorkDir（\nonadmin-work）在管理員檢查之前正規化為完整路徑' {
        $cfg = Get-NonAdminTestConfig -Root $script:root2
        $cfg.WorkDir = '\nonadmin-work'
        Push-Location -LiteralPath 'TestDrive:\'
        try {
            { Invoke-WindowsMediaRefresh -SourceIso $script:iso -Config $cfg } | Should -Throw '*需要系統管理員權限*'
        }
        finally {
            Pop-Location
        }
        Should -Invoke -ModuleName WinMediaRefresh Assert-WinMediaLocalPath -Times 1 -Exactly -ParameterFilter { $Name -eq 'WorkDir' -and $Path -notlike '\*' -and $Path -like '*\nonadmin-work' }
    }

    It '以 -WorkDir 傳入根目錄相對路徑時，LogDir 也須為完整路徑' {
        $cfg = Get-NonAdminTestConfig -Root $script:root2
        Push-Location -LiteralPath 'TestDrive:\'
        try {
            { Invoke-WindowsMediaRefresh -SourceIso $script:iso -Config $cfg -WorkDir '\nonadmin-work' } | Should -Throw '*需要系統管理員權限*'
        }
        finally {
            Pop-Location
        }
        Should -Invoke -ModuleName WinMediaRefresh Resolve-WinMediaLogLocation -Times 1 -Exactly -ParameterFilter { $Config.LogDir -notlike '\*' -and $Config.LogDir -like '*\nonadmin-work\logs' }
    }
}
