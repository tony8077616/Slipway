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

$result = Invoke-WindowsMediaRefresh -SourceIso $SourceIso -Config $config -Force:$Force -WhatIf:$WhatIfPreference `
    -WorkDir $WorkDir -MountDir $MountDir -OutputDir $OutputDir
if ($WhatIfPreference) {
    $result | ForEach-Object { Write-Output $_ }
}
else {
    Write-Output $result
}
