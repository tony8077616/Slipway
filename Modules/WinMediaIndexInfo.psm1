Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# install.wim 索引資訊：Get-WindowsImage 不帶 -Index 只回傳 BasicImageInfoObject（沒有 Build／EditionId／Architecture），必須逐索引再查
# 模組名稱刻意與 PSModules\Imaging\WinMediaImage.psm1（Mount-WinMediaImage）不同，避免 Import-Module 互相覆寫
# 需要的 Config 鍵：DismProvider、DismLogLevel、DebugTrace、OperationLog、LogLevel／LogFile
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\PSModules\Imaging\WinMediaDism.psm1') -Force

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

Export-ModuleMember -Function Get-WinMediaIndexInfo
