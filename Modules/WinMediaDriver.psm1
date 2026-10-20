Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# 自訂驅動模組（§3.1）：依 ALL／WinPE／OS 子資料夾分類，並注入 WinRE、Install、Boot 映像
# 需要的 Config 鍵：Drivers.ForceUnsigned、DismProvider、DismLogLevel、DebugTrace、LogLevel／LogFile、OperationLog
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\PSModules\Common\WinMediaLog.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\PSModules\Imaging\WinMediaDism.psm1') -Force

function Resolve-WinMediaDriverSet {
    # §3.1（Convert-UUP.cmd 第 87–97、440–444 行）：驅動依 ALL／WinPE／OS 子資料夾分類，遞迴搜尋 .inf
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][hashtable]$Config
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "找不到驅動程式資料夾：$Path"
    }

    if (@(Get-ChildItem -LiteralPath $Path -Filter '*.inf' -File).Count -gt 0) {
        Write-WinMediaLog -Config $Config -Level Warning -Message "驅動根目錄的 .inf 會被忽略，請放入 ALL／WinPE／OS 子資料夾：$Path"
    }

    $states = [ordered]@{
        ALL   = @{ WinRE = $true;  Install = $true;  Boot = $true }
        WinPE = @{ WinRE = $true;  Install = $false; Boot = $true }
        OS    = @{ WinRE = $false; Install = $true;  Boot = $false }
    }
    $found = [ordered]@{}
    foreach ($state in $states.Keys) {
        $sub = Join-Path -Path $Path -ChildPath $state
        $infs = @()
        if (Test-Path -LiteralPath $sub -PathType Container) {
            $infs = @(Get-ChildItem -LiteralPath $sub -Filter '*.inf' -File -Recurse)
        }
        if ($infs.Count -eq 0) {
            Write-WinMediaLog -Config $Config -Level Warning -Message "驅動子資料夾 '$state' 不存在或沒有 .inf，略過。"
            continue
        }
        $found[$state] = [pscustomobject]@{ Path = $sub; InfCount = $infs.Count; Targets = $states[$state] }
    }
    if ($found.Count -eq 0) {
        Write-WinMediaLog -Config $Config -Level Warning -Message "驅動資料夾內三種狀態皆無 .inf，略過驅動注入：$Path"
        return $null
    }
    if ([bool]$Config.Drivers.ForceUnsigned) {
        Write-WinMediaLog -Config $Config -Level Warning -Message '已啟用 ForceUnsigned，未簽章驅動將被注入映像。'
    }
    return $found
}

function Install-WinMediaDriver {
    # §3.1（依目標映像注入符合的狀態子資料夾）
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MountPath,
        [Parameter(Mandatory)][ValidateSet('WinRE', 'Install', 'Boot')][string]$Target,
        [Parameter(Mandatory)][System.Collections.IDictionary]$DriverSet,
        [Parameter(Mandatory)][bool]$ForceUnsigned,
        [Parameter(Mandatory)][hashtable]$Config
    )

    foreach ($state in $DriverSet.Keys) {
        if (-not $DriverSet[$state].Targets[$Target]) { continue }
        $driverPath = $DriverSet[$state].Path
        Write-WinMediaLog -Config $Config -Level Verbose -Message "注入驅動：$state → $Target（掛載點 $MountPath，ForceUnsigned=$ForceUnsigned）"
        Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
            Add-WindowsDriver -Path $MountPath -Driver $driverPath -Recurse -ForceUnsigned:$ForceUnsigned -LogLevel $Config.DismLogLevel -ErrorAction Stop | Out-Null
        } | Out-Null
    }
}

Export-ModuleMember -Function Resolve-WinMediaDriverSet, Install-WinMediaDriver
