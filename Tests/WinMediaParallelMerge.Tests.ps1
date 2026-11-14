#Requires -Version 5.1

# Step 12c-3a RED：平行匯出與合併（Public\Invoke-WinMediaParallelMerge.ps1，尚未存在）。
# 全部以 mock 取代 Export-WindowsImage、Invoke-WinMediaDism、Get-WinMediaIndexInfo、Move-Item 與 Remove-Item；
# 預設 mock 一律 throw，確保測試不會真的匯出或移動映像。兩個 host 都是系統管理員，所以安全關卡是必要的。

BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    $script:mergeFile = Join-Path $script:root 'Public\Invoke-WinMediaParallelMerge.ps1'
    $script:manifest = Join-Path $script:root 'WinMediaRefresh.psd1'
    if (Test-Path -LiteralPath $script:manifest -PathType Leaf) {
        Import-Module -Name $script:manifest -Force
    }

    # Export-WindowsImage 在這台機器上是真的 DISM cmdlet；若命令不存在才建立全域 stub，AfterAll 移除
    $script:stubbedExport = $false
    if (-not (Get-Command -Name Export-WindowsImage -ErrorAction SilentlyContinue)) {
        Set-Item -Path 'function:global:Export-WindowsImage' -Value { param($SourceImagePath, $SourceIndex, $DestinationImagePath, $CompressionType, $LogLevel, $ScratchDirectory) $null = $SourceImagePath, $SourceIndex, $DestinationImagePath, $CompressionType, $LogLevel, $ScratchDirectory }
        $script:stubbedExport = $true
    }

    function Assert-MergeFilePresent {
        (Test-Path -LiteralPath $script:mergeFile -PathType Leaf) | Should -BeTrue -Because 'file missing: Invoke-WinMediaParallelMerge.ps1'
    }

    # 函式只被 dot-source 進根模組、未匯出，故於模組範圍內執行
    function Invoke-InModule {
        param([scriptblock]$Script, [object[]]$ArgList = @())
        & (Get-Module -Name WinMediaRefresh) $Script @ArgList
    }

    # 安全關卡：被 mock 的名稱在模組範圍內必須解析為 Alias；否則停止，避免真的匯出或移動映像
    function Assert-MocksLive {
        foreach ($n in @('Export-WindowsImage', 'Invoke-WinMediaDism', 'Get-WinMediaIndexInfo', 'Move-Item', 'Remove-Item')) {
            $type = Invoke-InModule { param($x) (Get-Command -Name $x -ErrorAction Stop).CommandType } @($n)
            $type | Should -Be 'Alias' -Because "mock not live in WinMediaRefresh scope: $n"
        }
    }

    function Register-SafeDefaultMock {
        Mock -ModuleName WinMediaRefresh Export-WindowsImage { throw 'unexpected call: Export-WindowsImage' }
        Mock -ModuleName WinMediaRefresh Get-WinMediaIndexInfo { throw 'unexpected call: Get-WinMediaIndexInfo' }
        Mock -ModuleName WinMediaRefresh Invoke-WinMediaDism { param($Provider, $Config, $ScriptBlock) $null = $Provider, $Config, $ScriptBlock; throw 'unexpected call: Invoke-WinMediaDism' }
        Mock -ModuleName WinMediaRefresh Move-Item { throw 'unexpected call: Move-Item' }
        Mock -ModuleName WinMediaRefresh Remove-Item { throw 'unexpected call: Remove-Item' }
    }

    # 依 $SourceInfo（原始 WIM）與 $MergedInfo（合併後）設定 mock；所有動作依序記錄在 $Ops
    function Register-MergeMock {
        param([object[]]$SourceInfo, [object[]]$MergedInfo, [System.Collections.Generic.List[string]]$Ops, [string]$FailExportTo = '')
        $si = $SourceInfo
        $mi = $MergedInfo
        $o = $Ops
        $fail = $FailExportTo
        Mock -ModuleName WinMediaRefresh Get-WinMediaIndexInfo {
            param($ImagePath, $Config)
            $null = $Config
            if ($ImagePath -like '*merged.wim') { $mi } else { $si }
        }.GetNewClosure()
        Mock -ModuleName WinMediaRefresh Invoke-WinMediaDism {
            param($Provider, $Config, $ScriptBlock)
            $null = $Provider, $Config
            & $ScriptBlock
        }
        Mock -ModuleName WinMediaRefresh Export-WindowsImage {
            param($SourceImagePath, $SourceIndex, $DestinationImagePath, $CompressionType, $LogLevel, $ScratchDirectory)
            $null = $CompressionType, $LogLevel, $ScratchDirectory
            $o.Add("export:$SourceImagePath|$SourceIndex|$DestinationImagePath")
            if ($fail -and $DestinationImagePath -eq $fail) { throw 'export failed' }
        }.GetNewClosure()
        Mock -ModuleName WinMediaRefresh Move-Item {
            param($LiteralPath, $Destination, $Force)
            $null = $Force
            $o.Add("move:$LiteralPath|$Destination")
        }.GetNewClosure()
        Mock -ModuleName WinMediaRefresh Remove-Item {
            param($LiteralPath, $Force)
            $null = $Force
            $o.Add("remove:$LiteralPath")
        }.GetNewClosure()
    }

    function Invoke-Merge {
        param([int[]]$AllIndexes, [int[]]$Targets, [string]$Root, [string]$Source)
        Assert-MocksLive
        Invoke-InModule { param($src, $all, $tg, $rt, $cfg) Invoke-WinMediaParallelMerge -SourceWim $src -AllIndexes $all -Targets $tg -ParallelRoot $rt -Config $cfg } @($Source, $AllIndexes, $Targets, $Root, $script:cfg)
    }

    function Invoke-Stage {
        param([int[]]$Targets, [string]$Root, [string]$Source)
        Assert-MocksLive
        Invoke-InModule { param($src, $tg, $rt, $cfg) Invoke-WinMediaParallelStage -SourceWim $src -Targets $tg -ParallelRoot $rt -Config $cfg } @($Source, $Targets, $Root, $script:cfg)
    }

    $script:cfg = @{ DismProvider = 'Inbox'; DismLogLevel = 'Errors'; LogLevel = 'Error'; LogFile = ''; OperationLog = ''; DebugTrace = 0 }
    $script:srcInfo = @(
        [pscustomobject]@{ ImageIndex = 1; ImageName = 'Home'; EditionId = 'Core' },
        [pscustomobject]@{ ImageIndex = 2; ImageName = 'Pro'; EditionId = 'Professional' },
        [pscustomobject]@{ ImageIndex = 3; ImageName = 'Enterprise'; EditionId = 'Enterprise' }
    )
}

