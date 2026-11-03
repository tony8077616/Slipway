#Requires -Version 5.1

# Step 12c-2a RED：樹狀終止與單一掛載清理（Public\Invoke-WinMediaParallelCleanup.ps1）。
# 所有程序、CIM 與 DISM 呼叫都以 mock 取代；每個 Describe 的 BeforeEach 先設定「不應被呼叫」的預設 mock，
# 各 It 只覆寫需要的部分。假 PID 一律使用奇數，避免對到真實程序。

BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    $script:cleanupFile = Join-Path $script:root 'Public\Invoke-WinMediaParallelCleanup.ps1'
    $script:manifest = Join-Path $script:root 'WinMediaRefresh.psd1'
    if (Test-Path -LiteralPath $script:manifest -PathType Leaf) {
        Import-Module -Name $script:manifest -Force
    }

    # 只在命令不存在時建立 DISM 的全域 stub，AfterAll 移除（同 WinMediaDismLogLevel.Tests.ps1 L69–77）
    $script:stubbedDism = $false
    if (-not (Get-Command -Name Dismount-WindowsImage -ErrorAction SilentlyContinue)) {
        Set-Item -Path 'function:global:Dismount-WindowsImage' -Value { param($Path, [switch]$Discard, [switch]$Save, $LogLevel, $ScratchDirectory, $ErrorAction) $null = $Path, $Discard, $Save, $LogLevel, $ScratchDirectory, $ErrorAction }
        $script:stubbedDism = $true
    }

    function Assert-CleanupFilePresent {
        (Test-Path -LiteralPath $script:cleanupFile -PathType Leaf) | Should -BeTrue -Because 'file missing: Invoke-WinMediaParallelCleanup.ps1'
    }

    # 函式只被 dot-source 進根模組、未匯出，故於模組範圍內執行
    function Invoke-InModule {
        param([scriptblock]$Script, [object[]]$ArgList = @())
        & (Get-Module -Name WinMediaRefresh) $Script @ArgList
    }

    # 安全關卡：呼叫前確認所有會被 mock 的名稱在模組範圍內都解析為 Alias；否則停止，避免真的碰到程序或 DISM
    function Assert-MocksLive {
        foreach ($n in @('Get-Process', 'Get-CimInstance', 'Mount-WinMediaImage', 'Get-WinMediaMountState', 'Invoke-WinMediaDism', 'Remove-Item', 'Write-WinMediaLog', 'Dismount-WindowsImage')) {
            $type = Invoke-InModule { param($x) (Get-Command -Name $x -ErrorAction Stop).CommandType } @($n)
            $type | Should -Be 'Alias' -Because "mock not live in WinMediaRefresh scope: $n"
        }
    }

    # 預設 mock：任何未被 It 覆寫的呼叫都會以明確訊息失敗，不會碰到真實程序或 DISM
    function Register-SafeDefaultMock {
        Mock -ModuleName WinMediaRefresh Get-CimInstance { param($ClassName) $null = $ClassName; @() }
        Mock -ModuleName WinMediaRefresh Get-Process { param($Id) throw "Cannot find a process with the process identifier $Id." }
        Mock -ModuleName WinMediaRefresh Mount-WinMediaImage { throw 'unexpected call: Mount-WinMediaImage' }
        Mock -ModuleName WinMediaRefresh Get-WinMediaMountState { 'Unknown' }
        Mock -ModuleName WinMediaRefresh Invoke-WinMediaDism { throw 'unexpected call: Invoke-WinMediaDism' }
        Mock -ModuleName WinMediaRefresh Remove-Item { throw 'unexpected call: Remove-Item' }
        Mock -ModuleName WinMediaRefresh Write-WinMediaLog { param($Config, $Level, $Message) $null = $Config, $Level, $Message }
        Mock -ModuleName WinMediaRefresh Dismount-WindowsImage { throw 'unexpected call: Dismount-WindowsImage' }
    }

    function Get-FakeProcess {
        param([int]$ProcId, [datetime]$StartTime, [object]$Log, [string]$KillError = '', [switch]$HandleError)
        $p = [pscustomobject]@{ Id = $ProcId; StartTime = $StartTime; HasExited = $false; Log = $Log; KillError = $KillError; HandleError = [bool]$HandleError }
        $p | Add-Member -MemberType ScriptProperty -Name Handle -Value {
            $this.Log.Add("handle:$($this.Id)")
            if ($this.HandleError) { throw [System.ComponentModel.Win32Exception]::new(5) }
            [IntPtr]::Zero
        }
        $p | Add-Member -MemberType ScriptMethod -Name Kill -Value {
            $this.Log.Add("kill:$($this.Id)")
            if ($this.KillError -eq 'exited') { throw [InvalidOperationException]::new('process has exited') }
            if ($this.KillError -eq 'denied') { throw [UnauthorizedAccessException]::new('access denied') }
            $this.HasExited = $true
        }
        return $p
    }

    function Get-SnapRow {
        param([int]$ProcId, [int]$Parent, [datetime]$Created)
        [pscustomobject]@{ ProcessId = $ProcId; ParentProcessId = $Parent; CreationDate = $Created }
    }

    function Invoke-TreeKill {
        param($Root, [object[]]$Snapshot, [hashtable]$Procs)
        $snap = $Snapshot
        $map = $Procs
        Mock -ModuleName WinMediaRefresh Get-CimInstance { param($ClassName) $null = $ClassName; $snap }.GetNewClosure()
        Mock -ModuleName WinMediaRefresh Get-Process { param($Id) if ($map.ContainsKey([int]$Id)) { $map[[int]$Id] } else { throw "Cannot find a process with the process identifier $Id." } }.GetNewClosure()
        Assert-MocksLive
        Invoke-InModule { param($r) Invoke-WinMediaParallelTreeKill -RootProcess $r } @($Root)
    }

    function Invoke-MountCleanup {
        param([string]$Path, [string]$State, [hashtable]$Config)
        $st = $State
        Mock -ModuleName WinMediaRefresh Get-WinMediaMountState { $st }.GetNewClosure()
        Assert-MocksLive
        Invoke-InModule { param($p, $c) Invoke-WinMediaParallelMountCleanup -MountPath $p -Config $c } @($Path, $Config)
    }

    $script:cfg = @{ DismProvider = 'Inbox'; DismLogLevel = 'Errors'; LogLevel = 'Error'; LogFile = ''; OperationLog = ''; DebugTrace = 0 }
    $script:t0 = [datetime]'2026-11-03 10:00:00.000'
}

