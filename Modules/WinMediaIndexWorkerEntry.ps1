param([Parameter(Mandatory)][string]$JobPath)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# 子行程入口（powershell.exe -File 只接受 .ps1）。PSModulePath 重設與 Tests\Invoke-Validation.ps1 相同，只在 Windows PowerShell 5.1 生效
if ($PSVersionTable.PSEdition -ne 'Core') {
    $docs = [Environment]::GetFolderPath('MyDocuments')
    $env:PSModulePath = @(
        [IO.Path]::Combine($docs, 'WindowsPowerShell\Modules'),
        [IO.Path]::Combine($env:ProgramFiles, 'WindowsPowerShell\Modules'),
        [IO.Path]::Combine($env:SystemRoot, 'system32\WindowsPowerShell\v1.0\Modules'),
        [IO.Path]::Combine($docs, 'PowerShell\Modules')
    ) -join ';'
}

$indexDir = Split-Path -Parent $JobPath
$resultPath = Join-Path -Path $indexDir -ChildPath 'result.clixml'
try {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'WinMediaIndexWorker.psm1') -Force
    $job = Import-Clixml -LiteralPath $JobPath
    Invoke-WinMediaIndexWorkerJob -Job $job -ResultPath $resultPath
    if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) { throw "子行程未寫出結果檔：$resultPath" }
    exit 0
}
catch {
    $_ | Out-String | Set-Content -LiteralPath (Join-Path -Path $indexDir -ChildPath 'error.txt') -Encoding UTF8
    exit 1
}
