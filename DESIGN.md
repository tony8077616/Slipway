# WinMediaRefresh 设计文档

## 设计概述

### 目标

以使用者手動放入的更新包，更新原版 Windows 10 21H2 LTSC 與 Windows 11 安裝 ISO，產出可用於 Ventoy 的 ISO 或 install.esd。規劃來源為 `.claude/plan/windows-media-update-v5.md`。

### 非目標

- 不自動下載更新（Update Catalog）。
- 不做 FAT32 分割；產出單一 ISO。
- 不做 UUP 轉換；母檔一律為原版 ISO。
- 不移除 Appx。
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
        ├─ 外部程式 ─ Invoke-WinMediaExternal（oscdimg、wimlib）
        ├─ ESD 轉換 ─ Convert-WinMediaEsdToWim / Export-WinMediaEsd
        ├─ 虛擬版本 ─ Add-WinMediaVirtualEdition / Test-WinMediaVirtualEdition
        └─ 日誌 ─ Write-WinMediaLog、Invoke-WinMediaOperation、Protect-WinMediaLogValue
```

### 核心組件

- **Invoke-WindowsMediaRefresh**：主流程，依 §3.2 步驟執行，成功才清除 WorkDir。
- **Get-WinMediaPackageCategory**：讀取 `update.mum` 與 manifest 分類更新包（SSU、SafeOS DU、LCU、Setup DU、.NET、語言包、FoD）。
- **Resolve-WinMediaAdk**：依序探測 ADK 的 DISM 目錄，取第一個含 `Dism.psd1` 或 `dism.exe` 者。`dism.exe` 只用於讀取版本號，不執行。
- **Invoke-WinMediaDism**：包裝 DISM Cmdlet，檢查回傳碼，非零即中止。
- **Mount-WinMediaImage**：掛載與卸載，失敗時 `-Discard`。
- **Invoke-WinMediaExternal**：呼叫 oscdimg 與 wimlib 等外部程式。
- **Test-WinMediaVirtualEdition**：檢查虛擬版本條件與 EditionID。
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
| 2026-10-14 | WorkDir 預設為執行腳本所在磁碟根目錄；OutputDir 預設為腳本所在目錄 | 使用者需求（取代先前參照 Convert-UUP 的 WorkDir 預設） | 預設值於入口腳本 `Update-WindowsMedia.ps1` 解析；設定檔兩鍵留空；主流程 WorkDir 為空或非絕對路徑即中止；OutputDir 不做 OneDrive 檢查，腳本位於 OneDrive 內時成品會被同步 |

### 技術選型

- **語言**：PowerShell 5.1（基準）；PS 7 語法僅在 `$PSVersionTable` 守衛分支內使用。
- **理由**：目標環境為 Windows 內建 PowerShell，避免額外安裝執行環境；DISM Cmdlet 與 Pester 6.2.0 可在 5.1 上執行。

## 權衡取捨

### 已知限制

- 更新包須手動準備，無法自動判斷是否為最新版本。
- Windows 10 21H2 無 checkpoint 機制；實機測試需覆蓋兩種母檔狀態。
- ESD 輸出依賴 wimlib；未安裝時 ESD 模式直接報錯，不退回 DISM。
- 虛擬版本的 SPP 檔缺失時中止，不略過。

### 技術債務

- **Learn 文件內部不一致**：checkpoint 段落的 step 編號（12/13、23 與範例註解）前後不一致。計畫採表格讀法，`-WhatIf` 輸出標示此差異，待實機確認。
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

## 未決問題

以下項目尚未以實際 Windows ISO 驗證，來自規劃 §7、§8：

1. 實際 ISO 的完整流程（需使用者提供 ISO 路徑）。
2. ADK `oscdimg.exe` 的路徑（含空白）。
3. `Get-WindowsEdition -Target` 的屬性名稱。
4. `Save-WindowsImage` 的語意。
5. Setup DU 的版面配置。
6. 真實更新包的分類結果。
7. 掛載失敗後的清理。
8. wimlib 的 ESD 轉換。

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
