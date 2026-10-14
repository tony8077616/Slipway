@{
    PowerShellVersion    = '5.1'                 # 最低版本；5.1 以下不保證
    PackageDir           = 'D:\WinMediaPkgs'
    WorkDir              = ''                    # 工作目錄（暫存）；空白 = 執行腳本所在磁碟的根目錄，使用前檢查不在 OneDrive 內；可由 -WorkDir 覆寫
    MountDir             = ''                    # 掛載目錄；空白 = 依 Convert-UUP：WorkDir 所在磁碟根目錄\MountUUP（非 NTFS 改用系統碟）；可由 -MountDir 覆寫
    OutputDir            = ''                    # 輸出目錄；空白 = 執行腳本所在目錄；可由 -OutputDir 覆寫
    Languages            = @('ja-JP')
    FodIsoPath           = ''                    # LOF/FOD 或 LANGPACK ISO
    Indexes              = @()                   # 空 = 全部
    ResetBase            = $false
    ResetBaseOS          = $false
    OutputFormat         = 'WIM'                 # 'WIM' 或 'ESD'
    Wimlib               = @{ Path = '' }
    DismProvider         = 'Inbox'               # 'Inbox' 或 'ADK'，見 §3.4
    AdkRoot              = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit'  # oscdimg 與 ADK DISM 位置
    VirtualEditions      = @()                   # 例：@('IoTEnterpriseS')，見 §2.7
    DeleteSourceEdition  = $false                # 建立虛擬版本後是否刪除 EnterpriseS，見 §2.7.6
    LogLevel             = 'Info'
    DebugTrace           = 0                     # 0/1/2/3，見 §4
}
