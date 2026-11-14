Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# 更新包分類模組（§2.1、§11.3、§11.4）：依展開後的內容判斷 .cab／.msu 的類別
# 需要的 Config 鍵：LogLevel／LogFile、DebugTrace、OperationLog
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\PSModules\Common\WinMediaLog.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\PSModules\Common\WinMediaOperation.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\PSModules\Common\WinMediaProcess.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\PSModules\Imaging\WinMediaWimlib.psm1') -Force

function Get-WinMediaPackageCategory {
    <#
    .SYNOPSIS
        將 PackageDir 中的 .cab / .msu 依內容分類（§2.1、§11.4）。
    .DESCRIPTION
        一律以展開後的內容為準；檔名只在內容無法判斷（Unknown）時作為後備提示。
        .msu 內的巢狀 cab 會再展開一層，以讀到 update.mum 與 manifest 名稱。
        合併 CU 同時供應 LCU 與內含的 SSU-*.cab（§11.3）。
    .PARAMETER PackageDir
        使用者放置更新包的資料夾。
    .PARAMETER ExpandDir
        展開用的暫存資料夾（位於 WorkDir 下）。
    .PARAMETER Config
        設定表。
    .EXAMPLE
        Get-WinMediaPackageCategory -PackageDir '<更新包資料夾>' -ExpandDir '<WorkDir>\expand' -Config $config
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$PackageDir,
        [Parameter(Mandatory)][string]$ExpandDir,
        [Parameter(Mandatory)][hashtable]$Config
    )

    $result = [pscustomobject]@{
        SSU          = @()
        SafeOS       = @()
        Checkpoint   = @()
        LCU          = @()
        SetupDU      = @()
        Enablement   = @()
        DotNetCU     = @()
        LanguagePack = @()
        FoD          = @()
        Unclassified = @()
    }

    $packages = Get-ChildItem -LiteralPath $PackageDir -File | Where-Object { $_.Extension -in '.cab', '.msu' }
    foreach ($package in $packages) {
        # AggregatedMetadata 是 MSU 重組用的中繼資料（convert-UUP 只用於重組、不整合），不分類、不展開
        if ($package.Name -match 'AggregatedMetadata') {
            Write-WinMediaLog -Config $Config -Level Info -Message "中繼資料略過（convert-UUP 不整合）：$($package.Name)"
            continue
        }
        $hint = Get-WinMediaPackageCategoryByName -Name $package.Name
        $category = Get-WinMediaPackageCategoryByContent -Package $package.FullName -ExpandDir $ExpandDir -Config $Config
        if ($category -eq 'Unknown' -and $hint -notin 'Combined', 'Unknown') {
            $category = $hint
        }
        Write-WinMediaLog -Config $Config -Level Verbose -Message "分類 $($package.Name) → $category"

        if ($category -eq 'CombinedCU') {
            # 合併 CU：LCU 用整包；內含的 SSU-*.cab 另外取出供 SSU 使用（§11.3）
            $result.LCU += $package.FullName
            $expanded = Join-Path -Path $ExpandDir -ChildPath $package.Name
            $result.SSU += @(Get-ChildItem -LiteralPath $expanded -Recurse -File -Filter 'SSU-*.cab' | ForEach-Object { $_.FullName })
            continue
        }

        switch ($category) {
            'SafeOS'       { $result.SafeOS += $package.FullName }
            'SSU'          { $result.SSU += $package.FullName }
            'Checkpoint'   { $result.Checkpoint += $package.FullName }
            'LCU'          { $result.LCU += $package.FullName }
            'SetupDU'      { $result.SetupDU += $package.FullName }
            'DotNetCU'     { $result.DotNetCU += $package.FullName }
            'LanguagePack' { $result.LanguagePack += $package.FullName }
            'FoD'          { $result.FoD += $package.FullName }
            'Enablement'   {
                # 啟用套件（eKB）：安裝前依 convert-UUP 條件判定是否套用（Edition 命中且非 LTSC），見 Test-WinMediaEnablementApplicable
                $result.Enablement += $package.FullName
                $enableMum = Get-ChildItem -LiteralPath (Join-Path -Path $ExpandDir -ChildPath $package.Name) -Recurse -File -Filter '*-Version-Enablement-Package~*.mum' | Select-Object -First 1
                $version = if ($enableMum -and $enableMum.Name -match '~(\d+\.\d+\.\d+\.\d+)\.mum$') { $Matches[1] } else { '未知' }
                Write-WinMediaLog -Config $Config -Level Info -Message "啟用套件（eKB）：$($package.Name)，cab 版本 $version，於各索引依 Edition 條件判定是否套用。"
            }
            default        { $result.Unclassified += $package.FullName }
        }
    }

    return $result
}

