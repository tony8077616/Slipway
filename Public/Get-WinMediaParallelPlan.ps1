# 平行處理計畫的純函式：不呼叫 DISM、不碰檔案系統、不啟動子行程。

function Get-WinMediaParallelCount {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)]
        [int]$Requested,

        [Parameter(Mandatory = $true)]
        [int]$TargetCount
    )

    return [Math]::Max(1, [Math]::Min($Requested, $TargetCount))
}

function Get-WinMediaParallelStagingGB {
    # 暫存區需要的空間：每個目標索引一份 idx WIM，加上一份 merged.wim
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory = $true)]
        [int[]]$Targets,

        [Parameter(Mandatory = $true)]
        [double]$InstallWimGB
    )

    if ($Targets.Count -eq 0) {
        throw 'Targets 不可為空。'
    }

    return [double](($Targets.Count + 1) * $InstallWimGB)
}

function Get-WinMediaParallelSpaceWarning {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string[]]$Path,

        [Parameter(Mandatory = $true)]
        [int]$Count,

        [Parameter(Mandatory = $true)]
        [double]$EstimateGB,

        [Parameter(Mandatory = $true)]
        [hashtable]$FreeSpaceGB
    )

    $requiredGB = [double]($Count * $EstimateGB)
    $seenRoots = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($p in $Path) {
        if ([string]::IsNullOrWhiteSpace($p)) {
            continue
        }

        $root = [System.IO.Path]::GetPathRoot($p)
        if ([string]::IsNullOrWhiteSpace($root)) {
            continue
        }

        $rootUpper = $root.ToUpperInvariant()
        if (-not $seenRoots.Add($rootUpper)) {
            continue
        }

        $freeGB = $null
        $status = 'Unknown'
        if ($FreeSpaceGB.ContainsKey($rootUpper) -and $null -ne $FreeSpaceGB[$rootUpper]) {
            $freeGB = $FreeSpaceGB[$rootUpper]
            $status = if ($freeGB -lt $requiredGB) { 'Low' } else { 'Ok' }
        }

        [pscustomobject]@{
            Root       = $rootUpper
            RequiredGB = $requiredGB
            FreeGB     = $freeGB
            Status     = $status
        }
    }
}

function Get-WinMediaParallelJob {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$BaseJob,

        [Parameter(Mandatory = $true)]
        [int[]]$Targets,

        [Parameter(Mandatory = $true)]
        [string]$ParallelRoot
    )

    if ($Targets.Count -eq 0) {
        throw 'Targets 不可為空。'
    }

    $sharedKeys = @('mountSwitches', 'Config', 'ssu', 'lcuStage', 'langFod', 'dotNet', 'enablement', 'appxList', 'storeSet', 'lxpItems', 'driverSet', 'forceUnsigned', 'resetBaseOS', 'common', 'winreWim')
    foreach ($key in $sharedKeys) {
        if (-not $BaseJob.ContainsKey($key)) {
            throw "BaseJob 缺少必要鍵 '$key'。"
        }
    }

    $parentConfig = $BaseJob['Config']
    $parentCommon = $BaseJob['common']
    $firstTarget = $Targets[0]

    foreach ($t in $Targets) {
        $indexDir = Join-Path -Path $ParallelRoot -ChildPath ('idx' + $t)
        $logDir = Join-Path -Path $parentConfig['LogDir'] -ChildPath ('idx' + $t)

        $config = @{}
        foreach ($k in $parentConfig.Keys) {
            $config[$k] = $parentConfig[$k]
        }
        $config['LogDir'] = $logDir
        $config['LogFile'] = Join-Path -Path $logDir -ChildPath 'worker.log'
        if (-not [string]::IsNullOrEmpty($parentConfig['OperationLog'])) {
            $config['OperationLog'] = Join-Path -Path $logDir -ChildPath 'OperationLog.txt'
        }

        $common = @{}
        foreach ($k in $parentCommon.Keys) {
            $common[$k] = $parentCommon[$k]
        }

        $scratch = [string]$parentConfig['ScratchDirectory']
        if ([string]::IsNullOrWhiteSpace($scratch)) {
            [void]$config.Remove('ScratchDirectory')
            [void]$common.Remove('ScratchDirectory')
        }
        else {
            $scratchDir = Join-Path -Path $scratch -ChildPath ('idx' + $t)
            $config['ScratchDirectory'] = $scratchDir
            $common['ScratchDirectory'] = $scratchDir
        }

        # 每個子程序的 install.wim 只含一個映像，故索引固定為 1。
        $job = @{
            mountSwitches = $BaseJob['mountSwitches']
            Config        = $config
            ssu           = $BaseJob['ssu']
            lcuStage      = $BaseJob['lcuStage']
            langFod       = $BaseJob['langFod']
            dotNet        = $BaseJob['dotNet']
            enablement    = $BaseJob['enablement']
            appxList      = $BaseJob['appxList']
            storeSet      = $BaseJob['storeSet']
            lxpItems      = $BaseJob['lxpItems']
            driverSet     = $BaseJob['driverSet']
            forceUnsigned = $BaseJob['forceUnsigned']
            resetBaseOS   = $BaseJob['resetBaseOS']
            common        = $common
            winreWim      = $BaseJob['winreWim']
            ImagePath     = Join-Path -Path $indexDir -ChildPath 'install.wim'
            Index         = 1
            MountPath     = Join-Path -Path $parentConfig['MountDir'] -ChildPath ('install-' + $t)
            IsFirstTarget = ($t -eq $firstTarget)
        }

        [pscustomobject]@{
            OriginalIndex = $t
            IndexDir      = $indexDir
            Job           = $job
        }
    }
}

function Get-WinMediaParallelMergePlan {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [int[]]$AllIndexes,

        [Parameter(Mandatory = $true)]
        [int[]]$Targets
    )

    if ($Targets.Count -eq 0) {
        throw 'Targets 不可為空。'
    }

    $targetSet = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($t in $Targets) {
        if (-not $targetSet.Add($t)) {
            throw "Targets 含有重複索引 '$t'。"
        }
    }

    $allSet = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($idx in $AllIndexes) {
        [void]$allSet.Add($idx)
    }
    foreach ($t in $Targets) {
        if (-not $allSet.Contains($t)) {
            throw "Target 索引 '$t' 不在 AllIndexes 內。"
        }
    }

    foreach ($idx in @($AllIndexes | Sort-Object)) {
        [pscustomobject]@{
            Index        = $idx
            FromParallel = ($Targets -contains $idx)
        }
    }
}
