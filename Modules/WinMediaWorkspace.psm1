Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# 工作區清理（Step 11）：只處理本工具建立的掛載子資料夾、本工具加入的 Defender 排除與（明確指定時）來源 ISO；絕不碰 OutputDir
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\PSModules\Common\WinMediaLog.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\PSModules\Imaging\WinMediaImage.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'WinMediaPath.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'WinMediaDefender.psm1') -Force

# 本工具掛載子資料夾的名稱（與 Invoke-WindowsMediaRefresh 的命名一致）；不在清單內的資料夾一律略過，即使它位於 MountDir 之下
$script:OwnedChildPattern = '^(install-\d+|boot-\d+|winre|winre-src|spp-check)$'
# WorkDir 內由本工具登記的子目錄；只有 -IncludeWorkDir 時才移除（Remove-WinMediaWorkDir 會檢查登記檔）
$script:WorkSubDirs = @('media', 'winre', 'expand', 'lxp', 'update-stage')

function Get-WinMediaWorkspaceChildAction {
    # 狀態到動作的對應（純函式）：NeedsRemount 走 remount 分支；OK 與 Invalid 走卸載並捨棄；Unknown 只在空資料夾時移除，絕不遞迴刪除
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('OK', 'NeedsRemount', 'Invalid', 'Unknown')][string]$State,
        [Parameter(Mandatory)][bool]$IsEmpty
    )

    if ($Name -notmatch $script:OwnedChildPattern) { return 'Skip' }
    switch ($State) {
        'NeedsRemount' { return 'Remount' }
        { $_ -in 'OK', 'Invalid' } { return 'Clear' }
        default {
            if ($IsEmpty) { return 'RemoveEmpty' }
            return 'WarnNotEmpty'
        }
    }
}

function Invoke-WinMediaWorkspaceCleanup {
    # 順序：掛載（remount 後捨棄、OK／Invalid 以 Clear-WinMediaMount 一次處理）→ 移除空資料夾 → 來源 ISO（明確指定時）→ Defender 排除 → WorkDir 子目錄（明確指定時）
    # shortcut: Clear-WinMediaMount 內的 Clear-WindowsCorruptMountPoint 是整機範圍（DISM 無路徑參數），只在捨棄失敗時才會執行；已記錄於偏離清單
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$MountDir,
        [Parameter(Mandatory)][string]$WorkDir,
        [Parameter(Mandatory)][string]$OutputDir,
        [Parameter(Mandatory)][hashtable]$Config,
        [string]$SourceIso = '',
        [switch]$IncludeWorkDir
    )

    # OutputDir 不得位於會被清理的目錄之下（與主流程的 Assert-WinMediaOutputDir 相同規則）
    Assert-WinMediaOutputDir -OutputDir $OutputDir -ProtectedDir (@($MountDir) + @($script:WorkSubDirs | ForEach-Object { Join-Path -Path $WorkDir -ChildPath $_ }))
    $clear = @()
    $empty = @()
    if (Test-Path -LiteralPath $MountDir -PathType Container) {
        foreach ($child in @(Get-ChildItem -LiteralPath $MountDir -Directory -Force)) {
            $path = $child.FullName
            if ($child.Name -notmatch $script:OwnedChildPattern) {
                Write-WinMediaLog -Config $Config -Level Warning -Message "略過非本工具的資料夾：$path"
                continue
            }
            $state = Get-WinMediaMountState -Path $path -Config $Config
            $isEmpty = @(Get-ChildItem -LiteralPath $path -Force).Count -eq 0
            switch (Get-WinMediaWorkspaceChildAction -Name $child.Name -State $state -IsEmpty $isEmpty) {
                'Remount' {
                    if ($PSCmdlet.ShouldProcess($path, '重新掛載後捨棄')) {
                        try {
                            Mount-WinMediaImage -Remount -MountPath $path -CommitOnSuccess:$false -Action { } -Config $Config | Out-Null
                            $empty += $path
                        }
                        catch {
                            # 失敗通常是映像仍載入登錄檔；交給 Clear-WinMediaMount（先卸載登錄檔再捨棄），不中止其餘項目
                            Write-WinMediaLog -Config $Config -Level Warning -Message "重新掛載失敗，改用卸載流程：$path（$($_.Exception.Message)）"
                            $clear += $path
                        }
                    }
                }
                'Clear' { $clear += $path }
                'RemoveEmpty' { $empty += $path }
                'WarnNotEmpty' { Write-WinMediaLog -Config $Config -Level Warning -Message "狀態不明且非空，略過（不遞迴刪除）：$path" }
            }
        }
    }

    if ($clear.Count -gt 0 -and $PSCmdlet.ShouldProcess(($clear -join ', '), '卸載登錄檔並捨棄掛載')) {
        Clear-WinMediaMount -MountPath $clear -Config $Config
        $empty += $clear
    }

    foreach ($path in $empty) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        if (@(Get-ChildItem -LiteralPath $path -Force).Count -gt 0) {
            Write-WinMediaLog -Config $Config -Level Warning -Message "掛載資料夾仍非空，略過移除：$path"
            continue
        }
        # 不加 -Recurse：目錄非空時 Remove-Item 會失敗，而不會遞迴刪除
        if ($PSCmdlet.ShouldProcess($path, '移除空的掛載資料夾')) { Remove-Item -LiteralPath $path -Force }
    }

    if ($SourceIso) {
        $image = Get-DiskImage -ImagePath $SourceIso -ErrorAction SilentlyContinue
        if ($image -and $image.Attached -and $PSCmdlet.ShouldProcess($SourceIso, '卸載來源 ISO')) {
            Dismount-DiskImage -ImagePath $SourceIso | Out-Null
        }
    }

    $allowed = @($WorkDir, $MountDir, $OutputDir)
    $defenderStates = @((Resolve-WinMediaDefenderStatePath -WorkDir $WorkDir), (Join-Path -Path $WorkDir -ChildPath 'defender-state.json'))
    foreach ($state in $defenderStates) {
        if ((Test-Path -LiteralPath $state -PathType Leaf) -and $PSCmdlet.ShouldProcess($state, '還原本工具加入的 Defender 排除')) {
            Restore-WinMediaDefenderExclusion -StatePath $state -AllowedPath $allowed -Confirm:$false
        }
    }

    if ($IncludeWorkDir) {
        foreach ($sub in $script:WorkSubDirs) {
            Remove-WinMediaWorkDir -Path (Join-Path -Path $WorkDir -ChildPath $sub) -WhatIf:$WhatIfPreference -Confirm:$false
        }
    }
}

Export-ModuleMember -Function Get-WinMediaWorkspaceChildAction, Invoke-WinMediaWorkspaceCleanup
