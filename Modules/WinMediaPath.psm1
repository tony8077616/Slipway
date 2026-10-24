Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# 路徑規則模組：重疊檢查、輸入資料夾預設值、掛載目錄解析
# 所有路徑淨化經由 PSModules\Common\PathSanitize.psm1
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\PSModules\Common\PathSanitize.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\PSModules\Common\WinMediaOperation.psm1') -Force

function Test-WinMediaPathOverlap {
    # §3.4：更新原始檔、驅動、LXP、WorkDir 兩兩不得重疊（相等、包含或被包含）
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Paths
    )

    $normalized = @{}
    foreach ($key in $Paths.Keys) {
        if (-not [string]::IsNullOrWhiteSpace($Paths[$key])) {
            $normalized[$key] = Get-ComparablePath -Path $Paths[$key]
        }
    }
    foreach ($a in $normalized.Keys) {
        foreach ($b in $normalized.Keys) {
            if ($a -ge $b) { continue }
            if ($normalized[$a].StartsWith($normalized[$b], [StringComparison]::OrdinalIgnoreCase) -or
                $normalized[$b].StartsWith($normalized[$a], [StringComparison]::OrdinalIgnoreCase)) {
                throw "路徑重疊：$a 與 $b（更新原始檔、驅動、LXP 必須分開）。"
            }
        }
    }
}

function Resolve-WinMediaInputPath {
    # 輸入資料夾集中於執行腳本所在目錄：設定檔留空時補上預設位置；已指定者保持不變
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RootDir,
        [Parameter(Mandatory)][hashtable]$Config
    )

    if ([string]::IsNullOrWhiteSpace($Config.PackageDir)) {
        $Config.PackageDir = Join-Path -Path $RootDir -ChildPath 'Packages'
    }
    # 驅動、LXP、清單不存在時維持停用，與原本「空白 = 停用」的語意一致
    if ([string]::IsNullOrWhiteSpace($Config.Drivers.Path)) {
        $candidate = Join-Path -Path $RootDir -ChildPath 'Drivers'
        if (Test-Path -LiteralPath $candidate -PathType Container) { $Config.Drivers.Path = $candidate }
    }
    if ([string]::IsNullOrWhiteSpace($Config.Lxp.Path)) {
        $candidate = Join-Path -Path $RootDir -ChildPath 'Lxp'
        if (Test-Path -LiteralPath $candidate -PathType Container) { $Config.Lxp.Path = $candidate }
    }
    if ($Config.ContainsKey('Lang') -and [string]::IsNullOrWhiteSpace($Config.Lang.Path)) {
        $candidate = Join-Path -Path $RootDir -ChildPath 'Lang'
        if (Test-Path -LiteralPath $candidate -PathType Container) { $Config.Lang.Path = $candidate }
    }
    if ($Config.ContainsKey('Fod') -and [string]::IsNullOrWhiteSpace($Config.Fod.Path)) {
        $candidate = Join-Path -Path $RootDir -ChildPath 'Fod'
        if (Test-Path -LiteralPath $candidate -PathType Container) { $Config.Fod.Path = $candidate }
    }
    if ($Config.ContainsKey('StoreApps') -and [string]::IsNullOrWhiteSpace($Config.StoreApps.Path)) {
        $candidate = Join-Path -Path $RootDir -ChildPath 'StoreApps'
        if (Test-Path -LiteralPath $candidate -PathType Container) { $Config.StoreApps.Path = $candidate }
    }
    if ([string]::IsNullOrWhiteSpace($Config.Apps.CustomAppsList)) {
        $candidate = Join-Path -Path $RootDir -ChildPath 'CustomAppsList.txt'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $Config.Apps.CustomAppsList = $candidate }
    }
}

