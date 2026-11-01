[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$SourceIso,
    [string]$ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath 'Config\Default.psd1'),
    [switch]$Force,
    [string]$WorkDir,
    [string]$MountDir,
    [string]$OutputDir
)

$ErrorActionPreference = 'Stop'

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'WinMediaRefresh.psd1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Modules\WinMediaPath.psm1') -Force

$config = Import-PowerShellDataFile -LiteralPath $ConfigPath

# 預設值依執行腳本位置：WorkDir 與 OutputDir 皆為所在磁碟根目錄下的 WinMediaWork／WinMediaOut（與輸入資料夾不重疊，不在 OneDrive 內）
# 輸入資料夾（Packages、Drivers、Lxp、CustomAppsList.txt）由 Invoke-WindowsMediaRefresh 依模組目錄補齊
if (-not $WorkDir) { $WorkDir = $config.WorkDir }
if (-not $WorkDir) { $WorkDir = Join-Path -Path ([System.IO.Path]::GetPathRoot($PSScriptRoot)) -ChildPath 'WinMediaWork' }
if (-not $OutputDir) { $OutputDir = $config.OutputDir }
if (-not $OutputDir) { $OutputDir = Join-Path -Path ([System.IO.Path]::GetPathRoot($PSScriptRoot)) -ChildPath 'WinMediaOut' }

$config.WorkDir = $WorkDir
$config.LogDir = Join-Path -Path $WorkDir -ChildPath 'logs'
$config.OperationLog = Join-Path -Path $config.LogDir -ChildPath 'OperationLog.txt'

# 網路檢查先於提權與 UAC 提示（需求第 6、10 項）；預設 WorkDir 可能落在網路磁碟根，因此訊息會提示傳入 -WorkDir 與 -OutputDir
Assert-WinMediaLocalPath -Path $WorkDir -Name 'WorkDir'
Assert-WinMediaLocalPath -Path $OutputDir -Name 'OutputDir'
Assert-WinMediaLocalPath -Path $SourceIso -Name 'SourceIso'
if ($MountDir) { Assert-WinMediaLocalPath -Path $MountDir -Name 'MountDir' }
if ($config.ContainsKey('ScratchDirectory') -and $config.ScratchDirectory) { Assert-WinMediaLocalPath -Path $config.ScratchDirectory -Name 'ScratchDirectory' }
# -WhatIf 只列出步驟，不需要系統管理員權限，因此略過提權
if (-not $WhatIfPreference -and -not (Test-WinMediaAdministrator)) {
    if (-not [Environment]::UserInteractive) { throw '需要系統管理員權限。' }
    $choice = $Host.UI.PromptForChoice('需要系統管理員權限', '選擇「提權」以系統管理員身分重新執行，或選擇「離開」。', [System.Management.Automation.Host.ChoiceDescription[]]@('提權(&E)', '離開(&X)'), 1)
    if ($choice -ne 0) { return }
    $bound = @{}
    foreach ($key in $PSBoundParameters.Keys) { $bound[$key] = $PSBoundParameters[$key] }
    $bound.ConfigPath = $ConfigPath
    $bound.WorkDir = $WorkDir
    $bound.OutputDir = $OutputDir
    if ($MountDir) { $bound.MountDir = $MountDir }
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

$result = Invoke-WindowsMediaRefresh -SourceIso $SourceIso -Config $config -Force:$Force -WhatIf:$WhatIfPreference `
    -WorkDir $WorkDir -MountDir $MountDir -OutputDir $OutputDir
if ($WhatIfPreference) {
    $result | ForEach-Object { Write-Output $_ }
}
else {
    Write-Output $result
}
