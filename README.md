# WinMediaRefresh

以更新包更新原版 Windows 10 21H2 LTSC / Windows 11 安裝 ISO，支援 ESD/WIM 輸出與虛擬版本（模組版本 0.5.0）。

## 概述

本模組以 PowerShell 5.1 實作，依 `windows-media-update-v5.md` 規劃。母檔為原版 ISO，更新包由使用者手動放入 `PackageDir`，模組依內容分類後套用到 WinRE、install.wim、boot.wim 與安裝媒體，最後以 oscdimg 產出雙開機 ISO，或輸出 install.esd。

完整設計與未決事項見 [設計文件](DESIGN.md)。

## 特性

- **手動更新包**：不連網、不自動下載；依 `update.mum` 與 manifest 分類，不只看檔名。
- **DISM 只用 Cmdlet**：一律呼叫 DISM PowerShell 模組，不直接執行 `dism.exe`。
- **DISM 來源可切換**：`Config.DismProvider` 可設為 `Inbox`（預設）或 `ADK`。
- **ESD 與 WIM 輸出**：`Config.OutputFormat` 可選 `WIM` 或 `ESD`；ESD 需要 wimlib。
- **虛擬版本**：依 `VirtualEditions` 設定，以 DISM `/Set-Edition` 產生。
- **三層日誌**：操作紀錄與一般 Log 分開，敏感值會遮罩（見 `Protect-WinMediaLogValue`）。
- **安全卸載**：每個掛載包在 `try/finally` 中處理，失敗時 `-Discard`。

## 使用方法

### 需求

- Windows PowerShell 5.1（不保證 5.1 以下）
- 系統管理員權限
- 原版 Windows ISO
- 更新包放在 `Config.PackageDir`（預設 `D:\WinMediaPkgs`）
- `oscdimg.exe`（ADK 的 Deployment Tools，需自行安裝 Windows ADK）

### 第三方工具（已打包）

- `tools/wimlib/wimlib-1.14.5-windows-x86_64-bin.zip`：wimlib 1.14.5 x64 Windows 版，供 ESD 輸出使用。
  - 來源：<https://wimlib.net/downloads/>（官方頁面未提供校驗碼；`tools/wimlib/SHA256SUMS.txt` 為下載後自行計算的 SHA256）。
  - 授權：ZIP 內含 `COPYING.GPLv3.txt`、`COPYING.LGPL.txt` 等授權檔，依其條款散布。
  - 使用：解壓縮後，將 `Config/Default.psd1` 的 `Wimlib.Path` 設為 `wimlib-imagex.exe` 的絕對路徑。
- `oscdimg.exe` 與 ADK 的 DISM 不包含於本 repo，屬 Microsoft ADK，須自行安裝。

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
| `AdkRoot` | ADK 預設安裝路徑 | `DismProvider = 'ADK'` 時使用 |
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
├── Tests/WinMediaRefresh.Tests.ps1   Pester 測試
├── README.md
└── DESIGN.md
```

## 測試

```powershell
Import-Module Pester -RequiredVersion 6.2.0
Invoke-Pester -Path .\Tests
```

## 目前狀態

- Pester：17 個測試於 Windows 11 測試 VM 通過（Pester 6.2.0）。
- PSScriptAnalyzer（Error／Warning）：0 筆。
- **尚未驗證**：以實際 Windows ISO 完整跑通流程。`DESIGN.md` 的「未決問題」列出待確認項目，包括 ISO 實機測試、ADK oscdimg 路徑、`Get-WindowsEdition -Target` 屬性名稱與 wimlib ESD 轉換。

## 相關文檔

- [設計文件](DESIGN.md)
