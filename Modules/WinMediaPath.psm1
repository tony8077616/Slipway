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
        Assert-WinMediaNoReparsePoint -Path $Path
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
    if (Test-Path -LiteralPath $Path) {
        Assert-WinMediaNoReparsePoint -Path $Path
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
    Remove-Item -LiteralPath $marker -Force
}

function Assert-WinMediaNoReparsePoint {
    # 審查第 8 則：遞迴刪除會穿過 junction／symlink 刪到目標內容（5.1 尤其如此），所以清空前整棵樹只要有 reparse point 就拒絕；遇到即停，不進入連結
    # shortcut: 檢查與刪除之間仍有時間差（TOCTOU），WorkDir 根目錄的 ACL 只允許 SYSTEM／Administrators 寫入，以此縮小可利用範圍
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $pending = New-Object -TypeName 'System.Collections.Generic.Stack[System.IO.FileSystemInfo]'
    $pending.Push((Get-Item -LiteralPath $Path -Force))
    while ($pending.Count -gt 0) {
        $item = $pending.Pop()
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw "拒絕處理 reparse point（junction 或符號連結）：$($item.FullName)（請手動檢查並刪除該連結後重試）。"
        }
        if ($item -is [System.IO.DirectoryInfo]) {
            foreach ($child in $item.GetFileSystemInfos()) { $pending.Push($child) }
        }
    }
}

function Get-WinMediaWorkDirSecurity {
    # 純函式：WorkDir 根目錄的 ACL，關閉繼承（去掉從磁碟根目錄繼承的 Authenticated Users 修改權限），只有 SYSTEM 與 Administrators 完全控制
    [CmdletBinding()]
    [OutputType([System.Security.AccessControl.DirectorySecurity])]
    param()

    $security = New-Object -TypeName System.Security.AccessControl.DirectorySecurity
    $security.SetAccessRuleProtection($true, $false)
    foreach ($sid in 'S-1-5-18', 'S-1-5-32-544') {
        $rule = New-Object -TypeName System.Security.AccessControl.FileSystemAccessRule -ArgumentList @(
            [System.Security.Principal.SecurityIdentifier]$sid,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow)
        $security.AddAccessRule($rule)
    }
    return $security
}

function Set-WinMediaWorkDirAcl {
    # 套用 ACL 的唯一入口（AST 測試確認其他地方不直接呼叫 Set-Acl）；測試一律 mock 此函式
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][System.Security.AccessControl.DirectorySecurity]$Security
    )

    if ($PSCmdlet.ShouldProcess($Path, '套用 WorkDir ACL')) { Set-Acl -LiteralPath $Path -AclObject $Security }
}

function Get-WinMediaPathOwnerSid {
    [CmdletBinding()]
    [OutputType([System.Security.Principal.SecurityIdentifier])]
    param([Parameter(Mandatory)][string]$Path)

    return (Get-Acl -LiteralPath $Path).GetOwner([System.Security.Principal.SecurityIdentifier])
}

function Get-WinMediaVolumeFileSystem {
    # 回傳路徑所在磁碟區的檔案系統名稱；UNC 或無法判斷時回傳 $null（DriveInfo 不接受 UNC）
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    try { return ([System.IO.DriveInfo]::new([System.IO.Path]::GetPathRoot($Path))).DriveFormat } catch { return $null }
}

function Test-WinMediaWorkRootAclTrusted {
    # 根目錄 ACL 是否仍是 Get-WinMediaWorkDirSecurity 的狀態：受保護（不繼承），且 ACE 只有 SYSTEM 與 Administrators
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)

    $acl = Get-Acl -LiteralPath $Path
    if (-not $acl.AreAccessRulesProtected) { return $false }
    $sids = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) | ForEach-Object { $_.IdentityReference.Value })
    return ($sids.Count -gt 0 -and @($sids | Where-Object { @('S-1-5-18', 'S-1-5-32-544') -notcontains $_ }).Count -eq 0)
}