AfterAll {
    if ($script:stubbedDism) {
        Remove-Item -Path 'Function:\Dismount-WindowsImage' -ErrorAction SilentlyContinue
    }
}

Describe 'Parallel cleanup: static' {
    It 'Parallel cleanup file exists' {
        Assert-CleanupFilePresent
    }

    It 'Parallel cleanup file has no forbidden commands (AST, always runs)' {
        Assert-CleanupFilePresent
        $forbidden = @('Clear-WinMediaMount', 'Clear-WindowsCorruptMountPoint', 'Invoke-WinMediaWorkspaceCleanup', 'Remove-WinMediaWorkDir', 'Stop-Process', 'taskkill', 'taskkill.exe')
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:cleanupFile, [ref]$null, [ref]$null)
        $cmds = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))
        $names = @($cmds | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
        $hits = @($names | Where-Object { $forbidden -contains $_ })
        $hits.Count | Should -Be 0 -Because ('forbidden commands: ' + ($hits -join ', '))
    }

    It 'Parallel cleanup file has no DISM cleanup-wide command (skipped when DISM absent)' {
        Assert-CleanupFilePresent
        if (-not (Get-Module -ListAvailable -Name DISM)) { Set-ItResult -Skipped -Because 'DISM 模組不存在於此環境'; return }
        Import-Module -Name DISM -ErrorAction Stop
        $dismNames = @((Get-Command -Module DISM).Name)
        $dismNames.Count | Should -BeGreaterThan 0
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:cleanupFile, [ref]$null, [ref]$null)
        $names = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
        $hits = @($names | Where-Object { $dismNames -contains $_ -and $_ -match 'Corrupt|Cleanup|Mountpoint' })
        $hits.Count | Should -Be 0 -Because ('DISM-wide cleanup: ' + ($hits -join ', '))
    }
}

