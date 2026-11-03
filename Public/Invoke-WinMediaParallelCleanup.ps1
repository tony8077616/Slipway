# 平行處理逾時清理：樹狀終止（只作用於已固定 Handle 的程序）與單一掛載點清理（沒有整機後備）。

function Invoke-WinMediaParallelTreeKill {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [object]$RootProcess
    )

    # 1 ms 容差（以 ticks 計）：CIM CreationDate 與 Process.StartTime 的差值超過此值就不殺
    $toleranceTicks = 10000
    $killed = [System.Collections.Generic.List[int]]::new()
    $skipped = [System.Collections.Generic.List[string]]::new()
    $failed = [System.Collections.Generic.List[string]]::new()
    $rootId = [int]$RootProcess.Id

    try {
        $rootHandle = $RootProcess.Handle
        if ($null -eq $rootHandle) { throw 'Handle unavailable' }
    }
    catch {
        $failed.Add("pid=$rootId root Handle: $($_.Exception.Message)")
        return [pscustomobject]@{ Killed = @(); Skipped = @(); Failed = @($failed) }
    }

    try {
        $snapshot = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)
    }
    catch {
        # 快照失敗時仍要殺根程序，否則逾時的 worker 會一直占著掛載點
        $snapshot = @()
        $failed.Add("pid=$rootId snapshot: $($_.Exception.Message)")
    }
    $rootRow = $snapshot | Where-Object { $_.ProcessId -eq $rootId } | Select-Object -First 1
    $rootCreated = $RootProcess.StartTime
    if ($null -ne $rootRow) {
        $rootCreated = $rootRow.CreationDate
    }

    # 先走訪並固定所有子孫的 Handle，全部固定之後才開始終止
    $pinned = [System.Collections.Generic.List[object]]::new()
    $queue = [System.Collections.Generic.Queue[object]]::new()
    $visited = [System.Collections.Generic.HashSet[int]]::new()
    [void]$visited.Add($rootId)
    $queue.Enqueue([pscustomobject]@{ Id = $rootId; Created = $rootCreated })

    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        foreach ($row in @($snapshot | Where-Object { $_.ParentProcessId -eq $current.Id })) {
            $childId = [int]$row.ProcessId
            if (-not $visited.Add($childId)) {
                continue
            }
            # 孤兒：父 PID 被重用，子程序的建立時間早於父程序，不往下走也不殺
            if ($row.CreationDate -lt $current.Created) {
                $skipped.Add("pid=$childId orphan: CreationDate precedes parent pid=$($current.Id)")
                continue
            }

            try {
                $proc = Get-Process -Id $childId -ErrorAction Stop
                $childHandle = $proc.Handle
                if ($null -eq $childHandle) { throw 'Handle unavailable' }
                $deltaTicks = [Math]::Abs(($proc.StartTime - $row.CreationDate).Ticks)
                if ($deltaTicks -le $toleranceTicks) {
                    $pinned.Add([pscustomobject]@{ Id = $childId; Process = $proc })
                }
                else {
                    $skipped.Add("pid=$childId StartTime differs from snapshot CreationDate by $deltaTicks ticks")
                }
            }
            catch {
                $skipped.Add("pid=$childId cannot pin: $($_.Exception.Message)")
            }

            # 即使本節點不殺，它的子孫仍需走訪
            $queue.Enqueue([pscustomobject]@{ Id = $childId; Created = $row.CreationDate })
        }
    }

    # 先根，再依 BFS 順序終止已固定的子孫
    try {
        $RootProcess.Kill()
        $killed.Add($rootId)
    }
    catch {
        $ignorable = $false
        for ($e = $_.Exception; $null -ne $e; $e = $e.InnerException) {
            if ($e -is [System.InvalidOperationException]) { $ignorable = $true; break }
        }
        if (-not $ignorable) { $failed.Add("pid=$rootId Kill: $($_.Exception.Message)") }
    }

    foreach ($entry in $pinned) {
        try {
            $entry.Process.Kill()
            $killed.Add($entry.Id)
        }
        catch {
            $ignorable = $false
            for ($e = $_.Exception; $null -ne $e; $e = $e.InnerException) {
                if ($e -is [System.InvalidOperationException]) { $ignorable = $true; break }
            }
            if (-not $ignorable) { $failed.Add("pid=$($entry.Id) Kill: $($_.Exception.Message)") }
        }
    }

    [pscustomobject]@{
        Killed  = @($killed)
        Skipped = @($skipped)
        Failed  = @($failed)
    }
}

function Invoke-WinMediaParallelMountCleanup {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$MountPath,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    # 只處理本工具建立的 install-N 掛載點；其他路徑在查詢狀態之前就拒絕
    if ((Split-Path -Path $MountPath -Leaf) -notmatch '^install-\d+$') {
        throw "拒絕清理非 install-N 的掛載點：$MountPath"
    }

    $state = Get-WinMediaMountState -Path $MountPath -Config $Config
    $result = 'Kept'
    switch ($state) {
        'NeedsRemount' {
            try {
                Mount-WinMediaImage -Remount -MountPath $MountPath -CommitOnSuccess:$false -Action {} -Config $Config | Out-Null
                $result = 'Discarded'
            }
            catch {
                Write-WinMediaLog -Config $Config -Level Warning -Message "重新掛載失敗，標記為需手動清理：$MountPath（$($_.Exception.Message)）"
                $result = 'ManualCleanup'
            }
        }
        { $_ -in 'OK', 'Invalid' } {
            try {
                $common = Get-WinMediaDismCommonParameter -Config $Config
                Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
                    Dismount-WindowsImage -Path $MountPath -Discard @common -LogLevel $Config.DismLogLevel | Out-Null
                } | Out-Null
                $result = 'Discarded'
            }
            catch {
                Write-WinMediaLog -Config $Config -Level Warning -Message "捨棄失敗，標記為需手動清理：$MountPath（$($_.Exception.Message)）"
                $result = 'ManualCleanup'
            }
        }
        default {
            try {
                if (Test-Path -LiteralPath $MountPath -PathType Container) {
                    if (@(Get-ChildItem -LiteralPath $MountPath -Force).Count -eq 0) {
                        Remove-Item -LiteralPath $MountPath -Force
                        $result = 'Removed'
                    }
                    else {
                        Write-WinMediaLog -Config $Config -Level Warning -Message "狀態不明且非空，保留：$MountPath"
                    }
                }
                else {
                    $result = 'Missing'
                }
            }
            catch {
                Write-WinMediaLog -Config $Config -Level Warning -Message "清理未知狀態的掛載點失敗，標記為需手動清理：$MountPath（$($_.Exception.Message)）"
                $result = 'ManualCleanup'
            }
        }
    }

    [pscustomobject]@{ Path = $MountPath; State = $state; Result = $result }
}