AfterAll {
    if ($script:stubbedExport) {
        Remove-Item -Path 'Function:\global:Export-WindowsImage' -ErrorAction SilentlyContinue
    }
}

Describe 'Parallel merge: static' {
    It 'Parallel merge file exists' {
        Assert-MergeFilePresent
    }

    It 'Parallel merge file has no forbidden commands and every Export-WindowsImage splats @common and passes -LogLevel (AST, always runs)' {
        Assert-MergeFilePresent
        $forbidden = @('Clear-WinMediaMount', 'Clear-WindowsCorruptMountPoint', 'Invoke-WinMediaWorkspaceCleanup', 'Stop-Process', 'taskkill', 'taskkill.exe', 'Start-Process')
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:mergeFile, [ref]$null, [ref]$null)
        $cmds = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))
        $names = @($cmds | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
        @($names | Where-Object { $forbidden -contains $_ }).Count | Should -Be 0
        $exports = @($cmds | Where-Object { $_.GetCommandName() -eq 'Export-WindowsImage' })
        $exports.Count | Should -BeGreaterThan 0
        foreach ($c in $exports) {
            $text = $c.Extent.Text
            ($text -match '-LogLevel') | Should -BeTrue -Because "Export-WindowsImage must pass -LogLevel: $text"
            ($text -match '@common') | Should -BeTrue -Because "Export-WindowsImage must splat @common: $text"
        }
    }
}

Describe 'Parallel merge: safety gate' {
    BeforeEach {
        Register-SafeDefaultMock
    }

    It 'Parallel merge safety gate sees every mocked name as live in module scope' {
        Assert-MocksLive
    }

    It 'Parallel merge harness drives the mocked DISM, move and remove calls in the expected order' {
        $ops = [System.Collections.Generic.List[string]]::new()
        Register-MergeMock -SourceInfo $script:srcInfo -MergedInfo @($script:srcInfo[0]) -Ops $ops
        $counts = Invoke-InModule {
            param($cfg)
            Invoke-WinMediaDism -Provider $cfg.DismProvider -Config $cfg -ScriptBlock { Export-WindowsImage -SourceImagePath 'a.wim' -SourceIndex 1 -DestinationImagePath 'b.wim' -LogLevel Errors | Out-Null } | Out-Null
            Move-Item -LiteralPath 'x' -Destination 'y' -Force
            Remove-Item -LiteralPath 'z' -Force
            $merged = @(Get-WinMediaIndexInfo -ImagePath 'C:\w\merged.wim' -Config $cfg).Count
            $source = @(Get-WinMediaIndexInfo -ImagePath 'C:\w\install.wim' -Config $cfg).Count
            @($merged, $source)
        } @($script:cfg)
        $ops[0] | Should -Be 'export:a.wim|1|b.wim'
        $ops[1] | Should -Be 'move:x|y'
        $ops[2] | Should -Be 'remove:z'
        $counts[0] | Should -Be 1
        $counts[1] | Should -Be 3
    }
}

