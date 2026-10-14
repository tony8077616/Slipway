function Invoke-WinMediaDism {
    # DISM 來源分派（§3.4）：只呼叫 DISM Cmdlet（§3.4.3），不直接呼叫 dism.exe
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Inbox', 'ADK')][string]$Provider,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [Parameter(Mandatory)][hashtable]$Config
    )

    switch ($Provider) {
        'Inbox' {
            # 內建 Dism 模組於 Windows 11 自動載入，不需匯入
        }
        'ADK' {
            $adk = Resolve-WinMediaAdk -Config $Config
            $loaded = Get-Module -Name Dism
            if ($loaded -and $loaded.Path -ne $adk.ModulePath) {
                throw "Dism 模組已從 '$($loaded.Path)' 載入，與 ADK 路徑不同；請重新開啟工作階段後再執行（§3.4.2 2e）。"
            }
            if (-not $loaded) {
                Import-Module -Name $adk.ModulePath -ErrorAction Stop
            }
        }
    }

    $wrapped = $ScriptBlock
    if ([int]$Config.DebugTrace -ge 3) {
        $tracePath = Join-Path -Path $Config.LogDir -ChildPath ('trace-dism-{0}.log' -f (Get-Date -Format 'HHmmssfff'))
        $inner = $ScriptBlock
        $wrapped = {
            Trace-Command -Name ParameterBinding, CommandDiscovery -Expression $inner -PSHost -FilePath $tracePath
        }.GetNewClosure()
    }

    return Invoke-WinMediaOperation -Category Dism -Operation $Provider -Target "DISM[$Provider]" -ScriptBlock $wrapped -Config $Config
}
