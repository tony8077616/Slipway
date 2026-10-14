function Install-WinMediaAdk {
    # 缺少 ADK 時自動安裝 Deployment Tools（oscdimg、ADK DISM）到 Config.AdkRoot；安裝程式必須為 Microsoft 簽章
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config
    )

    if ([string]::IsNullOrEmpty($Config.AdkRoot)) {
        throw 'AdkRoot 未設定，無法安裝 ADK。'
    }
    $url = 'https://go.microsoft.com/fwlink/?linkid=2289980'
    $downloadDir = Join-Path -Path $Config.WorkDir -ChildPath 'downloads'
    $installer = Join-Path -Path $downloadDir -ChildPath 'adksetup.exe'
    New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null

    Write-WinMediaLog -Config $Config -Level Info -Message "本地沒有 ADK Deployment Tools，自動下載安裝程式：$url"
    Invoke-WinMediaOperation -Category Download -Operation 'DownloadAdk' -Target $url -Config $Config -ScriptBlock {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing
    } | Out-Null

    $signature = Get-AuthenticodeSignature -LiteralPath $installer
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
        Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
        throw "ADK 安裝程式簽章無效或非 Microsoft 簽署，已刪除：$installer"
    }

    $arguments = '/quiet /norestart /installpath "{0}" /features OptionId.DeploymentTools' -f $Config.AdkRoot
    $process = Invoke-WinMediaOperation -Category External -Operation 'InstallAdk' -Target $installer -Config $Config -ScriptBlock {
        Start-Process -FilePath $installer -ArgumentList $arguments -Wait -PassThru
    }
    if ($process.ExitCode -notin 0, 3010) {
        throw "ADK 安裝失敗，結束碼 $($process.ExitCode)"
    }
}