function Get-WinMediaPackageCategoryByName {
    # 檔名只是候選；內容判斷才是準則（§2.1）
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Name
    )

    switch -Regex ($Name) {
        'SafeOS|sysreset|winre' { return 'SafeOS' }
        'SetupDU|setup_du|setupdu' { return 'SetupDU' }
        'NDP|dotnet|\.NET' { return 'DotNetCU' }
        'LanguagePack|LXP|lp\.cab|Lang' { return 'LanguagePack' }
        'LOF|FOD|Feature' { return 'FoD' }
        'SSU|ServicingStack' { return 'SSU' }
        'Checkpoint' { return 'Checkpoint' }
        'KB\d+' { return 'Combined' }
        default { return 'Unknown' }
    }
}

function Get-WinMediaMumXVersion {
    # LCU msu 內的 MumX 容器版本（依 convert-UUP.cmd :checkmsu 2393、2397 的位元組規則）；回傳 1 或 2
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $head = New-Object -TypeName byte[] -ArgumentList 216
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $read = $stream.Read($head, 0, $head.Length)
    }
    finally {
        $stream.Dispose()
    }
    if ([System.IO.Path]::GetFileName($Path) -match '\.mumx$') {
        # 無後綴的 .mumx：byte[7] 為 1 視為 v1
        if ($read -gt 7 -and ([string]$head[7]).Contains('1')) { return 1 }
        return 2
    }
    # .mumx.???（例如 .mumx.esd）：有 MUMX 檔頭時看 byte[215]；沒有檔頭視為 v1
    if ($read -ge 216 -and $head[208] -eq 0x4D -and $head[209] -eq 0x55 -and $head[210] -eq 0x4D -and $head[211] -eq 0x58) {
        if (([string]$head[215]).Contains('1')) { return 1 }
        return 2
    }
    return 1
}

