# WinMediaRefresh

以更新包更新原版 Windows 10 21H2 LTSC / Windows 11 安裝 ISO，支援 ESD/WIM 輸出與虛擬版本（模組版本 0.5.0）。

## 概述

本模組以 PowerShell 5.1 實作，依 `windows-media-update-v5.md` 規劃。母檔為原版 ISO，更新包由使用者手動放入 `PackageDir`，模組依內容分類後套用到 WinRE、install.wim、boot.wim 與安裝媒體，最後以 oscdimg 產出雙開機 ISO，或輸出 install.esd。

完整設計與未決事項見 [設計文件](DESIGN.md)。

## 特性

- **手動更新包**：不連網、不自動下載；依 `update.mum` 與 manifest 分類，不只看檔名。
- **DISM 只用 Cmdlet**：一律呼叫 DISM PowerShell 模組，不直接執行 `dism.exe`。
- **DISM 來源可切換**：`Config.DismProvider` 可設為 `Inbox`（預設）或 `ADK`。
- **ESD 與 WIM 輸出**：`Config.OutputFormat` 可選 `WIM` 或 `ESD`；產生 ESD 一律使用 wimlib。
- **第三方工具自動取得**：wimlib 與 ADK 缺少時自動取得（見下節）；wimlib 只依 `Wimlib.Path` 指定與 wimlib 自身參數執行，不與 DISM 指令混用。
- **虛擬版本**：依 `VirtualEditions` 設定，以 DISM `/Set-Edition` 產生。
- **三層日誌**：操作紀錄與一般 Log 分開，敏感值會遮罩（見 `Protect-WinMediaLogValue`）。
- **安全卸載**：每個掛載包在 `try/finally` 中處理，失敗時 `-Discard`。
- **自訂驅動**：依 ALL／WinPE／OS 三種子資料夾注入驅動（見下節）。
- **自訂 LXP**：遞迴偵測語言體驗套件，加入 install.wim。
- **Appx 清單**：`CustomAppsList.txt` 可指定要移除或只保留的 provisioned app。

## 使用方法

### 需求