function Initialize-WinMediaWorkRoot {
    # 審查第 8 則：WorkDir 根目錄（預設在磁碟根目錄下）建立或沿用時一律重新套用 ACL；舊版目錄繼承了 D:\ 的 Authenticated Users 修改權限，只在建立時修一次不夠
    # 審查 HIGH：只接手本工具建立（<WorkDir>\.winmedia-workroot）或為空的目錄，避免 -WorkDir 'E:\' 或使用者資料夾的權限被整棵改掉
    # IgnorePath：主流程在初始化前就會寫入的 LogDir 與 downloads，判斷是否為空時排除
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowEmptyCollection()][AllowNull()][string[]]$IgnorePath = @()
    )

    # 純字串判斷，先於任何檔案系統呼叫；兩邊去掉結尾反斜線，因為 UNC 根目錄沒有結尾反斜線而磁碟根目錄有
    $full = [System.IO.Path]::GetFullPath($Path.TrimEnd('\', '/') + '\').TrimEnd('\')
    if ([System.IO.Path]::GetPathRoot($full + '\').TrimEnd('\') -eq $full) {
        throw "WorkDir 不可為磁碟根目錄：$Path（請改用根目錄下的資料夾）。"
    }

    $fileSystem = Get-WinMediaVolumeFileSystem -Path $full
    # 未知（UNC 等）照常套用；FAT／exFAT 沒有 ACL，擁有者也無意義
    $aclSupported = -not $fileSystem -or @('NTFS', 'ReFS') -contains $fileSystem
    $marker = Join-Path -Path $Path -ChildPath '.winmedia-workroot'
    # CreateNew：同名檔案（含檢查後才出現的硬連結）已存在就拋錯，不寫穿到連結目標
    $writeMarker = {
        $stream = [System.IO.File]::Open($full + '\.winmedia-workroot', [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
        try { $bytes = [System.Text.Encoding]::ASCII.GetBytes('WinMediaRefresh'); $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    }
    if (Test-Path -LiteralPath $Path) {
        if ((Get-Item -LiteralPath $Path -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw "WorkDir 是 reparse point（junction 或符號連結），拒絕使用：$Path（請改用一般資料夾）。"
        }
        $ownerAllowed = @('S-1-5-18', 'S-1-5-32-544', [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
        if ($aclSupported) {
            $owner = Get-WinMediaPathOwnerSid -Path $Path
            if ($ownerAllowed -notcontains $owner.Value) {
                throw "WorkDir 已存在，但擁有者 $($owner.Value) 不是 Administrators、SYSTEM 或目前使用者，拒絕使用：$Path（請改用新的或空的 WorkDir）。"
            }
        }
        # origin/main 從不寫標記，所以標記只在根目錄 ACL 仍是本工具設定的狀態時可信；非 NTFS 卷無 ACL 可驗證，有標記即信任
        $trusted = (Test-Path -LiteralPath $marker -PathType Leaf) -and (-not $aclSupported -or (Test-WinMediaWorkRootAclTrusted -Path $Path))
        if (-not $trusted) {
            # 允許清單：IgnorePath 各自在 WorkDir 底下的頂層祖先（WorkDir\a\logs → WorkDir\a）；不可信的標記不在其中，視為外來項目（可能是硬連結）
            $prefix = $full + '\'
            $allowed = @()
            foreach ($p in @($IgnorePath | Where-Object { $_ })) {
                $f = [System.IO.Path]::GetFullPath($p).TrimEnd('\')
                if ($f.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { $allowed += $prefix + $f.Substring($prefix.Length).Split('\')[0] }
            }
            # 允許的頂層項目也不得是 reparse point，擁有者也要合格（攻擊者可能搶先建立自己擁有的 downloads）；更深層內容不檢查
            $blocking = @(foreach ($item in Get-ChildItem -LiteralPath $Path -Force) {
                if (($allowed -notcontains $item.FullName.TrimEnd('\')) -or ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { $item.Name }
                elseif ($aclSupported -and $ownerAllowed -notcontains (Get-WinMediaPathOwnerSid -Path $item.FullName).Value) { $item.Name }
            })
            if ($blocking.Count -gt 0) {
                $shown = (@($blocking | Select-Object -First 5) -join '、') + $(if ($blocking.Count -gt 5) { ' 等' } else { '' })
                throw "工作目錄已存在且不是本工具建立：$Path；擋住執行的項目：$shown（請改用新的或空的 WorkDir，或把 OutputDir、MountDir 移出 WorkDir）。"
            }
            & $writeMarker
        }
    }
    else {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        & $writeMarker
    }
    if (-not $aclSupported) {
        Write-Warning "WorkDir 所在磁碟區為 $fileSystem，不支援 ACL，略過權限設定：$Path（WorkDir 不受 ACL 保護）。"
        return
    }
    Set-WinMediaWorkDirAcl -Path $Path -Security (Get-WinMediaWorkDirSecurity)
}

function Resolve-WinMediaDefenderStatePath {
    # 狀態檔放使用者設定檔（與 wimlib 快取同在 %LOCALAPPDATA%\WinMediaRefresh），WorkDir 在 RAMDisk 時重開機後仍在；每個 WorkDir 一份
    # 鍵：WorkDir 去結尾反斜線、轉大寫後的 SHA-256 前 16 個十六進位字元
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$WorkDir)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($WorkDir.TrimEnd('\').ToUpperInvariant())) } finally { $sha.Dispose() }
    $key = (-join ($hash | ForEach-Object { $_.ToString('x2') })).Substring(0, 16)
    return (Join-Path -Path $env:LOCALAPPDATA -ChildPath "WinMediaRefresh\defender-state\$key.json")
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

Export-ModuleMember -Function Test-WinMediaPathOverlap, Resolve-WinMediaInputPath, Resolve-WinMediaMountDir, Use-WinMediaWorkDir, Remove-WinMediaWorkDir, Initialize-WinMediaWorkRoot, Get-WinMediaWorkDirSecurity, Resolve-WinMediaDefenderStatePath, Assert-WinMediaOutputDir, Resolve-WinMediaLogFile, Resolve-WinMediaLogLocation, Resolve-WinMediaLegacyInputSection, Mount-WinMediaSourceIso, Remove-WinMediaCleanupDir