function Get-WinMediaPackageVersion {
    # 讀取 Rollup（RollupFix）或 SSU（ServicingStack）的 identity 版本，供同類候選「保留最新」比較（convert-UUP :chklcu、:chkssu）
    # 先讀已展開的 update.mum（ExpandDir\<檔名>、同層 nested-<檔名>）；找不到時，LCU msu 的 identity 在內層 .wim 裡（實機 KB5127936），
    # 才用 wimlib 只抽出 update.mum 到 ExpandDir\_version\<檔名>\。都讀不到回傳 $null
    [CmdletBinding()]
    [OutputType([version])]
    param(
        [Parameter(Mandatory)][string]$Package,
        [Parameter(Mandatory)][string]$ExpandDir,
        [Parameter(Mandatory)][ValidateSet('RollupFix', 'ServicingStack')][string]$Kind,
        [Parameter(Mandatory)][hashtable]$Config
    )

    $leaf = [System.IO.Path]::GetFileName($Package)
    $parent = Split-Path -Path $Package -Parent
    $candidateRoots = @(Join-Path -Path $ExpandDir -ChildPath $leaf)
    if ($parent) { $candidateRoots += Join-Path -Path $parent -ChildPath ('nested-' + $leaf) }
    $roots = @($candidateRoots | Where-Object { Test-Path -LiteralPath $_ })
    $namePattern = if ($Kind -eq 'RollupFix') { '^Package_for_RollupFix$' } else { '^Package_for_ServicingStack_\d+$' }

    $version = Read-WinMediaIdentityVersion -MumPath @($roots | ForEach-Object { Get-ChildItem -LiteralPath $_ -Filter 'update.mum' -Recurse -File } | ForEach-Object { $_.FullName }) -NamePattern $namePattern
    if ($version) { return $version }

    foreach ($wim in @($roots | ForEach-Object { Get-ChildItem -LiteralPath $_ -Filter '*.wim' -Recurse -File } | ForEach-Object { $_.FullName })) {
        # 每個 wim 各用一個子目錄，避免後一個 wim 誤讀前一個 wim 抽出的 update.mum
        $dest = Join-Path -Path $ExpandDir -ChildPath (Join-Path -Path '_version' -ChildPath (Join-Path -Path $leaf -ChildPath (Split-Path -Path $wim -Leaf)))
        if (-not (Test-Path -LiteralPath (Join-Path -Path $dest -ChildPath 'update.mum'))) {
            New-Item -ItemType Directory -Path $dest -Force | Out-Null
            try {
                $null = Invoke-WinMediaWimlib -ArgumentList @('extract', $wim, '1', 'update.mum', "--dest-dir=$dest", '--no-acls', '--no-attributes') -Config $Config
            }
            catch {
                Write-WinMediaLog -Config $Config -Level Warning -Message "無法從 $(Split-Path -Path $wim -Leaf) 讀取 update.mum 版本：$($_.Exception.Message)"
                continue
            }
        }
        $version = Read-WinMediaIdentityVersion -MumPath @(Join-Path -Path $dest -ChildPath 'update.mum') -NamePattern $namePattern
        if ($version) { return $version }
    }
    return $null
}

function Read-WinMediaIdentityVersion {
    # 從 update.mum 的 <assemblyIdentity> 標籤讀出符合 NamePattern 的版本；屬性順序與 xmlns 不影響結果
    [CmdletBinding()]
    [OutputType([version])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$MumPath,
        [Parameter(Mandatory)][string]$NamePattern
    )

    foreach ($mum in $MumPath) {
        $text = Get-Content -LiteralPath $mum -Raw
        $tag = [regex]::Match($text, '<assemblyIdentity\b[^>]*>').Value
        $name = [regex]::Match($tag, '\sname="([^"]+)"').Groups[1].Value
        $found = [regex]::Match($tag, '\sversion="([^"]+)"').Groups[1].Value
        if ($name -match $namePattern -and $found) { return [version]$found }
    }
    return $null
}

function Select-WinMediaNewestPackage {
    # 依版本選出最新者；版本相同時取排序靠前者（呼叫端把目標 CU 的候選排在前面）；讀不到版本視為 0.0.0.0
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Paths,
        [Parameter(Mandatory)][hashtable]$Versions
    )

    # 有任何候選讀不到版本時不比版本，直接採用排序第一者（目標 CU 內的 SSU 優先）
    $complete = @($Paths | Where-Object { $Versions.ContainsKey($_) -and $Versions[$_] }).Count -eq @($Paths).Count
    if (-not $complete) { return @($Paths)[0] }
    $best = $null
    $bestVersion = [version]'0.0.0.0'
    foreach ($path in $Paths) {
        $version = if ($Versions.ContainsKey($path) -and $Versions[$path]) { [version]$Versions[$path] } else { [version]'0.0.0.0' }
        if ($null -eq $best -or $version -gt $bestVersion) { $best = $path; $bestVersion = $version }
    }
    return $best
}