- Windows PowerShell 5.1（不保證 5.1 以下）
- 系統管理員權限
- 原版 Windows ISO
- 輸入資料夾集中於執行腳本所在目錄：更新包 `Packages\`、驅動 `Drivers\`、LXP `Lxp\`、語言包 `Lang\`、FoD `Fod\`（可為分發的 cab）、StoreApps `StoreApps\`（注入前驗證 Microsoft 簽章）、Appx 清單 `CustomAppsList.txt`（設定檔留空時自動採用，資料夾不存在則停用）
- `oscdimg.exe` 與 ADK DISM：缺少時自動下載 ADK 安裝程式（`go.microsoft.com/fwlink/?linkid=2289980`）並以 `/quiet` 安裝 Deployment Tools；安裝程式須為 Microsoft 簽章，否則刪除並中止。需系統管理員權限。
- wimlib-imagex 1.14.5：ESD 轉換在 `Wimlib.Path` 有指定時改用 wimlib；檔案不存在則下載 `wimlib-1.14.5-windows-<架構>-bin.zip`，以 wimlib 論壇公告的 SHA-256 校驗，不符即刪除並中止。若 `tools\wimlib\` 內已有相符的壓縮檔，直接使用，不連網。


### 第三方工具（已打包）

- wimlib 1.14.5（ESD 輸出用）：本 repo 不附帶 wimlib 壓縮檔。檔名依主機架構為 `wimlib-1.14.5-windows-<架構>-bin.zip`，架構為 `x86_64`、`aarch64`、`i686` 其中之一。
  - 來源：<https://wimlib.net/downloads/>；SHA-256 取自 wimlib 論壇 1.14.5 公告 <https://wimlib.net/forums/viewtopic.php?t=1133>，程式內以常數比對。
  - 未設定 `Wimlib.Path` 時，依下列順序取得：
    1. `%LOCALAPPDATA%\WinMediaRefresh\tools\wimlib-1.14.5\` 內的 wimlib 通過完整性檢查（zip 內容逐檔比對，多餘檔案會被拒絕）→ 直接使用；
    2. 快取中已驗證的 zip → 重新解壓；
    3. 子模組內附路徑 `PSModules\Imaging\tools\wimlib\<檔名>`，SHA-256 相符才使用；不符則略過，改走下一步；
    4. 下載，SHA-256 不符即刪除並中止。
  - 設定 `Wimlib.Path` 指向既有的 `wimlib-imagex.exe` 時，檔案存在即直接使用，不做 SHA-256 校驗。
- `oscdimg.exe` 與 ADK 的 DISM 不包含於本 repo，缺少時由模組自動安裝 ADK Deployment Tools（需系統管理員權限）。

### WorkDir 權限與 Defender 排除

- WorkDir 根目錄的 ACL 會改成關閉繼承，只有 SYSTEM 與 Administrators 完全控制。只有下列三種 WorkDir 會套用：
  1. 本次新建的目錄；
  2. 既存但為空的目錄（本次在檢查前寫入的 `logs`、`downloads` 這類允許項目不算內容）；
  3. 有可信標記的目錄：根目錄內有 `.winmedia-workroot`，且根目錄 ACL 仍是本工具設定的狀態（關閉繼承，ACE 只有 SYSTEM 與 Administrators）。
- 下列情況會拒絕執行，ACL 不動：
  - WorkDir 是磁碟根目錄（例如 `E:\` 或 UNC 共用根目錄）。
  - 既存、非空、沒有可信標記的目錄。錯誤訊息會列出擋住執行的項目。舊版留下的 WorkDir 第一次執行會因此被擋，請改用新的或空的 WorkDir，或把 OutputDir、MountDir 移出 WorkDir。
  - WorkDir 或允許項目的擁有者不是 Administrators、SYSTEM 或目前使用者。
  - WorkDir 本身、允許項目，或要清空的工作子目錄內有 junction 或符號連結。
- 根目錄若手動加過 ACE，標記會被判定為不可信，改依上面「是否為空」的規則處理。
- 非 NTFS／ReFS 卷（例如 FAT32、exFAT）沒有 ACL：只發出警告、不套用 ACL，標記存在即信任。這類卷上 WorkDir 與 `defender-state.json` 不受權限保護。
- 復原：若錯誤訊息只列出 `.winmedia-workroot`，代表上次寫入標記後套用權限沒有完成。確認目錄內容後刪除 `.winmedia-workroot`，再重新執行。
- Defender 排除（設定 `DefenderExclusions` 開啟時）：
  - 加入排除前先把即將新增的路徑寫入狀態檔 `<WorkDir>\defender-state.json`；結束時只移除本次新增的排除。
  - 程序被強制結束後，下次啟動時（不論當次是否開啟 `DefenderExclusions`）只移除同時列在狀態檔、又等於本次 WorkDir、MountDir、OutputDir 其中之一的排除，其餘只發出警告、不移除。
  - 出現「排除狀態檔仍在」或「排除狀態檔無法解析」的警告時，先到「Windows 安全性」手動檢查排除清單，再刪除狀態檔。

### 示例

先預覽不實際寫入：

```powershell
.\Update-WindowsMedia.ps1 -SourceIso 'D:\ISO\Win11.iso' -WhatIf
```

實際執行：

```powershell
.\Update-WindowsMedia.ps1 -SourceIso 'D:\ISO\Win11.iso'
```

`-Force` 可覆寫 `OutputDir` 中已存在的 ISO。

指定路徑（掛載、暫存、輸出皆可自訂）：

```powershell
.\Update-WindowsMedia.ps1 -SourceIso 'D:\ISO\Win11.iso' -WorkDir 'E:\WMWork' -MountDir 'E:\MountUUP' -OutputDir 'F:\Out'
```

設定檔為 `Config\Default.psd1`，主要欄位：

| 欄位 | 預設 | 說明 |
|------|------|------|
| `PackageDir` | 空白 | 更新包資料夾；空白 = 執行腳本所在目錄\`Packages` |
| `WorkDir` | 空白 | 工作（暫存）目錄；空白時為執行腳本所在磁碟根目錄下的 `WinMediaWork`（例如 `D:\WinMediaWork`，與腳本目錄內的輸入資料夾不重疊），使用前檢查為絕對路徑且不在 OneDrive 內；參數 `-WorkDir` 覆寫 |
| `MountDir` | 空白 | 掛載目錄；空白時依 Convert-UUP.cmd：WorkDir 所在磁碟根目錄下的 `MountUUP`（非 NTFS 改用系統碟）；參數 `-MountDir` 覆寫，必須是空目錄或不存在 |
| `OutputDir` | 空白 | 成品輸出目錄；空白時為工具所在磁碟根目錄\WinMediaOut（不在 OneDrive 內）；參數 `-OutputDir` 覆寫 |
| `Wimlib.Path` | 空白 | 非空 = 手動指定 `wimlib-imagex.exe`，ESD→WIM 改用 wimlib；檔案不存在時自動下載。空白 = ESD→WIM 用 DISM，WIM→ESD 自動下載至 `%LOCALAPPDATA%\WinMediaRefresh\tools\wimlib-1.14.5` |
| `AdkRoot` | ADK 預設安裝路徑 | `DismProvider = 'ADK'` 或需要 oscdimg 時使用；缺少時自動安裝 Deployment Tools |
| `DismProvider` | `Inbox` | `Inbox` 或 `ADK` |
| `OutputFormat` | `WIM` | `WIM` 或 `ESD` |
| `WinPEUpdate` | `SafeOS` | WinPE 核心更新路線：`SafeOS`（套用 SafeOS DU，已驗證）或 `Lcu`（convert-UUP 路線：WinRE 套 SSU＋SafeOS DU，boot.wim 再套最新 LCU；尚未 e2e 驗證） |
| `UpdateBootFiles` | `$true` | 選項 B：改用安裝映像內已套用 LCU 的 `_EX` 開機檔（bootx64、bootmgr、efisys、memtest、boot.stl、fonts、cipolicies）。**風險**：這些是 UEFI CA 2023 開機檔，韌體 db 沒有 2023 CA 的機器開啟 Secure Boot 可能無法開機 |
| `ResetBase` | `$false` | 啟用後無法解除安裝更新 |
| `Drivers.Path` | 空白 | 驅動資料夾（含 `ALL`、`WinPE`、`OS` 子資料夾）；空白 = 執行腳本所在目錄\`Drivers`（不存在則停用） |
| `Drivers.ForceUnsigned` | `$false` | 是否注入未簽章驅動（有風險，開啟時寫入 Warning） |
| `Lxp.Path` | 空白 | LXP 資料夾（遞迴偵測）；空白 = 執行腳本所在目錄\`Lxp`（不存在則停用），只加入 install.wim |
| `Apps.CustomAppsList` | 空白 | `CustomAppsList.txt` 路徑；空白 = 執行腳本所在目錄\`CustomAppsList.txt`（不存在則停用） |
| `Apps.CustomListMode` | `Remove` | `Remove` = 移除清單內的 app；`Keep` = 只保留清單內的 app（框架與語言套件不移除） |
| `Download.Method` | `WebRequest` | 下載方式：`WebRequest`、`Bits` 或 `Curl`（需 Windows 內建 `curl.exe`）；SHA-1 驗證不受影響 |
| `Download.Build` | 空白 | 目標 build（例如 `26100.9711`）。有值時以 UUP 下載整組檔案（目標 CU、checkpoint、SafeOS、SetupDU、.NET）到 PackageDir；Learn 只作交叉檢查；UUP 會移除舊 build，無法提供時會提示改用 `Download.KB`。空白 = 不下載 |
| `Download.KB` | 空白 | 只指定 KB（例如 `KB5127648`）時改用 Catalog；`Download.Build` 與本項同時有值時以 Build 為準。空白 = 不下載 |

