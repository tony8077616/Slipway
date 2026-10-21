# WinMediaRefresh 設計文件

## 设计概述

### 目标

以使用者手動放入的更新包，更新原版 Windows 10 21H2 LTSC 與 Windows 11 安裝 ISO，產出可用於 Ventoy 的 ISO 或 install.esd。規劃來源為 `.claude/plan/windows-media-update-v5.md`。

### 非目標

- 不自動下載 FoD、語言包與 StoreApps；三者改由獨立資料夾（`Lang`、`Fod`、`StoreApps`）提供，StoreApps 每個套件須通過 Microsoft 簽章驗證。更新包下載見 `Save-WinMediaUpdate`（Catalog 優先、UUP 輔助與驗證）；`Download.Build` 路徑已改為 UUP 為主、Learn 只作交叉檢查，見 2026-10-16 決策。
- 不做 FAT32 分割；產出單一 ISO。
- 不做 UUP 轉換；母檔一律為原版 ISO。
- Appx 只能依 `Apps.CustomAppsList` 移除或保留（預設停用），不做其他 Appx 清理。
- 不依賴 `dism.exe`；所有 DISM 操作改用 DISM PowerShell Cmdlet。
- 不支援 PowerShell 5.1 以下。

## 架構設計

### 整體架構

```
Update-WindowsMedia.ps1 (入口)
        │
        ▼
Invoke-WindowsMediaRefresh (主流程，Public)
        │
        ├─ 前置檢查 ─ Resolve-WinMediaAdk（DISM 來源）
        ├─ 掛載母檔 ─ Mount-WinMediaImage
        ├─ 更新包分類 ─ Get-WinMediaPackageCategory
        ├─ DISM 操作 ─ Invoke-WinMediaDism（僅 Cmdlet）
        ├─ 外部程式 ─ Invoke-WinMediaExternal（oscdimg）、Invoke-WinMediaWimlib（wimlib）
        ├─ ESD 轉換 ─ Convert-WinMediaEsdToWim / Export-WinMediaEsd
        ├─ 虛擬版本 ─ Add-WinMediaVirtualEdition / Test-WinMediaVirtualEdition
        ├─ 自訂內容 ─ 驅動（Resolve／Install-WinMediaDriver）、LXP（Resolve／Install-WinMediaLxp）、Appx（Resolve-WinMediaAppxList／Remove-WinMediaAppx）
        ├─ 路徑檢查 ─ Test-WinMediaPathOverlap
        └─ 日誌 ─ Write-WinMediaLog、Invoke-WinMediaOperation、Protect-WinMediaLogValue
```

### 核心組件

- **Invoke-WindowsMediaRefresh**：主流程，依 §3.2 步驟執行，成功才清除 WorkDir。
- **Get-WinMediaPackageCategory**：讀取 `update.mum` 與 manifest 分類更新包（SSU、SafeOS DU、LCU、Setup DU、.NET、語言包、FoD）。
- **Resolve-WinMediaAdk**：依序探測 ADK 的 DISM 目錄，取第一個含 `Dism.psd1` 或 `dism.exe` 者。`dism.exe` 只用於讀取版本號，不執行。
- **Invoke-WinMediaDism**：包裝 DISM Cmdlet，檢查回傳碼，非零即中止。
- **Mount-WinMediaImage**：掛載與卸載，失敗時 `-Discard`。
- **Invoke-WinMediaExternal**：呼叫 oscdimg 等外部程式。
- **Resolve-WinMediaWimlib**：解析 wimlib-imagex 路徑；缺少時先找模組內附的壓縮檔，再下載固定版本 1.14.5，校驗 SHA-256 後解壓。
- **Invoke-WinMediaWimlib**：wimlib 的唯一呼叫入口，內部經 `Invoke-WinMediaExternal`，非零結束碼即中止。
- **Install-WinMediaAdk**：ADK 缺少時下載安裝程式，驗證 Microsoft 簽章後以 `/quiet /installpath` 安裝 Deployment Tools。
- **Test-WinMediaVirtualEdition**：檢查虛擬版本條件與 EditionID。
- **Resolve-WinMediaDriverSet**：掃描 `Drivers.Path` 的 `ALL`、`WinPE`、`OS` 子資料夾（遞迴找 `.inf`），無 `.inf` 的子資料夾略過並寫入 Warning。
- **Install-WinMediaDriver**：依目標（WinRE、Install、Boot）對映像呼叫 `Add-WindowsDriver -Recurse`，狀態與目標的對應見 README。
- **Resolve-WinMediaLxp**：遞迴找 `LanguageExperiencePack*` 套件，從 zip 讀出 `AppxManifest.xml`（或 bundle 的 `AppxMetadata/AppxBundleManifest.xml`）與 `License.xml`。
- **Install-WinMediaLxp**：以 `Add-AppxProvisionedPackage -Regions 'all'` 加入 install.wim。
- **Resolve-WinMediaAppxList／Remove-WinMediaAppx**：解析 CustomAppsList；`Remove` 移除清單內的 provisioned app，`Keep` 移除清單外者並保留框架與語言套件。
- **Test-WinMediaPathOverlap**：`PackageDir`、`WorkDir`、`Drivers.Path`、`Lxp.Path` 兩兩不得重疊。
- **日誌三件組**：`Write-WinMediaLog`（UTF-8 無 BOM）、`Invoke-WinMediaOperation`（操作紀錄）、`Protect-WinMediaLogValue`（遮罩敏感值）。

