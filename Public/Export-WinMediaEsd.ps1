function Export-WinMediaEsd {
    <#
    .SYNOPSIS
        以 wimlib-imagex 將 install.wim 轉為 LZMS 壓縮的 install.esd（§2.4）。
    .DESCRIPTION
        未設定 wimlib 時直接中止，不退回 DISM（Learn 未記載 DISM 直接產生 ESD，§2.4、§7 第 9 項）。
        成功後移除來源 install.wim。
    .PARAMETER SourceWim
        來源 install.wim 路徑。
    .PARAMETER DestinationEsd
        輸出 install.esd 路徑。
    .PARAMETER Config
        由 Import-PowerShellDataFile 載入並補上執行期鍵值的設定表。
    .EXAMPLE
        Export-WinMediaEsd -SourceWim 'C:\WinMediaWork\media\sources\install.wim' -DestinationEsd 'C:\WinMediaWork\media\sources\install.esd' -Config $config
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceWim,
        [Parameter(Mandatory)][string]$DestinationEsd,
        [Parameter(Mandatory)][hashtable]$Config
    )

    $wimlib = $Config.Wimlib.Path
    if ([string]::IsNullOrEmpty($wimlib) -or -not (Test-Path -LiteralPath $wimlib)) {
        throw 'OutputFormat 為 ESD，但 Wimlib.Path 未設定或找不到 wimlib-imagex.exe（不退回 DISM，§2.4）。'
    }

    $result = Invoke-WinMediaExternal -FilePath $wimlib -ArgumentList @('export', $SourceWim, 'all', $DestinationEsd, '--compress=LZMS', '--solid') -Config $Config
    if ($result.ExitCode -ne 0) {
        throw "wimlib export 失敗，結束碼 $($result.ExitCode)：$($result.StdErr)"
    }

    Invoke-WinMediaOperation -Category File -Operation 'Remove' -Target $SourceWim -Config $Config -ScriptBlock {
        Remove-Item -LiteralPath $SourceWim -Force
    } | Out-Null
}