自訂設定檔需包含 `Drivers`、`Lxp`、`Apps` 三區塊（模組以 `Set-StrictMode 2.0` 執行）。

### 自訂內容

**更新原始檔**（`PackageDir`）、**驅動**（`Drivers.Path`）、**LXP**（`Lxp.Path`）必須是三個獨立資料夾，不得相等、包含或被包含，也不得位於 `WorkDir` 內，否則步驟 1 即中止。

驅動資料夾結構（與 Convert-UUP.cmd 相同）：

| 子資料夾 | WinRE（winre.wim） | install.wim | boot.wim 索引 1、2 |
|----------|:---:|:---:|:---:|
| `ALL` | ✅ | ✅ | ✅ |
| `WinPE` | ✅ | ❌ | ✅ |
| `OS` | ❌ | ✅ | ❌ |

- 只使用這三個子資料夾，根目錄的 `.inf` 會被忽略。
- 子資料夾內會遞迴搜尋 `.inf`；沒有 `.inf` 的子資料夾略過並寫入 Warning。
- **開機必要的儲存驅動請放入 `ALL`**，只放 `OS` 時安裝程式可能看不到磁碟。
- 未簽章驅動預設拒絕。

LXP：遞迴偵測檔名含 `LanguageExperiencePack` 的 `.appx`、`.appxbundle`、`.msix`、`.msixbundle`，從套件內讀取 `AppxManifest.xml`（或 bundle 的 `AppxMetadata/AppxBundleManifest.xml`）與 `License.xml`；缺少 `License.xml` 時略過並寫入 Warning。

