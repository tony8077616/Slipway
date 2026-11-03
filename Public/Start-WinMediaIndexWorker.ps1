function Start-WinMediaIndexWorker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = '內部啟動器，由排程流程呼叫；測試以 mock 取代 Start-Process')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Job,
        [Parameter(Mandatory)][string]$IndexDir
    )

    New-Item -ItemType Directory -Path $IndexDir -Force | Out-Null
    $jobPath = Join-Path -Path $IndexDir -ChildPath 'job.clixml'
    Export-Clixml -LiteralPath $jobPath -InputObject $Job -Depth 10

    $entryPath = Join-Path -Path $script:ModuleRoot -ChildPath 'Modules\WinMediaIndexWorkerEntry.ps1'
    $powershell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $argumentList = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (ConvertTo-WinMediaArgumentValue -Value $entryPath), (ConvertTo-WinMediaArgumentValue -Value $jobPath))

    return Start-Process -FilePath $powershell -ArgumentList $argumentList -PassThru
}
