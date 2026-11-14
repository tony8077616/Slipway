function Invoke-WinMediaInstallIndexImageUpdate {
    # 單一 install 索引的映像端套件、功能、清理與驅動步驟（自 Invoke-WinMediaInstallIndexUpdate 抽出；純映像端作業）
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ssu', Justification = '由 scriptblock 閉包使用，PSSA 無法追蹤')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'lcuStage', Justification = '由 scriptblock 閉包使用，PSSA 無法追蹤')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'resetBaseOS', Justification = '由 scriptblock 閉包使用，PSSA 無法追蹤')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'common', Justification = '由 scriptblock 閉包使用，PSSA 無法追蹤')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'winreWim', Justification = '由 scriptblock 閉包使用，PSSA 無法追蹤')]
    [CmdletBinding()]
    param(
        $mounted,
        $ssu,
        $lcuStage,
        $langFod,
        $dotNet,
        $enablement,
        $appxList,
        $storeSet,
        $lxpItems,
        $driverSet,
        $forceUnsigned,
        $resetBaseOS,
        $common,
        [bool]$IsFirstTarget,
        $winreWim,
        [hashtable]$Config
    )

    Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
        Add-WindowsPackage -Path $mounted -PackagePath $ssu @common -LogLevel $Config.DismLogLevel | Out-Null
    } | Out-Null
    # 啟用套件（eKB）：convert-UUP 把 eKB 放在 ldr 批次最前面（cumulative 之前）；依映像 Edition 套件判定，LTSC 略過
    $packagesDir = Join-Path -Path $mounted -ChildPath 'Windows\servicing\Packages'
    $ekb = $null
    foreach ($ekb in @($enablement | Where-Object { $_ })) {
        if (-not (Test-WinMediaEnablementApplicable -Editions @($ekb.Editions) -PackagesDir $packagesDir)) {
            Write-WinMediaLog -Config $Config -Level Info -Message "啟用套件不適用此索引（Edition 未命中或為 LTSC），略過：$(Split-Path -Path $ekb.Path -Leaf)"
            continue
        }
        Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
            Add-WindowsPackage -Path $mounted -PackagePath $ekb.Path @common -LogLevel $Config.DismLogLevel | Out-Null
        } | Out-Null
    }
    # 文件步驟 10–11：語言包與 FoD 必須在最新 LCU 之前注入
    Install-WinMediaLangFod -MountPath $mounted -Set $langFod -Config $Config | Out-Null
    # 文件步驟 13：最新 LCU（連同前置 checkpoint，經暫存資料夾）
    Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
        Add-WindowsPackage -Path $mounted -PackagePath $lcuStage @common -LogLevel $Config.DismLogLevel | Out-Null
    } | Out-Null
    # 文件步驟 14：cleanup；CBS_E_PENDING（0x800F0806）只警告，其他錯誤照常中止（Mount-WinMediaImage 失敗時會 Discard）
    try {
        Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
            Repair-WindowsImage -Path $mounted -StartComponentCleanup -ResetBase:$resetBaseOS @common -LogLevel $Config.DismLogLevel | Out-Null
        } | Out-Null
    }
    catch {
        if ($_.Exception.HResult -ne -2146498554 -and $_.Exception.Message -notmatch '0x800f0806') { throw }
        Write-WinMediaLog -Config $Config -Level Warning -Message 'install.wim cleanup 有待處理作業（0x800F0806），略過本次 cleanup；需開機完成後再處理。'
    }
    # 選用：WIMBoot 等最佳化目標（OptimizationTarget 為空時不呼叫）；值原樣傳給 DISM，不做驗證（藍圖 F13）
    if ($Config.ContainsKey('OptimizationTarget') -and -not [string]::IsNullOrWhiteSpace($Config.OptimizationTarget)) {
        Optimize-WinMediaImage -Path $mounted -OptimizationTarget $Config.OptimizationTarget -Config $Config | Out-Null
    }
    # 文件步驟 15：NetFx3 必須在 cleanup 之後、.NET CU 之前
    Install-WinMediaDeferredFod -MountPath $mounted -Set $langFod -Config $Config | Out-Null
    if ($dotNet) {
        Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
            Add-WindowsPackage -Path $mounted -PackagePath $dotNet @common -LogLevel $Config.DismLogLevel | Out-Null
        } | Out-Null
    }
    if ($appxList) { Remove-WinMediaAppx -MountPath $mounted -AppxList $appxList -Config $Config | Out-Null }
    Install-WinMediaStoreApp -MountPath $mounted -Set $storeSet -Config $Config | Out-Null
    if ($null -ne $lxpItems -and @($lxpItems).Count -gt 0) { Install-WinMediaLxp -MountPath $mounted -Lxp $lxpItems -Config $Config | Out-Null }
    if ($driverSet) { Install-WinMediaDriver -MountPath $mounted -Target 'Install' -DriverSet $driverSet -ForceUnsigned $forceUnsigned -Config $Config | Out-Null }
    $kernelVersion = $null
    $info = $null
    if ($IsFirstTarget) {
        $kernelVersion = (Get-Item -LiteralPath (Join-Path -Path $mounted -ChildPath 'Windows\System32\ntoskrnl.exe')).VersionInfo.FileVersion
        $info = Get-WinMediaBuildInfo -MountPath $mounted -WorkDir $Config.WorkDir -Config $Config
    }
    Invoke-WinMediaOperation -Category File -Operation 'ReplaceWinRE' -Target $mounted -Config $Config -ScriptBlock {
        Copy-Item -LiteralPath $winreWim -Destination (Join-Path -Path $mounted -ChildPath 'Windows\System32\Recovery\winre.wim') -Force
    } | Out-Null

    [pscustomobject]@{
        KernelVersion = $kernelVersion
        BuildInfo     = $info
    }
}
