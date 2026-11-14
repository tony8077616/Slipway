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
        $statePath = (Get-Item -LiteralPath $DriverSet[$state].Path).FullName.TrimEnd('\')
        Write-WinMediaLog -Config $Config -Level Verbose -Message "注入驅動：$state → $Target（掛載點 $MountPath，ForceUnsigned=$ForceUnsigned）"
        $injected = @{}
        $deferred = @()
        foreach ($inf in @(Get-ChildItem -LiteralPath $statePath -Filter '*.inf' -File -Recurse | Where-Object { $_.Extension -eq '.inf' } | Sort-Object FullName)) {
            $rel = $inf.FullName.Substring($statePath.Length).TrimStart('\')
            if ($rel -match '(^|\\)WTx64\\') { $deferred += $rel; continue }
            try { Invoke-WinMediaDriverInf -MountPath $MountPath -InfPath $inf.FullName -ForceUnsigned $ForceUnsigned -Config $Config }
            catch {
                $pairedWt = $rel -replace '(^|\\)W11x64\\', '${1}WTx64\'
                if ($pairedWt -ne $rel -and (Test-Path -LiteralPath (Join-Path -Path $statePath -ChildPath $pairedWt))) {
                    Write-WinMediaLog -Config $Config -Level Warning -Message "W11x64 驅動注入失敗，略過同名 WTx64：$rel（$($_.Exception.Message)）"
                    continue
                }
                throw "驅動注入失敗：$rel（$($_.Exception.Message)）"
            }
            $injected[$rel.ToLowerInvariant()] = $true
        }
        # WTx64 與同名 W11x64 重複（以同名 INF 的相對路徑配對）：W11x64 注入成功才略過 WTx64；無 W11x64 則嘗試 WTx64；其餘不注入並警告
        foreach ($rel in $deferred) {
            $sibling = $rel -replace '(^|\\)WTx64\\', '${1}W11x64\'
            if ($injected.ContainsKey($sibling.ToLowerInvariant())) {
                Write-WinMediaLog -Config $Config -Level Info -Message "略過 WTx64 驅動（同名 W11x64 已注入）：$rel"
                continue
            }
            if (Test-Path -LiteralPath (Join-Path -Path $statePath -ChildPath $sibling)) {
                Write-WinMediaLog -Config $Config -Level Warning -Message "略過 WTx64 驅動（同名 W11x64 存在但未注入成功）：$rel"
                continue
            }
            try { Invoke-WinMediaDriverInf -MountPath $MountPath -InfPath (Join-Path -Path $statePath -ChildPath $rel) -ForceUnsigned $ForceUnsigned -Config $Config }
            catch { Write-WinMediaLog -Config $Config -Level Warning -Message "WTx64 驅動注入失敗，已略過：$rel（$($_.Exception.Message)）" }
        }
    }
}

function Invoke-WinMediaDriverInf {
    # 單一 INF 注入：每個 INF 各呼叫一次 Add-WindowsDriver，失敗時由呼叫端決定中止或警告
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MountPath,
        [Parameter(Mandatory)][string]$InfPath,
        [Parameter(Mandatory)][bool]$ForceUnsigned,
        [Parameter(Mandatory)][hashtable]$Config
    )

    Write-WinMediaLog -Config $Config -Level Verbose -Message "注入 INF：$InfPath（掛載點 $MountPath，ForceUnsigned=$ForceUnsigned）"
    $common = Get-WinMediaDismCommonParameter -Config $Config
    Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
        Add-WindowsDriver -Path $MountPath -Driver $InfPath -ForceUnsigned:$ForceUnsigned @common -LogLevel $Config.DismLogLevel -ErrorAction Stop | Out-Null
    } | Out-Null
}

function Resolve-WinMediaForceUnsigned {
    # 字串（例如 'false'）經 [bool] 轉型會變成 $true，改為直接拒絕；缺鍵視為 $false
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][hashtable]$Config)

    if (-not $Config.Drivers.ContainsKey('ForceUnsigned')) { return $false }
    $value = $Config.Drivers.ForceUnsigned
    if ($value -isnot [bool]) { throw "Drivers.ForceUnsigned 必須是 `$true 或 `$false（布林），目前為：'$value'。" }
    return $value
}

Export-ModuleMember -Function Resolve-WinMediaDriverSet, Install-WinMediaDriver, Resolve-WinMediaForceUnsigned
