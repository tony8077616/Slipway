Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# CustomAppsList 與 provisioned Appx 移除模組（§3.3）
# 需要的 Config 鍵：DismProvider、LogLevel／LogFile、DebugTrace、OperationLog
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\PSModules\Common\WinMediaLog.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\PSModules\Imaging\WinMediaDism.psm1') -Force

function Resolve-WinMediaAppxList {
    # §3.3：解析 CustomAppsList.txt（每行一個 PackageFamilyName；# 為註解）
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][ValidateSet('Remove', 'Keep')][string]$Mode,
        [Parameter(Mandatory)][hashtable]$Config
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "找不到 CustomAppsList：$Path" }
    $names = @(Get-Content -LiteralPath $Path | ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') })
    if ($Mode -eq 'Keep' -and $names.Count -eq 0) {
        throw 'CustomListMode 為 Keep 但清單為空，拒絕執行（會移除所有 app）。'
    }
    Write-WinMediaLog -Config $Config -Level Info -Message "CustomAppsList：$Path（$Mode，$($names.Count) 項）"
    return [pscustomobject]@{ Mode = $Mode; Names = $names }
}

function Remove-WinMediaAppx {
    # §3.3：依 Remove（移除清單內）或 Keep（移除清單外，保留框架與語言套件）處理 provisioned app
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$MountPath,
        [Parameter(Mandatory)][pscustomobject]$AppxList,
        [Parameter(Mandatory)][hashtable]$Config
    )

    if (-not $PSCmdlet.ShouldProcess($MountPath, '依 CustomAppsList 移除 provisioned app')) { return }
    # Keep 模式的保護清單：框架、語言套件，以及 2026-10-15 盤點 install.wim（Win10 22H2、Win11 24H2 LTSC、Win11 26H2）確認存在的 Store、安全性與編解碼套件
    $protected = @(
        'Microsoft.VCLibs*', 'Microsoft.UI.Xaml*', 'Microsoft.NET.*', 'Microsoft.WindowsAppRuntime*', '*LanguageExperiencePack*',
        'Microsoft.WindowsStore', 'Microsoft.StorePurchaseApp', 'Microsoft.DesktopAppInstaller', 'Microsoft.SecHealthUI',
        'Microsoft.VP9VideoExtensions', 'Microsoft.WebMediaExtensions', 'Microsoft.HEIFImageExtension', 'Microsoft.HEVCVideoExtension',
        'Microsoft.AV1VideoExtension', 'Microsoft.RawImageExtension', 'Microsoft.WebpImageExtension', 'Microsoft.AVCEncoderVideoExtension',
        'Microsoft.MPEG2VideoExtension'
    )
    $all = @(Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
        Get-AppxProvisionedPackage -Path $MountPath
    })
    foreach ($pkg in $all) {
        # PackageName 為 PackageFullName（Name_Version_Arch_ResourceId_PublisherId），取最後一段組成 PFN，與清單精確比對
        $pfn = '{0}_{1}' -f $pkg.DisplayName, ($pkg.PackageName -split '_')[-1]
        $listed = $AppxList.Names -contains $pfn
        $isProtected = @($protected | Where-Object { $pkg.DisplayName -like $_ }).Count -gt 0
        $remove = if ($AppxList.Mode -eq 'Remove') { $listed } else { -not ($listed -or $isProtected) }
        if (-not $remove) { continue }
        $name = $pkg.PackageName
        Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
            Remove-AppxProvisionedPackage -Path $MountPath -PackageName $name -ErrorAction Stop | Out-Null
        } | Out-Null
        Write-WinMediaLog -Config $Config -Level Info -Message "已移除 provisioned app：$pfn"
    }
}

Export-ModuleMember -Function Resolve-WinMediaAppxList, Remove-WinMediaAppx
