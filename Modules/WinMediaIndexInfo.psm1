Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# install.wim 索引資訊：Get-WindowsImage 不帶 -Index 只回傳 BasicImageInfoObject（沒有 Build／EditionId／Architecture），必須逐索引再查
# 模組名稱刻意與 PSModules\Imaging\WinMediaImage.psm1（Mount-WinMediaImage）不同，避免 Import-Module 互相覆寫
# 需要的 Config 鍵：DismProvider、DismLogLevel、DebugTrace、OperationLog、LogLevel／LogFile
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\PSModules\Imaging\WinMediaDism.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\PSModules\Common\WinMediaProcess.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\PSModules\Common\WinMediaLog.psm1') -Force

function Get-WinMediaIndexInfo {
    # 回傳每個索引的 ImageIndex、ImageName、EditionId、Build（整數）與 Architecture（amd64／arm64）
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ImagePath,
        [Parameter(Mandatory)][hashtable]$Config
    )

    # 先固定路徑變數，讓 ScriptBlock 內的使用對靜態分析可見
    $wimPath = $ImagePath
    $basic = @(Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
        Get-WindowsImage -ImagePath $wimPath -LogLevel $Config.DismLogLevel
    })
    foreach ($item in $basic) {
        $index = [uint32]$item.ImageIndex
        $detail = @(Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
            Get-WindowsImage -ImagePath $wimPath -Index $index -LogLevel $Config.DismLogLevel
        }) | Select-Object -First 1
        # Architecture 為 UInt32：9 = x64（amd64）、12 = ARM64
        $architecture = switch ([uint32]$detail.Architecture) {
            9 { 'amd64' }
            12 { 'arm64' }
            default { throw "不支援的映像架構代碼：$($detail.Architecture)（索引 $index）" }
        }
        [pscustomobject]@{
            ImageIndex   = $index
            ImageName    = [string]$detail.ImageName
            EditionId    = [string]$detail.EditionId
            Build        = [int]$detail.Build
            Architecture = $architecture
        }
    }
}
function ConvertFrom-WinMediaRegQuery {
    # 解析 reg query 輸出（"    名稱    REG_SZ    值"）；UBR 的 0x 十六進位轉十進位。回傳 hashtable：DisplayVersion、CurrentBuild、UBR（int 或 $null）、BuildBranch
    [CmdletBinding()]
    param([AllowEmptyString()][AllowNull()][string[]]$Text)

    $values = @{}
    foreach ($line in @($Text)) {
        if ($line -match '^\s+(\S+)\s+(REG_\w+)\s+(.*?)\s*$') { $values[$Matches[1]] = @{ Type = $Matches[2]; Data = $Matches[3] } }
    }
    $ubr = $null
    if ($values.ContainsKey('UBR') -and $values['UBR'].Data -match '^0x([0-9a-fA-F]+)$') { $ubr = [Convert]::ToInt32($Matches[1], 16) }
    $result = @{ DisplayVersion = $null; CurrentBuild = $null; UBR = $ubr; BuildBranch = $null }
    foreach ($name in 'DisplayVersion', 'CurrentBuild', 'BuildBranch') {
        if ($values.ContainsKey($name)) { $result[$name] = $values[$name].Data }
    }
    return $result
}

