function Resolve-WinMediaAdk {
    # ADK 路徑探測（§3.4、§3.4.2 2a–2d）；兩種文件路徑都探測，缺少時自動安裝一次後重新探測
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config
    )

    $found = Find-WinMediaAdkDism -Config $Config
    if (-not $found) {
        Install-WinMediaAdk -Config $Config
        $found = Find-WinMediaAdkDism -Config $Config
    }
    if (-not $found) {
        throw "安裝 ADK 後仍找不到 DISM：'$($Config.AdkRoot)'"
    }

    $dismExe = Join-Path -Path $found -ChildPath 'dism.exe'
    $version = if (Test-Path -LiteralPath $dismExe) { (Get-Item -LiteralPath $dismExe).VersionInfo.FileVersion } else { 'unknown' }
    Write-WinMediaLog -Config $Config -Level Info -Message ("ADK DISM 目錄：$found；dism.exe 版本：$version")

    [pscustomobject]@{
        Root       = $found
        ModulePath = Join-Path -Path $found -ChildPath 'Dism.psd1'
        DismExe    = $dismExe
    }
}

function Find-WinMediaAdkDism {
    # 回傳第一個含 Dism.psd1 或 dism.exe 的候選目錄；皆無則回傳 $null
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config
    )

    if ([string]::IsNullOrEmpty($Config.AdkRoot)) {
        throw 'AdkRoot 未設定。'
    }

    $candidates = @(
        (Join-Path -Path $Config.AdkRoot -ChildPath 'Deployment Tools\10\DISM'),
        (Join-Path -Path $Config.AdkRoot -ChildPath 'Deployment Tools\amd64\DISM')
    )
    foreach ($candidate in $candidates) {
        if ((Test-Path -LiteralPath (Join-Path -Path $candidate -ChildPath 'Dism.psd1')) -or
            (Test-Path -LiteralPath (Join-Path -Path $candidate -ChildPath 'dism.exe'))) {
            return $candidate
        }
    }
    return $null
}

function Resolve-WinMediaOscdimg {
    # oscdimg 解析（§3.5）：來源為 Q&A，非 Learn 官方，實機確認；缺少時自動安裝 ADK 後再確認
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config
    )

    if ([string]::IsNullOrEmpty($Config.AdkRoot)) {
        throw 'AdkRoot 未設定。'
    }
    $path = Join-Path -Path $Config.AdkRoot -ChildPath 'Deployment Tools\amd64\Oscdimg\oscdimg.exe'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Install-WinMediaAdk -Config $Config
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "安裝 ADK 後仍找不到 oscdimg.exe：'$path'"
    }
    return $path
}
