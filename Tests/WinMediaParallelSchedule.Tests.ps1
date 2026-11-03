#Requires -Version 5.1

# Step 12c-2b RED：平行排程器（Public\Invoke-WinMediaParallelRun.ps1，尚未存在）。
# 所有程序啟動、睡眠、時間與清理都以 mock 取代；Start-WinMediaIndexWorker 與 Start-Process 的預設 mock 一律 throw，
# 確保測試不會真的啟動 powershell.exe，也不會掛載映像。假程序的 HasExited 會在被讀取若干次後才變成 true。

BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    $script:runFile = Join-Path $script:root 'Public\Invoke-WinMediaParallelRun.ps1'
    $script:manifest = Join-Path $script:root 'WinMediaRefresh.psd1'
    if (Test-Path -LiteralPath $script:manifest -PathType Leaf) {
        Import-Module -Name $script:manifest -Force
    }

    function Assert-RunFilePresent {
        (Test-Path -LiteralPath $script:runFile -PathType Leaf) | Should -BeTrue -Because 'file missing: Invoke-WinMediaParallelRun.ps1'
    }

    # 函式只被 dot-source 進根模組、未匯出，故於模組範圍內執行
    function Invoke-InModule {
        param([scriptblock]$Script, [object[]]$ArgList = @())
        & (Get-Module -Name WinMediaRefresh) $Script @ArgList
    }

    # 安全關卡：所有會被 mock 的名稱在模組範圍內都必須可解析；否則停止，避免真的啟動程序或睡眠
    function Assert-MocksLive {
        foreach ($n in @('Start-WinMediaIndexWorker', 'Start-Process', 'Start-Sleep', 'Get-Date', 'Invoke-WinMediaParallelTreeKill', 'Invoke-WinMediaParallelMountCleanup')) {
            $type = Invoke-InModule { param($x) (Get-Command -Name $x -ErrorAction Stop).CommandType } @($n)
            $type | Should -Be 'Alias' -Because "mock not live in WinMediaRefresh scope: $n"
        }
    }

    function Register-SafeDefaultMock {
        Mock -ModuleName WinMediaRefresh Start-WinMediaIndexWorker { throw 'unexpected call: Start-WinMediaIndexWorker' }
        Mock -ModuleName WinMediaRefresh Start-Process { throw 'unexpected call: Start-Process' }
        Mock -ModuleName WinMediaRefresh Start-Sleep { throw 'unexpected call: Start-Sleep' }
        Mock -ModuleName WinMediaRefresh Get-Date { throw 'unexpected call: Get-Date' }
        Mock -ModuleName WinMediaRefresh Invoke-WinMediaParallelTreeKill { throw 'unexpected call: Invoke-WinMediaParallelTreeKill' }
        Mock -ModuleName WinMediaRefresh Invoke-WinMediaParallelMountCleanup { throw 'unexpected call: Invoke-WinMediaParallelMountCleanup' }
    }

    # 假 worker 程序：Handle 讀取與 HasExited 讀取都寫入 log；HasExited 在讀取 ExitAfter 次後才為 true，Kill 會立即使其結束
    function Get-FakeWorker {
        param([int]$ProcId, [object]$ExitAfter = 2, [object]$ExitCode = 0, [bool]$HandleOk = $true, [System.Collections.Generic.List[string]]$Log)
        $w = [pscustomobject]@{ Id = $ProcId; Reads = 0; ExitAfter = $ExitAfter; Killed = $false; ExitCode = $ExitCode; HandleOk = $HandleOk; Logged = $false; Log = $Log }
        $w | Add-Member -MemberType ScriptProperty -Name Handle -Value {
            $this.Log.Add("handle:$($this.Id)")
            if ($this.HandleOk) { [IntPtr]::Zero } else { $null }
        }
        $w | Add-Member -MemberType ScriptProperty -Name HasExited -Value {
            $this.Reads = $this.Reads + 1
            $this.Log.Add("hasexited:$($this.Id)")
            $done = $this.Killed -or ($null -ne $this.ExitAfter -and $this.Reads -ge [int]$this.ExitAfter)
            if ($done -and -not $this.Logged) { $this.Logged = $true; $this.Log.Add("exit:$($this.Id)") }
            $done
        }
        $w | Add-Member -MemberType ScriptMethod -Name Kill -Value {
            $this.Log.Add("kill:$($this.Id)")
            $this.Killed = $true
        }
        $w
    }

    # 依 $Workers（Index → 假程序）設定 mock；$TreeKillBody 與 Invoke-WinMediaParallelTreeKill 的回傳同形
    function Register-ScheduleMock {
        param([hashtable]$Workers, [System.Collections.Generic.List[string]]$Log, [hashtable]$State, [scriptblock]$TreeKillBody)
        $w = $Workers
        $l = $Log
        $st = $State
        $tk = $TreeKillBody
        Mock -ModuleName WinMediaRefresh Start-WinMediaIndexWorker {
            param($Job, $IndexDir)
            $i = [int]$Job.Index
            $l.Add("start:$i")
            $st.Dirs[$i] = $IndexDir
            $w[$i]
        }.GetNewClosure()
        Mock -ModuleName WinMediaRefresh Start-Sleep {
            $st.Sleeps = $st.Sleeps + 1
            $l.Add('sleep')
            if ($st.Sleeps -gt 500) { throw 'poll loop did not terminate' }
        }.GetNewClosure()
        Mock -ModuleName WinMediaRefresh Get-Date { $st.Base.AddMinutes($st.Sleeps) }.GetNewClosure()
        Mock -ModuleName WinMediaRefresh Invoke-WinMediaParallelTreeKill {
            param($RootProcess)
            $l.Add("treekill:$($RootProcess.Id)")
            & $tk $RootProcess
        }.GetNewClosure()
        Mock -ModuleName WinMediaRefresh Invoke-WinMediaParallelMountCleanup {
            param($MountPath, $Config)
            $null = $Config
            $l.Add("mountcleanup:$(Split-Path -Leaf $MountPath)")
            [pscustomobject]@{ Path = $MountPath; State = 'OK'; Result = 'Discarded' }
        }.GetNewClosure()
    }

    function Invoke-Run {
        param([object[]]$Jobs, [hashtable]$Config, [int]$Max = 2, [int]$Timeout = 180, [int]$Grace = 60)
        Assert-MocksLive
        Invoke-InModule { param($j, $c, $m, $t, $g) Invoke-WinMediaParallelRun -Jobs $j -Config $c -MaxConcurrent $m -TimeoutMinutes $t -GraceSeconds $g -PollMilliseconds 1 } @($Jobs, $Config, $Max, $Timeout, $Grace)
    }

    function Get-RunJob {
        param([int]$Index, [string]$Root)
        [pscustomobject]@{ Index = $Index; Job = @{ Index = $Index }; IndexDir = (Join-Path $Root "idx$Index"); MountPath = (Join-Path $Root "install-$Index") }
    }

    function Add-ResultFile {
        param([string]$IndexDir, [int]$Index)
        New-Item -ItemType Directory -Path $IndexDir -Force | Out-Null
        Export-Clixml -LiteralPath (Join-Path $IndexDir 'result.clixml') -InputObject ([pscustomobject]@{ Index = $Index; KernelVersion = "10.0.26300.$Index"; BuildInfo = 'fake' })
    }

    $script:cfg = @{ DismProvider = 'Inbox'; DismLogLevel = 'Errors'; LogLevel = 'Error'; LogFile = ''; OperationLog = ''; DebugTrace = 0 }
    $script:killingTreeKill = { param($RootProcess) $RootProcess.Kill(); [pscustomobject]@{ Killed = @($RootProcess.Id); Skipped = @(); Failed = @() } }
    $script:quietTreeKill = { param($RootProcess) $null = $RootProcess; [pscustomobject]@{ Killed = @(); Skipped = @(); Failed = @() } }
    $script:failingTreeKill = { param($RootProcess) $null = $RootProcess; [pscustomobject]@{ Killed = @(); Skipped = @(); Failed = @('pid=1001 snapshot: wmi down') } }
}