CustomAppsList：每行一個 PackageFamilyName（例如 `Microsoft.WindowsCalculator_8wekyb3d8bbwe`），`#` 開頭為註解，比對不分大小寫。

- `Remove`（預設）：移除清單中列出的 provisioned app。
- `Keep`：移除清單以外的 provisioned app。清單為空時拒絕執行。以下套件一律保留：框架（`Microsoft.VCLibs*`、`Microsoft.UI.Xaml*`、`Microsoft.NET.*`、`Microsoft.WindowsAppRuntime*`）、語言體驗套件，以及依 install.wim 盤點確認存在的 Store（`Microsoft.WindowsStore`、`Microsoft.StorePurchaseApp`）、App Installer（`Microsoft.DesktopAppInstaller`）、安全性（`Microsoft.SecHealthUI`）與編解碼擴充（VP9、WebMedia、HEIF、HEVC、AV1、RAW、WebP、AVC、MPEG2）。`Remove` 模式不受此保護清單影響，仍以明確列出的清單為準。

Appx 移除與 LXP 加入只作用於 install.wim；執行順序為 LCU → Appx 移除 → LXP 加入 → 驅動注入。

### 公開函式

- `Invoke-WindowsMediaRefresh`：主流程
- `Export-WinMediaEsd`：輸出 ESD
- `Add-WinMediaVirtualEdition`：加入虛擬版本
- `Get-WinMediaPackageCategory`：分類更新包

## 目錄結構

```
WinMediaRefresh/
├── WinMediaRefresh.psd1          模組清單
├── WinMediaRefresh.psm1          模組載入
├── Update-WindowsMedia.ps1       命令列入口
├── Config/Default.psd1           預設設定
├── Public/                       公開函式
├── Modules/                      專案功能模組（路徑規則、驅動、LXP、Appx、更新包分類）
├── Tests/WinMediaRefresh.Tests.ps1   Pester 測試（既有功能）
├── Tests/WinMediaWimlib.Tests.ps1    Pester 測試（wimlib／ADK 取得與分流）
├── Tests/WinMediaDriver.Tests.ps1    Pester 測試（路徑重疊、驅動三種狀態、注入位置）
├── Tests/WinMediaAddons.Tests.ps1    Pester 測試（LXP、CustomAppsList、Appx 移除、步驟順序）
├── Tests/PathSanitize.Tests.ps1      Pester 測試（路徑、登錄機碼、網址淨化）
├── Tests/WinMediaInputPath.Tests.ps1 Pester 測試（輸入資料夾預設值）
├── Tests/WinMediaRedirect.Tests.ps1  Pester 測試（共用下載器的重導向逐跳驗證）
├── Tests/WinMediaMountPoint.Tests.ps1   Pester 測試（掛載點目錄由建立者於成功、失敗後清除）
├── Tests/WinMediaPackageWim.Tests.ps1   Pester 測試（WIM 格式 .msu 以 wimlib 展開、檔頭判斷）
├── Tests/WinMediaRootImports.Tests.ps1  Pester 測試（根模組可解析 PathSanitize 函式）
├── Tests/WinMediaSetupDu.Tests.ps1      Pester 測試（Setup DU 內容辨識、SafeOS 反向測試、文件第 26–28 列順序）
├── Tests/Invoke-Validation.ps1       驗證入口：Pester 6.2.0 + PSScriptAnalyzer
├── README.md
└── DESIGN.md
```

