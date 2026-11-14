#Requires -Version 5.1
# 手動清理工具（Step 11）：卸載本工具遺留的掛載、移除空的掛載資料夾、還原本工具加入的 Defender 排除；
# 可選：卸載指定的來源 ISO，與移除登記過的 WorkDir 子目錄（-IncludeWorkDir）。絕不碰 OutputDir。
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath,
    [string]$WorkDir,
    [string]$MountDir,
    [string]$OutputDir,
    [string]$SourceIso,
    [switch]$IncludeWorkDir
)

$ErrorActionPreference = 'Stop'

# 順序：先匯入組合模組，最後匯入 WinMediaPath（與 Update-WindowsMedia.ps1 相同；組合模組內會以 -Force 重新匯入 WinMediaPath）
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Modules\WinMediaWorkspace.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Modules\WinMediaPath.psm1') -Force

# 預設設定檔在函式本體內解析：Windows PowerShell 5.1 的參數預設值中 $PSScriptRoot 可能為空
if (-not $ConfigPath) { $ConfigPath = Join-Path -Path $PSScriptRoot -ChildPath 'Config\Default.psd1' }
$config = Import-PowerShellDataFile -LiteralPath $ConfigPath
# 預設值與 Update-WindowsMedia.ps1 共用同一個 helper，Defender 狀態檔才會對到同一個 WorkDir 雜湊
$WorkDir = Resolve-WinMediaScriptDefault -Value $WorkDir -ConfigValue $config.WorkDir -RootDir $PSScriptRoot -ChildName 'WinMediaWork'
$OutputDir = Resolve-WinMediaScriptDefault -Value $OutputDir -ConfigValue $config.OutputDir -RootDir $PSScriptRoot -ChildName 'WinMediaOut'
# 網路檢查先於提權與 UAC 提示（需求第 6、10 項）；在 Resolve-WinMediaMountDir 之前檢查，避免對網路路徑做存取
Assert-WinMediaLocalPath -Path $WorkDir -Name 'WorkDir'
Assert-WinMediaLocalPath -Path $OutputDir -Name 'OutputDir'
if ($SourceIso) { Assert-WinMediaLocalPath -Path $SourceIso -Name 'SourceIso' }
if ($MountDir) { Assert-WinMediaLocalPath -Path $MountDir -Name 'MountDir' }
$mountDirValue = if ($MountDir) { $MountDir } else { [string]$config.MountDir }
$MountDir = Resolve-WinMediaMountDir -WorkDir $WorkDir -MountDir $mountDirValue
Assert-WinMediaLocalPath -Path $MountDir -Name 'MountDir'

# -WhatIf 只列出動作，不需要系統管理員權限，因此略過提權（與 Update-WindowsMedia.ps1 相同）
if (-not $WhatIfPreference -and -not (Test-WinMediaAdministrator)) {
    if (-not [Environment]::UserInteractive) { throw '需要系統管理員權限。' }
    $choice = $Host.UI.PromptForChoice('需要系統管理員權限', '選擇「提權」以系統管理員身分重新執行，或選擇「離開」。', [System.Management.Automation.Host.ChoiceDescription[]]@('提權(&E)', '離開(&X)'), 1)
    if ($choice -ne 0) { return }
    $bound = @{}
    foreach ($key in $PSBoundParameters.Keys) { $bound[$key] = $PSBoundParameters[$key] }
    $bound.ConfigPath = $ConfigPath
    $bound.WorkDir = $WorkDir
    $bound.OutputDir = $OutputDir
    $bound.MountDir = $MountDir
    $relaunch = Get-WinMediaRelaunchArgument -ScriptPath $PSCommandPath -Bound $bound -PathKeys @('SourceIso', 'ConfigPath', 'WorkDir', 'MountDir', 'OutputDir')
    try {
        Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $relaunch -Verb RunAs -Wait
    }
    catch [System.ComponentModel.Win32Exception] {
        if ($_.Exception.NativeErrorCode -eq 1223) { Write-Warning '已取消提權。'; return }
        throw
    }
    return
}

# 日誌位置與主流程相同（OperationLog、LogFile 依 WorkDir 推導）
$config.WorkDir = $WorkDir
$location = Resolve-WinMediaLogLocation -Config $config
$config.LogDir = $location.LogDir
$config.OperationLog = $location.OperationLog
$config.LogFile = Resolve-WinMediaLogFile -Config $config
# 第一筆日誌寫入前先建立資料夾（主流程也會先建立 LogDir）；-WhatIf 時仍會留下 logs，屬預期
$logParent = Split-Path -Parent $config.LogFile
# -WhatIf:$false：$WhatIfPreference 是全域偏好，New-Item 會因此被跳過，日誌資料夾就不會建立
if (-not (Test-Path -LiteralPath $logParent)) { New-Item -ItemType Directory -Path $logParent -Force -WhatIf:$false | Out-Null }

Invoke-WinMediaWorkspaceCleanup -MountDir $MountDir -WorkDir $WorkDir -OutputDir $OutputDir -Config $config -SourceIso $SourceIso -IncludeWorkDir:$IncludeWorkDir -WhatIf:$WhatIfPreference