Describe 'Parallel schedule: static' {
    It 'Parallel schedule file exists' {
        Assert-RunFilePresent
    }

    It 'Parallel schedule file has no forbidden commands or waiting members (AST, always runs)' {
        Assert-RunFilePresent
        $forbidden = @('Start-Process', 'Clear-WinMediaMount', 'Clear-WindowsCorruptMountPoint', 'Invoke-WinMediaWorkspaceCleanup', 'Stop-Process', 'taskkill', 'taskkill.exe')
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:runFile, [ref]$null, [ref]$null)
        $names = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
        $hits = @($names | Where-Object { $forbidden -contains $_ })
        $hits.Count | Should -Be 0 -Because ('forbidden commands: ' + ($hits -join ', '))
        $members = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true) | ForEach-Object { $_.Member.Value })
        $badMembers = @($members | Where-Object { $_ -in @('WaitForExit', 'Refresh') })
        $badMembers.Count | Should -Be 0 -Because ('forbidden members: ' + ($badMembers -join ', '))
    }
}

Describe 'Parallel schedule: safety gate' {
    BeforeEach {
        Register-SafeDefaultMock
    }

    It 'Parallel schedule safety gate sees every mocked name as live in module scope' {
        Assert-MocksLive
    }

    It 'Parallel schedule harness drives a mocked worker through the expected order' {
        $log = [System.Collections.Generic.List[string]]::new()
        $st = @{ Sleeps = 0; Base = [datetime]'2026-11-04 09:00:00'; Dirs = @{} }
        Register-ScheduleMock -Workers @{ 1 = (Get-FakeWorker -ProcId 1001 -ExitAfter 2 -Log $log) } -Log $log -State $st -TreeKillBody $script:quietTreeKill
        $dir = Join-Path $TestDrive 'harness'
        $r = Invoke-InModule { param($d) $p = Start-WinMediaIndexWorker -Job @{ Index = 1 } -IndexDir $d; $null = $p.Handle; $h1 = $p.HasExited; $h2 = $p.HasExited; Start-Sleep -Milliseconds 1; @($h1, $h2, (Get-Date)) } @($dir)
        ($log -join ',') | Should -Be 'start:1,handle:1001,hasexited:1001,hasexited:1001,exit:1001,sleep'
        $r[0] | Should -BeFalse
        $r[1] | Should -BeTrue
        $r[2] | Should -Be $st.Base.AddMinutes(1)
        $st.Sleeps | Should -Be 1
    }
}

