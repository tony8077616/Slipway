function Add-WinMediaVirtualEdition {
    <#
    .SYNOPSIS
        以 DISM Cmdlet 在映像中新增一個虛擬版本索引（§2.7.4）。
    .DESCRIPTION
        掛載來源索引 → Get-WindowsEdition -Target 確認可用 → Set-WindowsEdition → Save-WindowsImage -Append
        → 卸載一律 -Discard（避免覆寫來源索引，§2.7.4）→ 以 Get-WindowsImage 驗證新索引的 EditionId。
        每個 Set-WindowsEdition 與 Save-WindowsImage 另寫入 DismVirtualEditions.log。
    .PARAMETER ImagePath
        install.wim 路徑（必須為可寫的 WIM，不是 install.esd）。
    .PARAMETER Index
        來源索引（應為 EnterpriseS）。
    .PARAMETER MountPath
        掛載目錄。
    .PARAMETER Edition
        目標 EditionID，即 §2.7.8 的清單 token。
    .PARAMETER Config
        設定表。
    .EXAMPLE
        Add-WinMediaVirtualEdition -ImagePath $wim -Index 1 -MountPath $mp -Edition 'IoTEnterpriseS' -Config $config
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ImagePath,
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][string]$MountPath,
        [Parameter(Mandatory)][string]$Edition,
        [Parameter(Mandatory)][hashtable]$Config
    )

    $virtualLog = Join-Path -Path $Config.LogDir -ChildPath 'DismVirtualEditions.log'

    $action = {
        param($mountedPath)
        Write-WinMediaLog -Config $Config -Level Verbose -Message "虛擬版本掛載點：$mountedPath，目標 $Edition"

        $available = Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
            Get-WindowsEdition -Path $mountedPath -Target
        }
        $names = @($available | ForEach-Object { $_.Edition })
        $match = $names | Where-Object { $_ -ieq $Edition } | Select-Object -First 1
        if (-not $match) {
            throw "目標 EditionID '$Edition' 不在 Get-WindowsEdition -Target 清單中：$($names -join ', ')（§2.7.2）"
        }

        Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
            Set-WindowsEdition -Path $mountedPath -Edition $match
        } | Out-Null
        Add-WinMediaTextLine -Path $virtualLog -Line ("{0} Set-WindowsEdition -Edition {1}" -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'), $match)

        Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
            Save-WindowsImage -Path $mountedPath -Append | Out-Null
        } | Out-Null
        Add-WinMediaTextLine -Path $virtualLog -Line ("{0} Save-WindowsImage -Append" -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'))
    }

    Mount-WinMediaImage -ImagePath $ImagePath -Index $Index -MountPath $MountPath -CommitOnSuccess:$false -Action $action -Config $Config | Out-Null

    $images = Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
        Get-WindowsImage -ImagePath $ImagePath
    }
    $appended = $images | Select-Object -Last 1
    if ($appended.EditionId -ine $Edition) {
        throw "驗證失敗：新索引 $($appended.ImageIndex) 的 EditionId 為 '$($appended.EditionId)'，預期 '$Edition'（§6.2）。"
    }
    Write-WinMediaLog -Config $Config -Level Info -Message "已新增虛擬版本索引 $($appended.ImageIndex)：$Edition"
    return $appended
}
