Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# 語言包與 FoD 獨立資料夾（§2.3）：依 Config.Languages 篩選，於 LCU 之後注入 install.wim
# 需要的 Config 鍵：Lang.Path、Fod.Path、Languages、DismProvider、LogLevel／LogFile、DebugTrace、OperationLog
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\PSModules\Common\WinMediaLog.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\PSModules\Imaging\WinMediaDism.psm1') -Force

function Get-WinMediaLanguageTag {
    # 從套件檔名取出語言標籤（例如 ja-jp）；檔名沒有語言標籤即為語言中立，回傳 $null
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FileName
    )

    $match = [regex]::Match($FileName, '(?i)(?<![a-z])([a-z]{2,3}-[a-z0-9]{2,4})(?![a-z0-9])')
    if ($match.Success) { return $match.Groups[1].Value.ToLowerInvariant() }
    return $null
}

function Get-WinMediaCabFile {
    # 列出資料夾（遞迴）內的 .cab；Add-WindowsPackage 不接受 .esd，其他副檔名略過並記錄
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][hashtable]$Config
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return @() }
    $files = @(Get-ChildItem -LiteralPath $Path -Recurse -File)
    foreach ($ignored in $files | Where-Object { $_.Extension -ne '.cab' }) {
        Write-WinMediaLog -Config $Config -Level Warning -Message "略過非 .cab 檔案：$($ignored.Name)"
    }
    return @($files | Where-Object { $_.Extension -eq '.cab' } | Sort-Object -Property Name)
}

function Resolve-WinMediaLangFodSet {
    # 語言包：只保留檔名語言標籤屬於 Config.Languages 者（語言中立者不屬於語言包，略過）
    # FoD：語言中立者一律保留；有語言標籤者只保留設定語言
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$LangPath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$FodPath,
        [Parameter(Mandatory)][hashtable]$Config
    )

    $wanted = @($Config.Languages | ForEach-Object { $_.ToLowerInvariant() })

    $langPacks = @()
    foreach ($file in Get-WinMediaCabFile -Path $LangPath -Config $Config) {
        $tag = Get-WinMediaLanguageTag -FileName $file.Name
        if ($tag -and ($wanted -contains $tag)) { $langPacks += $file.FullName }
        else { Write-WinMediaLog -Config $Config -Level Info -Message "略過語言包（非設定語言或無語言標籤）：$($file.Name)" }
    }

    # NetFx3 會留下待處理作業（0x800F0806），必須在 install.wim 的 cleanup 之後注入（文件表格步驟 15），因此獨立成 Deferred
    $fod = @()
    $deferred = @()
    foreach ($file in Get-WinMediaCabFile -Path $FodPath -Config $Config) {
        $tag = Get-WinMediaLanguageTag -FileName $file.Name
        if ($tag -and ($wanted -notcontains $tag)) {
            Write-WinMediaLog -Config $Config -Level Info -Message "略過 FoD（非設定語言）：$($file.Name)"
        }
        elseif ($file.Name -match '(?i)NetFx3') { $deferred += $file.FullName }
        else { $fod += $file.FullName }
    }

    [pscustomobject]@{
        LangPacks = $langPacks
        Fod       = $fod
        Deferred  = $deferred
    }
}

function Install-WinMediaDeferredFod {
    # cleanup 之後才注入的 FoD（NetFx3）；由主流程在 .NET CU 之前呼叫
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$MountPath,
        [Parameter(Mandatory)][pscustomobject]$Set,
        [Parameter(Mandatory)][hashtable]$Config
    )

    if (-not $PSCmdlet.ShouldProcess($MountPath, '注入 cleanup 後的 FoD')) { return }
    foreach ($package in @($Set.Deferred)) {
        Write-WinMediaLog -Config $Config -Level Info -Message "注入 cleanup 後的 FoD：$(Split-Path -Path $package -Leaf)"
        Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
            Add-WindowsPackage -Path $MountPath -PackagePath $package | Out-Null
        } | Out-Null
    }
}

function Install-WinMediaLangFod {
    # 先注入語言包、再注入 FoD（FoD 的語言功能依賴語言包）
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$MountPath,
        [Parameter(Mandatory)][pscustomobject]$Set,
        [Parameter(Mandatory)][hashtable]$Config
    )

    if (-not $PSCmdlet.ShouldProcess($MountPath, '注入語言包與 FoD')) { return }

    foreach ($package in @($Set.LangPacks) + @($Set.Fod)) {
        Write-WinMediaLog -Config $Config -Level Info -Message "注入語言包／FoD：$(Split-Path -Path $package -Leaf)"
        Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
            Add-WindowsPackage -Path $MountPath -PackagePath $package | Out-Null
        } | Out-Null
    }
}

Export-ModuleMember -Function Resolve-WinMediaLangFodSet, Install-WinMediaLangFod, Install-WinMediaDeferredFod
