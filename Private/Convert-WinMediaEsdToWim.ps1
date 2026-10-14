function Convert-WinMediaEsdToWim {
    # install.esd → install.wim（§3.2 步驟 2a、§2.7.3）：全部索引轉換；Config.Wimlib.Path 有指定才走 wimlib，否則走 DISM
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceEsd,
        [Parameter(Mandatory)][string]$DestinationWim,
        [Parameter(Mandatory)][hashtable]$Config
    )

    if (Test-Path -LiteralPath $DestinationWim) {
        Invoke-WinMediaOperation -Category File -Operation 'Remove' -Target $DestinationWim -Config $Config -ScriptBlock {
            Remove-Item -LiteralPath $DestinationWim -Force
        } | Out-Null
    }

    if (-not [string]::IsNullOrWhiteSpace($Config.Wimlib.Path)) {
        Write-WinMediaLog -Config $Config -Level Info -Message "使用 wimlib-imagex 轉換 ESD（Wimlib.Path 已指定）：$SourceEsd"
        Invoke-WinMediaWimlib -ArgumentList @('export', $SourceEsd, 'all', $DestinationWim) -Config $Config | Out-Null
    }
    else {
        Write-WinMediaLog -Config $Config -Level Info -Message "使用 DISM Cmdlet 轉換 ESD（未指定 Wimlib.Path）：$SourceEsd"
        $indexes = Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
            Get-WindowsImage -ImagePath $SourceEsd
        }
        foreach ($image in $indexes) {
            $exportIndex = $image.ImageIndex
            $export = {
                Export-WindowsImage -SourceImagePath $SourceEsd -SourceIndex $exportIndex -DestinationImagePath $DestinationWim -CompressionType Max | Out-Null
            }.GetNewClosure()
            Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock $export | Out-Null
        }
    }

    if (-not (Test-Path -LiteralPath $DestinationWim)) {
        throw "ESD 轉換後找不到輸出檔：$DestinationWim"
    }
    Invoke-WinMediaOperation -Category File -Operation 'Remove' -Target $SourceEsd -Config $Config -ScriptBlock {
        Remove-Item -LiteralPath $SourceEsd -Force
    } | Out-Null
}
