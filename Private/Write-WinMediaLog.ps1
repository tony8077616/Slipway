function Write-WinMediaLog {
    # 第 1 層日誌（§4）：依 LogLevel 過濾後寫入 LogFile，使用無 BOM 的 UTF-8 逐行附加
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][ValidateSet('Info', 'Verbose', 'Debug', 'Warning', 'Error')][string]$Level,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message
    )

    $Message = Protect-WinMediaLogValue -Value $Message
    $rank = @{ Error = 0; Warning = 1; Info = 2; Verbose = 3; Debug = 4 }
    $threshold = $rank[[string]$Config.LogLevel]
    if ($null -eq $threshold) { $threshold = $rank['Info'] }

    if ($rank[$Level] -le $threshold -and $Config.LogFile) {
        $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level.ToUpperInvariant(), $Message
        Add-WinMediaTextLine -Path $Config.LogFile -Line $line
    }

    switch ($Level) {
        'Warning' { Write-Warning -Message $Message }
        'Verbose' { Write-Verbose -Message $Message }
        'Debug'   { Write-Debug -Message $Message }
        default   { }
    }
}

function Add-WinMediaTextLine {
    # 統一的 UTF-8（無 BOM）附加寫入；Add-Content -Encoding UTF8 在 5.1 會每次寫入 BOM
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Line
    )

    # .NET 的 File API 以行程 CWD 解析相對路徑，先依 PowerShell 位置轉為完整路徑
    $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $dir = Split-Path -Path $fullPath -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $encoding = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
    [System.IO.File]::AppendAllText($fullPath, $Line + [Environment]::NewLine, $encoding)
}
