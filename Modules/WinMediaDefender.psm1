#Requires -Version 5.1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# 正規化路徑：去除結尾反斜線，比對時忽略大小寫
function script:ConvertTo-DefenderPathKey {
    param([string]$Path)
    return $Path.TrimEnd('\').ToUpperInvariant()
}

function Get-WinMediaDefenderExclusion {
    <#
    .SYNOPSIS
        取得目前 Windows Defender 的路徑排除清單；無法確定時回傳 $null（呼叫端必須據此略過，不可當成空清單）。
    #>
    [CmdletBinding()]
    param()

    try {
        $pref = Get-MpPreference
        $raw = @($pref.ExclusionPath)
        # Tamper Protection 或權限不足時，Get-MpPreference 會回傳 "N/A…" 字串，此時清單不可信
        if (@($raw | Where-Object { $_ -is [string] -and $_ -like 'N/A*' }).Count -gt 0) {
            Write-Warning '無法讀取 Windows Defender 排除清單（N/A），略過排除設定。'
            return $null
        }
        return ,@($raw | Where-Object { $_ -is [string] -and $_ })
    }
    catch {
        Write-Warning ('無法讀取 Windows Defender 排除清單，略過排除設定：{0}' -f $_.Exception.Message)
        return $null
    }
}

function Add-WinMediaDefenderExclusion {
    <#
    .SYNOPSIS
        加入路徑排除，並回傳「本次實際新增」的路徑；已存在的路徑不納入，供結束時只移除自己加的項目。
    .DESCRIPTION
        讀不到既有清單時整批略過（不新增、也不會在結束時移除既有排除）。
        非管理員或 Tamper Protection 開啟時 Add-MpPreference 會失敗，此時只發出警告，不中止流程。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string[]]$Path,
        # 審查第 15 則：先把即將新增的排除寫入狀態檔再呼叫 Add-MpPreference，程序被強制結束後下次啟動可由 Restore 還原
        [string]$StatePath
    )

    if ($StatePath -and (Test-Path -LiteralPath $StatePath)) {
        # 上次的排除尚未還原（Restore 失敗或狀態檔損毀）：不覆寫，保留還原依據
        Write-Warning ('上次的 Windows Defender 排除狀態檔仍在，略過本次排除設定：{0}' -f $StatePath)
        return ,@()
    }
    $current = Get-WinMediaDefenderExclusion
    if ($null -eq $current) { return ,@() }
    $existing = @{}
    foreach ($item in $current) {
        $existing[(ConvertTo-DefenderPathKey -Path $item)] = $true
    }

    $pending = New-Object -TypeName System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($item in $Path) {
        if ([string]::IsNullOrWhiteSpace($item)) { continue }
        $key = ConvertTo-DefenderPathKey -Path $item
        if ($existing.ContainsKey($key) -or $seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $pending.Add($item)
    }
    if ($pending.Count -eq 0) { return ,@() }
    if ($StatePath) {
        try { Write-DefenderState -StatePath $StatePath -Path $pending.ToArray() }
        catch {
            # 寫不進狀態檔就不加排除，否則被強制結束後無法還原
            Write-Warning ('無法寫入 Windows Defender 排除狀態檔，略過排除設定：{0}' -f $_.Exception.Message)
            return ,@()
        }
    }

    $added = New-Object -TypeName System.Collections.Generic.List[string]
    foreach ($item in $pending) {
        try {
            Add-MpPreference -ExclusionPath $item
            $added.Add($item)
        }
        catch {
            Write-Warning ('無法加入 Windows Defender 排除 {0}：{1}' -f $item, $_.Exception.Message)
        }
    }
    if ($StatePath -and $added.Count -ne $pending.Count) {
        # 狀態檔只留實際加入的項目；全部失敗就刪除
        if ($added.Count -eq 0) { Remove-Item -LiteralPath $StatePath -Force }
        else { Write-DefenderState -StatePath $StatePath -Path $added.ToArray() }
    }
    return ,$added.ToArray()
}

function script:Write-DefenderState {
    param([string]$StatePath, [string[]]$Path)
    # %LOCALAPPDATA%\WinMediaRefresh\defender-state 第一次使用時不存在
    [System.IO.Directory]::CreateDirectory((Split-Path -Path $StatePath -Parent)) | Out-Null
    [System.IO.File]::WriteAllText($StatePath, (ConvertTo-Json -InputObject @($Path)))
}

function Restore-WinMediaDefenderExclusion {
    <#
    .SYNOPSIS
        啟動時還原上次被強制結束而遺留的排除：只移除同時出現在狀態檔、且等於本次 WorkDir／MountDir／OutputDir 之一的項目，之後刪除狀態檔。
    .DESCRIPTION
        沒有狀態檔時不呼叫任何 Defender cmdlet。狀態檔損毀時只警告並保留檔案，不移除任何排除。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$StatePath,
        [AllowEmptyCollection()][string[]]$AllowedPath = @()
    )

    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) { return }
    try {
        # 5.1 的 ConvertFrom-Json 不會在管線上展開陣列，先存變數再包 @()
        $parsed = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($StatePath))
        $listed = @($parsed)
        if (@($listed | Where-Object { $_ -isnot [string] }).Count -gt 0) { throw '內容不是路徑字串陣列' }
    }
    catch {
        Write-Warning ('Windows Defender 排除狀態檔無法解析，保留檔案、不移除任何排除：{0}（{1}）' -f $StatePath, $_.Exception.Message)
        return
    }

    $allowed = @{}
    foreach ($item in $AllowedPath) {
        if (-not [string]::IsNullOrWhiteSpace($item)) { $allowed[(ConvertTo-DefenderPathKey -Path $item)] = $true }
    }
    $targets = New-Object -TypeName System.Collections.Generic.List[string]
    foreach ($item in $listed) {
        if ($allowed.ContainsKey((ConvertTo-DefenderPathKey -Path $item))) { $targets.Add($item) }
        else { Write-Warning ('狀態檔列出的排除不是本次的工作、掛載或輸出目錄，不移除：{0}' -f $item) }
    }
    if (-not $PSCmdlet.ShouldProcess($StatePath, '還原上次遺留的 Windows Defender 排除')) { return }
    Remove-WinMediaDefenderExclusion -Path $targets.ToArray() -StatePath $StatePath -Confirm:$false
}

function Remove-WinMediaDefenderExclusion {
    <#
    .SYNOPSIS
        移除先前由 Add-WinMediaDefenderExclusion 新增的路徑排除；失敗只警告，供 finally 呼叫。
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string[]]$Path,
        # 全部移除成功才刪除狀態檔；任一失敗就保留，下次啟動再由 Restore 還原
        [string]$StatePath
    )

    $failed = $false
    foreach ($item in @($Path)) {
        if ([string]::IsNullOrWhiteSpace($item)) { continue }
        if (-not $PSCmdlet.ShouldProcess($item, '移除 Windows Defender 排除')) { $failed = $true; continue }
        try {
            Remove-MpPreference -ExclusionPath $item
        }
        catch {
            $failed = $true
            Write-Warning ('無法移除 Windows Defender 排除 {0}：{1}' -f $item, $_.Exception.Message)
        }
    }
    if ($StatePath -and -not $failed -and (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        Remove-Item -LiteralPath $StatePath -Force
    }
}

Export-ModuleMember -Function @(
    'Get-WinMediaDefenderExclusion',
    'Add-WinMediaDefenderExclusion',
    'Restore-WinMediaDefenderExclusion',
    'Remove-WinMediaDefenderExclusion'
)
