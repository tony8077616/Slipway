Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# StoreApps 獨立資料夾（例如 rg-adguard 下載的 Appx／MSIX）：注入前逐一驗證 Microsoft 簽章
# 需要的 Config 鍵：StoreApps.Path、DismProvider、DismLogLevel、LogLevel／LogFile、DebugTrace、OperationLog
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
    # 值內含逗號或換行時 Subject 會加引號；真正的 Microsoft 簽署者主體沒有引號，有就拒絕（防引號 CN 繞過）
    $ok = ($sig.Status -eq 'Valid') -and ($subject -notmatch '"') -and ($subject -match '(^|,\s*)O=Microsoft Corporation(,|$)')
    if (-not $ok) {
        Write-WinMediaLog -Config $Config -Level Error -Message "StoreApps 簽章驗證失敗（狀態：$($sig.Status)，簽署者：$subject）：$(Split-Path -Path $Path -Leaf)"
    }
    return $ok
}

function Get-WinMediaFileSha256 {
    # 以 .NET 計算（不依賴 Get-FileHash 模組載入）；檔案不存在或讀不到時照實拋錯
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LiteralPath)

    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($LiteralPath)
    try { return -join ($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') }) }
    finally { $stream.Dispose(); $sha.Dispose() }
}

function Resolve-WinMediaStoreAppSet {
    # 遞迴列出 Appx／MSIX 套件，只保留通過 Microsoft 簽章驗證者；未通過者不注入（不刪除原檔）
    # Hashes 記錄通過者（含框架與同名授權 xml）的 SHA-256，Install 注入前須重算比對
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][hashtable]$Config
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [pscustomobject]@{ Frameworks = @(); Apps = @(); Hashes = @{} }
    }
    $files = @(Get-ChildItem -LiteralPath $Path -Recurse -File |
        Where-Object { $script:AppExtensions -contains $_.Extension.ToLowerInvariant() } |
        Sort-Object -Property Name)

    $frameworks = @()
    $apps = @()
    $hashes = @{}
    foreach ($file in $files) {
        if (-not (Test-WinMediaMicrosoftSignature -Path $file.FullName -Config $Config)) { continue }
        if ($file.Name -match $script:FrameworkPattern) { $frameworks += $file.FullName }
        else { $apps += $file.FullName }
        $hashes[$file.FullName] = Get-WinMediaFileSha256 -LiteralPath $file.FullName
        $license = [IO.Path]::ChangeExtension($file.FullName, '.xml')
        if (Test-Path -LiteralPath $license -PathType Leaf) { $hashes[$license] = Get-WinMediaFileSha256 -LiteralPath $license }
    }
    Write-WinMediaLog -Config $Config -Level Info -Message "StoreApps：$Path（框架 $($frameworks.Count) 個、app $($apps.Count) 個，已通過簽章驗證）"
    return [pscustomobject]@{ Frameworks = $frameworks; Apps = $apps; Hashes = $hashes }
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
    # fail-closed：Resolve 之後檔案若被換掉、授權 xml 新增或變更，一律在任何注入之前中止；沒有 Hashes 的 Set 不放行
    if (-not $Set.PSObject.Properties['Hashes'] -or $null -eq $Set.Hashes) { throw 'StoreApps 集合缺少 SHA-256 記錄，拒絕注入（請重新執行 Resolve-WinMediaStoreAppSet）' }
    $expected = $Set.Hashes
    $toCheck = @($Set.Frameworks) + @($Set.Apps) + @(@($Set.Apps) | ForEach-Object { [IO.Path]::ChangeExtension($_, '.xml') } | Where-Object { $expected.ContainsKey($_) -or (Test-Path -LiteralPath $_ -PathType Leaf) })
    foreach ($item in $toCheck) {
        if (-not $expected.ContainsKey($item)) { throw "StoreApps 檔案不在 Resolve 的雜湊記錄中，拒絕注入：$item" }
        if (-not (Test-Path -LiteralPath $item -PathType Leaf)) { throw "StoreApps 檔案已不存在，拒絕注入：$item" }
        if ((Get-WinMediaFileSha256 -LiteralPath $item) -ne $expected[$item]) { throw "StoreApps 檔案在驗證之後被變更（SHA-256 不符），拒絕注入：$item" }
    }
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

Export-ModuleMember -Function Resolve-WinMediaStoreAppSet, Install-WinMediaStoreApp, Test-WinMediaMicrosoftSignature
