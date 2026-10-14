function Convert-WinMediaEsdToWim {
    # install.esd → install.wim（§3.2 步驟 2a、§2.7.3）：全部索引轉換；有 wimlib 則優先使用
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

    $wimlib = $Config.Wimlib.Path
    if (-not [string]::IsNullOrEmpty($wimlib) -and (Test-Path -LiteralPath $wimlib)) {
        Write-WinMediaLog -Config $Config -Level Info -Message "使用 wimlib 轉換 ESD：$SourceEsd"
        $result = Invoke-WinMediaExternal -FilePath $wimlib -ArgumentList @('export', $SourceEsd, 'all', $DestinationWim) -Config $Config
        if ($result.ExitCode -ne 0) { throw "wimlib export 失敗，結束碼 $($result.ExitCode)" }
    }
    else {
        Write-WinMediaLog -Config $Config -Level Info -Message "使用 Export-WindowsImage 轉換 ESD（未設定 wimlib）：$SourceEsd"
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
