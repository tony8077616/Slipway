#Requires -Version 5.1

# Step 12c-3b：平行安裝索引的編排（Public\Invoke-WinMediaParallelInstall.ps1）。RED 4c62887，GREEN 66708d9。
# 排程器保持真實，只 mock Start-WinMediaIndexWorker（假程序＋寫入 result.clixml）。
# 其餘 DISM、掛載、開機檔、合併與清理一律以 throw 或記錄動作的 mock 取代。

BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    $script:helperFile = Join-Path $script:root 'Public\Invoke-WinMediaParallelInstall.ps1'
    $script:refreshFile = Join-Path $script:root 'Public\Invoke-WindowsMediaRefresh.ps1'
    $script:manifest = Join-Path $script:root 'WinMediaRefresh.psd1'
    Import-Module -Name $script:manifest -Force

    function Assert-InstallFilePresent {
        (Test-Path -LiteralPath $script:helperFile -PathType Leaf) | Should -BeTrue -Because 'file missing: Invoke-WinMediaParallelInstall.ps1'
    }

    function Invoke-InModule {
        param([scriptblock]$Script, [object[]]$ArgList = @())
        & (Get-Module -Name WinMediaRefresh) $Script @ArgList
    }

    # 安全關卡：被 mock 的名稱在模組範圍內必須能解析；否則停止，避免真的啟動子程序或掛載映像
    function Assert-InstallMocksLive {
        foreach ($n in @('Start-WinMediaIndexWorker', 'Mount-WinMediaImage', 'Copy-WinMediaUpdatedBootFiles', 'Invoke-WinMediaParallelStage', 'Invoke-WinMediaParallelMerge', 'Invoke-WinMediaParallelMountCleanup', 'Invoke-WinMediaParallelTreeKill', 'Invoke-WinMediaOperation', 'Get-WinMediaParallelSpaceWarning', 'Write-WinMediaLog', 'Start-Sleep')) {
            $type = Invoke-InModule { param($x) (Get-Command -Name $x -ErrorAction Stop).CommandType } @($n)
            $type | Should -Be 'Alias' -Because "mock not live in WinMediaRefresh scope: $n"
        }
    }
}

Describe 'Parallel install: static' {
    It 'Parallel install file exists' {
        Assert-InstallFilePresent
    }

    It 'Refresh routes on $parallelCount: parallel helper in the if branch, serial install loop in the else branch (AST)' {
        $refreshAst = [System.Management.Automation.Language.Parser]::ParseFile($script:refreshFile, [ref]$null, [ref]$null)
        $ifs = @($refreshAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -match '\$parallelCount' }, $true))
        $ifs.Count | Should -Be 1
        $ifs[0].Clauses[0].Item2.Extent.Text | Should -Match 'Invoke-WinMediaParallelInstall'
        $ifs[0].Clauses[0].Item2.Extent.Text | Should -Not -Match 'Invoke-WinMediaInstallIndexUpdate'
        $ifs[0].ElseClause.Extent.Text | Should -Match 'Invoke-WinMediaInstallIndexUpdate'
        $ifs[0].ElseClause.Extent.Text | Should -Not -Match 'Invoke-WinMediaParallelInstall'
    }
    It 'Parallel install: the mock gate rejects names that are not mocked (Function is not enough)' {
        { Assert-InstallMocksLive } | Should -Throw
    }
}

