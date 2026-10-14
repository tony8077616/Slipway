function Mount-WinMediaImage {
    # 掛載包裝（§3.3）：try/finally 保證卸載；成功才 -Save，其餘一律 -Discard
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ImagePath,
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][string]$MountPath,
        [switch]$ReadOnly,
        [bool]$CommitOnSuccess = $true,
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][hashtable]$Config
    )

    Write-WinMediaLog -Config $Config -Level Verbose -Message "掛載 $ImagePath 索引 $Index → $MountPath（ReadOnly=$ReadOnly）"
    Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
        Mount-WindowsImage -ImagePath $ImagePath -Index $Index -Path $MountPath -ReadOnly:$ReadOnly | Out-Null
    }

    $succeeded = $false
    $save = $false
    try {
        $result = & $Action $MountPath
        $succeeded = $true
        return $result
    }
    finally {
        $save = $succeeded -and $CommitOnSuccess -and (-not $ReadOnly)
        Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
            if ($save) {
                Dismount-WindowsImage -Path $MountPath -Save | Out-Null
            }
            else {
                Dismount-WindowsImage -Path $MountPath -Discard | Out-Null
            }
        }
    }
}
