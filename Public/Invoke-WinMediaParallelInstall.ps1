# Step 12c-3b：平行安裝索引（匯出 → 排程 → 合併 → 唯讀掛載依序同步 xmllite 與開機檔）（不匯出）

function Invoke-WinMediaParallelInstall {
    param(
        [Parameter(Mandatory)][string]$InstallWim,
        [Parameter(Mandatory)][int[]]$AllIndexes,
        [Parameter(Mandatory)][int[]]$Targets,
        [Parameter(Mandatory)][string]$ParallelRoot,
        [Parameter(Mandatory)][string]$MountDir,
        [Parameter(Mandatory)][hashtable]$BaseJob,
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$SourcesDir,
        [Parameter(Mandatory)][string]$MediaDir,
        [Parameter(Mandatory)][int]$MaxConcurrent,
        [Parameter(Mandatory)][hashtable]$InstallKernel,
        [Parameter(Mandatory)][hashtable]$BuildInfo,
        [Parameter(Mandatory)][hashtable]$BootEx,
        [bool]$IsEsdSource
    )

    $mountRoot = [IO.Path]::GetPathRoot($MountDir).ToUpperInvariant()
    $stagingRoot = [IO.Path]::GetPathRoot($ParallelRoot).ToUpperInvariant()
    $freeSpace = @{}
    foreach ($r in @($mountRoot, $stagingRoot | Select-Object -Unique)) {
        $freeSpace[$r] = [math]::Round((Get-WinMediaDriveInfo -Root $r).AvailableFreeSpace / 1GB, 2)
    }
    $installWimGB = if (Test-Path -LiteralPath $InstallWim -PathType Leaf) { [math]::Round((Get-Item -LiteralPath $InstallWim).Length / 1GB, 2) } else { 0 }
    $stagingGB = Get-WinMediaParallelStagingGB -Targets $Targets -InstallWimGB $installWimGB
    $spaceWarnings = @(Get-WinMediaParallelSpaceWarning -Path @($MountDir) -Count $MaxConcurrent -EstimateGB $Config.MountSpaceEstimateGB -FreeSpaceGB $freeSpace) + @(Get-WinMediaParallelSpaceWarning -Path @($ParallelRoot) -Count 1 -EstimateGB $stagingGB -FreeSpaceGB $freeSpace)
    foreach ($w in $spaceWarnings) {
        if ($w.Status -eq 'Low') {
            Write-WinMediaLog -Config $Config -Level Warning -Message "平行掛載的可用空間可能不足：$($w.Root) 需要約 $($w.RequiredGB) GB，可用 $($w.FreeGB) GB"
        }
    }

    Invoke-WinMediaParallelStage -SourceWim $InstallWim -Targets $Targets -ParallelRoot $ParallelRoot -Config $Config
    $planned = @(Get-WinMediaParallelJob -BaseJob $BaseJob -Targets $Targets -ParallelRoot $ParallelRoot)
    $jobs = @($planned | ForEach-Object { [pscustomobject]@{ Index = $_.OriginalIndex; IndexDir = $_.IndexDir; MountPath = $_.Job.MountPath; Job = $_.Job } })
    $results = @(Invoke-WinMediaParallelRun -Jobs $jobs -Config $Config -MaxConcurrent $MaxConcurrent)
    Invoke-WinMediaParallelMerge -SourceWim $InstallWim -AllIndexes $AllIndexes -Targets $Targets -ParallelRoot $ParallelRoot -Config $Config

    $first = @($results | Where-Object { $_.Index -eq $Targets[0] })[0]
    $InstallKernel.Version = $first.KernelVersion
    $BuildInfo.Info = $first.BuildInfo

    # 與序列路徑相同的順序：每個目標先 xmllite（只有第一個）再開機檔；唯讀掛載只讀取，不改動合併後的檔案
    $needBoot = (-not $IsEsdSource) -and ((-not $Config.ContainsKey('UpdateBootFiles')) -or [bool]$Config.UpdateBootFiles)
    $syncTargets = if ($needBoot) { $Targets } else { @($Targets[0]) }
    $xmlTarget = $SourcesDir
    $mediaTarget = $MediaDir
    $bootState = $BootEx
    foreach ($t in $syncTargets) {
        Mount-WinMediaImage -ImagePath $InstallWim -Index $t -MountPath (Join-Path -Path $MountDir -ChildPath 'winre-src') -ReadOnly -Config $Config -Action {
            param($mounted)
            if ($t -eq $Targets[0]) {
                Invoke-WinMediaOperation -Category File -Operation 'CopyXmlLite' -Target $xmlTarget -Config $Config -ScriptBlock {
                    Copy-Item -LiteralPath (Join-Path -Path $mounted -ChildPath 'Windows\System32\xmllite.dll') -Destination (Join-Path -Path $xmlTarget -ChildPath 'xmllite.dll') -Force
                } | Out-Null
            }
            if ($needBoot) { $bootState.Applied = Copy-WinMediaUpdatedBootFiles -MountPath $mounted -MediaDir $mediaTarget -Config $Config }
        } | Out-Null
    }

    # 只在全部成功且合併、同步完成後清理：失敗時已先丟例外，保留各索引的暫存目錄供診斷；刪除失敗只記警告
    foreach ($j in $jobs) {
        $jc = $j.Job.Config
        if (-not $jc.ContainsKey('ScratchDirectory') -or [string]::IsNullOrWhiteSpace([string]$jc['ScratchDirectory'])) { continue }
        $sd = [string]$jc['ScratchDirectory']
        if ((Split-Path -Path $sd -Leaf) -notmatch '^idx\d+$' -or -not (Test-Path -LiteralPath $sd -PathType Container)) { continue }
        if (@(Get-ChildItem -LiteralPath $sd -Force).Count -eq 0) {
            try { Remove-Item -LiteralPath $sd -Force }
            catch { Write-WinMediaLog -Config $Config -Level Warning -Message "無法移除空的暫存目錄：$sd（$($_.Exception.Message)）" }
        }
        else { Write-WinMediaLog -Config $Config -Level Warning -Message "平行掛載的暫存目錄非空，保留：$sd" }
    }
}
