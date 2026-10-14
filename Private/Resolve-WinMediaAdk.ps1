function Resolve-WinMediaAdk {
    # ADK 路徑探測（§3.4、§3.4.2 2a–2d）；兩種文件路徑都探測，取第一個有 Dism.psd1 或 dism.exe 者
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config
    )

    if ([string]::IsNullOrEmpty($Config.AdkRoot) -or -not (Test-Path -LiteralPath $Config.AdkRoot)) {
        throw "DismProvider 為 ADK，但 AdkRoot 不存在：'$($Config.AdkRoot)'"
    }

    $candidates = @(
        (Join-Path -Path $Config.AdkRoot -ChildPath 'Deployment Tools\10\DISM'),
        (Join-Path -Path $Config.AdkRoot -ChildPath 'Deployment Tools\amd64\DISM')
    )

    $found = $null
    foreach ($candidate in $candidates) {
        if ((Test-Path -LiteralPath (Join-Path -Path $candidate -ChildPath 'Dism.psd1')) -or
            (Test-Path -LiteralPath (Join-Path -Path $candidate -ChildPath 'dism.exe'))) {
            $found = $candidate
            break
        }
    }
    if (-not $found) {
        throw ('找不到 ADK DISM，已探測：' + ($candidates -join '; '))
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

function Resolve-WinMediaOscdimg {
    # oscdimg 解析（§3.5）：來源為 Q&A，非 Learn 官方，實機確認；找不到即中止
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config
    )

    $path = Join-Path -Path $Config.AdkRoot -ChildPath 'Deployment Tools\amd64\Oscdimg\oscdimg.exe'
    if ([string]::IsNullOrEmpty($Config.AdkRoot) -or -not (Test-Path -LiteralPath $path)) {
        throw "找不到 oscdimg.exe：'$path'"
    }
    return $path
}
