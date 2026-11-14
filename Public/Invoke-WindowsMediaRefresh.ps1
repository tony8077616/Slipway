function Invoke-WindowsMediaRefresh {
    <#
    .SYNOPSIS
        依 §3.2 的順序，以 PackageDir 中的更新包更新原版 ISO，產出新的 ISO 或 install.esd 媒體。
    .DESCRIPTION
        順序：前置檢查 → 複製母檔 → install.esd 轉 WIM → 偵測索引 → 分類更新包 → 虛擬版本條件 →
        WinRE → install.wim 各索引 → 虛擬版本 → boot.wim → Setup DU → ei.cfg → 移除來源索引 → 輸出 → 清理。
        母檔以唯讀掛載，只複製到 WorkDir，不會被修改（§3.3）。-WhatIf 只回傳步驟清單。
        工作子目錄只在成功輸出後清除；logs 保留。
    .PARAMETER SourceIso
        原版 Windows ISO 路徑（母檔）。
    .PARAMETER Config
        由 Import-PowerShellDataFile 載入並補上 LogDir、OperationLog 的設定表。
    .PARAMETER Force
        允許覆寫 OutputDir 中已存在的同名輸出（§3.3）。
    .PARAMETER WorkDir
        工作（暫存）目錄，覆寫 Config.WorkDir；未指定則用設定檔值。
    .PARAMETER MountDir
        掛載目錄，覆寫 Config.MountDir；未指定且設定檔為空時，依 Convert-UUP.cmd 規則產生預設值（見 Resolve-WinMediaMountDir）。
    .PARAMETER OutputDir
        成品輸出目錄，覆寫 Config.OutputDir；未指定且設定檔為空時與 WorkDir 相同（Convert-UUP.cmd 輸出於工作目錄）。
    .PARAMETER DismLogLevel
        DISM cmdlet 的 -LogLevel 名稱（Errors／Warnings／WarningsInfo／Debug），覆寫 Config.DismLogLevel；未指定則用設定檔值。
    .EXAMPLE
        Invoke-WindowsMediaRefresh -SourceIso 'D:\Win11.iso' -Config $config -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$SourceIso,
        [Parameter(Mandatory)][hashtable]$Config,
        [switch]$Force,
        [string]$WorkDir,
        [string]$MountDir,
        [string]$OutputDir,
        # 參數端先擋掉非法值（給出 PowerShell 的參數錯誤）；合法名單與預設值的權威定義在 Resolve-WinMediaDismLogLevel
        [ValidateSet('Errors', 'Warnings', 'WarningsInfo', 'Debug')][string]$DismLogLevel,
        # 輸出形式覆寫 Config.OutputForm；未指定時沿用設定檔（空白 = 自動）
        [ValidateSet('Iso', 'Folder', 'Image')][string]$OutputForm
    )

    $steps = @(
        '1 前置檢查（管理員、PowerShell 版本、WorkDir 不在 OneDrive、輸出工具、DISM 來源）',
        '2 掛載母檔（唯讀）並複製到 WorkDir\media',
        '2a 若有 install.esd，轉為 install.wim',
        '3 偵測 build 與索引',
        '4 下載更新包（僅於設定 Download.Build 或 Download.KB 時）；分類 PackageDir（缺 SSU 或 LCU 即中止；目標與 checkpoint 經 WorkDir\update-stage 注入）',
        '4a 虛擬版本條件（§2.7.1、§2.7.7）',
        '5 WinRE：取索引 1 的 winre.wim → SSU → SafeOS DU（有則套用）→ cleanup（不套 LCU，§11.8 2a）→ 驅動（若設定，WinRE 目標）',
        '6 install.wim 各索引：SSU → 語言包與 FoD → 最新 LCU（含 checkpoint）→ cleanup（CBS 待處理只警告）→ NetFx3 → .NET CU → 移除 Appx（若設定）→ 加入 LXP → 驅動 → 放入 WinRE → 選項 UpdateBootFiles（預設開）時取用已套用 LCU 映像的 _EX 開機檔',
        '7 虛擬版本（僅來源為 EnterpriseS 且在 Indexes 目標內；§2.7.4）',
        '8 展開 Setup DU 到 sources（第 26 列）',
        '9 boot.wim 索引 1、2：WinPEUpdate 為 Lcu 時以目標 MSU 檔案路徑加入（需與 checkpoint 同資料夾；SafeOS 路線跳過）→ cleanup → 驅動（若設定，Boot 目標）；索引 2 內 boot manager 覆蓋媒體（第 28 列；選項 UpdateBootFiles 已套用 _EX 開機檔時跳過）；兩個索引卸載後，以 wimlib update 把媒體 sources\ 覆蓋 WinPE 索引 2 的同名檔（convert-UUP bootwim.txt／bootmui.txt，方向與 MS 文件第 27 列相反）；最後 boot.wim 做 export（保留可開機索引）與 optimize',
        '10 移除來源 EnterpriseS（僅 DeleteSourceEdition 且已建立虛擬版本）後，依 §2.7.5 處理 ei.cfg',
        '11 輸出：oscdimg 雙開機 ISO 或 install.esd（寫入 OutputDir）',
        '12 成功後清除 WorkDir 下的 media、winre、expand；MountDir 若由本次建立則一併清除；logs 保留'
    )
    if (-not $PSCmdlet.ShouldProcess($SourceIso, '更新 Windows 安裝媒體')) {
        return $steps
    }

    # 參數覆寫設定檔；LogDir 與 OperationLog 跟隨 WorkDir
    $Config = $Config.Clone()
    # 自訂設定檔可能沒有此鍵；缺少時採預設路線 Lcu（驗證不接受 $null）
    if (-not $Config.ContainsKey('WinPEUpdate')) { $Config.WinPEUpdate = 'Lcu' }
    # 空白 = 腳本所在磁碟根目錄\WinMediaWork，避免直接放在系統磁碟區根目錄（除非腳本本身位於 C 槽）
    if (-not $WorkDir -and [string]::IsNullOrWhiteSpace($Config.WorkDir)) {
        $WorkDir = Join-Path -Path ([System.IO.Path]::GetPathRoot($PSScriptRoot)) -ChildPath 'WinMediaWork'
    }
    if ($WorkDir) {
        $Config.WorkDir = $WorkDir
        $Config.LogDir = Join-Path -Path $WorkDir -ChildPath 'logs'
        $Config.OperationLog = Join-Path -Path $Config.LogDir -ChildPath 'OperationLog.txt'
    }
    if ([string]::IsNullOrWhiteSpace($Config.WorkDir) -or -not [System.IO.Path]::IsPathRooted($Config.WorkDir)) {
        throw "WorkDir 必須為絕對路徑，目前為：'$($Config.WorkDir)'。"
    }
    # 根目錄相對路徑（如 \WinMediaWork）會通過 IsPathRooted，須補成完整路徑（與提權參數相同的解析）
    $Config.WorkDir = Get-WinMediaFullPath -Path $Config.WorkDir
    if ($WorkDir) {
        $Config.LogDir = Join-Path -Path $Config.WorkDir -ChildPath 'logs'
        $Config.OperationLog = Join-Path -Path $Config.LogDir -ChildPath 'OperationLog.txt'
    }
    # 設定檔可能沒有 LogDir／OperationLog；Invoke-WinMediaOperation 直接讀取 OperationLog，須在第一次呼叫前補齊
    $location = Resolve-WinMediaLogLocation -Config $Config
    $Config.LogDir = $location.LogDir
    $Config.OperationLog = $location.OperationLog
    $Config.LogFile = Resolve-WinMediaLogFile -Config $Config
    if ($MountDir) { $Config.MountDir = $MountDir }
    if ($OutputDir) { $Config.OutputDir = $OutputDir }
    if ($PSBoundParameters.ContainsKey('DismLogLevel')) { $Config.DismLogLevel = $DismLogLevel }
    # 舊設定檔缺 DismLogLevel 時補預設並驗證（規則集中在 Keel 的 Resolve-WinMediaDismLogLevel）
    $Config.DismLogLevel = Resolve-WinMediaDismLogLevel -Config $Config
    if ($PSBoundParameters.ContainsKey('OutputForm')) { $Config.OutputForm = $OutputForm }
    # 新鍵補預設值並驗證（舊設定檔可能沒有）；OutputForm 由 Step 10 的輸出流程使用
    $Config = Resolve-WinMediaMountOption -Config $Config
    # pwsh 7 下的 DISM 主機檢查（DismUseWindowsPowerShell 為關閉時中止）；開啟時於第一次 DISM 呼叫前先檢查、沒有才匯入
    Test-WinMediaDismHost -Provider $Config.DismProvider -Config $Config
    $Config.MountDir = Resolve-WinMediaMountDir -WorkDir $Config.WorkDir -MountDir $Config.MountDir
    # .esd 來源沒有開機檔與媒體樹：輸出形式在此一次決定（明確指定 Iso／Folder 直接拒絕，早於任何檔案動作）
    $isEsdSource = [System.IO.Path]::GetExtension($SourceIso) -ieq '.esd'
    $plan = Resolve-WinMediaOutputPlan -OutputFormat $Config.OutputFormat -OutputForm $Config.OutputForm -SourceKind $(if ($isEsdSource) { 'Esd' } else { 'Iso' })
    if ($plan.AutoImage) { Write-Warning '來源為 .esd 且未指定 OutputForm，改輸出 Image（install.wim 或 install.esd 放在 OutputDir）；.esd 來源沒有開機檔，無法打包 ISO。' }
    # 空白 = 工具所在磁碟根目錄\WinMediaOut（與 WorkDir 並列，不在 OneDrive 內，不受第 12 步清理影響）
    if ([string]::IsNullOrWhiteSpace($Config.OutputDir)) {
        $Config.OutputDir = Join-Path -Path ([System.IO.Path]::GetPathRoot($PSScriptRoot)) -ChildPath 'WinMediaOut'
    }
    # 相對路徑依 PowerShell 位置解析；.NET 的 GetFullPath 與 oscdimg 則依行程目錄，兩者不同時保護檢查會對錯路徑
    $Config.OutputDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Config.OutputDir)
    # 舊設定檔缺 Lang／Fod／StoreApps 時先補空路徑，須在下方 Clone 之前（Clone 會直接讀取這些鍵）
    Resolve-WinMediaLegacyInputSection -Config $Config
    # 巢狀設定 Clone 為淺複製；補齊輸入路徑前先複製，避免改到呼叫端的設定
    $Config.Drivers = $Config.Drivers.Clone()
    $Config.Lxp = $Config.Lxp.Clone()
    $Config.Apps = $Config.Apps.Clone()
    $Config.Lang = $Config.Lang.Clone()
    $Config.Fod = $Config.Fod.Clone()
    $Config.StoreApps = $Config.StoreApps.Clone()
    Resolve-WinMediaInputPath -RootDir $script:ModuleRoot -Config $Config

    # 字串誤設為 ForceUnsigned 時在此中止，不靜默變成 $true（未簽章驅動會被注入）
    $forceUnsigned = Resolve-WinMediaForceUnsigned -Config $Config
    # ResetBaseOS 同樣拒絕非布林；只作用於 install.wim 的 cleanup（WinRE 由 ResetBase 控制）
    $resetBaseOS = Resolve-WinMediaResetBaseOS -Config $Config

    # 步驟 1：前置檢查
    # 網路路徑於管理員檢查之前拒絕（需求第 6、10 項）；入口腳本已先做過一次，函式直接呼叫時仍需檢查
    Assert-WinMediaLocalPath -Path $SourceIso -Name 'SourceIso'
    Assert-WinMediaLocalPath -Path $Config.WorkDir -Name 'WorkDir'
    Assert-WinMediaLocalPath -Path $Config.MountDir -Name 'MountDir'
    Assert-WinMediaLocalPath -Path $Config.OutputDir -Name 'OutputDir'
    if (-not [string]::IsNullOrWhiteSpace($Config.ScratchDirectory)) {
        Assert-WinMediaScratchPath -ScratchDirectory $Config.ScratchDirectory -MountDir $Config.MountDir -WorkDir $Config.WorkDir
    }
    # 不在此提示提權：提權由入口腳本 Update-WindowsMedia.ps1 負責；函式只警告並丟出原訊息
    if (-not (Test-WinMediaAdministrator)) {
        if ([Environment]::UserInteractive) { Write-Warning '請以系統管理員身分重新執行，或改用 Update-WindowsMedia.ps1（會提示提權）。' }
        throw '需要系統管理員權限。'
    }
    # Defender 排除（選項 DefenderExclusions）：WorkDir 建立並套用 ACL 後才加入（狀態檔放 WorkDir 根目錄），finally 只還原本次新增的項目
    $defenderAdded = @()
    $defenderState = $null
    try {
    # 雲端同步資料夾只警告不中止：使用者可能已確認同步設定；掛載點位於同步資料夾時風險較高，文字不同
    $cloud = Get-WinMediaCloudProvider -Path $Config.WorkDir
    if ($cloud) { Write-Warning "WorkDir 位於 $cloud 同步資料夾內，同步服務可能鎖定或搬移工作檔，建議改用其他路徑（見 Config/Default.psd1）。" }
    $cloud = Get-WinMediaCloudProvider -Path $Config.MountDir
    if ($cloud) { Write-Warning "MountDir 位於 $cloud 同步資料夾內，掛載點可能被同步服務鎖定，建議改用其他路徑。" }
    if (-not [string]::IsNullOrWhiteSpace($Config.ScratchDirectory)) {
        $cloud = Get-WinMediaCloudProvider -Path $Config.ScratchDirectory
        if ($cloud) { Write-Warning "ScratchDirectory 位於 $cloud 同步資料夾內，同步服務可能鎖定暫存檔，建議改用其他路徑。" }
    }
    # 掛載需要 NTFS；無法判斷檔案系統（UNC 等，已於前面拒絕）時不擋
    $mountFileSystem = Get-WinMediaVolumeFileSystem -Path $Config.MountDir
    if ($mountFileSystem -and $mountFileSystem -ne 'NTFS') {
        throw "MountDir 必須位於 NTFS 磁碟區，目前為 $mountFileSystem：$($Config.MountDir)"
    }
    if (-not (Test-Path -LiteralPath $SourceIso -PathType Leaf)) {
        throw "找不到母檔：$SourceIso"
    }
    if (-not (Test-Path -LiteralPath $Config.PackageDir -PathType Container)) {
        throw "找不到更新包資料夾：$($Config.PackageDir)"
    }
    Test-WinMediaPathOverlap -Paths @{ PackageDir = $Config.PackageDir; WorkDir = $Config.WorkDir; Drivers = $Config.Drivers.Path; Lxp = $Config.Lxp.Path; Lang = $Config.Lang.Path; Fod = $Config.Fod.Path; StoreApps = $Config.StoreApps.Path }
    $driverSet = Resolve-WinMediaDriverSet -Path $Config.Drivers.Path -Config $Config
    $appxList = Resolve-WinMediaAppxList -Path $Config.Apps.CustomAppsList -Mode $Config.Apps.CustomListMode -Config $Config
    $langFod = Resolve-WinMediaLangFodSet -LangPath $Config.Lang.Path -FodPath $Config.Fod.Path -Config $Config
    $storeSet = Resolve-WinMediaStoreAppSet -Path $Config.StoreApps.Path -Config $Config
    # 步驟 9 之後的 boot.wim export／optimize 與 ESD 都需要 wimlib；先解析，離線環境在開始前就失敗
    Resolve-WinMediaWimlib -Config $Config | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($Config.Lxp.Path) -and -not (Test-Path -LiteralPath $Config.Lxp.Path -PathType Container)) {
        throw "找不到 LXP 資料夾：$($Config.Lxp.Path)"
    }
    if ($Config.WinPEUpdate -notin 'SafeOS', 'Lcu') { throw "不支援的 WinPEUpdate：$($Config.WinPEUpdate)" }
    # $plan 已於 Resolve-WinMediaMountDir 之後算好（含 .esd 來源規則），此處沿用
    # 可寫掛載才帶 -Optimize／-CheckIntegrity（Keel 的 Remount 參數集不接受；唯讀掛載不需要）
    $mountSwitches = Get-WinMediaMountSwitch -Config $Config
    # DISM 共用參數（只在設定 ScratchDirectory 時含鍵）；每個 DISM 呼叫都要 splat，由 AST 測試確認
    $common = Get-WinMediaDismCommonParameter -Config $Config
    # 工具需求依 $plan：oscdimg 只在 Iso 時需要；wimlib 已由上方為 boot.wim 解析，此處只在 ESD 時補上
    $oscdimg = $null
    if ($plan.NeedsOscdimg) { $oscdimg = Resolve-WinMediaOscdimg -Config $Config }
    if ($plan.NeedsWimlib) { $null = Resolve-WinMediaWimlib -Config $Config }
    if ($Config.DismProvider -eq 'ADK') { $null = Resolve-WinMediaAdk -Config $Config }

    $workDir = $Config.WorkDir
    $mediaDir = Join-Path -Path $workDir -ChildPath 'media'
    $winreDir = Join-Path -Path $workDir -ChildPath 'winre'
    $mountDir = $Config.MountDir
    $expandDir = Join-Path -Path $workDir -ChildPath 'expand'
    $lxpDir = Join-Path -Path $workDir -ChildPath 'lxp'
    # 更新包暫存（目標 CU 與 checkpoint，DISM 只會在 -PackagePath 所在資料夾尋找 checkpoint）；結束時清除
    $stageDir = Join-Path -Path $workDir -ChildPath 'update-stage'
    $sourcesDir = Join-Path -Path $mediaDir -ChildPath 'sources'
    $installWim = Join-Path -Path $sourcesDir -ChildPath 'install.wim'
    $installEsd = Join-Path -Path $sourcesDir -ChildPath 'install.esd'
    $bootWim = Join-Path -Path $sourcesDir -ChildPath 'boot.wim'
    $winreWim = Join-Path -Path $winreDir -ChildPath 'winre.wim'

    # 輸出目錄不得位於會被清理或掛載的目錄之下（Must 2）；須在 Use 迴圈之前檢查，否則已登記目錄會先被清空
    # 來源不得位於會被 Use-WinMediaWorkDir 清空的目錄之內，否則使用者的原始檔會先被清掉（ISO 與 .esd 來源都適用）
    foreach ($dir in @($mediaDir, $winreDir, $expandDir, $lxpDir, $stageDir)) {
        if (Test-PathWithin -Child $SourceIso -Parent $dir) { throw "來源映像位於工作子目錄之內，會被清空：$SourceIso" }
    }
    # 來源即上一次的 Image 輸出時，匯出會先刪除目的檔（即使用者的來源），因此直接拒絕
    foreach ($outName in 'install.esd', 'install.wim') {
        if ((Get-WinMediaFullPath -Path $SourceIso) -ieq (Get-WinMediaFullPath -Path (Join-Path -Path $Config.OutputDir -ChildPath $outName))) { throw "來源與輸出相同，會被覆寫：$SourceIso" }
    }
    # 平行路徑的守衛提前到任何登記之前（與後段平行分支內的守衛相同；序列路徑不受影響）
    if ([int]$Config.MountParallelCount -gt 1) {
        $earlyParallelDir = Join-Path -Path $workDir -ChildPath 'parallel'
        if (Test-PathWithin -Child $SourceIso -Parent $earlyParallelDir) { throw "來源映像位於平行工作目錄之內，會被清空：$SourceIso" }
        if (Test-PathWithin -Child $Config.OutputDir -Parent $earlyParallelDir) { throw "OutputDir 位於平行工作目錄之內，會被清空：$($Config.OutputDir)" }
        if (Test-PathWithin -Child $mountDir -Parent $earlyParallelDir) { throw "MountDir 位於平行工作目錄之內，會被清空：$mountDir" }
        if (Test-PathWithin -Child $Config.LogDir -Parent $earlyParallelDir) { throw "LogDir 位於平行工作目錄之內，會被清空：$($Config.LogDir)" }
        if (Test-PathWithin -Child $Config.LogFile -Parent $earlyParallelDir) { throw "LogFile 位於平行工作目錄之內，會被清空：$($Config.LogFile)" }
        if (Test-PathWithin -Child $Config.OperationLog -Parent $earlyParallelDir) { throw "OperationLog 位於平行工作目錄之內，會被清空：$($Config.OperationLog)" }
        if ($Config.ContainsKey('ScratchDirectory') -and -not [string]::IsNullOrWhiteSpace($Config.ScratchDirectory) -and (Test-PathWithin -Child $Config.ScratchDirectory -Parent $earlyParallelDir)) { throw "ScratchDirectory 位於平行工作目錄之內，會被清空：$($Config.ScratchDirectory)" }
    }
    Assert-WinMediaOutputDir -OutputDir $Config.OutputDir -ProtectedDir @($mediaDir, $winreDir, $expandDir, $lxpDir, $stageDir, $mountDir)
    # 掛載目錄若已存在且非空，直接中止，不像 Convert-UUP.cmd:1060 那樣 rmdir 既有目錄
    if ((Test-Path -LiteralPath $mountDir) -and @(Get-ChildItem -LiteralPath $mountDir -Force).Count -gt 0) {
        # 映像掛載在子資料夾（install-N、boot-N、winre…）而非 $mountDir 本身；需要重新掛載的只拒絕並指向清理步驟，不在此自動處理
        $stale = @(Get-ChildItem -LiteralPath $mountDir -Directory -Force | Where-Object { (Get-WinMediaMountState -Path $_.FullName -Config $Config) -eq 'NeedsRemount' })
        if ($stale.Count -gt 0) {
            throw "掛載目錄內有需要重新掛載（NeedsRemount）的映像：$($stale[0].FullName)。請先執行 Clear-WindowsMediaWorkspace.ps1（步驟 11）清理，再重試。"
        }
        throw "掛載目錄已存在且非空：$mountDir（請指定空目錄或刪除後重試）。"
    }
    $mountDirCreated = -not (Test-Path -LiteralPath $mountDir)
    # 審查第 8 則：WorkDir 根目錄（預設在磁碟根目錄下）擁有者不合格或為 junction 時中止；每次都重新套用關閉繼承的 ACL
    # 此前 Write-WinMediaLog（LogDir）與 Resolve-WinMediaWimlib／Install-WinMediaAdk（WorkDir\downloads）可能已寫入，判斷是否為空時排除
    Initialize-WinMediaWorkRoot -Path $workDir -IgnorePath @($Config.LogDir, $Config.LogFile, $Config.OperationLog, (Join-Path -Path $workDir -ChildPath 'downloads'))
    # 審查第 15 則：上次被強制結束而遺留的排除，不論本次是否開啟 DefenderExclusions 都先還原
    $defenderState = Resolve-WinMediaDefenderStatePath -WorkDir $workDir
    Restore-WinMediaDefenderExclusion -StatePath $defenderState -AllowedPath @($workDir, $mountDir, $Config.OutputDir) -Confirm:$false
    # 舊版把狀態檔放在 WorkDir 根目錄：讀一次、還原後刪除；須在 Initialize-WinMediaWorkRoot 之後（位於 WorkDir 內）
    Restore-WinMediaDefenderExclusion -StatePath (Join-Path -Path $workDir -ChildPath 'defender-state.json') -AllowedPath @($workDir, $mountDir, $Config.OutputDir) -Confirm:$false
    if ($Config.ContainsKey('DefenderExclusions') -and $Config.DefenderExclusions) {
        $defenderAdded = Add-WinMediaDefenderExclusion -Path @($workDir, $mountDir, $Config.OutputDir) -StatePath $defenderState
    }
    # ScratchDirectory 由本工具建立（Keel 的 DISM 包裝不建立）；空白時略過
    foreach ($dir in @($mountDir, $Config.LogDir, $Config.OutputDir, $Config.ScratchDirectory) | Where-Object { $_ }) {
        if (-not (Test-Path -LiteralPath $dir)) {
            Invoke-WinMediaOperation -Category File -Operation 'CreateDirectory' -Target $dir -Config $Config -ScriptBlock {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            } | Out-Null
        }
    }
    # 工作子目錄：只清空本工具登記過的，未登記且非空的既有目錄直接拒絕（Must 1）；update-stage 也在此登記，因為 New-WinMediaUpdateStage 會無條件刪除它
    foreach ($dir in @($mediaDir, $winreDir, $expandDir, $lxpDir, $stageDir)) {
        Invoke-WinMediaOperation -Category File -Operation 'UseWorkDir' -Target $dir -Config $Config -ScriptBlock {
            Use-WinMediaWorkDir -Path $dir
        } | Out-Null
    }
    $lxpItems = @(Resolve-WinMediaLxp -Path $Config.Lxp.Path -TempDir $lxpDir -Config $Config)

    Write-WinMediaLog -Config $Config -Level Info -Message "開始更新：$SourceIso"
    if (@($Config.Languages).Count -gt 0) {
        Write-WinMediaLog -Config $Config -Level Info -Message "語言包 $(@($langFod.LangPacks).Count) 個、FoD $(@($langFod.Fod).Count) 個（依 Languages 篩選，於 LCU 之後注入）。"
    }

    if ($isEsdSource) {
        # .esd 來源沒有媒體樹：副本放在 media\sources\install.esd，下方步驟 2a 轉換後移除副本，原始檔不動
        Copy-WinMediaEsdSource -SourcePath $SourceIso -DestinationPath $installEsd -WimPath $installWim -WorkDir $workDir -Config $Config
    }
    else {
    # 步驟 2：掛載母檔（唯讀）並複製；母檔不修改（§3.3）
    $isoMount = Mount-WinMediaSourceIso -ImagePath $SourceIso -Confirm:$false
    try {
        $driveLetter = $isoMount.DriveLetter
        if (-not $driveLetter) { throw '無法取得 ISO 的磁碟機代號。' }
        $isoRoot = '{0}:\' -f $driveLetter
        Invoke-WinMediaOperation -Category File -Operation 'CopyMedia' -Target $mediaDir -Config $Config -ScriptBlock {
            Copy-Item -Path (Join-Path -Path $isoRoot -ChildPath '*') -Destination $mediaDir -Recurse -Force
        } | Out-Null
    }
    finally {
        # 使用者事先掛載的 ISO 不卸載（Mounted = $false）
        if ($isoMount.Mounted) { Dismount-DiskImage -ImagePath $SourceIso | Out-Null }
    }
    Get-ChildItem -LiteralPath $mediaDir -Recurse -Force -File | ForEach-Object { $_.IsReadOnly = $false }
    # 步驟 2 之後、2a 之前：移除未選取的額外語言（先於步驟 8 的 Setup DU，使 /U 規則不會把它們建回來）
    Remove-WinMediaExtraLanguage -MediaDir $mediaDir -Languages @($Config.Languages) -Config $Config
    }  # 結束：非 .esd 來源

    # 步驟 2a：install.esd → install.wim（§2.7.3）
    if (Test-Path -LiteralPath $installEsd) {
        Convert-WinMediaEsdToWim -SourceEsd $installEsd -DestinationWim $installWim -Config $Config
    }

    # 步驟 3：偵測 build 與索引
    if (-not (Test-Path -LiteralPath $installWim)) {
        throw '媒體中找不到 install.wim（若為 install.swm 分割檔，目前不支援）。'
    }
    # 逐索引取得 Build／EditionId／Architecture（不帶 -Index 的 Get-WindowsImage 沒有這些欄位）
    $images = @(Get-WinMediaIndexInfo -ImagePath $installWim -Config $Config)
    $build = [int]$images[0].Build
    $architecture = $images[0].Architecture
    $indexes = @($images | ForEach-Object { $_.ImageIndex })
    $targets = @(if (@($Config.Indexes).Count -gt 0) { @($indexes | Where-Object { $Config.Indexes -contains $_ }) } else { $indexes })
    if ($targets.Count -eq 0) { throw '設定的 Indexes 與映像內索引皆不相符。' }
    Write-WinMediaLog -Config $Config -Level Info -Message "build=$build；索引：$($indexes -join ',')"

    # 下載更新包（opt-in：Download.Build 優先，其次 Download.KB；兩者皆空則沿用 PackageDir 既有檔案）
    $downloaded = @()
    $buildSet = $null
    if ($Config.Download.Build) {
        $buildSet = Save-WinMediaBuildSet -Build $Config.Download.Build -Architecture $architecture -Config $Config
        $downloaded = @($buildSet.Files | Where-Object { $_ -match '\.msu$' })
    }
    elseif ($Config.Download.KB) {
        $downloaded = @(Save-WinMediaUpdate -KB $Config.Download.KB -Architecture $architecture -Config $Config | Where-Object { $_ -match '\.msu$' })
    }

    # 步驟 4：分類；缺必要類別即中止（尚未修改任何映像）
    $categories = Get-WinMediaPackageCategory -PackageDir $Config.PackageDir -ExpandDir $expandDir -Config $Config
    # Build 路徑只採用本次下載的檔案（依檔名比對），避免 PackageDir 殘留的舊 SafeOS、SetupDU、.NET、LCU 被套用
    if ($buildSet) {
        $setNames = @($buildSet.Files | ForEach-Object { Split-Path -Path $_ -Leaf })
        foreach ($key in 'SafeOS', 'SetupDU', 'DotNetCU', 'LCU', 'Checkpoint') {
            $categories.$key = @($categories.$key | Where-Object { $setNames -contains (Split-Path -Path $_ -Leaf) })
        }
    }
    if ($categories.SSU.Count -eq 0) { throw '缺少 SSU（可從合併 CU 取出，§11.3）。' }
    # 目標 CU 與前置 checkpoint：下載路徑只用本次下載的檔案；手動路徑用 PackageDir 內的 LCU（KB 較小者視為 checkpoint）
    $candidates = if ($downloaded.Count -gt 0) { $downloaded } else { @($categories.LCU) + @($categories.Checkpoint) }
    if (@($candidates).Count -eq 0) { throw '缺少最新 LCU。' }
    # Build 路徑直接採用 Save-WinMediaBuildSet 的判定結果；手動路徑才對候補清單重新判定
    $cumulative = if ($buildSet) {
        [pscustomobject]@{ Target = $buildSet.Target; Checkpoints = @($buildSet.Checkpoints) }
    }
    else {
        # 手動路徑依 identity 版本排序（convert-UUP :chklcu）；讀不到版本的候選退回 KB 編號排序
        $lcuVersions = @{}
        foreach ($lcuPath in @($candidates)) {
            $lcuVer = Get-WinMediaPackageVersion -Package $lcuPath -ExpandDir $expandDir -Kind RollupFix -Config $Config
            if ($lcuVer) { $lcuVersions[$lcuPath] = $lcuVer }
        }
        if ($lcuVersions.Count -lt @($candidates).Count) {
            # 有候選讀不到版本時不比版本（缺值會被當成 0.0.0.0，可能把目標誤判為 checkpoint），整組退回 KB 編號排序
            Write-WinMediaLog -Config $Config -Level Warning -Message 'LCU 候選有無法讀取版本者，本次改用 KB 編號排序判定目標。'
            $lcuVersions = @{}
        }
        Resolve-WinMediaCumulativeSet -Paths @($candidates) -Config $Config -Versions $lcuVersions
    }
    if (-not $cumulative) { throw '缺少最新 LCU（PackageDir 內沒有 .msu 累積更新）。' }
    if ($downloaded.Count -eq 0 -and @($cumulative.Checkpoints).Count -gt 0) {
        Write-WinMediaLog -Config $Config -Level Warning -Message ('PackageDir 內有較舊的累積更新，將視為前置 checkpoint：' + (($cumulative.Checkpoints | ForEach-Object { Split-Path -Path $_ -Leaf }) -join ', ') + '。建議只保留目標與其 checkpoint。')
    }
    if ($Config.WinPEUpdate -eq 'Lcu' -and @($cumulative.Checkpoints).Count -eq 0) {
        Write-WinMediaLog -Config $Config -Level Warning -Message '未偵測到目標 LCU 的 checkpoint；boot 步驟的 LCU 可能無效，並會在 install 索引全部完成後才中止；使用 Download.KB 時也會出現，請確認目標 MSU 所在資料夾已有 checkpoint。'
    }
    if ($categories.Unclassified.Count -gt 0) {
        Write-WinMediaLog -Config $Config -Level Warning -Message ('無法分類、略過的套件：' + (($categories.Unclassified | ForEach-Object { Split-Path -Path $_ -Leaf }) -join ', '))
    }
    if (@($categories.DotNetCU).Count -gt 1) {
        Write-WinMediaLog -Config $Config -Level Warning -Message '偵測到多個 .NET CU，僅使用排序第一者；建議只保留所需的一包。（SSU 依目標檔名選取，不受影響）'
    }
    # SSU 取自目標 CU 的展開目錄（CombinedCU 內的 SSU-*.cab）；checkpoint 內的 SSU 較舊，不可用於 WinRE 與主映像
    $targetName = Split-Path -Path $cumulative.Target -Leaf
    $escapedTarget = [System.Management.Automation.WildcardPattern]::Escape($targetName)
    $targetSsu = @($categories.SSU | Where-Object { $_ -like "*\$escapedTarget\*" })
    if ($buildSet) {
        if ($targetSsu.Count -eq 0) { throw '目標累積更新內找不到 SSU（Build 路徑不回退至 PackageDir 內的舊 SSU）。' }
        $ssu = $targetSsu | Select-Object -First 1
    }
    else {
        # 手動路徑：所有 SSU 候選比對 identity 版本，保留最新（convert-UUP :chkssu）；讀不到版本視為 0.0.0.0
        $ssuVersions = @{}
        foreach ($ssuPath in @($categories.SSU)) {
            $ssuVer = Get-WinMediaPackageVersion -Package $ssuPath -ExpandDir $expandDir -Kind ServicingStack -Config $Config
            if ($ssuVer) { $ssuVersions[$ssuPath] = $ssuVer }
        }
        # 目標 CU 內的 SSU 排在前面，版本相同時優先採用目標 CU 的 SSU
        $ssuOrder = @(@($targetSsu) + @($categories.SSU | Where-Object { $targetSsu -notcontains $_ }))
        if ($ssuVersions.Count -eq @($categories.SSU).Count) {
            $ssu = Select-WinMediaNewestPackage -Paths $ssuOrder -Versions $ssuVersions
        }
        else {
            # 有 SSU 讀不到版本時退回舊規則：目標 CU 內的 SSU 優先，不以缺值比較
            Write-WinMediaLog -Config $Config -Level Warning -Message 'SSU 有無法讀取版本者，本次改用目標 CU 內的 SSU（或排序第一者）。'
            $ssu = $ssuOrder | Select-Object -First 1
        }
        if (@($categories.SSU).Count -gt 1) {
            Write-WinMediaLog -Config $Config -Level Info -Message "SSU 依版本保留最新：$(Split-Path -Path $ssu -Leaf)（版本 $($ssuVersions[$ssu]) ，無版本資訊者以 0.0.0.0 計）。"
        }
        if ($targetSsu.Count -eq 0) {
            Write-WinMediaLog -Config $Config -Level Warning -Message '目標累積更新內找不到 SSU，改用 PackageDir 內版本最新的 SSU。'
        }
    }
    $lcuStage = New-WinMediaUpdateStage -Target $cumulative.Target -Checkpoints @($cumulative.Checkpoints) -StageDir $stageDir -Config $Config
    $dotNet = $categories.DotNetCU | Select-Object -First 1
    $safeOs = $categories.SafeOS | Select-Object -First 1
    $setupDu = $categories.SetupDU | Select-Object -First 1
    if (-not $safeOs) {
        Write-WinMediaLog -Config $Config -Level Warning -Message '未找到 SafeOS DU；WinRE 僅套用 SSU（§11.8 2a）。'
    }

    # 步驟 4a：虛擬版本條件（§2.7.1）；IoTEnterpriseS 需實際掛載 EnterpriseS 唯讀確認 SPP 檔（§2.7.7）
    $ltscIndex = $images | Where-Object { $_.EditionId -ieq 'EnterpriseS' -and $targets -contains $_.ImageIndex } | Select-Object -First 1
    $sppPresent = $true
    if (@($Config.VirtualEditions) -contains 'IoTEnterpriseS' -and $ltscIndex) {
        $sppPresent = [bool](Mount-WinMediaImage -ImagePath $installWim -Index $ltscIndex.ImageIndex -MountPath (Join-Path -Path $mountDir -ChildPath 'spp-check') -ReadOnly -Config $Config -Action {
            param($mounted)
            @(Get-ChildItem -Path (Join-Path -Path $mounted -ChildPath 'Windows\System32\spp\tokens\skus\IoTEnterpriseS') -Filter 'IoTEnterpriseS-OEM*.xrm-ms' -ErrorAction SilentlyContinue).Count -gt 0
        })
    }
    $virtualEditions = @(Test-WinMediaVirtualEdition -Build $build -SourceEditionIds @($images | ForEach-Object { $_.EditionId }) -RequestedEditions @($Config.VirtualEditions) -IoTEnterpriseSSppPresent $sppPresent)
    if ($virtualEditions.Count -gt 0 -and -not $ltscIndex) {
        throw '要求虛擬版本，但 EnterpriseS 索引不在 Indexes 目標內；虛擬版本必須從已更新的 EnterpriseS 建立（§2.7.4）。'
    }

    # 步驟 5：WinRE（取自索引 1，§3.2 step 5）
    $winreSourceIndex = $indexes[0]
    Mount-WinMediaImage -ImagePath $installWim -Index $winreSourceIndex -MountPath (Join-Path -Path $mountDir -ChildPath 'winre-src') -ReadOnly -Config $Config -Action {
        param($mounted)
        Write-WinMediaLog -Config $Config -Level Verbose -Message "WinRE 來源掛載點：$mounted"
        Invoke-WinMediaOperation -Category File -Operation 'CopyWinRE' -Target $winreWim -Config $Config -ScriptBlock {
            Copy-Item -LiteralPath (Join-Path -Path $mounted -ChildPath 'Windows\System32\Recovery\winre.wim') -Destination $winreWim -Force
        } | Out-Null
    } | Out-Null

    # WinRE 套用 SafeOS DU 後的 ntoskrnl 版本，供步驟 9 守衛判斷開機索引是否取自已更新的 WinRE
    $winreKernel = @{ Base = $null; Version = $null }
    Mount-WinMediaImage -ImagePath $winreWim -Index 1 -MountPath (Join-Path -Path $mountDir -ChildPath 'winre') @mountSwitches -Config $Config -Action {
        param($mounted)
        Write-WinMediaLog -Config $Config -Level Verbose -Message "WinRE 掛載點：$mounted"
        $winreKernel.Base = (Get-Item -LiteralPath (Join-Path -Path $mounted -ChildPath 'Windows\System32\ntoskrnl.exe')).VersionInfo.FileVersion
        Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
            Add-WindowsPackage -Path $mounted -PackagePath $ssu @common -LogLevel $Config.DismLogLevel | Out-Null
        }
        if ($safeOs) {
            Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
                Add-WindowsPackage -Path $mounted -PackagePath $safeOs @common -LogLevel $Config.DismLogLevel | Out-Null
            }
        }
        Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
            Repair-WindowsImage -Path $mounted -StartComponentCleanup -ResetBase:([bool]$Config.ResetBase) @common -LogLevel $Config.DismLogLevel | Out-Null
        }
        $winreKernel.Version = (Get-Item -LiteralPath (Join-Path -Path $mounted -ChildPath 'Windows\System32\ntoskrnl.exe')).VersionInfo.FileVersion
        if ($driverSet) { Install-WinMediaDriver -MountPath $mounted -Target 'WinRE' -DriverSet $driverSet -ForceUnsigned $forceUnsigned -Config $Config }
    } | Out-Null

    # 步驟 6：install.wim 各索引；WinRE 複製到每個索引（§3.2 step 5）
    # 選項 UpdateBootFiles 使用 _EX 開機檔時，$bootEx.Applied 為 $true，步驟 9 據此跳過 WinPE 的開機管理員覆寫（每個目標檔只有一個來源）
    $bootEx = @{ Applied = $false }
    # 第一個目標索引的 ntoskrnl 版本，供步驟 9 的守衛比對（LCU 未套用到開機索引時會被發現）
    $installKernel = @{ Version = $null }
    # 第一個目標索引的建置資訊（SOFTWARE hive：CurrentBuild、UBR、DisplayVersion、BuildBranch），供步驟 11 組 ISO 檔名；讀取失敗時保持 $null
    $buildInfo = @{ Info = $null }
    # Step 12c-3b：MountParallelCount 大於 1 時改走平行路徑；1 維持下方的序列迴圈
    $parallelCount = Get-WinMediaParallelCount -Requested ([int]$Config.MountParallelCount) -TargetCount $targets.Count
    if ($parallelCount -gt 1) {
        $parallelConfig = @{}
        foreach ($k in $Config.Keys) { $parallelConfig[$k] = $Config[$k] }
        $parallelConfig['MountDir'] = $mountDir
        $baseJob = @{ mountSwitches = $mountSwitches; Config = $parallelConfig; ssu = $ssu; lcuStage = $lcuStage; langFod = $langFod; dotNet = $dotNet; appxList = $appxList; storeSet = $storeSet; lxpItems = $lxpItems; driverSet = $driverSet; forceUnsigned = $forceUnsigned; resetBaseOS = $resetBaseOS; common = $common; winreWim = $winreWim }
        $parallelDir = Join-Path -Path $workDir -ChildPath 'parallel'
        # 登記前先守衛：來源或成品位於平行目錄之內時，登記的清空會刪除它們（與 L196、L202 同理）
        if (Test-PathWithin -Child $SourceIso -Parent $parallelDir) { throw "來源映像位於平行工作目錄之內，會被清空：$SourceIso" }
        if (Test-PathWithin -Child $Config.OutputDir -Parent $parallelDir) { throw "OutputDir 位於平行工作目錄之內，會被清空：$($Config.OutputDir)" }
        if (Test-PathWithin -Child $mountDir -Parent $parallelDir) { throw "MountDir 位於平行工作目錄之內，會被清空：$mountDir" }
        if (Test-PathWithin -Child $Config.LogDir -Parent $parallelDir) { throw "LogDir 位於平行工作目錄之內，會被清空：$($Config.LogDir)" }
        if (Test-PathWithin -Child $Config.LogFile -Parent $parallelDir) { throw "LogFile 位於平行工作目錄之內，會被清空：$($Config.LogFile)" }
        if (Test-PathWithin -Child $Config.OperationLog -Parent $parallelDir) { throw "OperationLog 位於平行工作目錄之內，會被清空：$($Config.OperationLog)" }
        if ($Config.ContainsKey('ScratchDirectory') -and -not [string]::IsNullOrWhiteSpace($Config.ScratchDirectory) -and (Test-PathWithin -Child $Config.ScratchDirectory -Parent $parallelDir)) { throw "ScratchDirectory 位於平行工作目錄之內，會被清空：$($Config.ScratchDirectory)" }
        Invoke-WinMediaOperation -Category File -Operation 'UseWorkDir' -Target $parallelDir -Config $Config -ScriptBlock {
            Use-WinMediaWorkDir -Path $parallelDir
        } | Out-Null
        Invoke-WinMediaParallelInstall -InstallWim $installWim -AllIndexes $indexes -Targets $targets -ParallelRoot $parallelDir -MountDir $mountDir -BaseJob $baseJob -Config $parallelConfig -SourcesDir $sourcesDir -MediaDir $mediaDir -MaxConcurrent $parallelCount -InstallKernel $installKernel -BuildInfo $buildInfo -BootEx $bootEx -IsEsdSource:([bool]$isEsdSource)
    }
    else {
    foreach ($index in $targets) {
        Mount-WinMediaImage -ImagePath $installWim -Index $index -MountPath (Join-Path -Path $mountDir -ChildPath ('install-{0}' -f $index)) @mountSwitches -Config $Config -Action {
            param($mounted)
        Invoke-WinMediaInstallIndexUpdate -mounted $mounted -ssu $ssu -lcuStage $lcuStage -langFod $langFod -dotNet $dotNet -appxList $appxList -storeSet $storeSet -lxpItems $lxpItems -driverSet $driverSet -forceUnsigned $forceUnsigned -resetBaseOS $resetBaseOS -common $common -IsFirstTarget:($index -eq $targets[0]) -sourcesDir $sourcesDir -winreWim $winreWim -isEsdSource:$isEsdSource -mediaDir $mediaDir -Config $Config -installKernel $installKernel -buildInfo $buildInfo -bootEx $bootEx
        } | Out-Null
    }
    }

    # 步驟 7：虛擬版本（§2.7.4）；從已更新的 EnterpriseS 索引建立
    if ($virtualEditions.Count -gt 0) {
        foreach ($edition in $virtualEditions) {
            Add-WinMediaVirtualEdition -ImagePath $installWim -Index $ltscIndex.ImageIndex -MountPath (Join-Path -Path $mountDir -ChildPath 'virtual') -Edition $edition -Config $Config | Out-Null
        }
    }

    # 步驟 8–9 需要媒體樹（Setup DU、boot.wim），.esd 來源略過
    if (-not $isEsdSource) {
    # 步驟 8（文件第 26 列）：Setup DU 先展開到暫存目錄，再依 convert-UUP 2349–2358 行的規則複製進 sources（只更新既有檔與既有語言）；其後的 setup.exe／setuphost.exe 由步驟 9 的 boot.wim 索引 2 同步覆蓋（第 27 列）；兩者的先後順序不可對調
    if ($setupDu) {
        $duDir = Join-Path -Path $workDir -ChildPath 'setupdu'
        [IO.Directory]::CreateDirectory($duDir) | Out-Null
        $expand = Invoke-WinMediaExternal -FilePath 'expand.exe' -ArgumentList @('-F:*', $setupDu, $duDir) -Config $Config
        if ($expand.ExitCode -ne 0) { throw "展開 Setup DU 失敗：$($expand.StdErr)" }
        Copy-WinMediaSetupDuFiles -ExpandedDir $duDir -SourcesDir $sourcesDir -Config $Config
        Remove-Item -LiteralPath $duDir -Recurse -Force
    }

    # convert-UUP 清單（已內建於 Config，來源為 uup-converter-wimlib\bin\bootwim.txt、bootmui.txt）
    $bootWimList = Join-Path -Path $PSScriptRoot -ChildPath '..\Config\bootwim.txt'
    $bootMuiList = Join-Path -Path $PSScriptRoot -ChildPath '..\Config\bootmui.txt'

    # 步驟 8.5：boot.wim 以已套用 SSU／SafeOS DU 的 WinRE 重建（convert-UUP 在 temp\winre.wim 更新後才複製為 boot.wim）；SafeOS 路線的 WinPE 核心由 SafeOS DU 決定；Lcu 路線以它為起點，再由步驟 9 的 LCU 決定；未更新的副本會停在 9444
    $archName = if ($architecture -in 'amd64', 'x64') { 'x64' } else { $architecture }
    New-WinMediaBootWimFromWinRE -WinreWim $winreWim -BootWim $bootWim -MediaDir $mediaDir -ArchName $archName -Config $Config

    # 步驟 9：boot.wim 索引 1 與 2（§3.2 step 7、8）
    foreach ($bootIndex in 1, 2) {
        Mount-WinMediaImage -ImagePath $bootWim -Index $bootIndex -MountPath (Join-Path -Path $mountDir -ChildPath ('boot-{0}' -f $bootIndex)) @mountSwitches -Config $Config -Action {
            param($mounted)
            # 不單獨加入 SSU：獨立加入的 SSU 會被暫停（pended），其後的 LCU 會被略過、CBS 停留在 9441；LCU 套件本身已含 SSU（實測單獨加入即升至 9711）
            # 直接套用目標 LCU msu（資料夾模式會先處理較舊的 checkpoint msu，實測 KB5043080 回 0x80070228）
            # Lcu 路線以目標 MSU 檔案路徑直接加入（非資料夾模式）；MSU 所在資料夾必須同時有目標 LCU 的 checkpoint，否則 Add 可能靜默失敗（full2 實測 Add 後 ntoskrnl 仍為 9817），見 README。SafeOS 路線的核心版本由步驟 5 的 SafeOS DU 提供
            if ($Config.WinPEUpdate -eq 'Lcu') {
                $lcuBefore = (Get-Item -LiteralPath (Join-Path -Path $mounted -ChildPath 'Windows\System32\ntoskrnl.exe')).VersionInfo.FileVersion
                Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
                    Add-WindowsPackage -Path $mounted -PackagePath $cumulative.Target @common -LogLevel $Config.DismLogLevel | Out-Null
                }
            }
            Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
                Repair-WindowsImage -Path $mounted -StartComponentCleanup @common -LogLevel $Config.DismLogLevel | Out-Null
            }
            $bootKernel = (Get-Item -LiteralPath (Join-Path -Path $mounted -ChildPath 'Windows\System32\ntoskrnl.exe')).VersionInfo.FileVersion
            if ($Config.WinPEUpdate -eq 'Lcu') { Test-WinMediaLcuApplied -BeforeKernel $lcuBefore -AfterKernel $bootKernel -InstallKernel $installKernel.Version -BootIndex $bootIndex }
            Test-WinMediaKernelConsistency -BootKernel $bootKernel -WinreKernel $winreKernel.Version -InstallKernel $installKernel.Version -WinreBaseKernel $winreKernel.Base -BootIndex $bootIndex
            if ($driverSet) { Install-WinMediaDriver -MountPath $mounted -Target 'Boot' -DriverSet $driverSet -ForceUnsigned $forceUnsigned -Config $Config }
            if ($bootIndex -eq 2) {
                # 第 28 列 boot manager：自 WinPE 覆蓋媒體上的同名檔案，須排在 setup／setuphost 覆蓋之後
                $winpeEfi = Join-Path -Path $mounted -ChildPath 'Windows\boot\efi'
                $bootmgfw = Join-Path -Path $winpeEfi -ChildPath 'bootmgfw.efi'
                $bootmgr = Join-Path -Path $winpeEfi -ChildPath 'bootmgr.efi'
                $bootStl = Join-Path -Path $winpeEfi -ChildPath 'boot.stl'
                # 選項 B 已套用 _EX 開機檔時整段跳過，避免 EX 版被 WinPE 的非 EX 檔覆蓋
                $bootTargets = if ($bootEx.Applied) { @() } else { @(Get-ChildItem -LiteralPath $mediaDir -Recurse -Force -File -Filter 'b*.efi') }
                foreach ($target in $bootTargets) {
                    if ($target.Name -in 'bootmgfw.efi', 'bootx64.efi', 'bootia32.efi', 'bootaa64.efi' -and (Test-Path -LiteralPath $bootmgfw)) {
                        Invoke-WinMediaOperation -Category File -Operation 'BootManager' -Target $target.FullName -Config $Config -ScriptBlock {
                            Copy-Item -LiteralPath $bootmgfw -Destination $target.FullName -Force
                        } | Out-Null
                    }
                    elseif ($target.Name -eq 'bootmgr.efi' -and (Test-Path -LiteralPath $bootmgr)) {
                        Invoke-WinMediaOperation -Category File -Operation 'BootManager' -Target $target.FullName -Config $Config -ScriptBlock {
                            Copy-Item -LiteralPath $bootmgr -Destination $target.FullName -Force
                        } | Out-Null
                    }
                }
                if (-not $bootEx.Applied -and (Test-Path -LiteralPath $bootStl)) {
                    Invoke-WinMediaOperation -Category File -Operation 'BootManager' -Target $bootStl -Config $Config -ScriptBlock {
                        Copy-Item -LiteralPath $bootStl -Destination (Join-Path -Path $mediaDir -ChildPath 'efi\microsoft\boot\boot.stl') -Force
                    } | Out-Null
                }
            }
        } | Out-Null
    }

    # 步驟 9 之後（兩個索引皆已卸載）：媒體 sources\ 以 wimlib update 覆蓋 WinPE 索引 2 的同名檔（convert-UUP boot-wim.txt；媒體 → WinPE，方向與 MS 文件第 27 列相反，見 README）
    # 放在 LCU 之後，避免 LCU 把這些檔案蓋回去
    $syncLanguages = Get-WinMediaEffectiveLanguage -MediaDir $mediaDir -Languages @($Config.Languages)
    Write-WinMediaLog -Config $Config -Level Info -Message ('WinPE 同步語言：{0}' -f ($syncLanguages -join ', '))
    Copy-WinMediaBootWimSources -MediaDir $mediaDir -WimPath $bootWim -Index 2 -WimListPath $bootWimList -MuiListPath $bootMuiList -Languages $syncLanguages -Config $Config
    # convert-UUP 1165 行：boot.wim 更新完成後刪除媒體 sources\xmllite.dll（參考成品的媒體根目錄沒有此檔）
    Remove-Item -LiteralPath (Join-Path -Path $sourcesDir -ChildPath 'xmllite.dll') -Force -ErrorAction SilentlyContinue

    # 步驟 9 之後：boot.wim export（--boot）與 optimize，對應 convert-UUP 的 wimlib export／optimize
    Compress-WinMediaBootWim -BootWim $bootWim -Config $Config

    }  # 結束：非 .esd 來源（步驟 8–9）
    # 步驟 10：移除來源 EnterpriseS（僅在設定開啟且已建立虛擬版本時，§2.7.6）
    if ($Config.DeleteSourceEdition -and $virtualEditions.Count -gt 0 -and $ltscIndex) {
        Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
            Remove-WindowsImage -ImagePath $installWim -Index $ltscIndex.ImageIndex @common -LogLevel $Config.DismLogLevel | Out-Null
        } | Out-Null
    }

    if (-not $isEsdSource) {
    # 步驟 10（續）：ei.cfg 必須在索引移除之後判斷（§2.7.5）
    $eiCfg = Join-Path -Path $sourcesDir -ChildPath 'ei.cfg'
    $userEiCfg = Join-Path -Path $Config.PackageDir -ChildPath 'ei.cfg'
    $finalCount = @(Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
        Get-WindowsImage -ImagePath $installWim @common -LogLevel $Config.DismLogLevel
    }).Count
    if ($finalCount -gt 1) {
        if (Test-Path -LiteralPath $userEiCfg) {
            Invoke-WinMediaOperation -Category File -Operation 'CopyUserEiCfg' -Target $eiCfg -Config $Config -ScriptBlock {
                Copy-Item -LiteralPath $userEiCfg -Destination $eiCfg -Force
            } | Out-Null
        }
        elseif (Test-Path -LiteralPath $eiCfg) {
            Invoke-WinMediaOperation -Category File -Operation 'RemoveEiCfg' -Target $eiCfg -Config $Config -ScriptBlock {
                Remove-Item -LiteralPath $eiCfg -Force
            } | Out-Null
        }
    }

    }  # 結束：非 .esd 來源（ei.cfg）
    # 檔名只在 Iso 與 Folder 需要，Image 不組名（避免 Image 執行時出現無關的「組 ISO 檔名失敗」警告）
    if ($plan.OutputForm -ne 'Image') {
    # 步驟 11：輸出形式（藍圖 F7）；檔名在任何 ESD 匯出移除 install.wim 之前組好，供 Iso 與 Folder 共用
    # 組檔名所需的建置資訊已在步驟 6 讀出；任何失敗只記警告並退回預設名稱，不中止整次執行
    $nameArgs = @{ Timestamp = (Get-Date -Format 'yyyyMMdd-HHmmss'); Arch = $architecture; Languages = @($syncLanguages) }
    try {
        $info = $buildInfo.Info
        if ($info) {
            $nameArgs.DisplayVersion = $info.DisplayVersion
            $nameArgs.Build = $info.CurrentBuild
            if ($null -ne $info.UBR) { $nameArgs.Revision = [string]$info.UBR }
            if ($info.BuildBranch) { $nameArgs.BranchUpper = ([string]$info.BuildBranch).ToUpperInvariant() }
        }
        if ($targets.Count -lt @($images).Count) { Write-WinMediaLog -Config $Config -Level Warning -Message ('只更新 {0}/{1} 個索引，檔名的建置號與 UBR 取自第一個目標索引，未更新的索引不含這些更新' -f $targets.Count, @($images).Count) }
        if ($finalCount -gt 1) { $nameArgs.Edition = 'CLIENTMULTI' }
        else {
            $edition = @(Get-WinMediaIndexInfo -ImagePath $installWim -Config $Config)[0].EditionId
            if ($edition) { $nameArgs.Edition = 'CLIENT' + ([string]$edition).ToUpperInvariant() }
        }
        $idwb = Join-Path -Path $sourcesDir -ChildPath 'idwbinfo.txt'
        if ((Test-Path -LiteralPath $idwb) -and ((Get-Content -LiteralPath $idwb -Raw) -match '(?m)^\s*BuildType\s*=\s*(\w+)')) { $nameArgs.BuildType = $Matches[1] }
        $isoName = New-WinMediaOutputName @nameArgs
    }
    catch {
        Write-WinMediaLog -Config $Config -Level Warning -Message ('組 ISO 檔名失敗，改用預設名稱：{0}' -f $_.Exception.Message)
        $isoName = 'WinMedia_{0}.iso' -f $nameArgs.Timestamp
    }
    }  # 結束：檔名（Iso／Folder）
    $isEsd = $Config.OutputFormat -eq 'ESD'
    switch ($plan.OutputForm) {
        'Iso' {
            $output = Join-Path -Path $Config.OutputDir -ChildPath $isoName
            if ((Test-Path -LiteralPath $output) -and -not $Force) {
                throw "輸出已存在：$output（使用 -Force 覆寫，§3.3）"
            }
            # 開機檔依架構不同：x64 有 BIOS（etfsboot.com）與 UEFI（efisys.bin）；ARM64 媒體只有 UEFI，沒有 etfsboot.com
            # 所有失敗檢查都在 ESD 匯出（會移除 install.wim）與 oscdimg 之前完成
            $efiBoot = Join-Path -Path $mediaDir -ChildPath 'efi\microsoft\boot\efisys.bin'
            if (-not (Test-Path -LiteralPath $efiBoot)) { throw "找不到 UEFI 開機檔：$efiBoot（媒體目錄可能不完整）" }
            if ($architecture -eq 'arm64') {
                $bootData = '-bootdata:1#pEF,e,b"{0}"' -f $efiBoot
            }
            else {
                $biosBoot = Join-Path -Path $mediaDir -ChildPath 'boot\etfsboot.com'
                if (-not (Test-Path -LiteralPath $biosBoot)) { throw "找不到 BIOS 開機檔：$biosBoot（媒體目錄可能不完整）" }
                $bootData = '-bootdata:2#p0,e,b"{0}"#pEF,e,b"{1}"' -f $biosBoot, $efiBoot
            }
            # ESD 來源 WIM 只在 WorkDir 內轉成 install.esd；Keel 驗證映像數後才移除 install.wim，不寫到 OutputDir
            if ($isEsd) { Export-WinMediaEsd -SourceWim $installWim -DestinationEsd $installEsd -Config $Config }
            # -o：去除重複檔案，與 convert-UUP 的 oscdimg 參數一致（對應參考腳本 convert-UUP.cmd 的 oscdimg 參數）
            $burn = Invoke-WinMediaExternal -FilePath $oscdimg -ArgumentList @($bootData, '-o', '-u2', '-udfver102', '-m', $mediaDir, $output) -Config $Config
            if ($burn.ExitCode -ne 0) {
                throw "oscdimg 失敗，結束碼 $($burn.ExitCode)：$($burn.StdErr)"
            }
        }
        'Folder' {
            $output = Join-Path -Path $Config.OutputDir -ChildPath ($isoName -replace '\.iso$', '')
            # 不覆寫既有資料夾，即使指定 -Force（與 ISO 不同；刪除遞迴目錄的風險較高，見 Assert-WinMediaNoReparsePoint）
            if (Test-Path -LiteralPath $output) {
                throw "輸出資料夾已存在：$output（Folder 形式不覆寫既有資料夾，請改用其他 OutputDir 或刪除後重試）"
            }
            if ($isEsd) { Export-WinMediaEsd -SourceWim $installWim -DestinationEsd $installEsd -Config $Config }
            Invoke-WinMediaOperation -Category File -Operation 'CopyMedia' -Target $output -Config $Config -ScriptBlock {
                Copy-Item -LiteralPath $mediaDir -Destination $output -Recurse
            } | Out-Null
        }
        'Image' {
            if ($isEsd) {
                $output = Join-Path -Path $Config.OutputDir -ChildPath 'install.esd'
                if ((Test-Path -LiteralPath $output) -and -not $Force) {
                    throw "輸出已存在：$output（使用 -Force 覆寫，§3.3）"
                }
                Export-WinMediaEsd -SourceWim $installWim -DestinationEsd $output -Config $Config
            }
            else {
                $output = Join-Path -Path $Config.OutputDir -ChildPath 'install.wim'
                if ((Test-Path -LiteralPath $output) -and -not $Force) {
                    throw "輸出已存在：$output（使用 -Force 覆寫，§3.3）"
                }
                Invoke-WinMediaOperation -Category File -Operation 'MoveImage' -Target $output -Config $Config -ScriptBlock {
                    Move-Item -LiteralPath $installWim -Destination $output -Force:$Force
                } | Out-Null
            }
        }
        default { throw "不支援的 OutputForm：$($plan.OutputForm)" }
    }

    # 步驟 12：成功後才清除工作子目錄；logs 保留
    # 單一目錄刪不掉只記警告，其餘目錄照常清除；ISO 已完成，不因清理失敗而報錯
    foreach ($dir in @($mediaDir, $winreDir, $expandDir, $lxpDir, $stageDir)) {
        Remove-WinMediaCleanupDir -Path $dir -Config $Config -Confirm:$false
    }
    if ($mountDirCreated -and (Test-Path -LiteralPath $mountDir)) {
        Remove-WinMediaCleanupDir -Path $mountDir -Config $Config -Remove { param($p) Remove-Item -LiteralPath $p -Recurse -Force } -Confirm:$false
    }

    Write-WinMediaLog -Config $Config -Level Info -Message "完成：$output"
    return $output
    }
    finally {
        # 沒有新增任何排除時不碰狀態檔（可能是上次未還原成功而保留的）
        if (@($defenderAdded).Count -gt 0) { Remove-WinMediaDefenderExclusion -Path $defenderAdded -StatePath $defenderState -Confirm:$false }
    }
}