## 設計決策

### 決策記錄

| 日期 | 決策 | 理由 | 影響 |
|------|------|------|------|
| 2026-10-14 | 不自動下載更新，手動放置更新包 | 使用者需求 | 需人工準備 PackageDir |
| 2026-10-14 | DISM 只用 Cmdlet，不呼叫 `dism.exe` | 使用者限制；Learn 建議 | `Invoke-WinMediaDism` 包裝 Cmdlet |
| 2026-10-14 | WinRE 不套用 checkpoint，只取 SSU 與 SafeOS DU | Learn 查證（規劃 §1） | WinRE 流程獨立 |
| 2026-10-14 | 預設 `ResetBase = $false` | 避免無法解除安裝更新 | 需要時須明確開啟 |
| 2026-10-14 | 虛擬版本以 DISM `/Set-Edition` 實作 | 依 `create_virtual_editions.cmd` | 來源須先轉 WIM；卸載一律 `-Discard` |
| 2026-10-14 | WorkDir、MountDir、OutputDir 皆可由參數指定；MountDir 預設參照 Convert-UUP.cmd | 使用者需求；Convert-UUP.cmd:4648–4654 掛載於工作磁碟 `MountUUP`（非 NTFS 回退系統碟） | MountDir 空白 = 依 WorkDir 推導；MountDir 非空即中止，不像 Convert-UUP.cmd:1060 直接 rmdir |
| 2026-10-14 | wimlib 只在 `Wimlib.Path` 非空時用於 ESD→WIM；WIM→ESD 一律使用 wimlib | Learn 未記載 DISM 直接產生 ESD；ESD→WIM 保留 DISM 以減少外部依賴 | `Convert-WinMediaEsdToWim` 分流；`Wimlib.Path` 空白時不改寫，維持 DISM |
| 2026-10-14 | wimlib 缺少時自動下載固定版本 1.14.5，以論壇公告 SHA-256 校驗 | 使用者需求；校驗碼取自 wimlib 論壇公告（viewtopic.php?t=1133） | 校驗不符即刪除並中止；需網路（僅於本地無檔時） |
| 2026-10-14 | wimlib 參數與 DISM 指令分開，wimlib 只經 `Invoke-WinMediaWimlib` 呼叫 | 使用者需求：依 wimlib 自身參數執行，不與 DISM 混用 | 僅在 DISM 無對應功能時才使用另一側（目前無此情況） |
| 2026-10-14 | ADK 缺少時自動安裝 Deployment Tools，安裝程式須為 Microsoft 簽章 | 使用者需求；安裝程式來源為 Microsoft 官方連結 | 需系統管理員權限；Inbox 模式產 WIM 時若需 oscdimg 亦會觸發安裝（不得已） |
| 2026-10-14 | 驗證閘門：`Tests\Invoke-Validation.ps1` 同時執行 Pester 6.2.0 與 PSScriptAnalyzer，任一失敗即非 0 結束；所有 PowerShell 檔為 CRLF＋UTF-8 BOM | 使用者需求 | 每次修改須執行；測試不連網，以 Mock 代替下載與安裝 |
| 2026-10-15 | 驅動分 ALL／WinPE／OS 三種狀態，比照 Convert-UUP.cmd | 使用者決定；E: 版本 `convert-UUP.cmd` 第 92–96、2959、3969 行 | ALL＝WinRE＋Install＋Boot；WinPE＝WinRE＋Boot；OS＝Install；無 `.inf` 略過並警告 |
| 2026-10-15 | LXP 獨立資料夾，只加入 install.wim；License.xml 取自套件 zip | 使用者決定；比照 `lxp_sort`／`appx_add` | 不依賴 7-Zip；找不到 License.xml 時略過並警告 |
| 2026-10-15 | CustomAppsList 兩種語意以 `Apps.CustomListMode` 切換，預設 `Remove` | 使用者決定 | `Keep` 清單為空時拒絕執行；框架與語言套件不被 Keep 移除 |
| 2026-10-15 | 注入時機 `PostUpdate`：LCU 之後、dismount 之前；Appx 移除 → LXP → 驅動 | 計畫 v3 §3；驅動需在 LCU 後才不被覆蓋 | 步驟 5、6、8 各插入一段 |
| 2026-10-15 | 未簽章驅動預設拒絕（`Drivers.ForceUnsigned = $false`） | 使用者決定 | 開啟時寫入 Warning |
| 2026-10-15 | Appx 比對採完整 PFN（DisplayName ＋ PackageFullName 最後一段發行者 ID），不只比 DisplayName | 避免不同發行者的同名 app 被誤判 | 發行者 ID 的取得方式需以真實映像確認 |
| 2026-10-15 | 模組拆分：通用層放在專案外的 `PSModules\Common`（`WinMediaLog`、`WinMediaOperation`、`WinMediaProcess`、`PathSanitize`），映像層放在 `PSModules\Imaging`（DISM、ADK、wimlib、ESD、掛載、虛擬版本），專案專屬功能放在 `Modules\`（路徑規則、驅動、LXP、Appx、套件分類）；主流程留在根模組作為組合點 | 使用者需求（通用模組可在其他專案重用） | 模組各自以 `Import-Module` 匯入依賴；mock 以 `InModuleScope <擁有該函式的模組>` 設定；路徑淨化（`PathSanitize`）處理一般路徑、`\\?\` 長路徑、UNC、登錄機碼（PowerShell 與 reg.exe 形式）與網址（http／https／ftp，移除帳密後才紀錄）；所有路徑比對經 `Get-ComparablePath`，不再直接呼叫 `GetFullPath` |
| 2026-10-15 | StoreApps 獨立資料夾（`StoreApps`，預設為腳本目錄下）：遞迴列出 .appx／.appxbundle／.msix／.msixbundle；每個套件須 Authenticode 為 Valid 且簽署者 O=Microsoft Corporation，未通過者不注入（保留原檔）；框架（VCLibs、UI.Xaml、NET.Native）以依賴方式注入；同名 .xml 授權檔存在則使用，否則 `-SkipLicense`；於 CustomAppsList 移除之後注入 | 使用者需求（StoreApps 集中於腳本目錄；rg-adguard 下載需驗證微軟簽章）；移除 `Config.FodIsoPath`（Fod 可能是分發的 cab，不限於 ISO，由 `Fod.Path` 處理） | 留空且資料夾不存在則停用；未驗證者不刪除，只記錄 Error；PFN 與 PackageName 比對未實作 |
| 2026-10-15 | FoD 與語言包獨立資料夾（`Lang`、`Fod`）：遞迴只取 .cab；語言包依 `Languages` 篩選，FoD 保留語言中立與設定語言；於 LCU 之後注入 | 使用者需求（FoD 與語言包個別獨立存放） | 空白路徑時補齊為腳本目錄下的 `Lang`、`Fod`，不存在則停用；與其他輸入資料夾一樣納入路徑重疊檢查 |
| 2026-10-15 | 更新包下載：Catalog 為主要來源，UUP dump 為輔助（交叉驗證 SHA-1，Catalog 無結果時作為下載網址備援）；`Download.Method` 預設 `WebRequest`，可選 `Bits`／`Curl` | 使用者決定（a：Catalog 優先 UUP 輔助＋驗證；b：UUP 資源整合為替代來源） | 下載到 PackageDir；`.partial` 完成後改名；Learn 只作參考，未用於 KB 查詢（此為 KB 路徑；`Download.Build` 路徑已改為 UUP 為主，見 2026-10-16 決策）；UUP 與 Catalog 任一失敗的處理見 `Save-WinMediaUpdate` 說明 |
| 2026-10-15 | 輸入資料夾（Packages、Drivers、Lxp、CustomAppsList.txt）預設集中於模組（執行腳本）所在目錄；WorkDir 預設改為磁碟根目錄下的 `WinMediaWork` | 使用者需求（集中放置）；原 WorkDir 預設為磁碟根目錄，與 PackageDir 重疊會被路徑檢查擋下 | 由 `Resolve-WinMediaInputPath` 依 `$script:ModuleRoot` 補齊；留空且資料夾不存在則停用；已指定的路徑不覆寫；設定檔已指定者優先 |
| 2026-10-14 | WorkDir 預設為執行腳本所在磁碟根目錄；OutputDir 預設為腳本所在目錄 | 使用者需求（取代先前參照 Convert-UUP 的 WorkDir 預設） | 預設值於入口腳本 `Update-WindowsMedia.ps1` 解析；設定檔兩鍵留空；主流程 WorkDir 為空或非絕對路徑即中止；OutputDir 不做 OneDrive 檢查，腳本位於 OneDrive 內時成品會被同步 |
| 2026-10-16 | install.wim 步驟順序採 Microsoft「Update Windows installation media with Dynamic Update」表格：SSU → 語言包與 FoD（NetFx3 除外）→ 最新 LCU（含 checkpoint）→ cleanup → NetFx3 → .NET CU → Appx 移除 → LXP → 驅動 → WinRE；boot.wim：SSU → 語言包 → LCU → cleanup | 表格與 Learn 內文 checkpoint 段落的 step 編號不一致，採表格讀法；舊流程在 LCU 之前做 cleanup，已移除 | 步驟順序由 `WinMediaWiring.Tests.ps1` 與 `WinMediaAddons.Tests.ps1` 鎖定；cleanup 遇 CBS 待處理（0x800F0806）只記 Warning |
| 2026-10-16 | 累積更新整組下載與 checkpoint：目標為 KB 最大的 .msu，其餘為前置 checkpoint（24H2 規則，例如 KB5127648 需 KB5043080）；DISM 只在 `-PackagePath` 所在資料夾尋找 checkpoint，故以 `New-WinMediaUpdateStage` 只放入目標與 checkpoint | 避免 PackageDir 殘留的舊 LCU 被誤用；Build 路徑直接採用 `Save-WinMediaBuildSet` 的判定結果 | 同磁碟使用硬連結不增加空間；跨磁碟回退為複製（約多佔一份，5 GB 級）；多個 msu 檔名缺 KB 時中止 |
| 2026-10-16 | Learn 發行資訊頁只作交叉檢查，不作來源（使用者需求：UUP 為主、Learn 為輔） | Learn 只列各通道最新 build，且更新發布後才會出現；`Find-WinMediaLearnKb` 找不到 build 只記 Info，KB 不一致只記 Warning，以 UUP 為準 | Build 路徑不依賴 Learn 才能執行 |
| 2026-10-16 | `Download.Build`（UUP 整組）優先於 `Download.KB`（Catalog 單一 KB）；兩者皆空則沿用 PackageDir 既有檔案 | 使用者需求（UUP 為主，Catalog 為既有路徑保留） | Build 路徑的信任邊界見「安全措施」 |
| 2026-10-16 | 共用下載器改為逐跳解析重導向後才下載：每跳 https＋允許網域，最多 5 跳，WebRequest `-MaximumRedirection 0`，curl 不加 `-L`，BITS 以最終網址下載 | 原實作會跟隨重導向且不重新檢查網域，Build 路徑的網域檢查無法覆蓋重導向目標；採 `AllowAutoRedirect=false` 逐跳探測，而非改用 BITS 旗標（BITS cmdlet 無此選項） | 殘餘風險：BITS 傳輸中的重導向仍無法攔截，已記於「安全措施」；測試 `WinMediaRedirect.Tests.ps1` |
| 2026-10-16 | ISO 開機參數依架構分流：x64 `-bootdata:2`（etfsboot.com＋efisys.bin），ARM64 `-bootdata:1`（只有 efisys.bin）；oscdimg 加上 `-o`；開機檔不存在時先中止 | 原實作對 ARM64 媒體仍引用不存在的 etfsboot.com，會直接失敗；參照 `uup-converter-wimlib\convert-UUP.cmd` 約 783–787 行 | 只有文字斷言（`WinMediaWiring.Tests.ps1`），未以實機 ISO 驗證 |
| 2026-10-16 | UUP 來源的 `.msu` 可能是 WIM 格式（檔頭 `MSWIM\0\0\0`，非 cab 的 `MSCF`）：分類器改以檔頭判斷，WIM 改用 `Invoke-WinMediaWimlib extract <msu> 1`，其餘仍用 expand.exe；巢狀 cab 同樣處理 | 實機（26300.9711 離線包）分類結果為 SSU／LCU 皆空：expand.exe 對 WIM 檔回傳 0 但只複製原檔，結束碼不可靠；參照 convert-UUP.cmd 1641–1649 行的 `msuwim=1` 分支 | 測試 `WinMediaPackageWim.Tests.ps1`（mock）；實機分類：SSU、LCU、SafeOS、.NET 正確；SetupDU（KB5127650）原本只依檔名比對而未辨識，已改為內容辨識（見下列 (10)）；Enablement（KB5121794，`Version-Enablement-Package` 9544）未套用：原版 install.wim 索引 1 已含 8966 版（wimlib 列出 `Windows\servicing\Packages`）；成品的 enablement 版本待 verify 腳本實測（未驗證是否需要 9544）；DISM 套用 WIM 格式 .msu 已實機驗證（索引 1 為 10.0.26300.9711，索引 2 仍為 9457） |
| 2026-10-16 | 修正既有缺陷：(1) Catalog 標題格式已變為 `Windows 11, version 24H2`，原正規表示式無法比對；(2) 不帶 `-Index` 的 `Get-WindowsImage` 缺 Version、EditionId、Architecture；(3) UUP 同一 build 號會列出 Server／HCI 條目 | 三者皆使既有主流程取得錯誤結果 | 修正後的 Catalog 與 UUP 選擇以測試覆蓋；(2) 以 `WinMediaIndexInfo.psm1` 逐索引補查 |
| 2026-10-16 | 實機跑完整流程（索引 1）時的修正：(1) 根模組未匯入 PathSanitize，`Test-PathWithin` 不可見；(2) PackageDir 與 WorkDir 重疊為測試設定問題，改用 `C:\WinMediaPkg`；(3) `DirectoryInfo` 無 `IsReadOnly`（StrictMode 會中止），唯讀清除改以 `-File` 篩選；(4) 單一索引時 `$targets` 被展開為純量，改以 `@()` 包住；(5) DISM 不建立掛載點子目錄，`Mount-WinMediaImage` 補建；(6) boot.wim 索引 2 的 setuphost 實際位於 `\sources\SetupHost.exe`，改取該路徑；(7) 多 SSU 警告為誤報（SSU 依目標檔名選取），警告只保留給 .NET CU；(8) 掛載點殘留會使下次執行在 MountDir 非空檢查中止，改為卸載成功後移除本次建立的空掛載點；清理失敗只記錄警告，不取代操作結果；(9) SSU 比對的目標名稱先跳脫萬用字元；(10) Setup DU：扁平 cab 無 `update.mum`，改以 `SetupPlatform.exe`＋`SetupHost.exe` 內容辨識（規則限定 `-not $mum`，不攔截 SafeOS DU）；展開到 `sources`（保留語言子目錄），且位於 boot.wim 步驟之前，使 WinPE 的 setup.exe／setuphost.exe 覆蓋在後，對應 Microsoft「Update Windows installation media with Dynamic Update」第 26、27 列；實機 DU 內 `SetupHost.exe` 為 26100.9685，低於已服務的 9711，順序錯誤會降級；(11) 第 27 列的覆蓋目標為 `sources\setup.exe` 與 `sources\setuphost.exe`（來源為 boot.wim 索引 2 的同路徑），先前錯誤地覆蓋媒體根目錄 `setup.exe`，根目錄的 `setup.exe` 文件不更新；(12) 第 28 列 boot manager（`bootmgfw.efi`、`bootmgr.efi`、`boot.stl`）已實作：自 WinPE 索引 2 覆蓋媒體上同名檔案（`b*.efi` 遞迴搜尋），排在第 27 列之後 | 實機流程的每次失敗都應只需修正單一步驟後重跑；殘留目錄使重跑必須手動清理，違反此目標 | 測試 `WinMediaRootImports`、`WinMediaMountPoint`、`WinMediaWiring`、`WinMediaPackageWim`；實機結果見 README「目前狀態」 |
| 2026-10-20 | 使用者決定：SafeOS DU 依 Microsoft「用最近版本」的規則，不要求與 LCU 同版。步驟 9 守衛改由 `Test-WinMediaKernelConsistency` 判斷：開機索引等於安裝映像，或等於 WinRE 且 WinRE 核心與套用 SSU／SafeOS 前的基準版不同（即 SafeOS DU 生效），皆通過且不發警告；其餘情況中止。已知限制：若來源 WinRE 已是最新 SafeOS DU、套用後核心不變，開機索引等於 WinRE 而不等於安裝映像時會被誤擋，待以 Package_for_SafeOSDU 版本比對精確化 |
| 2026-10-20 | 26H2 啟用套件（eKB，例如 KB5121794）：使用者決定採選項 A。分類器需同時有 `update.mum` 與 `*-Version-Enablement-Package~*.mum` 才判為 `Enablement`（其他規則都不命中時才判），略過不套用（母檔已含對應功能），以 Info 記錄 cab 內版本，不發警告。離線套用的驗證實驗（選項 B）另記，不影響此決策 |
| 2026-10-20 | pwsh 7 下 DISM Cmdlet 的處理（使用者決定）：「無論是 ADK 的 DISM Cmdlet 還是系統內建的 DISM Cmdlet，只要運作於 pwsh 7 都需要先檢查，如果沒有則需要匯入」。以 `Import-Module -Name <DISM 或 Dism.psd1 路徑> -Verbose -Global -PassThru -UseWindowsPowerShell` 相容匯入；只認本工作階段自己匯入的來源（記在 `$global:WinMediaDismCompatSource`；存 `$global` 是因為多個模組以 `-Force` 重新匯入本模組時 `$script:` 狀態會被重設），原生自動載入的先移除再匯入；本工作階段中途換來源擲例外。設定鍵 `DismUseWindowsPowerShell`（預設 `$true`）：`$false` 時開工前中止並指出設定鍵；Windows PowerShell 5.1 忽略此項。使用者原話：「pwsh 7 改用 import-Module -Name DISM -Verbose -Global -PassThru -UseWindowsPowerShell 但是改增設選項切換」。已知：pwsh 7 下 `Get-Command` 會看到自動載入的原生 Dism，因此「是否存在」不足以判斷，須看來源。使用者決定：相容匯入的 WinPSCompatSession 還原序列化警告收進日誌（Info「已知」），不以警告顯示。 |
| 2026-10-21 | ISO 輸出檔名改為 UUP 風格：`WinMedia_<DisplayVersion>_<CurrentBuild>.<UBR>.<BuildBranch 大寫>_<CLIENTMULTI 或 CLIENT<EditionId>>_<X64 或 ARM64><FRE>_<語言或 MULTI>_<yyyyMMdd-HHmmss>.iso`（例：`WinMedia_26H2_26300.9807.GE_RELEASE_CLIENTMULTI_X64FRE_ZH-TW_20261021-081543.iso`）。DisplayVersion、CurrentBuild、UBR、BuildBranch 於第 6 步由已套用更新的索引讀取 SOFTWARE hive（以 `reg load`、`reg query`、`reg unload` 經暫存機碼處理，不使用 HKLM: 提供者）；BuildType 取自 `sources\idwbinfo.txt`。BuildLabEx 停在 RTM（`26100.1.amd64fre.ge_release.240331-1435`），不作為時間戳來源，因此檔名不含 UUP 的建置時間戳。任一欄位缺失即省略該段；hive 讀取整個失敗時退回 `WinMedia_<時間戳>.iso`。 | 使用者確認格式；UUP Dump 命名參照 O: 上既有檔名（例：`26300.9807.261013-1834.26H2_GE_RELEASE_SVC_PROD3_CLIENTMULTI_X64FRE_ZH-TW.ISO`）；26H2 前綴改由 DisplayVersion 取得，不從母檔檔名解析，也不建立 build 對照表 | 單元測試 `WinMediaOutputName.Tests.ps1`（完整名精確比對、降級、單一版本、arm64、接線）；`ConvertFrom-WinMediaRegQuery` 以實機 hive 複本的 reg query 輸出驗證；reg load、query、unload 已以實機 hive 複本做整合驗證（成功與失敗路徑）；第 6 步的真實掛載點與完整流程尚未驗證 |

### 技術選型

- **語言**：PowerShell 5.1（基準）；PS 7 語法僅在 `$PSVersionTable` 守衛分支內使用。
- **理由**：目標環境為 Windows 內建 PowerShell，避免額外安裝執行環境；DISM Cmdlet 與 Pester 6.2.0 可在 5.1 上執行。

## 權衡取捨

### 已知限制

- 更新包須手動準備，無法自動判斷是否為最新版本。
- Windows 10 21H2 無 checkpoint 機制；實機測試需覆蓋兩種母檔狀態。
- ESD 輸出依賴 wimlib；缺少時自動下載（需網路），下載或校驗失敗即中止，不退回 DISM。`Wimlib.Path` 指定的檔案不存在時同樣自動下載。
- 虛擬版本的 SPP 檔缺失時中止，不略過。

### 技術債務

- **Learn 文件內部不一致**：checkpoint 段落的 step 編號（12/13、23 與範例註解）前後不一致。已採表格讀法（見 2026-10-16 決策），`-WhatIf` 步驟清單仍標示此差異，待實機確認。
- **ADK 路徑不一致**：`Deployment Tools\10\DISM` 與 `Deployment Tools\amd64\DISM` 兩種寫法都會探測。

## 安全考量

### 威脅模型

- **更新包內容不可信**：來源為使用者放入的資料夾，分類前不應假設檔名可信。
- **母檔被覆寫**：錯誤路徑或中斷可能破壞來源 ISO 或既有輸出。
- **敏感資訊寫入日誌**：路徑、帳號或其他參數可能進入日誌。
- **掛載殘留**：失敗後未卸載的映像會佔用磁碟並可能留下不一致狀態。

### 安全措施

- 母檔唯讀掛載後複製到 WorkDir，來源 ISO 不修改。
- `OutputDir` 已有 ISO 時不覆寫，除非 `-Force`。
- 每個掛載包在 `try/finally` 中卸載；成功 `-Save`，失敗 `-Discard`。虛擬版本一律 `-Discard`，避免覆寫來源索引。
- 每步檢查 DISM 回傳碼，非零即中止。
- 日誌經 `Protect-WinMediaLogValue` 遮罩敏感值，並有測試覆蓋（`password=abc123` 會被遮罩）。
- 不呼叫 `dism.exe` 執行操作；靜態掃描未發現 `Invoke-Expression`、`-EncodedCommand` 等高風險模式。
- wimlib 壓縮檔以論壇公告的 SHA-256 校驗，不符即刪除；ADK 安裝程式須為 Microsoft 簽章，否則刪除並中止。
- 更新包以 Catalog 檔名中的 SHA-1 校驗，不符即刪除並中止；指定 `-Build` 時，UUP 的 SHA-1 會交叉比對，不一致則在下載前中止。`.msu`／`.cab` 不是 Authenticode 直接簽章，因此不以簽章作為驗證依據。網址只允許 Microsoft 網域的 https，檔名取自淨化後的網址末段。Build 路徑（UUP）的網址與 SHA-1 同來自 UUP 的單一回應，SHA-1 無法擋下被竄改的回應，因此網域檢查（`Assert-WinMediaUpdateUrl`，由 `Save-WinMediaUpdateFile` 於下載前執行）是該路徑唯一的信任邊界；測試 `WinMediaWiring.Tests.ps1` 覆蓋非 Microsoft 網址必須中止。檔名經 `Save-WinMediaUpdateFile` 驗證（單一葉節點、無 `..`、副檔名與網址相同），UUP 條目缺 SHA-1 時在下載前拒絕。共用下載器 `WinMediaDownload` 先以 `Resolve-WinMediaDownloadUri` 逐跳解析重導向（GET 加 `Range: 0-0`，只取標頭不下載本體，`AllowAutoRedirect=false`），每一跳都必須是 https 且符合 `AllowedHostPattern`（Windows Update 路徑傳入 `$script:MicrosoftHostPattern`），最多 5 跳；確認最終網址後才下載。WebRequest 使用 `-MaximumRedirection 0`，curl 不加 `-L`，因此下載本身不會再跟隨重導向。日誌只記錄遮罩後的各跳網址，不記錄原始 `Location`（CDN 網址可能含 token）。**殘餘限制**：BITS 無法透過 cmdlet 關閉自動重導向，只能使用已驗證的最終網址降低風險；若 BITS 傳輸過程中被重導向，仍不會重新檢查。測試位於 `Tests\WinMediaRedirect.Tests.ps1`。

## 未決問題

以下項目尚未以實際 Windows ISO 驗證，來自規劃 §7、§8：

1. 實際 ISO 的完整流程（需使用者提供 ISO 路徑）。
2. ADK `oscdimg.exe` 的路徑（含空白）。
3. `Get-WindowsEdition -Target` 的屬性名稱。
4. `Save-WindowsImage` 的語意。
5. Setup DU 的版面配置。
6. 真實更新包的分類結果。
7. 掛載失敗後的清理。
8. wimlib 的 ESD 轉換、自動下載與 ADK 自動安裝（已以 Mock 測試，尚未實機執行）。

## 變更歷史

### 2026-10-14 - 初始版本

**變更內容**: 建立模組文件骨架，並依實際程式內容補寫。

**變更理由**: 完成 CCG gen-docs 與 verify-module 的文件要求。

### 2026-10-14 - 掛載與輸出路徑參數化

**變更內容**: 新增 `-WorkDir`、`-MountDir`、`-OutputDir` 參數與 `MountDir` 設定鍵；新增私有函式 `Resolve-WinMediaMountDir`；清理時只刪除本次建立的掛載目錄。

**變更理由**: 使用者需求，預設路徑參照 Convert-UUP.cmd。Pester 測試由 17 個增至 23 個，全數通過（Windows PowerShell 5.1、Pester 6.2.0，主機執行）；PSScriptAnalyzer Error／Warning 為 0。

### 2026-10-14 - WorkDir／OutputDir 預設值改依執行位置

**變更內容**: WorkDir 預設為執行腳本所在磁碟根目錄；OutputDir 預設為腳本所在目錄。設定檔兩鍵改為空白，預設值於 `Update-WindowsMedia.ps1` 解析；`Invoke-WindowsMediaRefresh` 在使用 WorkDir 前檢查為絕對路徑。

**變更理由**: 使用者需求。取代先前 WorkDir 固定為 `C:\WinMediaWork` 的設定。

### 2026-10-14 - wimlib／ADK 自動取得與驗證閘門

**變更內容**: 新增 `Resolve-WinMediaWimlib`、`Invoke-WinMediaWimlib`、`Install-WinMediaAdk`；`Export-WinMediaEsd` 改經 `Invoke-WinMediaWimlib`；`Convert-WinMediaEsdToWim` 在 `Wimlib.Path` 非空時使用 wimlib，否則維持 DISM Cmdlet；`Resolve-WinMediaAdk` 缺少 DISM 時自動安裝；新增 `Tests\Invoke-Validation.ps1`。

**變更理由**: 使用者需求：手動指定 wimlib 但本地無檔時自動下載，ADK 比照辦理；wimlib 依自身參數執行，與 DISM 分開；每次測試須通過 Pester 與 PSScriptAnalyzer；PowerShell 檔案使用 CRLF。

**驗證結果**: Pester 47 項通過（Windows PowerShell 5.1、Pester 6.2.0）；PSScriptAnalyzer Error／Warning 為 0；所有 `.ps1`／`.psm1`／`.psd1` 為 CRLF＋UTF-8 BOM。實機 ISO 流程仍未驗證。

### 2026-10-15 - 自訂驅動、LXP 與 Appx 清單

**變更內容**: 新增驅動三種狀態注入（ALL、WinPE、OS）、LXP 加入、CustomAppsList 控制 Appx（`Remove`／`Keep`）與路徑重疊檢查。新增私有函式見「核心組件」；`Config/Default.psd1` 新增 `Drivers`、`Lxp`、`Apps` 區塊；`Invoke-WindowsMediaRefresh` 步驟 1 檢查、步驟 5、6、8 注入，步驟 12 清除 `lxp` 暫存目錄。非目標「不移除 Appx」改為可由清單控制。

**變更理由**: 使用者需求（計畫 `custom-driver-support.md` v3）。

**與計畫的差異**（實作時依實際 cmdlet 修正）:
- `Add-ProvisionedAppxPackage` 只是別名，改用 `Add-AppxProvisionedPackage`；區域參數為 `-Regions`（複數），不是 `-Region`。
- LXP 的 `.appxbundle`／`.msixbundle` 改讀 `AppxMetadata/AppxBundleManifest.xml`；兩種 manifest 都沒有時警告略過。
- Appx 比對改用完整 PFN，不只比 DisplayName。
- `Keep` 模式額外保護 `*LanguageExperiencePack*`，避免映像內既有語言套件被移除。
- `Drivers.Recurse`、`Drivers.Targets` 在此版本並不存在，計畫中的「移除」為無操作。
- 自訂設定檔需包含 `Drivers`、`Lxp`、`Apps` 三區塊（模組為 `Set-StrictMode 2.0`）。

**驗證結果**: Pester 91 項通過（既有 47 項＋新增 44 項，全部離線以 Mock 完成）；PSScriptAnalyzer Error／Warning 為 0。新增檔案與修改檔案皆為 CRLF＋UTF-8 BOM。

**審查修正**: antigravity 審查後修正：LXP 路徑於步驟 1 預先檢查；LXP 的 License.xml 暫存檔以 PFN 命名，避免同名套件互相覆寫；驅動集合改為有序字典（ALL→WinPE→OS）；步驟說明補上驅動注入。未採納「擴大 Keep 模式保護清單」的建議，理由是計畫規定 Keep 為「只保留清單內的 app」，框架保護範圍維持計畫定義，由使用者決定是否擴充。

**尚未驗證**（需實機或真實檔案）:
- LXP 的 `License.xml` 是否確實位於套件 zip 內。
- 真實 install.wim 中 `Get-AppxProvisionedPackage` 的 `DisplayName` 與 PackageFullName 尾段是否與清單 PFN 吻合。
- 步驟 7 虛擬版本：程式碼顯示其由已寫回的 EnterpriseS 索引 Append 產生，因此會帶入驅動與 Appx 變更；尚未以實機確認。
- 實機 ISO 完整流程。

### 2026-10-16 - 更新包整組下載、checkpoint 與主流程接線

**變更內容**: 新增 `Save-WinMediaBuildSet`（UUP 整組下載）、`Resolve-WinMediaCumulativeSet`（目標與 checkpoint 判定）、`New-WinMediaUpdateStage`（僅含目標與 checkpoint 的暫存資料夾）、`Find-WinMediaLearnKb`（Learn 交叉檢查）、`Get-WinMediaIndexInfo`（逐索引補查）、`Install-WinMediaDeferredFod`（NetFx3 延後注入）。主流程新增 `Download.Build`／`Download.KB` 下載步驟；install.wim 改為 SSU → 語言包 → LCU → cleanup → NetFx3 → .NET → Appx → LXP → 驅動 → WinRE。

**與既有行為的差異**:
- install.wim 的 cleanup 原本在 LCU 之前，現在移到 LCU 之後，並遵循 Microsoft 表格。
- Catalog 標題過濾、UUP 用戶端條目選擇、逐索引架構欄位為既有缺陷修正。

**驗證結果**: Pester 204 項通過、失敗 0（Windows PowerShell 5.1、Pester 6.2.0，Invoke-Validation 全量）；PSScriptAnalyzer Error／Warning 為 0。

**尚未驗證**（需實機）:
- 實際下載整組 `.msu`／`.cab` 的檔案完整性與 UUP 的速率限制。
- DISM 實際套用 checkpoint 與暫存資料夾硬連結的行為（使用者磁碟區的檔案系統）。
- PackageDir 位於 OneDrive 內時，多 GB 下載會被同步（未變更，待使用者決定）。
