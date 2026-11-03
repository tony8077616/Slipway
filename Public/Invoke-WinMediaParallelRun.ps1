# 平行排程（Step 12c-2b）：依序啟動索引子程序、輪詢結束、逾時終止，並在根程序退出後才清理掛載點。
# 只使用 Start-WinMediaIndexWorker 回傳的程序物件；不呼叫 WaitForExit／Refresh，ExitCode 只在 HasExited 為 true 之後讀取。

function Get-WinMediaParallelOutcome {
    param(
        [Parameter(Mandatory)]$Job,
        [Parameter(Mandatory)][bool]$Ok,
        [string]$Reason = '',
        [string]$ErrorText = '',
        [string]$Cleanup = '',
        $Result = $null
    )
    [pscustomobject]@{ Index = [int]$Job.Index; Ok = $Ok; Reason = $Reason; ErrorText = $ErrorText; Cleanup = $Cleanup; IndexDir = $Job.IndexDir; Result = $Result }
}

function Get-WinMediaParallelErrorText {
    param([Parameter(Mandatory)][string]$IndexDir)
    $path = Join-Path -Path $IndexDir -ChildPath 'error.txt'
    try {
        if (Test-Path -LiteralPath $path -PathType Leaf) { return (Get-Content -LiteralPath $path -Raw -Encoding UTF8).Trim() }
    }
    catch {
        return "讀取 error.txt 失敗：$($_.Exception.Message)"
    }
    ''
}

# 只能在根程序已退出後呼叫；清理失敗一律回報為 ManualCleanup
function Invoke-WinMediaParallelCleanupSafe {
    param([Parameter(Mandatory)]$Job, [Parameter(Mandatory)][hashtable]$Config)
    try {
        [string](Invoke-WinMediaParallelMountCleanup -MountPath $Job.MountPath -Config $Config).Result
    }
    catch {
        Write-WinMediaLog -Config $Config -Level Warning -Message "掛載清理失敗，標記為需手動清理：Index $($Job.Index)（$($_.Exception.Message)）"
        'ManualCleanup'
    }
}

