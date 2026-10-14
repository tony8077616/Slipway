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
        [string]$OutputDir
    )

    $steps = @(
        '1 前置檢查（管理員、PowerShell 版本、WorkDir 不在 OneDrive、輸出工具、DISM 來源）',
        '2 掛載母檔（唯讀）並複製到 WorkDir\media',
        '2a 若有 install.esd，轉為 install.wim',
        '3 偵測 build 與索引',
        '4 分類 PackageDir（缺 SSU 或 LCU 即中止；合併 CU 同時供應 LCU 與 SSU）',
        '4a 虛擬版本條件（§2.7.1、§2.7.7）',
        '5 WinRE：取索引 1 的 winre.wim → SSU → SafeOS DU（若有）→ cleanup（不套 LCU，§11.8 2a）',
        '6 install.wim 各索引：SSU → cleanup → .NET CU → 最新 LCU → 放入 WinRE',
        '7 虛擬版本（僅來源為 EnterpriseS 且在 Indexes 目標內；§2.7.4）',
        '8 boot.wim 索引 1、2：SSU → 最新 LCU → cleanup；索引 2 取出 setup.exe、setuphost.exe',
        '9 展開 Setup DU 到媒體',
        '10 移除來源 EnterpriseS（僅 DeleteSourceEdition 且已建立虛擬版本）後，依 §2.7.5 處理 ei.cfg',
        '11 輸出：oscdimg 雙開機 ISO 或 install.esd（寫入 OutputDir）',
        '12 成功後清除 WorkDir 下的 media、winre、expand；MountDir 若由本次建立則一併清除；logs 保留'
    )
    if (-not $PSCmdlet.ShouldProcess($SourceIso, '更新 Windows 安裝媒體')) {
        return $steps
    }

    # 參數覆寫設定檔；LogDir 與 OperationLog 跟隨 WorkDir
    $Config = $Config.Clone()
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
    $Config.MountDir = Resolve-WinMediaMountDir -WorkDir $Config.WorkDir -MountDir $Config.MountDir
    if ([string]::IsNullOrWhiteSpace($Config.OutputDir)) { $Config.OutputDir = $Config.WorkDir }

    # 步驟 1：前置檢查
    $principal = New-Object -TypeName Security.Principal.WindowsPrincipal -ArgumentList ([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw '需要系統管理員權限。'
    }
    $oneDrive = [string]$env:OneDrive
    if ($oneDrive) {
        $oneDriveRoot = $oneDrive.TrimEnd('\') + '\'
        if (($Config.WorkDir.TrimEnd('\') + '\').StartsWith($oneDriveRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'WorkDir 位於 OneDrive 內，請改用其他路徑（見 Config/Default.psd1）。'
        }
        if (($Config.MountDir.TrimEnd('\') + '\').StartsWith($oneDriveRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'MountDir 位於 OneDrive 內，掛載點不可由同步服務鎖定，請改用其他路徑。'
        }
    }
    if (-not (Test-Path -LiteralPath $SourceIso -PathType Leaf)) {
        throw "找不到母檔：$SourceIso"
    }
    if (-not (Test-Path -LiteralPath $Config.PackageDir -PathType Container)) {
        throw "找不到更新包資料夾：$($Config.PackageDir)"
    }
    $oscdimg = $null
    switch ($Config.OutputFormat) {
        'WIM' { $oscdimg = Resolve-WinMediaOscdimg -Config $Config }
        'ESD' {
            if ([string]::IsNullOrEmpty($Config.Wimlib.Path) -or -not (Test-Path -LiteralPath $Config.Wimlib.Path)) {
                throw 'OutputFormat 為 ESD，但 Wimlib.Path 未設定或找不到（§2.4）。'
            }
        }
        default { throw "不支援的 OutputFormat：$($Config.OutputFormat)" }
    }
    if ($Config.DismProvider -eq 'ADK') { $null = Resolve-WinMediaAdk -Config $Config }

    $workDir = $Config.WorkDir
    $mediaDir = Join-Path -Path $workDir -ChildPath 'media'
    $winreDir = Join-Path -Path $workDir -ChildPath 'winre'
    $mountDir = $Config.MountDir
    $expandDir = Join-Path -Path $workDir -ChildPath 'expand'
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
    foreach ($dir in @($workDir, $mediaDir, $winreDir, $mountDir, $expandDir, $Config.LogDir, $Config.OutputDir)) {
        if (-not (Test-Path -LiteralPath $dir)) {
            Invoke-WinMediaOperation -Category File -Operation 'CreateDirectory' -Target $dir -Config $Config -ScriptBlock {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            } | Out-Null
        }
    }

    Write-WinMediaLog -Config $Config -Level Info -Message "開始更新：$SourceIso"
    if (@($Config.Languages).Count -gt 0) {
        Write-WinMediaLog -Config $Config -Level Warning -Message '語言包與 FoD 尚未實作（§2.3），本次不會套用，見報告。'
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
    Get-ChildItem -LiteralPath $mediaDir -Recurse -Force | ForEach-Object { $_.IsReadOnly = $false }

    # 步驟 2a：install.esd → install.wim（§2.7.3）
    if (Test-Path -LiteralPath $installEsd) {
        Convert-WinMediaEsdToWim -SourceEsd $installEsd -DestinationWim $installWim -Config $Config
    }

    # 步驟 3：偵測 build 與索引
    if (-not (Test-Path -LiteralPath $installWim)) {
        throw '媒體中找不到 install.wim（若為 install.swm 分割檔，目前不支援）。'
    }
    $images = @(Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
        Get-WindowsImage -ImagePath $installWim
    })
    $build = [int]($images[0].Version.Split('.')[2])
    $indexes = @($images | ForEach-Object { $_.ImageIndex })
    $targets = if (@($Config.Indexes).Count -gt 0) { @($indexes | Where-Object { $Config.Indexes -contains $_ }) } else { $indexes }
    if ($targets.Count -eq 0) { throw '設定的 Indexes 與映像內索引皆不相符。' }
    Write-WinMediaLog -Config $Config -Level Info -Message "build=$build；索引：$($indexes -join ',')"

    # 步驟 4：分類；缺必要類別即中止（尚未修改任何映像）
    $categories = Get-WinMediaPackageCategory -PackageDir $Config.PackageDir -ExpandDir $expandDir -Config $Config
    if ($categories.SSU.Count -eq 0) { throw '缺少 SSU（可從合併 CU 取出，§11.3）。' }
    if ($categories.LCU.Count -eq 0) { throw '缺少最新 LCU。' }
    if ($categories.LCU.Count -gt 1) {
        Write-WinMediaLog -Config $Config -Level Warning -Message 'PackageDir 內有多個 LCU，將使用排序最後者；建議只保留最新一包。'
    }
    if ($categories.Unclassified.Count -gt 0) {
        Write-WinMediaLog -Config $Config -Level Warning -Message ('無法分類、略過的套件：' + (($categories.Unclassified | ForEach-Object { Split-Path -Path $_ -Leaf }) -join ', '))
    }
    if ($categories.SSU.Count -gt 1 -or $categories.DotNetCU.Count -gt 1) {
        Write-WinMediaLog -Config $Config -Level Warning -Message '偵測到多個 SSU 或 .NET CU，僅使用排序第一者；建議只保留所需的一包。'
    }
    $ssu = $categories.SSU | Select-Object -First 1
    $lcu = $categories.LCU | Select-Object -Last 1
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
            Add-WindowsPackage -Path $mounted -PackagePath $ssu | Out-Null
        }
        if ($safeOs) {
            Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
                Add-WindowsPackage -Path $mounted -PackagePath $safeOs | Out-Null
            }
        }
        Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
            Repair-WindowsImage -Path $mounted -StartComponentCleanup -ResetBase:([bool]$Config.ResetBase) | Out-Null
        }
    } | Out-Null

    # 步驟 6：install.wim 各索引；WinRE 複製到每個索引（§3.2 step 5）
    foreach ($index in $targets) {
        Mount-WinMediaImage -ImagePath $installWim -Index $index -MountPath (Join-Path -Path $mountDir -ChildPath ('install-{0}' -f $index)) -Config $Config -Action {
            param($mounted)
            Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
                Add-WindowsPackage -Path $mounted -PackagePath $ssu | Out-Null
            }
            Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
                Repair-WindowsImage -Path $mounted -StartComponentCleanup | Out-Null
            }
            if ($dotNet) {
                Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
                    Add-WindowsPackage -Path $mounted -PackagePath $dotNet | Out-Null
                }
            }
            Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
                Add-WindowsPackage -Path $mounted -PackagePath $lcu | Out-Null
            }
            Invoke-WinMediaOperation -Category File -Operation 'ReplaceWinRE' -Target $mounted -Config $Config -ScriptBlock {
                Copy-Item -LiteralPath $winreWim -Destination (Join-Path -Path $mounted -ChildPath 'Windows\System32\Recovery\winre.wim') -Force
            } | Out-Null
        } | Out-Null
    }

    # 步驟 7：虛擬版本（§2.7.4）；從已更新的 EnterpriseS 索引建立
    if ($virtualEditions.Count -gt 0) {
        foreach ($edition in $virtualEditions) {
            Add-WinMediaVirtualEdition -ImagePath $installWim -Index $ltscIndex.ImageIndex -MountPath (Join-Path -Path $mountDir -ChildPath 'virtual') -Edition $edition -Config $Config | Out-Null
        }
    }

    # 步驟 8：boot.wim 索引 1 與 2（§3.2 step 7、8）
    foreach ($bootIndex in 1, 2) {
        Mount-WinMediaImage -ImagePath $bootWim -Index $bootIndex -MountPath (Join-Path -Path $mountDir -ChildPath ('boot-{0}' -f $bootIndex)) -Config $Config -Action {
            param($mounted)
            Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
                Add-WindowsPackage -Path $mounted -PackagePath $ssu | Out-Null
            }
            Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
                Add-WindowsPackage -Path $mounted -PackagePath $lcu | Out-Null
            }
            Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
                Repair-WindowsImage -Path $mounted -StartComponentCleanup | Out-Null
            }
            if ($bootIndex -eq 2) {
                foreach ($file in 'setup.exe', 'setuphost.exe') {
                    $source = Join-Path -Path $mounted -ChildPath $file
                    if (Test-Path -LiteralPath $source) {
                        Invoke-WinMediaOperation -Category File -Operation 'ExtractSetup' -Target $source -Config $Config -ScriptBlock {
                            Copy-Item -LiteralPath $source -Destination (Join-Path -Path $mediaDir -ChildPath $file) -Force
                        } | Out-Null
                    }
                    else {
                        Write-WinMediaLog -Config $Config -Level Warning -Message "boot.wim 索引 2 找不到 $file（§11.8 第 27 列，實機確認）。"
                    }
                }
            }
        } | Out-Null
    }

    # 步驟 9：Setup DU
    if ($setupDu) {
        $expand = Invoke-WinMediaExternal -FilePath 'expand.exe' -ArgumentList @('-F:*', $setupDu, $mediaDir) -Config $Config
        if ($expand.ExitCode -ne 0) { throw "展開 Setup DU 失敗：$($expand.StdErr)" }
    }

    # 步驟 10：移除來源 EnterpriseS（僅在設定開啟且已建立虛擬版本時，§2.7.6）
    if ($Config.DeleteSourceEdition -and $virtualEditions.Count -gt 0 -and $ltscIndex) {
        Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
            Remove-WindowsImage -ImagePath $installWim -Index $ltscIndex.ImageIndex | Out-Null
        } | Out-Null
    }

    # 步驟 10（續）：ei.cfg 必須在索引移除之後判斷（§2.7.5）
    $eiCfg = Join-Path -Path $sourcesDir -ChildPath 'ei.cfg'
    $userEiCfg = Join-Path -Path $Config.PackageDir -ChildPath 'ei.cfg'
    $finalCount = @(Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
        Get-WindowsImage -ImagePath $installWim
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
        $bootData = '-bootdata:2#p0,e,b"{0}\boot\etfsboot.com"#pEF,e,b"{0}\efi\microsoft\boot\efisys.bin"' -f $mediaDir
        $burn = Invoke-WinMediaExternal -FilePath $oscdimg -ArgumentList @($bootData, '-u2', '-udfver102', '-m', $mediaDir, $output) -Config $Config
        if ($burn.ExitCode -ne 0) {
            throw "oscdimg 失敗，結束碼 $($burn.ExitCode)：$($burn.StdErr)"
        }
    }

    # 步驟 12：成功後才清除工作子目錄；logs 保留
    $cleanupDirs = @($mediaDir, $winreDir, $expandDir)
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