Describe 'Parallel cleanup: safety gate' {
    BeforeEach {
        Register-SafeDefaultMock
    }

    It 'Parallel cleanup safety gate sees every mocked name as a live alias in module scope' {
        Assert-MocksLive
    }
}

Describe 'Parallel cleanup: tree kill' {
    BeforeEach {
        Register-SafeDefaultMock
        $script:log = [System.Collections.Generic.List[string]]::new()
    }

    It 'Parallel tree kill pins every descendant Handle before any Kill' {
        Assert-CleanupFilePresent
        $root = Get-FakeProcess -ProcId 1001 -StartTime $script:t0 -Log $script:log
        $c = Get-FakeProcess -ProcId 1003 -StartTime $script:t0 -Log $script:log
        $g = Get-FakeProcess -ProcId 1005 -StartTime $script:t0 -Log $script:log
        $snap = @((Get-SnapRow 1001 4 $script:t0), (Get-SnapRow 1003 1001 $script:t0), (Get-SnapRow 1005 1003 $script:t0))
        $null = Invoke-TreeKill -Root $root -Snapshot $snap -Procs @{ 1003 = $c; 1005 = $g }
        $firstKill = $script:log.IndexOf('kill:1001')
        $firstKill | Should -BeGreaterThan -1
        ($script:log.IndexOf('handle:1003') -lt $firstKill) | Should -BeTrue
        ($script:log.IndexOf('handle:1005') -lt $firstKill) | Should -BeTrue
    }

    It 'Parallel tree kill kills the root before its children' {
        Assert-CleanupFilePresent
        $root = Get-FakeProcess -ProcId 1001 -StartTime $script:t0 -Log $script:log
        $c = Get-FakeProcess -ProcId 1003 -StartTime $script:t0 -Log $script:log
        $g = Get-FakeProcess -ProcId 1005 -StartTime $script:t0 -Log $script:log
        $snap = @((Get-SnapRow 1001 4 $script:t0), (Get-SnapRow 1003 1001 $script:t0), (Get-SnapRow 1005 1003 $script:t0))
        $null = Invoke-TreeKill -Root $root -Snapshot $snap -Procs @{ 1003 = $c; 1005 = $g }
        $kills = @($script:log | Where-Object { $_ -like 'kill:*' })
        ($kills -join ',') | Should -Be 'kill:1001,kill:1003,kill:1005'
    }

    It 'Parallel tree kill skips an orphan whose CreationDate precedes its parent' {
        Assert-CleanupFilePresent
        $root = Get-FakeProcess -ProcId 1001 -StartTime $script:t0 -Log $script:log
        $c = Get-FakeProcess -ProcId 1003 -StartTime $script:t0.AddMinutes(-5) -Log $script:log
        $g = Get-FakeProcess -ProcId 1005 -StartTime $script:t0 -Log $script:log
        $snap = @((Get-SnapRow 1001 4 $script:t0), (Get-SnapRow 1003 1001 $script:t0.AddMinutes(-5)), (Get-SnapRow 1005 1003 $script:t0))
        $r = Invoke-TreeKill -Root $root -Snapshot $snap -Procs @{ 1003 = $c; 1005 = $g }
        ($script:log -contains 'kill:1003') | Should -BeFalse
        ($script:log -contains 'kill:1005') | Should -BeFalse
        (@($r.Skipped) -join ';') | Should -Match 'pid=1003'
    }

    It 'Parallel tree kill skips a descendant whose StartTime is more than 1 ms from its snapshot CreationDate' {
        Assert-CleanupFilePresent
        $root = Get-FakeProcess -ProcId 1001 -StartTime $script:t0 -Log $script:log
        $c = Get-FakeProcess -ProcId 1003 -StartTime $script:t0.AddTicks(50000) -Log $script:log
        $snap = @((Get-SnapRow 1001 4 $script:t0), (Get-SnapRow 1003 1001 $script:t0))
        $r = Invoke-TreeKill -Root $root -Snapshot $snap -Procs @{ 1003 = $c }
        ($script:log -contains 'kill:1003') | Should -BeFalse
        (@($r.Skipped) -join ';') | Should -Match 'pid=1003'
    }

    It 'Parallel tree kill accepts a StartTime within 1 ms of the snapshot CreationDate' {
        Assert-CleanupFilePresent
        $root = Get-FakeProcess -ProcId 1001 -StartTime $script:t0 -Log $script:log
        $c = Get-FakeProcess -ProcId 1003 -StartTime $script:t0.AddTicks(5000) -Log $script:log
        $snap = @((Get-SnapRow 1001 4 $script:t0), (Get-SnapRow 1003 1001 $script:t0))
        $null = Invoke-TreeKill -Root $root -Snapshot $snap -Procs @{ 1003 = $c }
        ($script:log -contains 'kill:1003') | Should -BeTrue
    }

    It 'Parallel tree kill tolerates a descendant that exits before its Handle is pinned' {
        Assert-CleanupFilePresent
        $root = Get-FakeProcess -ProcId 1001 -StartTime $script:t0 -Log $script:log
        $snap = @((Get-SnapRow 1001 4 $script:t0), (Get-SnapRow 1003 1001 $script:t0))
        { Invoke-TreeKill -Root $root -Snapshot $snap -Procs @{} } | Should -Not -Throw
        ($script:log -contains 'kill:1003') | Should -BeFalse
        ($script:log -contains 'kill:1001') | Should -BeTrue
    }

    It 'Parallel tree kill skips a descendant whose Handle cannot be opened and still kills its siblings' {
        Assert-CleanupFilePresent
        $root = Get-FakeProcess -ProcId 1001 -StartTime $script:t0 -Log $script:log
        $c = Get-FakeProcess -ProcId 1003 -StartTime $script:t0 -Log $script:log -HandleError
        $sib = Get-FakeProcess -ProcId 1007 -StartTime $script:t0 -Log $script:log
        $snap = @((Get-SnapRow 1001 4 $script:t0), (Get-SnapRow 1003 1001 $script:t0), (Get-SnapRow 1007 1001 $script:t0))
        $r = Invoke-TreeKill -Root $root -Snapshot $snap -Procs @{ 1003 = $c; 1007 = $sib }
        ($script:log -contains 'kill:1003') | Should -BeFalse
        ($script:log -contains 'kill:1007') | Should -BeTrue
        (@($r.Skipped) -join ';') | Should -Match 'pid=1003'
    }

    It 'Parallel tree kill tolerates Kill on an already exited descendant and continues' {
        Assert-CleanupFilePresent
        $root = Get-FakeProcess -ProcId 1001 -StartTime $script:t0 -Log $script:log
        $c = Get-FakeProcess -ProcId 1003 -StartTime $script:t0 -Log $script:log -KillError 'exited'
        $g = Get-FakeProcess -ProcId 1005 -StartTime $script:t0 -Log $script:log
        $snap = @((Get-SnapRow 1001 4 $script:t0), (Get-SnapRow 1003 1001 $script:t0), (Get-SnapRow 1005 1003 $script:t0))
        $r = Invoke-TreeKill -Root $root -Snapshot $snap -Procs @{ 1003 = $c; 1005 = $g }
        ($script:log -contains 'kill:1005') | Should -BeTrue
        @($r.Failed).Count | Should -Be 0 -Because 'an already-exited Kill is ignored, not reported as a failure'
    }

    It 'Parallel tree kill reports an access-denied Kill in Failed and continues' {
        Assert-CleanupFilePresent
        $root = Get-FakeProcess -ProcId 1001 -StartTime $script:t0 -Log $script:log
        $c = Get-FakeProcess -ProcId 1003 -StartTime $script:t0 -Log $script:log -KillError 'denied'
        $g = Get-FakeProcess -ProcId 1005 -StartTime $script:t0 -Log $script:log
        $snap = @((Get-SnapRow 1001 4 $script:t0), (Get-SnapRow 1003 1001 $script:t0), (Get-SnapRow 1005 1003 $script:t0))
        $r = Invoke-TreeKill -Root $root -Snapshot $snap -Procs @{ 1003 = $c; 1005 = $g }
        (@($r.Failed) -join ';') | Should -Match 'pid=1003'
        ($script:log -contains 'kill:1005') | Should -BeTrue
    }

    It 'Parallel tree kill still kills descendants when the root is missing from the snapshot' {
        Assert-CleanupFilePresent
        $root = Get-FakeProcess -ProcId 1001 -StartTime $script:t0 -Log $script:log -KillError 'exited'
        $c = Get-FakeProcess -ProcId 1003 -StartTime $script:t0 -Log $script:log
        $snap = @((Get-SnapRow 1003 1001 $script:t0))
        { Invoke-TreeKill -Root $root -Snapshot $snap -Procs @{ 1003 = $c } } | Should -Not -Throw
        ($script:log -contains 'kill:1003') | Should -BeTrue
    }

    It 'Parallel tree kill never touches a process outside the snapshot tree' {
        Assert-CleanupFilePresent
        $root = Get-FakeProcess -ProcId 1001 -StartTime $script:t0 -Log $script:log
        $c = Get-FakeProcess -ProcId 1003 -StartTime $script:t0 -Log $script:log
        $outside = Get-FakeProcess -ProcId 2001 -StartTime $script:t0 -Log $script:log
        $snap = @((Get-SnapRow 1001 4 $script:t0), (Get-SnapRow 1003 1001 $script:t0))
        $null = Invoke-TreeKill -Root $root -Snapshot $snap -Procs @{ 1003 = $c; 2001 = $outside }
        (@($script:log | Where-Object { $_ -match '2001' })).Count | Should -Be 0
    }
}