function Resolve-WinMediaMountDir {
    <#
    .SYNOPSIS
        解析掛載目錄；未指定時依 Convert-UUP.cmd 的規則產生預設值。
    .DESCRIPTION
        Convert-UUP.cmd:4648–4654：預設為 %_drv%\MountUUP（_drv 為工作目錄所在磁碟）；
        該磁碟非 NTFS 時改用 %SystemDrive%\MountUUP。磁碟根目錄不可直接作為掛載目錄。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkDir,
        [string]$MountDir
    )

    if (-not [string]::IsNullOrWhiteSpace($MountDir)) {
        $resolved = (ConvertTo-SanitizedPath -Path $MountDir).Path.TrimEnd('\')
    }
    else {
        $base = $env:SystemDrive
        $root = [System.IO.Path]::GetPathRoot($WorkDir).TrimEnd('\')
        if ($root -match '^[A-Za-z]:$') {
            $volume = try { Get-Volume -DriveLetter $root.Substring(0, 1) -ErrorAction Stop } catch { $null }
            if ($root -ieq $env:SystemDrive -or ($volume -and $volume.FileSystem -eq 'NTFS')) {
                $base = $root
            }
        }
        $resolved = $base + '\MountUUP'
    }

    if (-not [System.IO.Path]::IsPathRooted($resolved)) {
        throw "掛載目錄必須為絕對路徑：$resolved"
    }
    if ($resolved -match '^[A-Za-z]:$') {
        throw "掛載目錄不可為磁碟根目錄：$resolved"
    }
    return $resolved
}

function Use-WinMediaWorkDir {
    # 工作子目錄登記（Must 1）：只有本工具登記過的目錄（同層 <dir>.winmedia-owned）才會被清空；未登記且非空的既有目錄拒絕使用
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $marker = "$Path.winmedia-owned"
    if (Test-Path -LiteralPath $Path) {
        if (Test-Path -LiteralPath $marker) {
            # 上次失敗留下的登記目錄：清空後再用，避免舊檔混進新成品
            Get-ChildItem -LiteralPath $Path -Force | Remove-Item -Recurse -Force
            return
        }
        if (@(Get-ChildItem -LiteralPath $Path -Force).Count -gt 0) {
            throw "工作子目錄已存在且不是本工具建立：$Path（若這是舊版失敗後留下的資料夾，請手動刪除後重試）。"
        }
    }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    Set-Content -LiteralPath $marker -Value 'WinMediaRefresh' -Encoding ASCII
}

function Remove-WinMediaWorkDir {
    # 只刪除登記過的目錄與登記檔；未登記的目錄完全不動
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path)

    $marker = "$Path.winmedia-owned"
    if (-not (Test-Path -LiteralPath $marker)) { return }
    if (-not $PSCmdlet.ShouldProcess($Path, '刪除工作子目錄')) { return }
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
    Remove-Item -LiteralPath $marker -Force
}

function Assert-WinMediaOutputDir {
    # 成品目錄不得等於或位於會被清理或掛載的目錄之下（Must 2）；否則步驟 12 會連同成品一起刪除
    # shortcut: 只做字串比對，8.3 短名稱、junction、subst 或指向同一位置的網路磁碟可繞過；有使用者回報別名路徑時改為解析最終路徑（GetFinalPathNameByHandle）
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OutputDir,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ProtectedDir
    )

    foreach ($dir in $ProtectedDir) {
        if (Test-PathWithin -Child $OutputDir -Parent $dir) {
            throw "OutputDir 位於工作或掛載目錄之下，成品會在清理時被刪除：$OutputDir（請改用其他路徑）。"
        }
    }
}