Describe 'Parallel merge: behaviour' {
    BeforeEach {
        Register-SafeDefaultMock
        $script:ops = [System.Collections.Generic.List[string]]::new()
        $script:mergeRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:mergeRoot -Force | Out-Null
        $script:src = Join-Path $script:mergeRoot 'install.wim'
        $script:merged = Join-Path $script:mergeRoot 'merged.wim'
    }

    It 'Parallel merge stage exports each target once to its own idx install.wim and no other index' {
        Assert-MergeFilePresent
        Register-MergeMock -SourceInfo $script:srcInfo -MergedInfo @() -Ops $script:ops
        Invoke-Stage -Targets @(2, 3) -Root $script:mergeRoot -Source $script:src
        $script:ops.Count | Should -Be 2
        $script:ops[0] | Should -Be ("export:$($script:src)|2|" + (Join-Path $script:mergeRoot 'idx2\install.wim'))
        $script:ops[1] | Should -Be ("export:$($script:src)|3|" + (Join-Path $script:mergeRoot 'idx3\install.wim'))
    }

    It 'Parallel merge exports every index in ascending order, taking targets from their idx WIM index 1' {
        Assert-MergeFilePresent
        Register-MergeMock -SourceInfo $script:srcInfo -MergedInfo $script:srcInfo -Ops $script:ops
        Invoke-Merge -AllIndexes @(1, 2, 3) -Targets @(2) -Root $script:mergeRoot -Source $script:src
        $exports = @($script:ops | Where-Object { $_ -like 'export:*' })
        $exports.Count | Should -Be 3
        $exports[0] | Should -Be ("export:$($script:src)|1|$($script:merged)")
        $exports[1] | Should -Be ("export:$(Join-Path $script:mergeRoot 'idx2\install.wim')|1|$($script:merged)")
        $exports[2] | Should -Be ("export:$($script:src)|3|$($script:merged)")
    }

    It 'Parallel merge refuses non-contiguous indexes before any export' {
        Assert-MergeFilePresent
        Register-MergeMock -SourceInfo $script:srcInfo -MergedInfo $script:srcInfo -Ops $script:ops
        { Invoke-Merge -AllIndexes @(1, 3) -Targets @(1) -Root $script:mergeRoot -Source $script:src } | Should -Throw -ExpectedMessage '*連續*'
        @($script:ops | Where-Object { $_ -like 'export:*' }).Count | Should -Be 0
    }

    It 'Parallel merge throws with a count message on an index count mismatch and does not move or delete anything' {
        Assert-MergeFilePresent
        Register-MergeMock -SourceInfo $script:srcInfo -MergedInfo @($script:srcInfo[0]) -Ops $script:ops
        { Invoke-Merge -AllIndexes @(1, 2, 3) -Targets @(2) -Root $script:mergeRoot -Source $script:src } | Should -Throw -ExpectedMessage '*數量*'
        @($script:ops | Where-Object { $_ -like 'move:*' }).Count | Should -Be 0
        @($script:ops | Where-Object { $_ -like 'remove:*' }).Count | Should -Be 0
    }

    It 'Parallel merge throws with a name message on an ImageName mismatch and does not move or delete anything' {
        Assert-MergeFilePresent
        $renamed = @($script:srcInfo[0], [pscustomobject]@{ ImageIndex = 2; ImageName = 'Standard'; EditionId = 'Professional' }, $script:srcInfo[2])
        Register-MergeMock -SourceInfo $script:srcInfo -MergedInfo $renamed -Ops $script:ops
        { Invoke-Merge -AllIndexes @(1, 2, 3) -Targets @(2) -Root $script:mergeRoot -Source $script:src } | Should -Throw -ExpectedMessage '*名稱*'
        @($script:ops | Where-Object { $_ -like 'move:*' }).Count | Should -Be 0
        @($script:ops | Where-Object { $_ -like 'remove:*' }).Count | Should -Be 0
    }

    It 'Parallel merge throws with an edition message on an EditionId mismatch and does not move or delete anything' {
        Assert-MergeFilePresent
        $edition = @($script:srcInfo[0], [pscustomobject]@{ ImageIndex = 2; ImageName = 'Pro'; EditionId = 'Core' }, $script:srcInfo[2])
        Register-MergeMock -SourceInfo $script:srcInfo -MergedInfo $edition -Ops $script:ops
        { Invoke-Merge -AllIndexes @(1, 2, 3) -Targets @(2) -Root $script:mergeRoot -Source $script:src } | Should -Throw -ExpectedMessage '*版本*'
        @($script:ops | Where-Object { $_ -like 'move:*' }).Count | Should -Be 0
        @($script:ops | Where-Object { $_ -like 'remove:*' }).Count | Should -Be 0
    }

    It 'Parallel merge keeps the idx WIMs and does not move when an export fails' {
        Assert-MergeFilePresent
        Register-MergeMock -SourceInfo $script:srcInfo -MergedInfo $script:srcInfo -Ops $script:ops -FailExportTo $script:merged
        { Invoke-Merge -AllIndexes @(1, 2, 3) -Targets @(2) -Root $script:mergeRoot -Source $script:src } | Should -Throw -ExpectedMessage '*export failed*'
        @($script:ops | Where-Object { $_ -like 'move:*' }).Count | Should -Be 0
        @($script:ops | Where-Object { $_ -like 'remove:*' }).Count | Should -Be 0
    }

    It 'Parallel merge moves the merged WIM over the source once after all exports and removes only the idx WIM after the move' {
        Assert-MergeFilePresent
        Register-MergeMock -SourceInfo $script:srcInfo -MergedInfo $script:srcInfo -Ops $script:ops
        Invoke-Merge -AllIndexes @(1, 2, 3) -Targets @(2) -Root $script:mergeRoot -Source $script:src | Out-Null
        $moves = @($script:ops | Where-Object { $_ -like 'move:*' })
        $moves.Count | Should -Be 1
        $moves[0] | Should -Be ("move:$($script:merged)|$($script:src)")
        $moveIdx = $script:ops.FindIndex([Predicate[string]] { param($s) $s -like 'move:*' })
        $lastExport = -1
        for ($i = 0; $i -lt $script:ops.Count; $i++) { if ($script:ops[$i] -like 'export:*') { $lastExport = $i } }
        ($moveIdx -gt $lastExport) | Should -BeTrue -Because 'the move must follow every export'
        $removes = @($script:ops | Where-Object { $_ -like 'remove:*' })
        $removes.Count | Should -Be 1
        $removes[0] | Should -Be ("remove:$(Join-Path $script:mergeRoot 'idx2\install.wim')")
        $removeIdx = $script:ops.FindIndex([Predicate[string]] { param($s) $s -like 'remove:*' })
        ($removeIdx -gt $moveIdx) | Should -BeTrue -Because 'idx WIMs are removed only after the move succeeds'
    }

    It 'Parallel merge removes an existing merged WIM before the first export' {
        Assert-MergeFilePresent
        New-Item -ItemType File -Path $script:merged -Force | Out-Null
        Register-MergeMock -SourceInfo $script:srcInfo -MergedInfo $script:srcInfo -Ops $script:ops
        Invoke-Merge -AllIndexes @(1, 2, 3) -Targets @(2) -Root $script:mergeRoot -Source $script:src | Out-Null
        $removeIdx = $script:ops.FindIndex([Predicate[string]] { param($s) $s -eq "remove:$($script:merged)" })
        $firstExport = $script:ops.FindIndex([Predicate[string]] { param($s) $s -like 'export:*' })
        $removeIdx | Should -BeGreaterThan -1
        ($removeIdx -lt $firstExport) | Should -BeTrue -Because 'the old merged WIM must be removed before the first export'
    }

    It 'Parallel merge stage removes stale result.clixml and error.txt from each target idx folder before its export' {
        Assert-MergeFilePresent
        Register-MergeMock -SourceInfo $script:srcInfo -MergedInfo @() -Ops $script:ops
        $idx2 = Join-Path $script:mergeRoot 'idx2'
        New-Item -ItemType Directory -Path $idx2 -Force | Out-Null
        $res = Join-Path $idx2 'result.clixml'
        $err = Join-Path $idx2 'error.txt'
        New-Item -ItemType File -Path $res -Force | Out-Null
        New-Item -ItemType File -Path $err -Force | Out-Null
        Invoke-Stage -Targets @(2) -Root $script:mergeRoot -Source $script:src
        $script:ops | Should -Contain "remove:$res"
        $script:ops | Should -Contain "remove:$err"
        $firstExport = $script:ops.FindIndex([Predicate[string]] { param($s) $s -like 'export:*' })
        $resIdx = $script:ops.FindIndex([Predicate[string]] { param($s) $s -eq "remove:$res" })
        ($resIdx -lt $firstExport) | Should -BeTrue -Because 'stale result files must be gone before the export starts'
    }
}