Describe 'Parallel cleanup: mount cleanup' {
    BeforeEach {
        Register-SafeDefaultMock
        $script:mc = [System.Collections.Generic.List[object]]::new()
        $script:dc = [System.Collections.Generic.List[object]]::new()
    }

    It 'Parallel mount cleanup remounts a NeedsRemount path with CommitOnSuccess false for that path only' {
        Assert-CleanupFilePresent
        $mp = Join-Path $TestDrive 'install-2'
        New-Item -ItemType Directory -Path $mp -Force | Out-Null
        $calls = $script:mc
        Mock -ModuleName WinMediaRefresh Mount-WinMediaImage { param($Remount, $MountPath, $CommitOnSuccess, $Action, $Config) $null = $Action, $Config; $calls.Add([pscustomobject]@{ Remount = [bool]$Remount; MountPath = $MountPath; CommitOnSuccess = $CommitOnSuccess }) }.GetNewClosure()
        $null = Invoke-MountCleanup -Path $mp -State 'NeedsRemount' -Config $script:cfg
        $calls.Count | Should -Be 1
        $calls[0].MountPath | Should -Be $mp
        $calls[0].Remount | Should -BeTrue
        $calls[0].CommitOnSuccess | Should -BeFalse
    }

    It 'Parallel mount cleanup discards an OK or Invalid path through Dismount -Discard for that path only' {
        Assert-CleanupFilePresent
        foreach ($state in 'OK', 'Invalid') {
            $mp = Join-Path $TestDrive ("install-{0}" -f ($(if ($state -eq 'OK') { 3 } else { 4 })))
            New-Item -ItemType Directory -Path $mp -Force | Out-Null
            $dismounts = [System.Collections.Generic.List[object]]::new()
            $d = $dismounts
            Mock -ModuleName WinMediaRefresh Invoke-WinMediaDism { param($Provider, $Config, $ScriptBlock) $null = $Provider, $Config; & $ScriptBlock }
            Mock -ModuleName WinMediaRefresh Dismount-WindowsImage { param($Path, $Discard, $Save, $LogLevel, $ScratchDirectory) $null = $LogLevel, $ScratchDirectory; $d.Add([pscustomobject]@{ Path = $Path; Discard = [bool]$Discard; Save = [bool]$Save }) }.GetNewClosure()
            $null = Invoke-MountCleanup -Path $mp -State $state -Config $script:cfg
            $dismounts.Count | Should -Be 1 -Because "state $state"
            $dismounts[0].Path | Should -Be $mp
            $dismounts[0].Discard | Should -BeTrue
            $dismounts[0].Save | Should -BeFalse
        }
    }

    It 'Parallel mount cleanup removes an empty Unknown folder without -Recurse' {
        Assert-CleanupFilePresent
        $mp = Join-Path $TestDrive 'install-5'
        New-Item -ItemType Directory -Path $mp -Force | Out-Null
        $removed = $script:dc
        Mock -ModuleName WinMediaRefresh Remove-Item { param($LiteralPath, [switch]$Recurse, $Force) $null = $Force; $removed.Add([pscustomobject]@{ Path = $LiteralPath; HasRecurse = [bool]$Recurse }) }.GetNewClosure()
        $null = Invoke-MountCleanup -Path $mp -State 'Unknown' -Config $script:cfg
        $removed.Count | Should -Be 1
        $removed[0].Path | Should -Be $mp
        $removed[0].HasRecurse | Should -BeFalse
    }

    It 'Parallel mount cleanup keeps a non-empty Unknown folder and does not remove it' {
        Assert-CleanupFilePresent
        $mp = Join-Path $TestDrive 'install-6'
        New-Item -ItemType Directory -Path $mp -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $mp 'keep.txt') -Value 'x'
        $removed = $script:dc
        Mock -ModuleName WinMediaRefresh Remove-Item { param($LiteralPath, [switch]$Recurse, $Force) $null = $Recurse, $Force; $removed.Add($LiteralPath) }.GetNewClosure()
        $r = Invoke-MountCleanup -Path $mp -State 'Unknown' -Config $script:cfg
        $removed.Count | Should -Be 0
        Should -Invoke -ModuleName WinMediaRefresh Remove-Item -Times 0 -Exactly
        $r.Result | Should -Be 'Kept'
    }

    It 'Parallel mount cleanup reports ManualCleanup when discard fails and makes no second DISM call' {
        Assert-CleanupFilePresent
        $mp = Join-Path $TestDrive 'install-7'
        New-Item -ItemType Directory -Path $mp -Force | Out-Null
        $count = [System.Collections.Generic.List[int]]::new()
        $cnt = $count
        Mock -ModuleName WinMediaRefresh Invoke-WinMediaDism { param($Provider, $Config, $ScriptBlock) $null = $Provider, $Config, $ScriptBlock; $cnt.Add(1); throw 'discard failed' }.GetNewClosure()
        $r = Invoke-MountCleanup -Path $mp -State 'OK' -Config $script:cfg
        $r.Result | Should -Be 'ManualCleanup'
        $count.Count | Should -Be 1
    }

    It 'Parallel mount cleanup reports ManualCleanup when remount fails and never calls DISM' {
        Assert-CleanupFilePresent
        $mp = Join-Path $TestDrive 'install-8'
        New-Item -ItemType Directory -Path $mp -Force | Out-Null
        Mock -ModuleName WinMediaRefresh Mount-WinMediaImage { throw 'remount failed' }
        $r = Invoke-MountCleanup -Path $mp -State 'NeedsRemount' -Config $script:cfg
        $r.Result | Should -Be 'ManualCleanup'
        Should -Invoke -ModuleName WinMediaRefresh Invoke-WinMediaDism -Times 0 -Exactly
    }

    It 'Parallel mount cleanup refuses a MountPath whose leaf is not install-N before any state query' {
        Assert-CleanupFilePresent
        $mp = Join-Path $TestDrive 'winre'
        New-Item -ItemType Directory -Path $mp -Force | Out-Null
        Assert-MocksLive
        $cfg = $script:cfg
        { Invoke-InModule { param($p, $c) Invoke-WinMediaParallelMountCleanup -MountPath $p -Config $c } @($mp, $cfg) } | Should -Throw -ExpectedMessage '*install-*'
        Should -Invoke -ModuleName WinMediaRefresh Get-WinMediaMountState -Times 0 -Exactly
    }
}