function Invoke-WinMediaParallelRun {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)][object[]]$Jobs,
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][ValidateRange(1, 64)][int]$MaxConcurrent,
        [ValidateRange(1, 1440)][int]$TimeoutMinutes = 180,
        [ValidateRange(1, 3600)][int]$GraceSeconds = 60,
        [ValidateRange(0, 60000)][int]$PollMilliseconds = 2000
    )

    $pending = [System.Collections.Generic.Queue[object]]::new()
    foreach ($j in $Jobs) { $pending.Enqueue($j) }
    $active = [System.Collections.Generic.List[object]]::new()
    $outcomes = [System.Collections.Generic.List[object]]::new()
    $stop = $false

    try {
        while ((-not $stop -and $pending.Count -gt 0) -or $active.Count -gt 0) {
            # 每一輪最多啟動一個（錯開啟動）；失敗後不再啟動
            if (-not $stop -and $pending.Count -gt 0 -and $active.Count -lt $MaxConcurrent) {
                $j = $pending.Dequeue()
                try {
                    $proc = Start-WinMediaIndexWorker -Job $j.Job -IndexDir $j.IndexDir
                    if ($null -eq $proc.Handle) { throw 'Handle unavailable' }
                    $active.Add([pscustomobject]@{ Job = $j; Proc = $proc; Started = (Get-Date); Draining = $false; DrainStart = $null })
                }
                catch {
                    $outcomes.Add((Get-WinMediaParallelOutcome -Job $j -Ok $false -Reason "啟動失敗：$($_.Exception.Message)" -Cleanup 'ManualCleanup'))
                    $stop = $true
                }
            }

            $now = Get-Date
            foreach ($e in @($active.ToArray())) {
                # 先讀 HasExited，再比對期限
                $exited = [bool]$e.Proc.HasExited
                if (-not $exited) {
                    if (-not $e.Draining) {
                        if (($now - $e.Started).TotalMinutes -gt $TimeoutMinutes) {
                            $e.Draining = $true
                            $e.DrainStart = $now
                            $stop = $true
                            $treeFailed = @()
                            try {
                                $tk = Invoke-WinMediaParallelTreeKill -RootProcess $e.Proc
                                $treeFailed = @($tk.Failed)
                                foreach ($line in @($tk.Skipped) + @($tk.Failed)) {
                                    Write-WinMediaLog -Config $Config -Level Warning -Message "樹狀終止（Index $($e.Job.Index)）：$line"
                                }
                            }
                            catch {
                                $treeFailed = @("tree kill threw: $($_.Exception.Message)")
                            }
                            if ($treeFailed.Count -gt 0) {
                                $outcomes.Add((Get-WinMediaParallelOutcome -Job $e.Job -Ok $false -Reason "timeout after $TimeoutMinutes min; 樹狀終止有失敗：$($treeFailed -join '；')" -ErrorText (Get-WinMediaParallelErrorText -IndexDir $e.Job.IndexDir) -Cleanup 'ManualCleanup'))
                                $null = $active.Remove($e)
                            }
                        }
                    }
                    elseif ((($now - $e.DrainStart).TotalSeconds) -ge $GraceSeconds) {
                        $outcomes.Add((Get-WinMediaParallelOutcome -Job $e.Job -Ok $false -Reason "timeout after $TimeoutMinutes min; 根程序在寬限期 $GraceSeconds 秒內未退出" -ErrorText (Get-WinMediaParallelErrorText -IndexDir $e.Job.IndexDir) -Cleanup 'ManualCleanup'))
                        $null = $active.Remove($e)
                    }
                    continue
                }

                # 根程序已退出：只在這裡讀 ExitCode；掛載清理只在根退出之後執行
                $null = $active.Remove($e)
                $timedOut = [bool]$e.Draining
                $exitCode = $e.Proc.ExitCode
                $resultPath = Join-Path -Path $e.Job.IndexDir -ChildPath 'result.clixml'
                $why = $null
                if ($null -eq $exitCode) { $why = 'ExitCode 為 null' }
                elseif ([int]$exitCode -ne 0) { $why = "ExitCode $exitCode" }
                elseif (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) { $why = '結束碼 0 但未寫出 result.clixml' }

                if ($null -eq $why -and -not $timedOut) {
                    try {
                        $outcomes.Add((Get-WinMediaParallelOutcome -Job $e.Job -Ok $true -Result (Import-Clixml -LiteralPath $resultPath)))
                    }
                    catch {
                        $outcomes.Add((Get-WinMediaParallelOutcome -Job $e.Job -Ok $false -Reason "result.clixml 無法讀取：$($_.Exception.Message)" -ErrorText (Get-WinMediaParallelErrorText -IndexDir $e.Job.IndexDir) -Cleanup (Invoke-WinMediaParallelCleanupSafe -Job $e.Job -Config $Config)))
                    }
                    continue
                }

                if ($null -eq $why) { $why = '已逾時' }
                if ($timedOut) { $why = "timeout after $TimeoutMinutes min; $why" }
                $stop = $true
                $outcomes.Add((Get-WinMediaParallelOutcome -Job $e.Job -Ok $false -Reason $why -ErrorText (Get-WinMediaParallelErrorText -IndexDir $e.Job.IndexDir) -Cleanup (Invoke-WinMediaParallelCleanupSafe -Job $e.Job -Config $Config)))
            }

            Start-Sleep -Milliseconds $PollMilliseconds
        }
    }
    finally {
        # 中斷（例如 Ctrl+C 或模組內例外）時：只處理仍在 active 的項目；不吞掉原本的例外
        foreach ($e in @($active.ToArray())) {
            try {
                $tk = Invoke-WinMediaParallelTreeKill -RootProcess $e.Proc
                if (@($tk.Failed).Count -gt 0) {
                    Write-WinMediaLog -Config $Config -Level Warning -Message "中斷時樹狀終止有失敗，標記為需手動清理：Index $($e.Job.Index)"
                    continue
                }
                $start = Get-Date
                while (-not [bool]$e.Proc.HasExited) {
                    if (((Get-Date) - $start).TotalSeconds -ge $GraceSeconds) { break }
                    Start-Sleep -Milliseconds $PollMilliseconds
                }
                if ([bool]$e.Proc.HasExited) {
                    $null = Invoke-WinMediaParallelCleanupSafe -Job $e.Job -Config $Config
                }
                else {
                    Write-WinMediaLog -Config $Config -Level Warning -Message "中斷後根程序未在寬限期內退出，標記為需手動清理：Index $($e.Job.Index)"
                }
            }
            catch {
                Write-WinMediaLog -Config $Config -Level Warning -Message "中斷清理失敗，標記為需手動清理：Index $($e.Job.Index)（$($_.Exception.Message)）"
            }
        }
    }

    $bad = @($outcomes | Where-Object { -not $_.Ok } | Sort-Object -Property Index)
    $notStarted = @($pending | ForEach-Object { $_.Index })
    if ($bad.Count -gt 0 -or $notStarted.Count -gt 0) {
        $lines = @($bad | ForEach-Object { "Index=$($_.Index): $($_.Reason); error: $($_.ErrorText); cleanup: $($_.Cleanup); dir: $($_.IndexDir)" })
        if ($notStarted.Count -gt 0) { $lines += "未啟動（因先前失敗）：Index=$($notStarted -join ',')" }
        throw ("平行子程序失敗（$($bad.Count) 個）：`n" + ($lines -join "`n"))
    }

    @($outcomes | Sort-Object -Property Index | ForEach-Object { $_.Result })
}
