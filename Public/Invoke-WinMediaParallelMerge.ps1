# Step 12c-3a：平行匯出（每個目標索引一個 idx<N>\install.wim）與合併回 install.wim（不匯出）

function Invoke-WinMediaParallelStage {
    param(
        [Parameter(Mandatory)][string]$SourceWim,
        [Parameter(Mandatory)][int[]]$Targets,
        [Parameter(Mandatory)][string]$ParallelRoot,
        [Parameter(Mandatory)][hashtable]$Config
    )

    $common = Get-WinMediaDismCommonParameter -Config $Config
    foreach ($t in $Targets) {
        $dir = Join-Path -Path $ParallelRoot -ChildPath "idx$t"
        $wim = Join-Path -Path $dir -ChildPath 'install.wim'
        $from = $SourceWim
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        # 上次執行殘留的結果或錯誤檔會被排程器誤讀為本次結果
        foreach ($stale in @('result.clixml', 'error.txt')) {
            $p = Join-Path -Path $dir -ChildPath $stale
            if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
        }
        # Export-WindowsImage 會附加到既有 WIM，殘留檔案必須先清掉
        if (Test-Path -LiteralPath $wim) { Remove-Item -LiteralPath $wim -Force }
        Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
            Export-WindowsImage -SourceImagePath $from -SourceIndex $t -DestinationImagePath $wim -LogLevel $Config.DismLogLevel @common | Out-Null
        } | Out-Null
    }
}

function Invoke-WinMediaParallelMerge {
    param(
        [Parameter(Mandatory)][string]$SourceWim,
        [Parameter(Mandatory)][int[]]$AllIndexes,
        [Parameter(Mandatory)][int[]]$Targets,
        [Parameter(Mandatory)][string]$ParallelRoot,
        [Parameter(Mandatory)][hashtable]$Config
    )

    $ordered = @($AllIndexes | Sort-Object)
    for ($k = 0; $k -lt $ordered.Count; $k++) {
        if ($ordered[$k] -ne $k + 1) { throw "平行合併的索引必須連續（1..N），目前為：$($AllIndexes -join ',')" }
    }
    foreach ($t in $Targets) {
        if ($ordered -notcontains $t) { throw "平行目標索引 $t 不在索引範圍內" }
    }

    $merged = Join-Path -Path $ParallelRoot -ChildPath 'merged.wim'
    if (Test-Path -LiteralPath $merged) { Remove-Item -LiteralPath $merged -Force }

    $common = Get-WinMediaDismCommonParameter -Config $Config
    foreach ($i in $ordered) {
        if ($Targets -contains $i) {
            $from = Join-Path -Path (Join-Path -Path $ParallelRoot -ChildPath "idx$i") -ChildPath 'install.wim'
            $fromIndex = 1
        }
        else {
            $from = $SourceWim
            $fromIndex = $i
        }
        Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
            Export-WindowsImage -SourceImagePath $from -SourceIndex $fromIndex -DestinationImagePath $merged -CompressionType Max -LogLevel $Config.DismLogLevel @common | Out-Null
        } | Out-Null
    }

    $source = @(Get-WinMediaIndexInfo -ImagePath $SourceWim -Config $Config | Where-Object { $ordered -contains $_.ImageIndex } | Sort-Object ImageIndex)
    $actual = @(Get-WinMediaIndexInfo -ImagePath $merged -Config $Config | Sort-Object ImageIndex)
    if ($actual.Count -ne $ordered.Count) { throw "合併後映像數量不符：預期 $($ordered.Count)，實際 $($actual.Count)" }
    for ($k = 0; $k -lt $ordered.Count; $k++) {
        if ($actual[$k].ImageName -ne $source[$k].ImageName) { throw "合併後索引 $($ordered[$k]) 名稱不符：'$($actual[$k].ImageName)'，預期 '$($source[$k].ImageName)'" }
        if ($actual[$k].EditionId -ne $source[$k].EditionId) { throw "合併後索引 $($ordered[$k]) 版本不符：'$($actual[$k].EditionId)'，預期 '$($source[$k].EditionId)'" }
    }

    Move-Item -LiteralPath $merged -Destination $SourceWim -Force
    foreach ($t in $Targets) {
        Remove-Item -LiteralPath (Join-Path -Path (Join-Path -Path $ParallelRoot -ChildPath "idx$t") -ChildPath 'install.wim') -Force
    }
}
