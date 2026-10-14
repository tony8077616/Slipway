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

# 預設值依執行腳本位置：WorkDir 為所在磁碟根目錄，OutputDir 為腳本所在目錄
if (-not $WorkDir) { $WorkDir = $config.WorkDir }
if (-not $WorkDir) { $WorkDir = [System.IO.Path]::GetPathRoot($PSScriptRoot) }
if (-not $OutputDir) { $OutputDir = $config.OutputDir }
if (-not $OutputDir) { $OutputDir = $PSScriptRoot }

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
