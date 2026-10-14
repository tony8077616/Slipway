function Resolve-WinMediaWimlib {
    # wimlib-imagex 解析：Config.Wimlib.Path 已存在則直接使用；否則取得固定版本並校驗 SHA-256 後解壓縮到目標位置
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config
    )

    $exe = $Config.Wimlib.Path
    if ([string]::IsNullOrWhiteSpace($exe)) {
        $exe = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'WinMediaRefresh\tools\wimlib-1.14.5\wimlib-imagex.exe'
    }
    if (Test-Path -LiteralPath $exe -PathType Leaf) {
        return $exe
    }

    $spec = Get-WinMediaWimlibSpec
    $toolDir = Split-Path -Path $exe -Parent
    $downloadDir = Join-Path -Path $Config.WorkDir -ChildPath 'downloads'
    $zip = Join-Path -Path $downloadDir -ChildPath $spec.FileName
    $bundled = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath ('tools\wimlib\' + $spec.FileName)

    if (Test-WinMediaFileHash -Path $bundled -Sha256 $spec.Sha256) {
        Write-WinMediaLog -Config $Config -Level Info -Message "使用模組內附的 wimlib 壓縮檔：$bundled"
        $zip = $bundled
    }
    else {
        New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null
        Write-WinMediaLog -Config $Config -Level Info -Message "本地沒有 wimlib-imagex，自動下載 $($spec.Url)"
        Invoke-WinMediaOperation -Category Download -Operation 'DownloadWimlib' -Target $spec.Url -Config $Config -ScriptBlock {
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $spec.Url -OutFile $zip -UseBasicParsing
        } | Out-Null
        if (-not (Test-WinMediaFileHash -Path $zip -Sha256 $spec.Sha256)) {
            Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
            throw "wimlib 壓縮檔 SHA-256 不符，已刪除：$($spec.FileName)"
        }
    }

    New-Item -ItemType Directory -Path $toolDir -Force | Out-Null
    Invoke-WinMediaOperation -Category Archive -Operation 'ExpandWimlib' -Target $toolDir -Config $Config -ScriptBlock {
        Expand-Archive -LiteralPath $zip -DestinationPath $toolDir -Force
    } | Out-Null

    $extracted = Join-Path -Path $toolDir -ChildPath 'wimlib-imagex.exe'
    if (-not (Test-Path -LiteralPath $extracted -PathType Leaf)) {
        throw "解壓縮後找不到 wimlib-imagex.exe：$toolDir"
    }
    if ($extracted -ine $exe) {
        Copy-Item -LiteralPath $extracted -Destination $exe -Force
    }
    return $exe
}
