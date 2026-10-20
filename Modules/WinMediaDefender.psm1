#Requires -Version 5.1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# 正規化路徑：去除結尾反斜線，比對時忽略大小寫
function script:ConvertTo-DefenderPathKey {
    param([string]$Path)
    return $Path.TrimEnd('\').ToUpperInvariant()
}

function Get-WinMediaDefenderExclusion {
    <#
    .SYNOPSIS
        取得目前 Windows Defender 的路徑排除清單；無法確定時回傳 $null（呼叫端必須據此略過，不可當成空清單）。
    #>
    [CmdletBinding()]
    param()

    try {
        $pref = Get-MpPreference
        $raw = @($pref.ExclusionPath)
        # Tamper Protection 或權限不足時，Get-MpPreference 會回傳 "N/A…" 字串，此時清單不可信
        if (@($raw | Where-Object { $_ -is [string] -and $_ -like 'N/A*' }).Count -gt 0) {
            Write-Warning '無法讀取 Windows Defender 排除清單（N/A），略過排除設定。'
            return $null
        }
        return ,@($raw | Where-Object { $_ -is [string] -and $_ })
    }
    catch {
        Write-Warning ('無法讀取 Windows Defender 排除清單，略過排除設定：{0}' -f $_.Exception.Message)
        return $null
    }
}

function Add-WinMediaDefenderExclusion {
    <#
    .SYNOPSIS
        加入路徑排除，並回傳「本次實際新增」的路徑；已存在的路徑不納入，供結束時只移除自己加的項目。
    .DESCRIPTION
        讀不到既有清單時整批略過（不新增、也不會在結束時移除既有排除）。
        非管理員或 Tamper Protection 開啟時 Add-MpPreference 會失敗，此時只發出警告，不中止流程。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string[]]$Path
    )

    $current = Get-WinMediaDefenderExclusion
    if ($null -eq $current) { return ,@() }
    $existing = @{}
    foreach ($item in $current) {
        $existing[(ConvertTo-DefenderPathKey -Path $item)] = $true
    }

    $added = New-Object -TypeName System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($item in $Path) {
        if ([string]::IsNullOrWhiteSpace($item)) { continue }
        $key = ConvertTo-DefenderPathKey -Path $item
        if ($existing.ContainsKey($key) -or $seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        try {
            Add-MpPreference -ExclusionPath $item
            $added.Add($item)
        }
        catch {
            Write-Warning ('無法加入 Windows Defender 排除 {0}：{1}' -f $item, $_.Exception.Message)
        }
    }
    return ,$added.ToArray()
}

function Remove-WinMediaDefenderExclusion {
    <#
    .SYNOPSIS
        移除先前由 Add-WinMediaDefenderExclusion 新增的路徑排除；失敗只警告，供 finally 呼叫。
    #>
    [CmdletBinding()]
    param(
        [string[]]$Path
    )

    foreach ($item in @($Path)) {
        if ([string]::IsNullOrWhiteSpace($item)) { continue }
        try {
            Remove-MpPreference -ExclusionPath $item
        }
        catch {
            Write-Warning ('無法移除 Windows Defender 排除 {0}：{1}' -f $item, $_.Exception.Message)
        }
    }
}

Export-ModuleMember -Function @(
    'Get-WinMediaDefenderExclusion',
    'Add-WinMediaDefenderExclusion',
    'Remove-WinMediaDefenderExclusion'
)