function Get-WinMediaEnablementEdition {
    # eKB 的 Edition 清單：update.mum 內的 Microsoft-Windows-<X>Edition identity（convert-UUP :enablement 3413 的 findstr Edition）
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$Package,
        [Parameter(Mandatory)][string]$ExpandDir
    )

    $root = Join-Path -Path $ExpandDir -ChildPath ([System.IO.Path]::GetFileName($Package))
    $mum = Get-ChildItem -LiteralPath $root -Filter 'update.mum' -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $mum) { return @() }
    $text = Get-Content -LiteralPath $mum.FullName -Raw
    return @([regex]::Matches($text, 'name="(Microsoft-Windows-[A-Za-z]+Edition)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
}

function Test-WinMediaEnablementApplicable {
    # convert-UUP :enablement（3411–3423）：映像的 Windows\Servicing\Packages 內有 eKB 任一 Edition 套件才套用；
    # LTSC 映像略過（convert-UUP 的 LtscAddEP 預設 0；本工具不提供 1／2）。LTSC 判定同 convert-UUP 2954–2958
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Editions,
        [Parameter(Mandatory)][string]$PackagesDir
    )

    if (-not (Test-Path -LiteralPath $PackagesDir)) { return $false }
    $names = @(Get-ChildItem -LiteralPath $PackagesDir -Filter '*.mum' -File | ForEach-Object { $_.Name })
    $hci = [bool]($names | Where-Object { $_ -like 'Microsoft-Windows-ServerAzureStackHCI*Edition~*.mum' })
    $ltsc = (-not $hci) -and [bool]($names | Where-Object { $_ -like 'Microsoft-Windows-EnterpriseS*Edition~*.mum' -or $_ -like 'Microsoft-Windows-Server*Edition~*.mum' })
    if ($ltsc) { return $false }
    foreach ($edition in @($Editions)) {
        if ($names | Where-Object { $_ -like "$edition*.mum" }) { return $true }
    }
    return $false
}

function Test-WinMediaWimFile {
    # 讀取檔頭 8 位元組判斷是否為 WIM（MSWIM\0\0\0）；只讀前 8 位元組，避免 4.5 GB 的檔案被整包載入
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $head = New-Object -TypeName byte[] -ArgumentList 8
        $read = $stream.Read($head, 0, 8)
    }
    finally {
        $stream.Dispose()
    }
    return ($read -eq 8 -and [BitConverter]::ToString($head) -eq '4D-53-57-49-4D-00-00-00')
}

function Expand-WinMediaPackageToDir {
    # 展開 .cab／.msu 到 Target：WIM 格式（UUP 包的 .msu 常見）改用 wimlib；其餘維持 expand.exe
    # 注意：expand.exe 對 WIM 檔不會報錯，只會把原檔複製一份，因此不能只看結束碼
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Package,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][hashtable]$Config
    )

    if (Test-WinMediaWimFile -Path $Package) {
        try {
            $null = Invoke-WinMediaWimlib -ArgumentList @('extract', $Package, '1', "--dest-dir=$Target", '--no-acls', '--no-attributes') -Config $Config
            return $true
        }
        catch {
            Write-WinMediaLog -Config $Config -Level Warning -Message "wimlib 展開失敗：$(Split-Path -Path $Package -Leaf)：$($_.Exception.Message)"
            return $false
        }
    }
    $expand = Invoke-WinMediaExternal -FilePath 'expand.exe' -ArgumentList @('-F:*', $Package, $Target) -Config $Config
    return ($expand.ExitCode -eq 0)
}

