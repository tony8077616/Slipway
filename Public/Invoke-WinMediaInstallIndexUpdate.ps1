function Invoke-WinMediaInstallIndexUpdate {
    # 單一 install 索引的外層協調：呼叫映像端函式、回寫第一個目標的 kernel 與建置資訊、複製 xmllite、最後同步開機檔（自 Invoke-WindowsMediaRefresh 的 install 迴圈抽出；ReplaceWinRE 與 CopyXmlLite 順序已交換，見 deviations 第 52 項）
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
        $sourcesDir,
        $winreWim,
        [bool]$isEsdSource,
        $mediaDir,
        [hashtable]$Config,
        [hashtable]$installKernel,
        [hashtable]$buildInfo,
        [hashtable]$bootEx
    )

        $img = Invoke-WinMediaInstallIndexImageUpdate -mounted $mounted -ssu $ssu -lcuStage $lcuStage -langFod $langFod -dotNet $dotNet -enablement $enablement -appxList $appxList -storeSet $storeSet -lxpItems $lxpItems -driverSet $driverSet -forceUnsigned $forceUnsigned -resetBaseOS $resetBaseOS -common $common -IsFirstTarget:$IsFirstTarget -winreWim $winreWim -Config $Config
        if ($IsFirstTarget) {
            $installKernel.Version = $img.KernelVersion
            $buildInfo.Info = $img.BuildInfo
        }
        # 媒體 sources\xmllite.dll 取自第一個目標索引、已套用 LCU 的版本（convert-UUP 取自 metadata ESD 索引 3，此處沒有該來源）
        if ($IsFirstTarget) {
            Invoke-WinMediaOperation -Category File -Operation 'CopyXmlLite' -Target $sourcesDir -Config $Config -ScriptBlock {
                Copy-Item -LiteralPath (Join-Path -Path $mounted -ChildPath 'Windows\System32\xmllite.dll') -Destination (Join-Path -Path $sourcesDir -ChildPath 'xmllite.dll') -Force
            } | Out-Null
        }
        # 文件步驟之後（convert-UUP 3895–3930 行）：最後執行，使開機檔取自已套用 LCU 的映像
        # 缺鍵時視為開啟（預設開）；StrictMode 下直接讀取缺少的鍵會拋錯，因此先用 ContainsKey
        if (-not $isEsdSource) { if (-not $Config.ContainsKey('UpdateBootFiles') -or $Config.UpdateBootFiles) { $bootEx.Applied = Copy-WinMediaUpdatedBootFiles -MountPath $mounted -MediaDir $mediaDir -Config $Config } }
}