Describe 'Parallel install: behaviour' {
    BeforeAll {
        function Register-InstallMock {
            param([System.Collections.Generic.List[string]]$Ops, [hashtable]$ExitCodes = @{}, [bool]$SpaceLow = $false)
            $o = $Ops
            $ec = $ExitCodes
            $cnt = @(0)
            $status = if ($SpaceLow) { 'Low' } else { 'Ok' }
            Mock -ModuleName WinMediaRefresh Write-WinMediaLog { }
            Mock -ModuleName WinMediaRefresh Start-Sleep { }
            Mock -ModuleName WinMediaRefresh Invoke-WinMediaParallelTreeKill { throw 'unexpected call: Invoke-WinMediaParallelTreeKill' }
            Mock -ModuleName WinMediaRefresh Invoke-WinMediaParallelStage { $o.Add('stage') }.GetNewClosure()
            Mock -ModuleName WinMediaRefresh Invoke-WinMediaParallelMerge { $o.Add('merge') }.GetNewClosure()
            Mock -ModuleName WinMediaRefresh Start-WinMediaIndexWorker {
                param($Job, $IndexDir)
                $null = $Job
                New-Item -ItemType Directory -Path $IndexDir -Force | Out-Null
                $idx = [int]((Split-Path -Path $IndexDir -Leaf) -replace '^idx', '')
                $o.Add("start:$idx")
                $code = if ($ec.ContainsKey($idx)) { $ec[$idx] } else { 0 }
                if ($code -eq 0) {
                    Export-Clixml -LiteralPath (Join-Path -Path $IndexDir -ChildPath 'result.clixml') -InputObject ([pscustomobject]@{ Index = 1; KernelVersion = "10.0.26100.$idx"; BuildInfo = [pscustomobject]@{ Build = "26100.$idx" } })
                }
                [pscustomobject]@{ HasExited = $true; ExitCode = $code; Handle = 1 }
            }.GetNewClosure()
            Mock -ModuleName WinMediaRefresh Mount-WinMediaImage {
                param($ImagePath, $Index, $MountPath, $ReadOnly, $Action, $Config)
                $null = $ImagePath, $Config
                $o.Add("mount:${Index}:" + [bool]$ReadOnly)
                & $Action $MountPath
            }.GetNewClosure()
            Mock -ModuleName WinMediaRefresh Invoke-WinMediaOperation {
                param($Category, $Operation, $Target, $Config, $ScriptBlock)
                $null = $Category, $Target, $Config, $ScriptBlock
                $o.Add("op:$Operation")
            }.GetNewClosure()
            Mock -ModuleName WinMediaRefresh Copy-WinMediaUpdatedBootFiles {
                param($MountPath, $MediaDir, $Config)
                $null = $MountPath, $MediaDir, $Config
                $cnt[0]++
                $o.Add('boot')
                return ($cnt[0] -eq 2)
            }.GetNewClosure()
            Mock -ModuleName WinMediaRefresh Invoke-WinMediaParallelMountCleanup {
                param($MountPath, $Config)
                $null = $Config
                $o.Add('cleanup:' + (Split-Path -Path $MountPath -Leaf))
                [pscustomobject]@{ Result = 'Discarded' }
            }.GetNewClosure()
            Mock -ModuleName WinMediaRefresh Get-WinMediaParallelSpaceWarning {
                param($Path, $Count, $EstimateGB, $FreeSpaceGB)
                $null = $Path, $Count, $EstimateGB, $FreeSpaceGB
                [pscustomobject]@{ Root = 'C:\'; RequiredGB = 60; FreeGB = 10; Status = $status }
            }.GetNewClosure()
        }

        function Get-InstallTestConfig {
            param([string]$Root, [bool]$UpdateBootFiles = $true)
            @{
                MountDir = (Join-Path -Path $Root -ChildPath 'mnt'); LogDir = (Join-Path -Path $Root -ChildPath 'logs')
                LogFile = ''; OperationLog = ''; DismProvider = 'Inbox'; DismLogLevel = 'Errors'
                UpdateBootFiles = $UpdateBootFiles; MountSpaceEstimateGB = 30; MountParallelCount = 2
            }
        }

        function Invoke-InstallCase {
            param([int[]]$Targets = @(2, 3), [bool]$IsEsd = $false, [hashtable]$Cfg, [hashtable]$Kernel, [hashtable]$Build, [hashtable]$Boot, [string]$Root)
            Assert-InstallMocksLive
            $bj = @{
                mountSwitches = @{}; ssu = 'ssu.msu'; lcuStage = 'stage'; langFod = $null; dotNet = $null; appxList = $null
                storeSet = $null; lxpItems = $null; driverSet = $null; forceUnsigned = $false; resetBaseOS = $false
                common = @{}; winreWim = 'winre.wim'; Config = $Cfg
            }
            Invoke-InModule {
                param($tg, $esd, $cfg, $k, $b, $bx, $bjob, $r)
                Invoke-WinMediaParallelInstall -InstallWim (Join-Path -Path $r -ChildPath 'media\sources\install.wim') -AllIndexes @(1, 2, 3) -Targets $tg -ParallelRoot (Join-Path -Path $r -ChildPath 'parallel') -MountDir (Join-Path -Path $r -ChildPath 'mnt') -BaseJob $bjob -Config $cfg -SourcesDir (Join-Path -Path $r -ChildPath 'media\sources') -MediaDir (Join-Path -Path $r -ChildPath 'media') -MaxConcurrent 2 -InstallKernel $k -BuildInfo $b -BootEx $bx -IsEsdSource:$esd
            } @($Targets, $IsEsd, $Cfg, $Kernel, $Build, $Boot, $bj, $Root)
        }
    }

    It 'Parallel install: an empty per-index scratch folder is removed after a successful run' {
        Assert-InstallFilePresent
        $root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        $ops = [System.Collections.Generic.List[string]]::new()
        Register-InstallMock -Ops $ops
        $scratch = Join-Path -Path $root -ChildPath 'scratch'
        New-Item -ItemType Directory -Path (Join-Path -Path $scratch -ChildPath 'idx2') -Force | Out-Null
        $cfg = Get-InstallTestConfig -Root $root
        $cfg['ScratchDirectory'] = $scratch
        $k = @{ Version = $null }; $b = @{ Info = $null }; $bx = @{ Applied = $false }
        Invoke-InstallCase -Cfg $cfg -Kernel $k -Build $b -Boot $bx -Root $root
        Test-Path -LiteralPath (Join-Path -Path $scratch -ChildPath 'idx2') | Should -BeFalse
    }

    It 'Parallel install: a non-empty per-index scratch folder is kept and logged as a warning' {
        Assert-InstallFilePresent
        $root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        $ops = [System.Collections.Generic.List[string]]::new()
        Register-InstallMock -Ops $ops
        $scratch = Join-Path -Path $root -ChildPath 'scratch'
        New-Item -ItemType Directory -Path (Join-Path -Path $scratch -ChildPath 'idx3') -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path -Path $scratch -ChildPath 'idx3\keep.txt') -Force | Out-Null
        $cfg = Get-InstallTestConfig -Root $root
        $cfg['ScratchDirectory'] = $scratch
        $k = @{ Version = $null }; $b = @{ Info = $null }; $bx = @{ Applied = $false }
        Invoke-InstallCase -Cfg $cfg -Kernel $k -Build $b -Boot $bx -Root $root
        Test-Path -LiteralPath (Join-Path -Path $scratch -ChildPath 'idx3\keep.txt') | Should -BeTrue
        Should -Invoke -ModuleName WinMediaRefresh Write-WinMediaLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Warning' }
    }

    It 'Parallel install: a failed child leaves its per-index scratch folder for diagnosis' {
        Assert-InstallFilePresent
        $root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        $ops = [System.Collections.Generic.List[string]]::new()
        Register-InstallMock -Ops $ops -ExitCodes @{ 3 = 1 }
        $scratch = Join-Path -Path $root -ChildPath 'scratch'
        New-Item -ItemType Directory -Path (Join-Path -Path $scratch -ChildPath 'idx2') -Force | Out-Null
        $cfg = Get-InstallTestConfig -Root $root
        $cfg['ScratchDirectory'] = $scratch
        $k = @{ Version = $null }; $b = @{ Info = $null }; $bx = @{ Applied = $false }
        { Invoke-InstallCase -Cfg $cfg -Kernel $k -Build $b -Boot $bx -Root $root } | Should -Throw
        Test-Path -LiteralPath (Join-Path -Path $scratch -ChildPath 'idx2') | Should -BeTrue
    }

    It 'Parallel install: a failed scratch removal is logged as a warning and does not stop the merge or the sync' {
        Assert-InstallFilePresent
        $root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        $ops = [System.Collections.Generic.List[string]]::new()
        Register-InstallMock -Ops $ops
        Mock -ModuleName WinMediaRefresh Remove-Item { throw 'locked' } -ParameterFilter { $LiteralPath -like '*\scratch\idx*' }
        $scratch = Join-Path -Path $root -ChildPath 'scratch'
        New-Item -ItemType Directory -Path (Join-Path -Path $scratch -ChildPath 'idx2') -Force | Out-Null
        $cfg = Get-InstallTestConfig -Root $root
        $cfg['ScratchDirectory'] = $scratch
        $k = @{ Version = $null }; $b = @{ Info = $null }; $bx = @{ Applied = $false }
        Invoke-InstallCase -Cfg $cfg -Kernel $k -Build $b -Boot $bx -Root $root
        Test-Path -LiteralPath (Join-Path -Path $scratch -ChildPath 'idx2') | Should -BeTrue
        ($ops -join ',') | Should -Match 'merge'
        ($ops -join ',') | Should -Match 'mount:2:True'
        Should -Invoke -ModuleName WinMediaRefresh Write-WinMediaLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Warning' }
    }

    It 'order: stage, one worker per target, merge, then read-only mounts with xmllite on the first target and boot copy per target' {
        Assert-InstallFilePresent
        $root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        $ops = [System.Collections.Generic.List[string]]::new()
        Register-InstallMock -Ops $ops
        $k = @{ Version = $null }; $b = @{ Info = $null }; $bx = @{ Applied = $false }
        Invoke-InstallCase -Cfg (Get-InstallTestConfig -Root $root) -Kernel $k -Build $b -Boot $bx -Root $root
        ($ops -join ',') | Should -Be 'stage,start:2,start:3,merge,mount:2:True,op:CopyXmlLite,boot,mount:3:True,boot'
    }

    It 'kernel and build info come from the first target; BootEx.Applied is the result of the last boot copy' {
        Assert-InstallFilePresent
        $root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        $ops = [System.Collections.Generic.List[string]]::new()
        Register-InstallMock -Ops $ops
        $k = @{ Version = $null }; $b = @{ Info = $null }; $bx = @{ Applied = $false }
        Invoke-InstallCase -Cfg (Get-InstallTestConfig -Root $root) -Kernel $k -Build $b -Boot $bx -Root $root
        $k.Version | Should -Be '10.0.26100.2'
        $b.Info.Build | Should -Be '26100.2'
        $bx.Applied | Should -BeTrue
    }

    It 'UpdateBootFiles false: only the first target is mounted for xmllite; no boot copy; BootEx.Applied stays false' {
        Assert-InstallFilePresent
        $root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        $ops = [System.Collections.Generic.List[string]]::new()
        Register-InstallMock -Ops $ops
        $k = @{ Version = $null }; $b = @{ Info = $null }; $bx = @{ Applied = $false }
        Invoke-InstallCase -Cfg (Get-InstallTestConfig -Root $root -UpdateBootFiles $false) -Kernel $k -Build $b -Boot $bx -Root $root
        ($ops -join ',') | Should -Be 'stage,start:2,start:3,merge,mount:2:True,op:CopyXmlLite'
        $bx.Applied | Should -BeFalse
    }

    It 'ESD source: xmllite is still copied from the first target, and no boot copy runs' {
        Assert-InstallFilePresent
        $root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        $ops = [System.Collections.Generic.List[string]]::new()
        Register-InstallMock -Ops $ops
        $k = @{ Version = $null }; $b = @{ Info = $null }; $bx = @{ Applied = $false }
        Invoke-InstallCase -IsEsd $true -Cfg (Get-InstallTestConfig -Root $root) -Kernel $k -Build $b -Boot $bx -Root $root
        ($ops -join ',') | Should -Be 'stage,start:2,start:3,merge,mount:2:True,op:CopyXmlLite'
        $bx.Applied | Should -BeFalse
    }

    It 'child failure: throws, and merge, read-only mounts and boot copy never run' {
        Assert-InstallFilePresent
        $root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        $ops = [System.Collections.Generic.List[string]]::new()
        Register-InstallMock -Ops $ops -ExitCodes @{ 3 = 1 }
        $k = @{ Version = $null }; $b = @{ Info = $null }; $bx = @{ Applied = $false }
        { Invoke-InstallCase -Cfg (Get-InstallTestConfig -Root $root) -Kernel $k -Build $b -Boot $bx -Root $root } | Should -Throw -ExpectedMessage '*平行子程序失敗*'
        $ops | Should -Not -Contain 'merge'
        $ops | Should -Not -Contain 'boot'
        @($ops | Where-Object { $_ -like 'mount:*' }).Count | Should -Be 0
        $ops | Should -Contain 'cleanup:install-3'
    }

    It 'low free space logs one warning through Write-WinMediaLog' {
        Assert-InstallFilePresent
        $root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        $ops = [System.Collections.Generic.List[string]]::new()
        Register-InstallMock -Ops $ops -SpaceLow $true
        $k = @{ Version = $null }; $b = @{ Info = $null }; $bx = @{ Applied = $false }
        Invoke-InstallCase -Cfg (Get-InstallTestConfig -Root $root) -Kernel $k -Build $b -Boot $bx -Root $root
        Should -Invoke -ModuleName WinMediaRefresh Write-WinMediaLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Warning' }
    }

    It 'sync mount leaf names are owned by the Step 11 cleanup tool (same pattern the cleanup uses)' {
        Assert-InstallFilePresent
        $wsText = [IO.File]::ReadAllText((Join-Path -Path $script:root -ChildPath 'Modules\WinMediaWorkspace.psm1'))
        $m = [regex]::Match($wsText, "OwnedChildPattern\s*=\s*'([^']+)'")
        $m.Success | Should -BeTrue -Because 'OwnedChildPattern not found in WinMediaWorkspace.psm1'
        $pattern = $m.Groups[1].Value
        $pattern | Should -Not -BeNullOrEmpty
        'install-1' | Should -Match $pattern
        'boot-src' | Should -Not -Match $pattern
        $root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        $ops = [System.Collections.Generic.List[string]]::new()
        Register-InstallMock -Ops $ops
        $leaves = [System.Collections.Generic.List[string]]::new()
        $seen = $leaves
        Mock -ModuleName WinMediaRefresh Mount-WinMediaImage {
            param($ImagePath, $Index, $MountPath, $ReadOnly, $Action, $Config)
            $null = $ImagePath, $Index, $ReadOnly, $Config
            $seen.Add((Split-Path -Path $MountPath -Leaf))
            & $Action $MountPath
        }.GetNewClosure()
        $k = @{ Version = $null }; $b = @{ Info = $null }; $bx = @{ Applied = $false }
        Invoke-InstallCase -Cfg (Get-InstallTestConfig -Root $root) -Kernel $k -Build $b -Boot $bx -Root $root
        $leaves.Count | Should -BeGreaterThan 0
        foreach ($leaf in $leaves) { $leaf | Should -Match $pattern }
    }
}
