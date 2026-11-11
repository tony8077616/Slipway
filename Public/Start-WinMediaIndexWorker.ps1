function Start-WinMediaIndexWorker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = '內部啟動器，由排程流程呼叫；測試以 mock 取代 Start-Process')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Job,
        [Parameter(Mandatory)][string]$IndexDir
    )

    New-Item -ItemType Directory -Path $IndexDir -Force | Out-Null
    # DISM 的 ScratchDirectory 必須已存在；父程序只建立自己的，子程序的 <scratch>\idxN 在此建立
    if ($Job.ContainsKey('Config') -and $Job['Config'] -is [hashtable] -and $Job['Config'].ContainsKey('ScratchDirectory') -and -not [string]::IsNullOrWhiteSpace([string]$Job['Config']['ScratchDirectory'])) {
        New-Item -ItemType Directory -Path $Job['Config']['ScratchDirectory'] -Force | Out-Null
    }
    $jobPath = Join-Path -Path $IndexDir -ChildPath 'job.clixml'
    Export-Clixml -LiteralPath $jobPath -InputObject $Job -Depth 10

    $entryPath = Join-Path -Path $script:ModuleRoot -ChildPath 'Modules\WinMediaIndexWorkerEntry.ps1'
    $powershell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $argumentList = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (ConvertTo-WinMediaArgumentValue -Value $entryPath), (ConvertTo-WinMediaArgumentValue -Value $jobPath))

    return Start-Process -FilePath $powershell -ArgumentList $argumentList -PassThru
}