function Get-WinMediaBuildInfo {
    # 從已掛載映像的 SOFTWARE hive 讀版本資訊：複製到 WorkDir 的唯一暫存檔，再以唯一機碼名稱 reg load；失敗只警告並回傳 $null
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MountPath,
        [Parameter(Mandatory)][string]$WorkDir,
        [Parameter(Mandatory)][hashtable]$Config
    )

    $id = [guid]::NewGuid().ToString('N')
    $copy = Join-Path -Path $WorkDir -ChildPath ('SOFTWARE-{0}.hiv' -f $id)
    $keyName = 'WinMedia_{0}' -f $id
    $reg = Join-Path -Path ([Environment]::GetFolderPath('System')) -ChildPath 'reg.exe'
    $loaded = $false
    try {
        Copy-Item -LiteralPath (Join-Path -Path $MountPath -ChildPath 'Windows\System32\config\SOFTWARE') -Destination $copy -Force
        $load = Invoke-WinMediaExternal -FilePath $reg -ArgumentList @('load', "HKLM\$keyName", $copy) -Config $Config
        if ($load.ExitCode -ne 0) { throw "reg load 失敗（$($load.ExitCode)）：$($load.StdErr)" }
        $loaded = $true
        $query = Invoke-WinMediaExternal -FilePath $reg -ArgumentList @('query', "HKLM\$keyName\Microsoft\Windows NT\CurrentVersion") -Config $Config
        if ($query.ExitCode -ne 0) { throw "reg query 失敗（$($query.ExitCode)）：$($query.StdErr)" }
        return ConvertFrom-WinMediaRegQuery -Text ($query.StdOut -split "\r?\n")
    }
    catch {
        Write-WinMediaLog -Config $Config -Level Warning -Message ('讀取映像版本資訊失敗，輸出檔名降級：{0}' -f $_.Exception.Message)
        return $null
    }
    finally {
        if ($loaded) {
            try {
                $unload = Invoke-WinMediaExternal -FilePath $reg -ArgumentList @('unload', "HKLM\$keyName") -Config $Config
                if ($unload.ExitCode -ne 0) { Write-WinMediaLog -Config $Config -Level Warning -Message ('reg unload 失敗（{0}）：HKLM\{1}' -f $unload.ExitCode, $keyName) }
            }
            catch { Write-WinMediaLog -Config $Config -Level Warning -Message ('reg unload 例外：{0}' -f $_.Exception.Message) }
        }
        Remove-Item -LiteralPath $copy -Force -ErrorAction SilentlyContinue
    }
}

function New-WinMediaOutputName {
    # 純函式：組出 ISO 檔名；任一段不符 ^[A-Za-z0-9._-]+$ 就丟棄該段。缺 Build 時退回 WinMedia_<時間戳>.iso
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param(
        [string]$DisplayVersion,
        [string]$Build,
        [string]$Revision,
        [string]$BranchUpper,
        [string]$Edition,
        [string]$Arch,
        [string]$BuildType,
        [string[]]$Languages = @(),
        [Parameter(Mandatory)][string]$Timestamp
    )

    $ok = '^[A-Za-z0-9._-]+$'
    $buildSeg = $null
    if ($Build -and $Build -match $ok) {
        $buildSeg = $Build
        if ($Revision -and $Revision -match $ok) { $buildSeg = '{0}.{1}' -f $Build, $Revision }
        if ($BranchUpper -and $BranchUpper -match $ok) { $buildSeg += '.' + $BranchUpper }
    }
    $archSeg = switch ($Arch) { 'amd64' { 'X64' } 'arm64' { 'ARM64' } default { $null } }
    if ($archSeg -and $BuildType -and $BuildType -match $ok) { $archSeg += $BuildType.ToUpperInvariant() }
    $lang = @($Languages | Where-Object { $_ })
    $langSeg = $null
    if ($lang.Count -eq 1) { $langSeg = $lang[0].ToUpperInvariant() } elseif ($lang.Count -gt 1) { $langSeg = 'MULTI' }

    $parts = @('WinMedia')
    if ($buildSeg) {
        foreach ($seg in $DisplayVersion, $buildSeg, $Edition, $archSeg, $langSeg) {
            if ($seg -and $seg -match $ok) { $parts += $seg }
        }
    }
    $parts += $Timestamp
    return ($parts -join '_') + '.iso'
}

Export-ModuleMember -Function Get-WinMediaIndexInfo, ConvertFrom-WinMediaRegQuery, Get-WinMediaBuildInfo, New-WinMediaOutputName