function Resolve-WinMediaLogFile {
    # 一般 Log（第 1 層）：LogFile 留空時寫到 LogDir\WinMediaRefresh.log；Add-WinMediaTextLine 會建立父目錄
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    # 設定檔可能沒有這些鍵；StrictMode 下直接讀取不存在的鍵會拋錯，所以先用 ContainsKey 判斷
    $logFile = if ($Config.ContainsKey('LogFile')) { $Config.LogFile } else { $null }
    if (-not [string]::IsNullOrWhiteSpace($logFile)) { return [string]$logFile }
    $logDir = if ($Config.ContainsKey('LogDir')) { $Config.LogDir } else { $null }
    if ([string]::IsNullOrWhiteSpace($logDir)) { $logDir = Join-Path -Path $Config.WorkDir -ChildPath 'logs' }
    return (Join-Path -Path $logDir -ChildPath 'WinMediaRefresh.log')
}

function Resolve-WinMediaLogLocation {
    # 操作紀錄位置：Invoke-WinMediaOperation 直接讀取 OperationLog，設定檔沒有這兩個鍵時先由 WorkDir 推導；OperationLog 有鍵就原樣保留（空白＝不寫操作紀錄）
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][hashtable]$Config)

    $logDir = if ($Config.ContainsKey('LogDir')) { $Config.LogDir } else { $null }
    if ([string]::IsNullOrWhiteSpace($logDir)) { $logDir = Join-Path -Path $Config.WorkDir -ChildPath 'logs' }
    $operationLog = if ($Config.ContainsKey('OperationLog')) { $Config.OperationLog } else { Join-Path -Path $logDir -ChildPath 'OperationLog.txt' }
    return @{ LogDir = $logDir; OperationLog = $operationLog }
}

function Resolve-WinMediaLegacyInputSection {
    # 舊格式設定檔可能沒有 Lang、Fod、StoreApps；缺鍵時補空路徑，主流程之後以 StrictMode 讀取 .Path 才不會崩潰
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    foreach ($key in 'Lang', 'Fod', 'StoreApps') {
        if (-not $Config.ContainsKey($key) -or $null -eq $Config[$key]) { $Config[$key] = @{ Path = '' } }
    }
}

function Remove-WinMediaCleanupDir {
    # 清理失敗只記警告，不取代已完成的映像結果（DESIGN 2026-10-16 第 (8) 項）；失敗仍會留下 failure 紀錄
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Remove', Justification = '由 Invoke-WinMediaOperation 的 scriptblock 閉包使用，PSSA 無法追蹤')]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Config,
        # 路徑以參數傳入，不依賴作用域：呼叫端的 scriptblock 綁在其所屬模組，看不到這裡的 $Path
        [scriptblock]$Remove = { param($p) Remove-WinMediaWorkDir -Path $p }
    )

    if (-not $PSCmdlet.ShouldProcess($Path, '清除工作目錄')) { return }
    try {
        Invoke-WinMediaOperation -Category File -Operation 'RemoveWorkDir' -Target $Path -Config $Config -ScriptBlock { & $Remove $Path } | Out-Null
    }
    catch {
        Write-Warning ('無法清除 {0}：{1}' -f $Path, $_.Exception.Message)
    }
}

function Mount-WinMediaSourceIso {
    # 已掛載（例如使用者自行掛載）的 ISO 不再掛載，回報 Mounted = $false，主流程據此不卸載
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$ImagePath)

    if (-not $PSCmdlet.ShouldProcess($ImagePath, '掛載 ISO')) { return }
    $image = Get-DiskImage -ImagePath $ImagePath
    $mounted = -not $image.Attached
    if ($mounted) { $image = Mount-DiskImage -ImagePath $ImagePath -StorageType ISO -PassThru }
    return [pscustomobject]@{ DriveLetter = ($image | Get-Volume).DriveLetter; Mounted = $mounted }
}

Export-ModuleMember -Function Test-WinMediaPathOverlap, Resolve-WinMediaInputPath, Resolve-WinMediaMountDir, Use-WinMediaWorkDir, Remove-WinMediaWorkDir, Assert-WinMediaOutputDir, Resolve-WinMediaLogFile, Resolve-WinMediaLogLocation, Resolve-WinMediaLegacyInputSection, Mount-WinMediaSourceIso, Remove-WinMediaCleanupDir
