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
        [ValidateSet('Errors', 'Warnings', 'WarningsInfo', 'Debug')][string]$DismLogLevel
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
        '9 boot.wim 索引 1、2：WinPEUpdate 為 Lcu 時套用最新 LCU（含 checkpoint；SafeOS 路線跳過）→ cleanup → 驅動（若設定，Boot 目標）；索引 2 內 boot manager 覆蓋媒體（第 28 列；選項 UpdateBootFiles 已套用 _EX 開機檔時跳過）；兩個索引卸載後，以 wimlib update 把媒體 sources\ 覆蓋 WinPE 索引 2 的同名檔（convert-UUP bootwim.txt／bootmui.txt，方向與 MS 文件第 27 列相反）；最後 boot.wim 做 export（保留可開機索引）與 optimize',
        '10 移除來源 EnterpriseS（僅 DeleteSourceEdition 且已建立虛擬版本）後，依 §2.7.5 處理 ei.cfg',
        '11 輸出：oscdimg 雙開機 ISO 或 install.esd（寫入 OutputDir）',
        '12 成功後清除 WorkDir 下的 media、winre、expand；MountDir 若由本次建立則一併清除；logs 保留'
    )
    if (-not $PSCmdlet.ShouldProcess($SourceIso, '更新 Windows 安裝媒體')) {
        return $steps
    }

    # 參數覆寫設定檔；LogDir 與 OperationLog 跟隨 WorkDir
    $Config = $Config.Clone()
    # 自訂設定檔可能沒有此鍵；缺少時採預設路線 SafeOS（驗證不接受 $null）
    if (-not $Config.ContainsKey('WinPEUpdate')) { $Config.WinPEUpdate = 'SafeOS' }
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
    if ($MountDir) { $Config.MountDir = $MountDir }
    if ($OutputDir) { $Config.OutputDir = $OutputDir }
    if ($PSBoundParameters.ContainsKey('DismLogLevel')) { $Config.DismLogLevel = $DismLogLevel }
    # 舊設定檔缺 DismLogLevel 時補預設並驗證（規則集中在 Keel 的 Resolve-WinMediaDismLogLevel）
    $Config.DismLogLevel = Resolve-WinMediaDismLogLevel -Config $Config
    $Config.MountDir = Resolve-WinMediaMountDir -WorkDir $Config.WorkDir -MountDir $Config.MountDir
    # 空白 = 工具所在磁碟根目錄\WinMediaOut（與 WorkDir 並列，不在 OneDrive 內，不受第 12 步清理影響）
    if ([string]::IsNullOrWhiteSpace($Config.OutputDir)) {
        $Config.OutputDir = Join-Path -Path ([System.IO.Path]::GetPathRoot($PSScriptRoot)) -ChildPath 'WinMediaOut'
    }
    # 巢狀設定 Clone 為淺複製；補齊輸入路徑前先複製，避免改到呼叫端的設定
    $Config.Drivers = $Config.Drivers.Clone()
    $Config.Lxp = $Config.Lxp.Clone()
    $Config.Apps = $Config.Apps.Clone()
    $Config.Lang = $Config.Lang.Clone()
    $Config.Fod = $Config.Fod.Clone()
    $Config.StoreApps = $Config.StoreApps.Clone()
    Resolve-WinMediaInputPath -RootDir $script:ModuleRoot -Config $Config

    # 步驟 1：前置檢查
    $principal = New-Object -TypeName Security.Principal.WindowsPrincipal -ArgumentList ([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw '需要系統管理員權限。'
    }
    # Defender 排除（選項 DefenderExclusions）：開工前加入工作目錄，finally 只還原本次新增的項目
    $defenderAdded = @()
    if ($Config.ContainsKey('DefenderExclusions') -and $Config.DefenderExclusions) {
        $defenderAdded = Add-WinMediaDefenderExclusion -Path @($Config.WorkDir, $Config.MountDir, $Config.OutputDir)
    }
    try {
    $oneDrive = [string]$env:OneDrive
    if ($oneDrive) {
        if (Test-PathWithin -Child $Config.WorkDir -Parent $oneDrive) {
            throw 'WorkDir 位於 OneDrive 內，請改用其他路徑（見 Config/Default.psd1）。'
        }
        if (Test-PathWithin -Child $Config.MountDir -Parent $oneDrive) {
            throw 'MountDir 位於 OneDrive 內，掛載點不可由同步服務鎖定，請改用其他路徑。'
        }
    }
    if (-not (Test-Path -LiteralPath $SourceIso -PathType Leaf)) {
        throw "找不到母檔：$SourceIso"
    }
    if (-not (Test-Path -LiteralPath $Config.PackageDir -PathType Container)) {
        throw "找不到更新包資料夾：$($Config.PackageDir)"
    }
    Test-WinMediaPathOverlap -Paths @{ PackageDir = $Config.PackageDir; WorkDir = $Config.WorkDir; Drivers = $Config.Drivers.Path; Lxp = $Config.Lxp.Path; Lang = $Config.Lang.Path; Fod = $Config.Fod.Path; StoreApps = $Config.StoreApps.Path }
    $driverSet = Resolve-WinMediaDriverSet -Path $Config.Drivers.Path -Config $Config
    $forceUnsigned = [bool]$Config.Drivers.ForceUnsigned
    $appxList = Resolve-WinMediaAppxList -Path $Config.Apps.CustomAppsList -Mode $Config.Apps.CustomListMode -Config $Config
    $langFod = Resolve-WinMediaLangFodSet -LangPath $Config.Lang.Path -FodPath $Config.Fod.Path -Config $Config
    $storeSet = Resolve-WinMediaStoreAppSet -Path $Config.StoreApps.Path -Config $Config
    # 步驟 9 之後的 boot.wim export／optimize 與 ESD 都需要 wimlib；先解析，離線環境在開始前就失敗
    Resolve-WinMediaWimlib -Config $Config | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($Config.Lxp.Path) -and -not (Test-Path -LiteralPath $Config.Lxp.Path -PathType Container)) {
        throw "找不到 LXP 資料夾：$($Config.Lxp.Path)"
    }
    if ($Config.WinPEUpdate -notin 'SafeOS', 'Lcu') { throw "不支援的 WinPEUpdate：$($Config.WinPEUpdate)" }
    $oscdimg = $null
    switch ($Config.OutputFormat) {
        'WIM' { $oscdimg = Resolve-WinMediaOscdimg -Config $Config }
        'ESD' { $null = Resolve-WinMediaWimlib -Config $Config }
        default { throw "不支援的 OutputFormat：$($Config.OutputFormat)" }
    }
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

    # 掛載目錄若已存在且非空，直接中止，不像 Convert-UUP.cmd:1060 那樣 rmdir 既有目錄
    if ((Test-Path -LiteralPath $mountDir) -and @(Get-ChildItem -LiteralPath $mountDir -Force).Count -gt 0) {
        throw "掛載目錄已存在且非空：$mountDir（請指定空目錄或刪除後重試）。"
    }
    $mountDirCreated = -not (Test-Path -LiteralPath $mountDir)
    foreach ($dir in @($workDir, $mediaDir, $winreDir, $mountDir, $expandDir, $lxpDir, $Config.LogDir, $Config.OutputDir)) {
        if (-not (Test-Path -LiteralPath $dir)) {
            Invoke-WinMediaOperation -Category File -Operation 'CreateDirectory' -Target $dir -Config $Config -ScriptBlock {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            } | Out-Null
        }
    }
    $lxpItems = @(Resolve-WinMediaLxp -Path $Config.Lxp.Path -TempDir $lxpDir -Config $Config)

    Write-WinMediaLog -Config $Config -Level Info -Message "開始更新：$SourceIso"
    if (@($Config.Languages).Count -gt 0) {
        Write-WinMediaLog -Config $Config -Level Info -Message "語言包 $(@($langFod.LangPacks).Count) 個、FoD $(@($langFod.Fod).Count) 個（依 Languages 篩選，於 LCU 之後注入）。"
    }

    # 步驟 2：掛載母檔（唯讀）並複製；母檔不修改（§3.3）
    $iso = Mount-DiskImage -ImagePath $SourceIso -StorageType ISO -PassThru
    try {
        $driveLetter = ($iso | Get-Volume).DriveLetter
        if (-not $driveLetter) { throw '無法取得 ISO 的磁碟機代號。' }
        $isoRoot = '{0}:\' -f $driveLetter
        Invoke-WinMediaOperation -Category File -Operation 'CopyMedia' -Target $mediaDir -Config $Config -ScriptBlock {
            Copy-Item -Path (Join-Path -Path $isoRoot -ChildPath '*') -Destination $mediaDir -Recurse -Force
        } | Out-Null
    }
    finally {
        Dismount-DiskImage -ImagePath $SourceIso | Out-Null
    }
    Get-ChildItem -LiteralPath $mediaDir -Recurse -Force -File | ForEach-Object { $_.IsReadOnly = $false }
    # 步驟 2 之後、2a 之前：移除未選取的額外語言（先於步驟 8 的 Setup DU，使 /U 規則不會把它們建回來）
    Remove-WinMediaExtraLanguage -MediaDir $mediaDir -Languages @($Config.Languages) -Config $Config

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
    $cumulative = if ($buildSet) { [pscustomobject]@{ Target = $buildSet.Target; Checkpoints = @($buildSet.Checkpoints) } } else { Resolve-WinMediaCumulativeSet -Paths @($candidates) -Config $Config }
    if (-not $cumulative) { throw '缺少最新 LCU（PackageDir 內沒有 .msu 累積更新）。' }
    if ($downloaded.Count -eq 0 -and @($cumulative.Checkpoints).Count -gt 0) {
        Write-WinMediaLog -Config $Config -Level Warning -Message ('PackageDir 內有較舊的累積更新，將視為前置 checkpoint：' + (($cumulative.Checkpoints | ForEach-Object { Split-Path -Path $_ -Leaf }) -join ', ') + '。建議只保留目標與其 checkpoint。')
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
    $ssu = @($categories.SSU | Where-Object { $_ -like "*\$escapedTarget\*" }) | Select-Object -First 1
    if (-not $ssu) {
        if ($buildSet) { throw '目標累積更新內找不到 SSU（Build 路徑不回退至 PackageDir 內的舊 SSU）。' }
        $ssu = $categories.SSU | Select-Object -First 1
        Write-WinMediaLog -Config $Config -Level Warning -Message '目標累積更新內找不到 SSU，改用 PackageDir 內第一個 SSU。'
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

    Mount-WinMediaImage -ImagePath $winreWim -Index 1 -MountPath (Join-Path -Path $mountDir -ChildPath 'winre') -Config $Config -Action {
        param($mounted)
        Write-WinMediaLog -Config $Config -Level Verbose -Message "WinRE 掛載點：$mounted"
        Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
            Add-WindowsPackage -Path $mounted -PackagePath $ssu -LogLevel $Config.DismLogLevel | Out-Null
        }
        if ($safeOs) {
            Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
                Add-WindowsPackage -Path $mounted -PackagePath $safeOs -LogLevel $Config.DismLogLevel | Out-Null
            }
        }
        Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
            Repair-WindowsImage -Path $mounted -StartComponentCleanup -ResetBase:([bool]$Config.ResetBase) -LogLevel $Config.DismLogLevel | Out-Null
        }
        if ($driverSet) { Install-WinMediaDriver -MountPath $mounted -Target 'WinRE' -DriverSet $driverSet -ForceUnsigned $forceUnsigned -Config $Config }
    } | Out-Null

    # 步驟 6：install.wim 各索引；WinRE 複製到每個索引（§3.2 step 5）
    # 選項 UpdateBootFiles 使用 _EX 開機檔時，$bootEx.Applied 為 $true，步驟 9 據此跳過 WinPE 的開機管理員覆寫（每個目標檔只有一個來源）
    $bootEx = @{ Applied = $false }
    # 第一個目標索引的 ntoskrnl 版本，供步驟 9 的守衛比對（LCU 未套用到開機索引時會被發現）
    $installKernel = @{ Version = $null }
    foreach ($index in $targets) {
        Mount-WinMediaImage -ImagePath $installWim -Index $index -MountPath (Join-Path -Path $mountDir -ChildPath ('install-{0}' -f $index)) -Config $Config -Action {
            param($mounted)
            Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
                Add-WindowsPackage -Path $mounted -PackagePath $ssu -LogLevel $Config.DismLogLevel | Out-Null
            }
            # 文件步驟 10–11：語言包與 FoD 必須在最新 LCU 之前注入
            Install-WinMediaLangFod -MountPath $mounted -Set $langFod -Config $Config
            # 文件步驟 13：最新 LCU（連同前置 checkpoint，經暫存資料夾）
            Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
                Add-WindowsPackage -Path $mounted -PackagePath $lcuStage -LogLevel $Config.DismLogLevel | Out-Null
            }
            # 文件步驟 14：cleanup；CBS_E_PENDING（0x800F0806）只警告，其他錯誤照常中止（Mount-WinMediaImage 失敗時會 Discard）
            try {
                Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
                    Repair-WindowsImage -Path $mounted -StartComponentCleanup -LogLevel $Config.DismLogLevel | Out-Null
                } | Out-Null
            }
            catch {
                if ($_.Exception.HResult -ne -2146498554 -and $_.Exception.Message -notmatch '0x800f0806') { throw }
                Write-WinMediaLog -Config $Config -Level Warning -Message 'install.wim cleanup 有待處理作業（0x800F0806），略過本次 cleanup；需開機完成後再處理。'
            }
            # 文件步驟 15：NetFx3 必須在 cleanup 之後、.NET CU 之前
            Install-WinMediaDeferredFod -MountPath $mounted -Set $langFod -Config $Config
            if ($dotNet) {
                Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
                    Add-WindowsPackage -Path $mounted -PackagePath $dotNet -LogLevel $Config.DismLogLevel | Out-Null
                }
            }
            if ($appxList) { Remove-WinMediaAppx -MountPath $mounted -AppxList $appxList -Config $Config }
            Install-WinMediaStoreApp -MountPath $mounted -Set $storeSet -Config $Config
            if ($lxpItems.Count -gt 0) { Install-WinMediaLxp -MountPath $mounted -Lxp $lxpItems -Config $Config }
            if ($driverSet) { Install-WinMediaDriver -MountPath $mounted -Target 'Install' -DriverSet $driverSet -ForceUnsigned $forceUnsigned -Config $Config }
            if ($index -eq $targets[0]) { $installKernel.Version = (Get-Item -LiteralPath (Join-Path -Path $mounted -ChildPath 'Windows\System32\ntoskrnl.exe')).VersionInfo.FileVersion }
            # 媒體 sources\xmllite.dll 取自第一個目標索引、已套用 LCU 的版本（convert-UUP 取自 metadata ESD 索引 3，此處沒有該來源）
            if ($index -eq $targets[0]) {
                Invoke-WinMediaOperation -Category File -Operation 'CopyXmlLite' -Target $sourcesDir -Config $Config -ScriptBlock {
                    Copy-Item -LiteralPath (Join-Path -Path $mounted -ChildPath 'Windows\System32\xmllite.dll') -Destination (Join-Path -Path $sourcesDir -ChildPath 'xmllite.dll') -Force
                } | Out-Null
            }
            Invoke-WinMediaOperation -Category File -Operation 'ReplaceWinRE' -Target $mounted -Config $Config -ScriptBlock {
                Copy-Item -LiteralPath $winreWim -Destination (Join-Path -Path $mounted -ChildPath 'Windows\System32\Recovery\winre.wim') -Force
            } | Out-Null
            # 文件步驟之後（convert-UUP 3895–3930 行）：最後執行，使開機檔取自已套用 LCU 的映像
            # 缺鍵時視為開啟（預設開）；StrictMode 下直接讀取缺少的鍵會拋錯，因此先用 ContainsKey
            if (-not $Config.ContainsKey('UpdateBootFiles') -or $Config.UpdateBootFiles) { $bootEx.Applied = Copy-WinMediaUpdatedBootFiles -MountPath $mounted -MediaDir $mediaDir -Config $Config }
        } | Out-Null
    }

    # 步驟 7：虛擬版本（§2.7.4）；從已更新的 EnterpriseS 索引建立
    if ($virtualEditions.Count -gt 0) {
        foreach ($edition in $virtualEditions) {
            Add-WinMediaVirtualEdition -ImagePath $installWim -Index $ltscIndex.ImageIndex -MountPath (Join-Path -Path $mountDir -ChildPath 'virtual') -Edition $edition -Config $Config | Out-Null
        }
    }

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

    # 步驟 8.5：boot.wim 以已套用 SSU／SafeOS DU 的 WinRE 重建（convert-UUP 在 temp\winre.wim 更新後才複製為 boot.wim）；WinPE 核心版本由 SafeOS DU 決定，未更新的副本會停在 9444
    $archName = if ($architecture -in 'amd64', 'x64') { 'x64' } else { $architecture }
    New-WinMediaBootWimFromWinRE -WinreWim $winreWim -BootWim $bootWim -MediaDir $mediaDir -ArchName $archName -Config $Config

    # 步驟 9：boot.wim 索引 1 與 2（§3.2 step 7、8）
    foreach ($bootIndex in 1, 2) {
        Mount-WinMediaImage -ImagePath $bootWim -Index $bootIndex -MountPath (Join-Path -Path $mountDir -ChildPath ('boot-{0}' -f $bootIndex)) -Config $Config -Action {
            param($mounted)
            # 不單獨加入 SSU：獨立加入的 SSU 會被暫停（pended），其後的 LCU 會被略過、CBS 停留在 9441；LCU 套件本身已含 SSU（實測單獨加入即升至 9711）
            # 直接套用目標 LCU msu（資料夾模式會先處理較舊的 checkpoint msu，實測 KB5043080 回 0x80070228）
            # 只有 Lcu 路線在此以原始 MSU 直接加入 LCU；實測 DISM 判定 Not applicable（無效果），SafeOS 路線的核心版本由步驟 5 的 SafeOS DU 提供
            if ($Config.WinPEUpdate -eq 'Lcu') {
                Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
                    Add-WindowsPackage -Path $mounted -PackagePath $cumulative.Target -LogLevel $Config.DismLogLevel | Out-Null
                }
            }
            Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
                Repair-WindowsImage -Path $mounted -StartComponentCleanup -LogLevel $Config.DismLogLevel | Out-Null
            }
            # 守衛：開機索引的 ntoskrnl 必須與安裝映像一致（只比核心版本，無法區分 SafeOS DU 與 LCU 是否套用）；不一致時中止
            $bootKernel = (Get-Item -LiteralPath (Join-Path -Path $mounted -ChildPath 'Windows\System32\ntoskrnl.exe')).VersionInfo.FileVersion
            if ($bootKernel -ne $installKernel.Version) { throw "boot.wim 索引 $bootIndex 的 ntoskrnl 版本 $bootKernel 與安裝映像 $($installKernel.Version) 不一致（WinPEUpdate=$($Config.WinPEUpdate)）。" }
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

    # 步驟 10：移除來源 EnterpriseS（僅在設定開啟且已建立虛擬版本時，§2.7.6）
    if ($Config.DeleteSourceEdition -and $virtualEditions.Count -gt 0 -and $ltscIndex) {
        Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
            Remove-WindowsImage -ImagePath $installWim -Index $ltscIndex.ImageIndex -LogLevel $Config.DismLogLevel | Out-Null
        } | Out-Null
    }

    # 步驟 10（續）：ei.cfg 必須在索引移除之後判斷（§2.7.5）
    $eiCfg = Join-Path -Path $sourcesDir -ChildPath 'ei.cfg'
    $userEiCfg = Join-Path -Path $Config.PackageDir -ChildPath 'ei.cfg'
    $finalCount = @(Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
        Get-WindowsImage -ImagePath $installWim -LogLevel $Config.DismLogLevel
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

    # 步驟 11：輸出；ESD 寫入 OutputDir（不留在 WorkDir），ISO 以 oscdimg 產生
    if ($Config.OutputFormat -eq 'ESD') {
        $output = Join-Path -Path $Config.OutputDir -ChildPath 'install.esd'
        if ((Test-Path -LiteralPath $output) -and -not $Force) {
            throw "輸出已存在：$output（使用 -Force 覆寫，§3.3）"
        }
        Export-WinMediaEsd -SourceWim $installWim -DestinationEsd $output -Config $Config
    }
    else {
        $output = Join-Path -Path $Config.OutputDir -ChildPath ('WinMedia_{0}.iso' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        if ((Test-Path -LiteralPath $output) -and -not $Force) {
            throw "輸出已存在：$output（使用 -Force 覆寫，§3.3）"
        }
        # 開機檔依架構不同：x64 有 BIOS（etfsboot.com）與 UEFI（efisys.bin）；ARM64 媒體只有 UEFI，沒有 etfsboot.com
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
        # -o：去除重複檔案，與 convert-UUP 的 oscdimg 參數一致（對應參考腳本 convert-UUP.cmd 的 oscdimg 參數）
        $burn = Invoke-WinMediaExternal -FilePath $oscdimg -ArgumentList @($bootData, '-o', '-u2', '-udfver102', '-m', $mediaDir, $output) -Config $Config
        if ($burn.ExitCode -ne 0) {
            throw "oscdimg 失敗，結束碼 $($burn.ExitCode)：$($burn.StdErr)"
        }
    }

    # 步驟 12：成功後才清除工作子目錄；logs 保留
    $cleanupDirs = @($mediaDir, $winreDir, $expandDir, $lxpDir, $stageDir)
    if ($mountDirCreated) { $cleanupDirs += $mountDir }
    foreach ($dir in $cleanupDirs) {
        if (Test-Path -LiteralPath $dir) {
            Invoke-WinMediaOperation -Category File -Operation 'RemoveWorkDir' -Target $dir -Config $Config -ScriptBlock {
                Remove-Item -LiteralPath $dir -Recurse -Force
            } | Out-Null
        }
    }

    Write-WinMediaLog -Config $Config -Level Info -Message "完成：$output"
    return $output
    }
    finally {
        Remove-WinMediaDefenderExclusion -Path $defenderAdded
    }
}
