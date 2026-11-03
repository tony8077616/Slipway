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
    $freeSpace = @{ $mountRoot = [math]::Round(([IO.DriveInfo]$mountRoot).AvailableFreeSpace / 1GB, 2) }
    foreach ($w in @(Get-WinMediaParallelSpaceWarning -Path @($MountDir) -Count $MaxConcurrent -EstimateGB $Config.MountSpaceEstimateGB -FreeSpaceGB $freeSpace)) {
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
}
