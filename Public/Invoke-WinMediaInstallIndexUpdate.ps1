function Invoke-WinMediaInstallIndexUpdate {
    # 單一 install 索引的套件、功能、清理與開機檔步驟（自 Invoke-WindowsMediaRefresh 的 install 迴圈抽出；行為不變）
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
        $appxList,
        $storeSet,
        $lxpItems,
        $driverSet,
        $forceUnsigned,
        $resetBaseOS,
        $common,
        [bool]$IsFirstTarget,
        $sourcesDir,
        $winreWim,
        [bool]$isEsdSource,
        $mediaDir,
        [hashtable]$Config,
        [hashtable]$installKernel,
        [hashtable]$buildInfo,
        [hashtable]$bootEx
    )

        Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
            Add-WindowsPackage -Path $mounted -PackagePath $ssu @common -LogLevel $Config.DismLogLevel | Out-Null
        }
        # 文件步驟 10–11：語言包與 FoD 必須在最新 LCU 之前注入
        Install-WinMediaLangFod -MountPath $mounted -Set $langFod -Config $Config
        # 文件步驟 13：最新 LCU（連同前置 checkpoint，經暫存資料夾）
        Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
            Add-WindowsPackage -Path $mounted -PackagePath $lcuStage @common -LogLevel $Config.DismLogLevel | Out-Null
        }
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
        if (-not [string]::IsNullOrWhiteSpace($Config.OptimizationTarget)) {
            Optimize-WinMediaImage -Path $mounted -OptimizationTarget $Config.OptimizationTarget -Config $Config
        }
        # 文件步驟 15：NetFx3 必須在 cleanup 之後、.NET CU 之前
        Install-WinMediaDeferredFod -MountPath $mounted -Set $langFod -Config $Config
        if ($dotNet) {
            Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
                Add-WindowsPackage -Path $mounted -PackagePath $dotNet @common -LogLevel $Config.DismLogLevel | Out-Null
            }
        }
        if ($appxList) { Remove-WinMediaAppx -MountPath $mounted -AppxList $appxList -Config $Config }
        Install-WinMediaStoreApp -MountPath $mounted -Set $storeSet -Config $Config
        if ($lxpItems.Count -gt 0) { Install-WinMediaLxp -MountPath $mounted -Lxp $lxpItems -Config $Config }
        if ($driverSet) { Install-WinMediaDriver -MountPath $mounted -Target 'Install' -DriverSet $driverSet -ForceUnsigned $forceUnsigned -Config $Config }
        if ($IsFirstTarget) { $installKernel.Version = (Get-Item -LiteralPath (Join-Path -Path $mounted -ChildPath 'Windows\System32\ntoskrnl.exe')).VersionInfo.FileVersion }
        # 媒體 sources\xmllite.dll 取自第一個目標索引、已套用 LCU 的版本（convert-UUP 取自 metadata ESD 索引 3，此處沒有該來源）
        if ($IsFirstTarget) {
            $buildInfo.Info = Get-WinMediaBuildInfo -MountPath $mounted -WorkDir $Config.WorkDir -Config $Config
            Invoke-WinMediaOperation -Category File -Operation 'CopyXmlLite' -Target $sourcesDir -Config $Config -ScriptBlock {
                Copy-Item -LiteralPath (Join-Path -Path $mounted -ChildPath 'Windows\System32\xmllite.dll') -Destination (Join-Path -Path $sourcesDir -ChildPath 'xmllite.dll') -Force
            } | Out-Null
        }
        Invoke-WinMediaOperation -Category File -Operation 'ReplaceWinRE' -Target $mounted -Config $Config -ScriptBlock {
            Copy-Item -LiteralPath $winreWim -Destination (Join-Path -Path $mounted -ChildPath 'Windows\System32\Recovery\winre.wim') -Force
        } | Out-Null
        # 文件步驟之後（convert-UUP 3895–3930 行）：最後執行，使開機檔取自已套用 LCU 的映像
        # 缺鍵時視為開啟（預設開）；StrictMode 下直接讀取缺少的鍵會拋錯，因此先用 ContainsKey
        if (-not $isEsdSource) { if (-not $Config.ContainsKey('UpdateBootFiles') -or $Config.UpdateBootFiles) { $bootEx.Applied = Copy-WinMediaUpdatedBootFiles -MountPath $mounted -MediaDir $mediaDir -Config $Config } }
}