Describe 'Parallel schedule: behaviour' {
    BeforeEach {
        Register-SafeDefaultMock
        $script:log = [System.Collections.Generic.List[string]]::new()
        $script:st = @{ Sleeps = 0; Base = [datetime]'2026-11-04 09:00:00'; Dirs = @{} }
        $script:runRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:runRoot -Force | Out-Null
    }

    It 'Parallel schedule caps concurrent workers at MaxConcurrent' {
        Assert-RunFilePresent
        $jobs = @(1..3 | ForEach-Object { Get-RunJob -Index $_ -Root $script:runRoot })
        $w = @{ 1 = (Get-FakeWorker -ProcId 1001 -ExitAfter 2 -Log $script:log); 2 = (Get-FakeWorker -ProcId 1003 -ExitAfter 2 -Log $script:log); 3 = (Get-FakeWorker -ProcId 1005 -ExitAfter 2 -Log $script:log) }
        Register-ScheduleMock -Workers $w -Log $script:log -State $script:st -TreeKillBody $script:quietTreeKill
        foreach ($j in $jobs) { Add-ResultFile -IndexDir $j.IndexDir -Index $j.Index }
        $null = Invoke-Run -Jobs $jobs -Config $script:cfg -Max 2
        $active = 0
        $peak = 0
        foreach ($e in $script:log) {
            if ($e -like 'start:*') { $active++; if ($active -gt $peak) { $peak = $active } }
            elseif ($e -like 'exit:*') { $active-- }
        }
        $peak | Should -Be 2
        (@($script:log | Where-Object { $_ -like 'start:*' })).Count | Should -Be 3
    }

    It 'Parallel schedule launches at most one worker per poll round' {
        Assert-RunFilePresent
        $jobs = @(1..3 | ForEach-Object { Get-RunJob -Index $_ -Root $script:runRoot })
        $w = @{ 1 = (Get-FakeWorker -ProcId 1001 -ExitAfter 2 -Log $script:log); 2 = (Get-FakeWorker -ProcId 1003 -ExitAfter 2 -Log $script:log); 3 = (Get-FakeWorker -ProcId 1005 -ExitAfter 2 -Log $script:log) }
        Register-ScheduleMock -Workers $w -Log $script:log -State $script:st -TreeKillBody $script:quietTreeKill
        foreach ($j in $jobs) { Add-ResultFile -IndexDir $j.IndexDir -Index $j.Index }
        $null = Invoke-Run -Jobs $jobs -Config $script:cfg -Max 2
        $starts = [System.Collections.Generic.List[int]]::new()
        for ($i = 0; $i -lt $script:log.Count; $i++) {
            if ($script:log[$i] -like 'start:*') { $starts.Add($i) }
        }
        $starts.Count | Should -Be 3
        for ($k = 1; $k -lt $starts.Count; $k++) {
            $between = @($script:log.GetRange($starts[$k - 1] + 1, $starts[$k] - $starts[$k - 1] - 1))
            ($between -contains 'sleep') | Should -BeTrue -Because "no poll round between start $k and start $($k + 1)"
        }
    }

    It 'Parallel schedule reads Handle before the first HasExited read of each worker' {
        Assert-RunFilePresent
        $jobs = @(1..2 | ForEach-Object { Get-RunJob -Index $_ -Root $script:runRoot })
        $w = @{ 1 = (Get-FakeWorker -ProcId 1001 -ExitAfter 2 -Log $script:log); 2 = (Get-FakeWorker -ProcId 1003 -ExitAfter 2 -Log $script:log) }
        Register-ScheduleMock -Workers $w -Log $script:log -State $script:st -TreeKillBody $script:quietTreeKill
        foreach ($j in $jobs) { Add-ResultFile -IndexDir $j.IndexDir -Index $j.Index }
        $null = Invoke-Run -Jobs $jobs -Config $script:cfg -Max 2
        foreach ($procId in 1001, 1003) {
            $hIdx = $script:log.IndexOf("handle:$procId")
            $eIdx = $script:log.IndexOf("hasexited:$procId")
            $hIdx | Should -BeGreaterThan -1
            ($eIdx -gt $hIdx) | Should -BeTrue -Because "Handle must be pinned before HasExited for pid $procId"
        }
    }

    It 'Parallel schedule returns results sorted by Index and keeps index directories when workers exit in reverse order' {
        Assert-RunFilePresent
        $jobs = @(1..3 | ForEach-Object { Get-RunJob -Index $_ -Root $script:runRoot })
        $w = @{ 1 = (Get-FakeWorker -ProcId 1001 -ExitAfter 3 -Log $script:log); 2 = (Get-FakeWorker -ProcId 1003 -ExitAfter 2 -Log $script:log); 3 = (Get-FakeWorker -ProcId 1005 -ExitAfter 1 -Log $script:log) }
        Register-ScheduleMock -Workers $w -Log $script:log -State $script:st -TreeKillBody $script:quietTreeKill
        foreach ($j in $jobs) { Add-ResultFile -IndexDir $j.IndexDir -Index $j.Index }
        $res = @(Invoke-Run -Jobs $jobs -Config $script:cfg -Max 3)
        (@($res | ForEach-Object { $_.Index }) -join ',') | Should -Be '1,2,3'
        $res[0].KernelVersion | Should -Be '10.0.26300.1'
        foreach ($j in $jobs) { (Test-Path -LiteralPath $j.IndexDir -PathType Container) | Should -BeTrue }
    }

    It 'Parallel schedule treats exit code 0 without result.clixml as a failure and cleans the mount once' {
        Assert-RunFilePresent
        $jobs = @(Get-RunJob -Index 1 -Root $script:runRoot)
        $w = @{ 1 = (Get-FakeWorker -ProcId 1001 -ExitAfter 1 -ExitCode 0 -Log $script:log) }
        Register-ScheduleMock -Workers $w -Log $script:log -State $script:st -TreeKillBody $script:quietTreeKill
        New-Item -ItemType Directory -Path $jobs[0].IndexDir -Force | Out-Null
        { Invoke-Run -Jobs $jobs -Config $script:cfg } | Should -Throw -ExpectedMessage '*Index=1*result.clixml*'
        (@($script:log | Where-Object { $_ -eq 'mountcleanup:install-1' })).Count | Should -Be 1
        (@($script:log | Where-Object { $_ -like 'treekill:*' })).Count | Should -Be 0
    }

    It 'Parallel schedule treats a null ExitCode as a failure' {
        Assert-RunFilePresent
        $jobs = @(Get-RunJob -Index 1 -Root $script:runRoot)
        $w = @{ 1 = (Get-FakeWorker -ProcId 1001 -ExitAfter 1 -ExitCode $null -Log $script:log) }
        Register-ScheduleMock -Workers $w -Log $script:log -State $script:st -TreeKillBody $script:quietTreeKill
        Add-ResultFile -IndexDir $jobs[0].IndexDir -Index 1
        { Invoke-Run -Jobs $jobs -Config $script:cfg } | Should -Throw -ExpectedMessage '*Index=1*ExitCode*'
        (@($script:log | Where-Object { $_ -eq 'mountcleanup:install-1' })).Count | Should -Be 1
    }

    It 'Parallel schedule non-zero exit cleans the mount once, never tree-kills, and keeps the index directory with error text' {
        Assert-RunFilePresent
        $jobs = @(Get-RunJob -Index 1 -Root $script:runRoot)
        $w = @{ 1 = (Get-FakeWorker -ProcId 1001 -ExitAfter 1 -ExitCode 1 -Log $script:log) }
        Register-ScheduleMock -Workers $w -Log $script:log -State $script:st -TreeKillBody $script:quietTreeKill
        New-Item -ItemType Directory -Path $jobs[0].IndexDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $jobs[0].IndexDir 'error.txt') -Value 'boom-detail' -Encoding UTF8
        { Invoke-Run -Jobs $jobs -Config $script:cfg } | Should -Throw -ExpectedMessage '*Index=1*boom-detail*'
        (@($script:log | Where-Object { $_ -eq 'mountcleanup:install-1' })).Count | Should -Be 1
        (@($script:log | Where-Object { $_ -like 'treekill:*' })).Count | Should -Be 0
        (Test-Path -LiteralPath $jobs[0].IndexDir -PathType Container) | Should -BeTrue
    }

    It 'Parallel schedule stops launching after a failure and lets running workers finish' {
        Assert-RunFilePresent
        $jobs = @(1..3 | ForEach-Object { Get-RunJob -Index $_ -Root $script:runRoot })
        $w = @{ 1 = (Get-FakeWorker -ProcId 1001 -ExitAfter 1 -ExitCode 1 -Log $script:log); 2 = (Get-FakeWorker -ProcId 1003 -ExitAfter 4 -ExitCode 0 -Log $script:log); 3 = (Get-FakeWorker -ProcId 1005 -ExitAfter 1 -ExitCode 0 -Log $script:log) }
        Register-ScheduleMock -Workers $w -Log $script:log -State $script:st -TreeKillBody $script:quietTreeKill
        Add-ResultFile -IndexDir $jobs[1].IndexDir -Index 2
        { Invoke-Run -Jobs $jobs -Config $script:cfg -Max 2 } | Should -Throw -ExpectedMessage '*Index=1*'
        (@($script:log | Where-Object { $_ -eq 'start:3' })).Count | Should -Be 0
        ($script:log -contains 'exit:1003') | Should -BeTrue -Because 'the running sibling must finish'
    }

    It 'Parallel schedule timeout kills the root and runs mount cleanup only after the root has exited' {
        Assert-RunFilePresent
        $jobs = @(Get-RunJob -Index 1 -Root $script:runRoot)
        $w = @{ 1 = (Get-FakeWorker -ProcId 1001 -ExitAfter $null -Log $script:log) }
        Register-ScheduleMock -Workers $w -Log $script:log -State $script:st -TreeKillBody $script:killingTreeKill
        { Invoke-Run -Jobs $jobs -Config $script:cfg -Max 1 -Timeout 1 -Grace 5 } | Should -Throw -ExpectedMessage '*Index=1*timeout*'
        (@($script:log | Where-Object { $_ -eq 'treekill:1001' })).Count | Should -Be 1
        $exitIdx = $script:log.IndexOf('exit:1001')
        $cleanIdx = $script:log.IndexOf('mountcleanup:install-1')
        $exitIdx | Should -BeGreaterThan -1
        ($cleanIdx -gt $exitIdx) | Should -BeTrue -Because 'mount cleanup must follow the root exit'
    }

    It 'Parallel schedule timeout without root exit inside the grace period is ManualCleanup and runs no mount cleanup' {
        Assert-RunFilePresent
        $jobs = @(Get-RunJob -Index 1 -Root $script:runRoot)
        $w = @{ 1 = (Get-FakeWorker -ProcId 1001 -ExitAfter $null -Log $script:log) }
        Register-ScheduleMock -Workers $w -Log $script:log -State $script:st -TreeKillBody $script:quietTreeKill
        { Invoke-Run -Jobs $jobs -Config $script:cfg -Max 1 -Timeout 1 -Grace 5 } | Should -Throw -ExpectedMessage '*Index=1*ManualCleanup*'
        (@($script:log | Where-Object { $_ -like 'mountcleanup:*' })).Count | Should -Be 0
        (@($script:log | Where-Object { $_ -eq 'treekill:1001' })).Count | Should -Be 1
    }

    It 'Parallel schedule timeout with a TreeKill failure is ManualCleanup and runs no mount cleanup' {
        Assert-RunFilePresent
        $jobs = @(Get-RunJob -Index 1 -Root $script:runRoot)
        $w = @{ 1 = (Get-FakeWorker -ProcId 1001 -ExitAfter $null -Log $script:log) }
        Register-ScheduleMock -Workers $w -Log $script:log -State $script:st -TreeKillBody $script:failingTreeKill
        { Invoke-Run -Jobs $jobs -Config $script:cfg -Max 1 -Timeout 1 -Grace 5 } | Should -Throw -ExpectedMessage '*Index=1*ManualCleanup*'
        (@($script:log | Where-Object { $_ -like 'mountcleanup:*' })).Count | Should -Be 0
    }

    It 'Parallel schedule treats a null Handle at launch as a hard failure with no tree kill, no mount cleanup and no further launches' {
        Assert-RunFilePresent
        $jobs = @(1..2 | ForEach-Object { Get-RunJob -Index $_ -Root $script:runRoot })
        $w = @{ 1 = (Get-FakeWorker -ProcId 1001 -ExitAfter 1 -HandleOk $false -Log $script:log); 2 = (Get-FakeWorker -ProcId 1003 -ExitAfter 1 -Log $script:log) }
        Register-ScheduleMock -Workers $w -Log $script:log -State $script:st -TreeKillBody $script:quietTreeKill
        { Invoke-Run -Jobs $jobs -Config $script:cfg -Max 1 } | Should -Throw -ExpectedMessage '*Index=1*ManualCleanup*'
        (@($script:log | Where-Object { $_ -like 'treekill:*' })).Count | Should -Be 0
        (@($script:log | Where-Object { $_ -like 'mountcleanup:*' })).Count | Should -Be 0
        (@($script:log | Where-Object { $_ -eq 'start:2' })).Count | Should -Be 0
    }
}