## 測試

每次修改後須以 Windows PowerShell 5.1 執行驗證，Pester 或 PSScriptAnalyzer 任一失敗即非 0 結束：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Tests\Invoke-Validation.ps1
```

測試不連網：下載、安裝、解壓縮與外部程式皆以 Mock 代替。

## 目前狀態

- Pester：238 個單元測試通過（18 個測試檔，Windows PowerShell 5.1、Pester 6.2.0）。
- PSScriptAnalyzer（Error／Warning）：0 筆。
- 所有 `.ps1`／`.psm1`／`.psd1` 為 CRLF 行尾與 UTF-8 BOM。
- **尚未驗證**：LXP 的 `License.xml` 位置、真實映像中 `Get-AppxProvisionedPackage` 的 PFN 對應（見 `DESIGN.md` 變更歷史 2026-10-15）。
- **已驗證（實機）**：Win11 26300 zh-TW 消費版 ISO 以索引 1（Core）跑完整流程，輸出雙開機 ISO；install 索引 1 更新為 10.0.26300.9711；WIM 格式 `.msu` 經 wimlib 展開後套用成功。
- **實機發現並修正**：分類器原本未辨識 Setup DU（KB5127650，扁平 cab、無 `update.mum`），現以 `SetupPlatform.exe`＋`SetupHost.exe` 內容辨識；DU 先展開到暫存目錄，再依 convert-UUP 2349–2358 行的 `/U` 規則複製進 `sources`（只覆蓋既有檔，不比較時間戳；實測 DU 檔時間早於輸入 ISO，套用 `/D` 會擋掉 DU）。
- **方向與 Microsoft 文件相反（依 convert-UUP，採用）**：文件第 27 列是 WinPE → 媒體；本工具改為媒體 → WinPE 索引 2，在 LCU、cleanup、驅動之後以 `Config\bootwim.txt`、`Config\bootmui.txt`（來源 `uup-converter-wimlib\bin\`）覆蓋 WinPE 同名檔，並加入根目錄 `setup.exe` 與 `sources\inf\setup.cfg`。實測：參考 ISO 的 bootwim 清單 100 項媒體與 WinPE 完全相同；改採此方向前的輸出有 88 項不同，且全部是媒體版本較新的檔。
- **寫入方式（實機修正）**：WinPE 同步不掛載索引 2，改用 `wimlib-imagex update <boot.wim> 2`，指令經標準輸入傳入（wimlib 只接受一次 `--command`）。原因：掛載後映像內的 `sources\alert.gif` 只給 Administrators 讀取（擁有者 TrustedInstaller），`Copy-Item` 會被拒絕；`add` 會覆寫既有檔案（已用小型 WIM 實驗確認）。同步在兩個索引卸載之後、export／optimize 之前執行。
- **已實作（待實機雜湊驗證）**：文件第 28 列的 boot manager（`bootmgfw.efi`、`bootmgr.efi`、`boot.stl`）在索引 2 掛載中自 WinPE 覆蓋到媒體（`UpdateBootFiles` 套用 `_EX` 時略過）。
- **Enablement（待實測）**：Enablement 套件 KB5121794（10.0.26100.9544）未套用；原版 install.wim 索引 1 已內含同一套件 10.0.26100.8966（wimlib 列出 `Windows\servicing\Packages`），成品是否需要 9544 尚未驗證。
- **尚未驗證**：多索引輸出（索引 2–5 未更新，成品不可直接部署）、輸出 ISO 的開機測試（VM）、ARM64 開機參數、ADK oscdimg 路徑、`Get-WindowsEdition -Target` 屬性名稱與 wimlib ESD 轉換。`DESIGN.md` 的「未決問題」列出待確認項目。

## 授權

本專案以 [MIT 授權](LICENSE) 發佈。本 repo 不散布 wimlib；執行時下載的 wimlib 為 GPLv3／LGPL，授權檔包含於該壓縮檔內。

## 相關文檔

- [設計文件](DESIGN.md)
