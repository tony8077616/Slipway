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

## 使用方法

### 需求

- Windows PowerShell 5.1（不保證 5.1 以下）
- 系統管理員權限
- 原版 Windows ISO
- 更新包放在 `Config.PackageDir`（預設 `D:\WinMediaPkgs`）
- `oscdimg.exe` 與 ADK DISM：缺少時自動下載 ADK 安裝程式（`go.microsoft.com/fwlink/?linkid=2289980`）並以 `/quiet` 安裝 Deployment Tools；安裝程式須為 Microsoft 簽章，否則刪除並中止。需系統管理員權限。
- wimlib-imagex 1.14.5：ESD 轉換在 `Wimlib.Path` 有指定時改用 wimlib；檔案不存在則下載 `wimlib-1.14.5-windows-<架構>-bin.zip`，以 wimlib 論壇公告的 SHA-256 校驗，不符即刪除並中止。若 `tools\wimlib\` 內已有相符的壓縮檔，直接使用，不連網。


### 第三方工具（已打包）

- `tools/wimlib/wimlib-1.14.5-windows-x86_64-bin.zip`：wimlib 1.14.5 x64 Windows 版，供 ESD 輸出使用。
  - 來源：<https://wimlib.net/downloads/>；SHA-256 取自 wimlib 論壇 1.14.5 公告 <https://wimlib.net/forums/viewtopic.php?t=1133>，與 `tools/wimlib/SHA256SUMS.txt` 一致。
  - 授權：ZIP 內含 `COPYING.GPLv3.txt`、`COPYING.LGPL.txt` 等授權檔，依其條款散布。
  - 使用：不需手動設定。執行時會先以此壓縮檔解壓出 wimlib，校驗不符即中止。若要改用其他 `wimlib-imagex.exe`，設定 `Wimlib.Path`。
- `oscdimg.exe` 與 ADK 的 DISM 不包含於本 repo，缺少時由模組自動安裝 ADK Deployment Tools（需系統管理員權限）。

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
| `PackageDir` | `D:\WinMediaPkgs` | 更新包資料夾 |
| `WorkDir` | 空白 | 工作（暫存）目錄；空白時為執行腳本所在磁碟的根目錄（例如 `D:\`），使用前檢查為絕對路徑且不在 OneDrive 內；參數 `-WorkDir` 覆寫 |
| `MountDir` | 空白 | 掛載目錄；空白時依 Convert-UUP.cmd：WorkDir 所在磁碟根目錄下的 `MountUUP`（非 NTFS 改用系統碟）；參數 `-MountDir` 覆寫，必須是空目錄或不存在 |
| `OutputDir` | 空白 | 成品輸出目錄；空白時為執行腳本所在目錄；參數 `-OutputDir` 覆寫 |
| `Wimlib.Path` | 空白 | 非空 = 手動指定 `wimlib-imagex.exe`，ESD→WIM 改用 wimlib；檔案不存在時自動下載。空白 = ESD→WIM 用 DISM，WIM→ESD 自動下載至 `%LOCALAPPDATA%\WinMediaRefresh\tools\wimlib-1.14.5` |
| `AdkRoot` | ADK 預設安裝路徑 | `DismProvider = 'ADK'` 或需要 oscdimg 時使用；缺少時自動安裝 Deployment Tools |
| `DismProvider` | `Inbox` | `Inbox` 或 `ADK` |
| `OutputFormat` | `WIM` | `WIM` 或 `ESD` |
| `ResetBase` | `$false` | 啟用後無法解除安裝更新 |

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
├── Private/                      內部函式（DISM、掛載、日誌、ADK 解析等）
├── Tests/WinMediaRefresh.Tests.ps1   Pester 測試（既有功能）
├── Tests/WinMediaWimlib.Tests.ps1    Pester 測試（wimlib／ADK 取得與分流）
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

- Pester：47 個單元測試通過（Windows PowerShell 5.1、Pester 6.2.0）。
- PSScriptAnalyzer（Error／Warning）：0 筆。
- 所有 `.ps1`／`.psm1`／`.psd1` 為 CRLF 行尾與 UTF-8 BOM。
- **尚未驗證**：以實際 Windows ISO 完整跑通流程。`DESIGN.md` 的「未決問題」列出待確認項目，包括 ISO 實機測試、ADK oscdimg 路徑、`Get-WindowsEdition -Target` 屬性名稱與 wimlib ESD 轉換。

## 相關文檔

- [設計文件](DESIGN.md)
