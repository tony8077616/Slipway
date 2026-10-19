Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# 語言體驗套件（LXP）模組（§3.2）：遞迴偵測、從套件讀出 PFN 與 License.xml、加入 install.wim
# 需要的 Config 鍵：DismProvider、DismLogLevel、LogLevel／LogFile、DebugTrace、OperationLog
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\PSModules\Common\WinMediaLog.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\PSModules\Common\WinMediaOperation.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\PSModules\Imaging\WinMediaDism.psm1') -Force

function Resolve-WinMediaLxp {
    # §3.2：遞迴偵測 LXP，從套件 zip 讀出 PFN 與 License.xml（不依賴 7-Zip）
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][string]$TempDir,
        [Parameter(Mandatory)][hashtable]$Config
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return @() }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $files = @(Get-ChildItem -LiteralPath $Path -File -Recurse | Where-Object {
        $_.Name -like '*LanguageExperiencePack*' -and $_.Extension -in '.appx', '.appxbundle', '.msix', '.msixbundle'
    })
    $items = foreach ($file in $files) {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($file.FullName)
        try {
            # bundle 的 manifest 位於 AppxMetadata 下，根目錄沒有 AppxManifest.xml
            $manifestEntry = $zip.GetEntry('AppxManifest.xml')
            if (-not $manifestEntry) { $manifestEntry = $zip.GetEntry('AppxMetadata/AppxBundleManifest.xml') }
            $licenseEntry = $zip.GetEntry('License.xml')
            if (-not $manifestEntry -or -not $licenseEntry) {
                Write-WinMediaLog -Config $Config -Level Warning -Message "LXP 缺少 manifest 或 License.xml，略過：$($file.Name)"
                continue
            }

            $reader = [IO.StreamReader]::new($manifestEntry.Open())
            try { [xml]$manifest = $reader.ReadToEnd() }
            finally { $reader.Dispose() }

            $pfn = '{0}_8wekyb3d8bbwe' -f $manifest.DocumentElement.Identity.Name
            $licensePath = Join-Path -Path $TempDir -ChildPath ($pfn + '.License.xml')
            Invoke-WinMediaOperation -Category File -Operation 'ExtractLicense' -Target $licensePath -Config $Config -ScriptBlock {
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($licenseEntry, $licensePath, $true)
            } | Out-Null

            [pscustomobject]@{
                PackagePath = $file.FullName
                LicensePath = $licensePath
                Pfn         = $pfn
            }
        }
        finally { $zip.Dispose() }
    }
    return @($items)
}

function Install-WinMediaLxp {
    # §3.2：加入 install.wim；參數為 Add-AppxProvisionedPackage（Add-ProvisionedAppxPackage 只是別名）
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MountPath,
        [Parameter(Mandatory)][object[]]$Lxp,
        [Parameter(Mandatory)][hashtable]$Config
    )

    foreach ($item in $Lxp) {
        $pkg = $item.PackagePath
        $lic = $item.LicensePath
        Write-WinMediaLog -Config $Config -Level Info -Message "加入 LXP：$($item.Pfn) → $MountPath"
        Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
            Add-AppxProvisionedPackage -Path $MountPath -PackagePath $pkg -LicensePath $lic -Regions 'all' -LogLevel $Config.DismLogLevel -ErrorAction Stop | Out-Null
        } | Out-Null
    }
}

Export-ModuleMember -Function Resolve-WinMediaLxp, Install-WinMediaLxp
