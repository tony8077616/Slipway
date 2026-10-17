@{
    PowerShellVersion    = '5.1'                 # 最低版本；5.1 以下不保證
    PackageDir           = ''                    # 更新包資料夾；空白 = 執行腳本所在目錄\Packages（見 Resolve-WinMediaInputPath）
    WorkDir              = ''                    # 工作目錄（暫存）；空白 = 執行腳本所在磁碟根目錄\WinMediaWork（與輸入資料夾不重疊），使用前檢查不在 OneDrive 內；可由 -WorkDir 覆寫
    MountDir             = ''                    # 掛載目錄；空白 = 依 Convert-UUP：WorkDir 所在磁碟根目錄\MountUUP（非 NTFS 改用系統碟）；可由 -MountDir 覆寫
    OutputDir            = ''                    # 輸出目錄；空白 = 工具所在磁碟根目錄\WinMediaOut（不在 OneDrive 內）；可由 -OutputDir 覆寫
    Languages            = @('ja-JP')
    Indexes              = @()                   # 空 = 全部
    ResetBase            = $false
    ResetBaseOS          = $false
    OutputFormat         = 'WIM'                 # 'WIM' 或 'ESD'
    WinPEUpdate          = 'SafeOS'              # WinPE（WinRE／boot.wim）核心更新路線：'SafeOS'＝套用 SafeOS DU（已 e2e 驗證，預設）；'Lcu'＝convert-UUP 路線（WinRE 只套 SSU，boot.wim 套最新 LCU；目前實測無法提升核心版本，守衛會中止）
    UpdateBootFiles      = $true                 # 選項 B（convert-UUP UpdtBootFiles）：改用安裝映像內的 *_EX 開機檔（bootx64、bootmgr、efisys、memtest、boot.stl、fonts、cipolicies）；注意為 UEFI CA 2023 開機檔，韌體 db 沒有 2023 CA 的機器開啟 Secure Boot 可能無法開機
    Wimlib               = @{ Path = '' }        # 非空 = 手動指定 wimlib-imagex.exe，ESD 轉換改用 wimlib；檔案不存在時自動下載 1.14.5（SHA-256 校驗）；空白 = ESD→WIM 用 DISM，WIM→ESD 自動下載至 %LOCALAPPDATA%
    DismProvider         = 'Inbox'               # 'Inbox' 或 'ADK'，見 §3.4
    AdkRoot              = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit'  # oscdimg 與 ADK DISM 位置；缺少時自動安裝 Deployment Tools（需系統管理員權限）
    VirtualEditions      = @()                   # 例：@('IoTEnterpriseS')，見 §2.7
    DeleteSourceEdition  = $false                # 建立虛擬版本後是否刪除 EnterpriseS，見 §2.7.6
    LogLevel             = 'Info'
    DebugTrace           = 0                     # 0/1/2/3，見 §4
    Drivers = @{
        Path          = ''          # 含 ALL／WinPE／OS 子資料夾的獨立資料夾；空白 = 執行腳本所在目錄\Drivers（不存在則停用）；ALL＝WinRE＋Install＋Boot，WinPE＝WinRE＋Boot，OS＝Install
        ForceUnsigned = $false      # 是否傳遞 -ForceUnsigned（有風險，未簽章驅動會被注入）
    }
    Lxp = @{
        Path          = ''          # LXP 獨立資料夾（遞迴偵測）；空白 = 執行腳本所在目錄\Lxp（不存在則停用）；只加入 install.wim
    }
    Lang = @{
        Path = ''   # 語言包獨立資料夾（遞迴，只取 .cab）；空白 = 執行腳本所在目錄\Lang（不存在則停用）；只保留 Languages 內的語言
    }
    Fod = @{
        Path = ''   # FoD 獨立資料夾（遞迴，只取 .cab）；空白 = 執行腳本所在目錄\Fod（不存在則停用）；語言中立者一律注入
    }
    StoreApps = @{
        Path = ''   # StoreApps 獨立資料夾（遞迴，.appx／.appxbundle／.msix／.msixbundle）；空白 = 執行腳本所在目錄\StoreApps（不存在則停用）；每個套件都須通過 Microsoft 簽章驗證，未通過者不注入
    }
    Download = @{
        Method        = 'WebRequest'  # 'WebRequest'（預設）、'Bits' 或 'Curl'（需 Windows 內建 curl.exe）；更新包 SHA-1 驗證與 UUP 交叉驗證不受影響
        Build         = ''            # 目標 build，例如 26100.9711；有值時以 UUP 下載整組 KB 檔案（目標、checkpoint、SafeOS、SetupDU、.NET）到 PackageDir，Learn 只作交叉檢查。UUP 會移除舊 build。空白 = 不下載
        KB            = ''            # 只指定 KB（例如 KB5127648）時改用 Catalog；空白 = 不下載。Build 與 KB 同時有值時以 Build 為準
    }
    # 執行期間把 WorkDir、MountDir、OutputDir 加入 Windows Defender 排除（開工前加入，任何結束時只還原本次新增的項目）；需系統管理員權限
    DefenderExclusions   = $false
    Apps = @{
        CustomAppsList = ''         # CustomAppsList.txt 路徑（每行一個 PackageFamilyName，# 為註解）；空白 = 執行腳本所在目錄\CustomAppsList.txt（不存在則停用）
        CustomListMode = 'Remove'   # 'Remove' = 移除清單內的 app；'Keep' = 只保留清單內的 app（框架與語言套件除外）
    }
}