function Get-WinMediaPackageCategoryByContent {
    # 展開後（含 .msu 內的巢狀 cab）讀取 update.mum 與 manifest 名稱；無法判斷回傳 Unknown
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Package,
        [Parameter(Mandatory)][string]$ExpandDir,
        [Parameter(Mandatory)][hashtable]$Config
    )

    # 以完整檔名（含副檔名）命名，避免 foo.cab 與 foo.msu 互相覆寫
    $target = Join-Path -Path $ExpandDir -ChildPath ([System.IO.Path]::GetFileName($Package))
    if (-not (Test-Path -LiteralPath $target)) {
        Invoke-WinMediaOperation -Category File -Operation 'CreateDirectory' -Target $target -Config $Config -ScriptBlock {
            New-Item -ItemType Directory -Path $target -Force | Out-Null
        } | Out-Null
        $expanded = Expand-WinMediaPackageToDir -Package $Package -Target $target -Config $Config
        if (-not $expanded) {
            # 失敗時移除半成品目錄，避免之後重試時被當成已展開
            Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
            return 'Unknown'
        }
        # .msu 的內容是巢狀 cab，需再展開一層才看得到 update.mum
        foreach ($nested in @(Get-ChildItem -LiteralPath $target -File -Filter '*.cab')) {
            $nestedDir = Join-Path -Path $target -ChildPath ('nested-' + $nested.Name)
            New-Item -ItemType Directory -Path $nestedDir -Force | Out-Null
            if (-not (Expand-WinMediaPackageToDir -Package $nested.FullName -Target $nestedDir -Config $Config)) {
                # 巢狀展開失敗同樣移除半成品目錄，否則下次重跑會被當成已展開而略過
                Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
                return 'Unknown'
            }
        }
    }

    $mum = Get-ChildItem -LiteralPath $target -Filter 'update.mum' -Recurse -File | Select-Object -First 1
    $manifests = @(Get-ChildItem -LiteralPath $target -Recurse -File | ForEach-Object { $_.Name })
    $mumText = ''
    if ($mum) { $mumText = Get-Content -LiteralPath $mum.FullName -Raw }
    # MumX 容器只記錄版本，不改變套用行為（Slipway 一律整包交給 DISM，等同 convert-UUP 的 LCUmsuExpand=0）
    foreach ($mumx in @(Get-ChildItem -LiteralPath $target -Recurse -File | Where-Object { $_.Name -match '\.mumx' })) {
        Write-WinMediaLog -Config $Config -Level Info -Message "[MumX v$(Get-WinMediaMumXVersion -Path $mumx.FullName)] $($mumx.Name)"
    }

    $hasSsu = [bool]($manifests | Where-Object { $_ -like 'SSU-*' })
    $hasNestedLcu = [bool]($manifests | Where-Object { $_ -match 'KB\d+.*\.cab$' })
    if ($hasNestedLcu -and $hasSsu) { return 'CombinedCU' }
    # 含有巢狀 KB cab 的是累積更新（LCU），不可能是 SafeOS DU，避免完整 LCU 被誤送進 WinRE（§11.4）
    if ($hasNestedLcu) { return 'LCU' }
    # Setup DU 為扁平 cab、沒有 update.mum，以安裝程式本體辨識（實機 KB5127650 內容；convert-UUP 無此規則）
    # convert-UUP :cab2 2470–2481：沒有 update.mum 且沒有 defender xml 才視為 Setup DU
    if (-not $mum -and -not ($manifests | Where-Object { $_ -like '*defender*.xml' }) -and $manifests -contains 'SetupPlatform.exe' -and $manifests -contains 'SetupHost.exe') { return 'SetupDU' }

    if ($mumText -match 'Package_for_SafeOSDU') { return 'SafeOS' }
    if ($mumText -match 'Package_for_RollupFix') {
        $safeManifest = $manifests | Where-Object {
            $_ -match 'microsoft-windows-sysreset|microsoft-windows-winpe_tools|microsoft-windows-winre-tools|microsoft-windows-i\.\.dsetup-rejuvenation'
        }
        if ($safeManifest) { return 'SafeOS' }
        return 'LCU'
    }
    if ($mumText -match 'Package_for_DotNetRollup') { return 'DotNetCU' }
    if ($hasSsu) { return 'SSU' }
    if ($manifests | Where-Object { $_ -like 'lp.cab' -or $_ -like '*LXP*' }) { return 'LanguagePack' }
    # 啟用套件（eKB）：其他規則都不命中才判斷，且需有 update.mum，避免 CU 內含的 manifest 被誤判
    if ($mum -and ($manifests | Where-Object { $_ -like '*-Version-Enablement-Package~*.mum' })) { return 'Enablement' }

    return 'Unknown'
}

Export-ModuleMember -Function Get-WinMediaPackageCategory, Get-WinMediaPackageCategoryByName, Get-WinMediaPackageCategoryByContent, Get-WinMediaMumXVersion, Get-WinMediaPackageVersion, Select-WinMediaNewestPackage, Get-WinMediaEnablementEdition,Test-WinMediaEnablementApplicable
