Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# StoreApps 獨立資料夾（例如 rg-adguard 下載的 Appx／MSIX）：注入前逐一驗證 Microsoft 簽章
# 需要的 Config 鍵：StoreApps.Path、DismProvider、LogLevel／LogFile、DebugTrace、OperationLog
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\PSModules\Common\WinMediaLog.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\PSModules\Imaging\WinMediaDism.psm1') -Force

$script:AppExtensions = @('.appx', '.appxbundle', '.msix', '.msixbundle')
# 框架套件以依賴方式注入，不作為獨立 app 加入
$script:FrameworkPattern = '^Microsoft\.(VCLibs|UI\.Xaml|NET\.Native)'

function Test-WinMediaMicrosoftSignature {
    # Authenticode 必須為 Valid，且簽署者的 O 欄位為 Microsoft Corporation（自簽、未簽章或其他發行者一律拒絕）
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Config
    )

    $sig = Get-AuthenticodeSignature -LiteralPath $Path
    $subject = if ($sig.SignerCertificate) { [string]$sig.SignerCertificate.Subject } else { '' }
    $ok = ($sig.Status -eq 'Valid') -and ($subject -match '(^|,\s*)O=Microsoft Corporation(,|$)')
    if (-not $ok) {
        Write-WinMediaLog -Config $Config -Level Error -Message "StoreApps 簽章驗證失敗（狀態：$($sig.Status)，簽署者：$subject）：$(Split-Path -Path $Path -Leaf)"
    }
    return $ok
}

function Resolve-WinMediaStoreAppSet {
    # 遞迴列出 Appx／MSIX 套件，只保留通過 Microsoft 簽章驗證者；未通過者不注入（不刪除原檔）
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][hashtable]$Config
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [pscustomobject]@{ Frameworks = @(); Apps = @() }
    }
    $files = @(Get-ChildItem -LiteralPath $Path -Recurse -File |
        Where-Object { $script:AppExtensions -contains $_.Extension.ToLowerInvariant() } |
        Sort-Object -Property Name)

    $frameworks = @()
    $apps = @()
    foreach ($file in $files) {
        if (-not (Test-WinMediaMicrosoftSignature -Path $file.FullName -Config $Config)) { continue }
        if ($file.Name -match $script:FrameworkPattern) { $frameworks += $file.FullName }
        else { $apps += $file.FullName }
    }
    Write-WinMediaLog -Config $Config -Level Info -Message "StoreApps：$Path（框架 $($frameworks.Count) 個、app $($apps.Count) 個，已通過簽章驗證）"
    return [pscustomobject]@{ Frameworks = $frameworks; Apps = $apps }
}

function Install-WinMediaStoreApp {
    # 以 Add-AppxProvisionedPackage 加入 install.wim；同名 .xml 授權檔存在則使用，否則 -SkipLicense
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$MountPath,
        [Parameter(Mandatory)][pscustomobject]$Set,
        [Parameter(Mandatory)][hashtable]$Config
    )

    if (-not $PSCmdlet.ShouldProcess($MountPath, '注入 StoreApps')) { return }
    foreach ($app in @($Set.Apps)) {
        $license = [IO.Path]::ChangeExtension($app, '.xml')
        $licenseArg = if (Test-Path -LiteralPath $license -PathType Leaf) { @{ LicensePath = $license } } else { @{ SkipLicense = $true } }
        $depArg = if (@($Set.Frameworks).Count -gt 0) { @{ DependencyPackagePath = @($Set.Frameworks) } } else { @{} }
        Write-WinMediaLog -Config $Config -Level Info -Message "注入 StoreApps：$(Split-Path -Path $app -Leaf)"
        Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
            Add-AppxProvisionedPackage -Path $MountPath -PackagePath $app @licenseArg @depArg -LogLevel $Config.DismLogLevel -ErrorAction Stop | Out-Null
        } | Out-Null
    }
}

Export-ModuleMember -Function Resolve-WinMediaStoreAppSet, Install-WinMediaStoreApp
