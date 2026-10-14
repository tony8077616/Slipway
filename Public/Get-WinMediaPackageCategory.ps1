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
        Get-WinMediaPackageCategory -PackageDir 'D:\WinMediaPkgs' -ExpandDir 'C:\WinMediaWork\expand' -Config $config
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
        DotNetCU     = @()
        LanguagePack = @()
        FoD          = @()
        Unclassified = @()
    }

    $packages = Get-ChildItem -LiteralPath $PackageDir -File | Where-Object { $_.Extension -in '.cab', '.msu' }
    foreach ($package in $packages) {
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
        $expand = Invoke-WinMediaExternal -FilePath 'expand.exe' -ArgumentList @('-F:*', $Package, $target) -Config $Config
        if ($expand.ExitCode -ne 0) {
            # 失敗時移除半成品目錄，避免之後重試時被當成已展開
            Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
            return 'Unknown'
        }
        # .msu 的內容是巢狀 cab，需再展開一層才看得到 update.mum
        foreach ($nested in @(Get-ChildItem -LiteralPath $target -File -Filter '*.cab')) {
            $nestedDir = Join-Path -Path $target -ChildPath ('nested-' + $nested.Name)
            New-Item -ItemType Directory -Path $nestedDir -Force | Out-Null
            $null = Invoke-WinMediaExternal -FilePath 'expand.exe' -ArgumentList @('-F:*', $nested.FullName, $nestedDir) -Config $Config
        }
    }

    $mum = Get-ChildItem -LiteralPath $target -Filter 'update.mum' -Recurse -File | Select-Object -First 1
    $manifests = @(Get-ChildItem -LiteralPath $target -Recurse -File | ForEach-Object { $_.Name })
    $mumText = ''
    if ($mum) { $mumText = Get-Content -LiteralPath $mum.FullName -Raw }

    $hasSsu = [bool]($manifests | Where-Object { $_ -like 'SSU-*' })
    $hasNestedLcu = [bool]($manifests | Where-Object { $_ -match 'KB\d+.*\.cab$' })
    if ($hasNestedLcu -and $hasSsu) { return 'CombinedCU' }
    # 含有巢狀 KB cab 的是累積更新（LCU），不可能是 SafeOS DU，避免完整 LCU 被誤送進 WinRE（§11.4）
    if ($hasNestedLcu) { return 'LCU' }

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

    return 'Unknown'
}
