Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Windows 更新包下載（§2.1、§11.4）：Catalog 為主要來源，UUP dump 為輔助與驗證來源
# 需要的 Config 鍵：PackageDir（下載目的地）、Download.Method、DebugTrace、OperationLog、LogLevel／LogFile
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\PSModules\Common\WinMediaLog.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\PSModules\Common\WinMediaOperation.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\PSModules\Common\WinMediaDownload.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\PSModules\Common\PathSanitize.psm1') -Force

$script:CatalogSearchUri = 'https://www.catalog.update.microsoft.com/Search.aspx?q='
$script:CatalogDialogUri = 'https://www.catalog.update.microsoft.com/DownloadDialog.aspx'
$script:UupListUri = 'https://api.uupdump.net/listid.php?search='
$script:UupGetUri = 'https://api.uupdump.net/get.php?'
$script:LearnReleaseUri = 'https://learn.microsoft.com/en-us/windows/release-health/windows11-release-information'
# 更新包主機白名單：單一來源，供網址閘門與下載器的逐跳重導向驗證共用
$script:MicrosoftHostPattern = '(^|\.)(microsoft\.com|windowsupdate\.com)$'

function ConvertTo-WinMediaKbNumber {
    # 接受 KB5044284 或 5044284；其餘格式直接拒絕，避免拼入 URL 的內容不可控
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$KB
    )

    $match = [regex]::Match($KB.Trim(), '^(?i:KB)?(\d{6,8})$')
    if (-not $match.Success) { throw "KB 編號格式錯誤：$KB" }
    return $match.Groups[1].Value
}

function ConvertTo-WinMediaUpdateKey {
    # 同一更新包在 Catalog（檔名含 _SHA1）與 UUP（不含雜湊）之間的比對鍵：去掉 _SHA1、轉小寫
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name
    )

    return ([regex]::Replace($Name, '_[0-9a-fA-F]{40}(?=\.[^.]+$)', '')).ToLowerInvariant()
}

function ConvertFrom-WinMediaCatalogSearch {
    # 解析 Catalog 搜尋結果：只取 <a id='GUID_link'> 錨點，回傳 GUID 與標題
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Html
    )

    foreach ($m in [regex]::Matches($Html, "id='([0-9a-f\-]{36})_link'[^>]*>\s*([^<]*?)\s*</a>", 'Singleline')) {
        [pscustomobject]@{
            Guid  = $m.Groups[1].Value
            Title = [System.Net.WebUtility]::HtmlDecode($m.Groups[2].Value.Trim())
        }
    }
}

function ConvertFrom-WinMediaCatalogDialog {
    # 解析 DownloadDialog 回應：只接受 Microsoft 網域的 https 網址；檔名末段的 40 位十六進位即 SHA-1
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Html
    )

    $seen = @{}
    foreach ($m in [regex]::Matches($Html, "https://[A-Za-z0-9.\-]+/[^'""\s\\<>]+")) {
        if ($m.Value -notmatch '\.(?i:msu|cab|exe|msixbundle|appx|msix)$') { continue }
        $safe = ConvertTo-SanitizedUri -Uri $m.Value -AllowedSchemes 'https'
        if ($safe.Host -notmatch $script:MicrosoftHostPattern) { continue }
        if ($seen.ContainsKey($safe.Uri)) { continue }
        $seen[$safe.Uri] = $true

        $sha1 = [regex]::Match($safe.FileName, '_([0-9a-fA-F]{40})\.[^.]+$')
        [pscustomobject]@{
            FileName = $safe.FileName
            Uri      = $safe.Uri
            Sha1     = if ($sha1.Success) { $sha1.Groups[1].Value.ToLowerInvariant() } else { $null }
        }
    }
}

function Find-WinMediaCatalogUpdate {
    # Catalog 搜尋：以 KB 與架構過濾，只保留 Windows 11 24H2 桌面版
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$KB,
        [ValidateSet('amd64', 'arm64')][string]$Architecture = 'amd64'
    )

    $number = ConvertTo-WinMediaKbNumber -KB $KB
    $archText = if ($Architecture -eq 'amd64') { 'x64-based' } else { 'arm64-based' }
    $html = (Invoke-WebRequest -Uri ($script:CatalogSearchUri + 'KB' + $number) -UseBasicParsing).Content
    @(ConvertFrom-WinMediaCatalogSearch -Html $html | Where-Object {
        # Catalog 標題格式已變為 "Windows 11, version 24H2"（有逗號、小寫 version），兩種格式都接受
        $_.Title -match "Windows 11,? Version 24H2 for $archText" -and $_.Title -match "\(KB$number\)"
    })
}

function Get-WinMediaCatalogFile {
    # 取得單一 Catalog 項目的下載網址與 SHA-1；GUID 先驗格式，避免拼入請求的內容不可控
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')][string]$Guid
    )

    $body = 'updateIDs=' + [uri]::EscapeDataString('[{"size":0,"languages":"","uidInfo":"' + $Guid + '","updateID":"' + $Guid + '"}]')
    $html = (Invoke-WebRequest -Uri $script:CatalogDialogUri -Method Post -Body $body -ContentType 'application/x-www-form-urlencoded' -UseBasicParsing).Content
    $files = @(ConvertFrom-WinMediaCatalogDialog -Html $html)
    if ($files.Count -eq 0) { throw "Catalog 未回傳下載網址：$Guid" }
    return $files
}

function Get-WinMediaUupProperty {
    # StrictMode 下安全讀取屬性：缺少時回傳 $null，不拋出例外
    [CmdletBinding()]
    param(
        $Object,
        [Parameter(Mandatory)][string]$Name
    )

    if ($Object -and $Object.PSObject.Properties[$Name]) { return $Object.PSObject.Properties[$Name].Value }
    return $null
}

function Get-WinMediaUupResponse {
    # UUP 回應外層都是 { "response": {...} }；缺少時明確報錯
    [CmdletBinding()]
    param(
        $Json
    )

    $response = Get-WinMediaUupProperty -Object $Json -Name 'response'
    if (-not $response) { throw 'UUP 回應格式錯誤：缺少 response' }
    return $response
}

function Get-WinMediaUupError {
    [CmdletBinding()]
    param(
        $Response
    )

    $message = Get-WinMediaUupProperty -Object $Response -Name 'error'
    if ($message) { return [string]$message }
    return '無錯誤訊息'
}

function Get-WinMediaUupBuild {
    # UUP 以 build 號搜尋；只接受 build 完全相同的條目，避免取到相近版本
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Build,
        [ValidateSet('amd64', 'arm64')][string]$Architecture = 'amd64'
    )

    if ($Build -notmatch '^\d+\.\d+$') { throw "build 格式錯誤（應為 26100.1882）：$Build" }
    $response = Get-WinMediaUupResponse -Json (Invoke-RestMethod -Uri ($script:UupListUri + [uri]::EscapeDataString($Build) + '&sortByName=1') -UseBasicParsing)
    $builds = Get-WinMediaUupProperty -Object $response -Name 'builds'
    if (-not $builds) { throw "UUP 回應沒有 build 清單（$(Get-WinMediaUupError -Response $response)）" }
    # listid 對同一 build 會列出每個架構各一筆，必須依 arch 篩選
    # 同一 build 號 Server、HCI 也會使用；只接受用戶端 "Windows 11, version …" 條目（title 缺少時視為不符）
    # 缺欄位的條目視為不符，不讓單一條目拋出例外而中止整個選擇
    $match = @($builds.PSObject.Properties.Value | Where-Object {
        ([string](Get-WinMediaUupProperty -Object $_ -Name 'build')) -eq $Build -and
        ([string](Get-WinMediaUupProperty -Object $_ -Name 'arch')) -eq $Architecture -and
        ([string](Get-WinMediaUupProperty -Object $_ -Name 'title')) -like 'Windows 11,*'
    }) | Select-Object -First 1
    if (-not $match) { throw "UUP 找不到 build $Build" }
    return [string]$match.uuid
}

function Get-WinMediaUupFile {
    # UUP get.php：只保留 KB 與架構相符的檔案，回傳檔名、SHA-1 與下載網址（UUP 提供的網址同樣以 SHA-1 驗證）
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')][string]$Uuid,
        [Parameter(Mandatory)][string]$KB,
        [ValidateSet('amd64', 'arm64')][string]$Architecture = 'amd64'
    )

    $number = ConvertTo-WinMediaKbNumber -KB $KB
    $archToken = if ($Architecture -eq 'amd64') { 'x64' } else { 'arm64' }
    foreach ($entry in Get-WinMediaUupEntry -Uuid $Uuid) {
        if ($entry.Name -match "(?i)kb$number[-_.]" -and $entry.Name -match "(?i)[-_.]$archToken\.") { $entry }
    }
}

function Get-WinMediaUupEntry {
    # UUP get.php 的完整檔案清單（不過濾 KB）；EMPTY_FILELIST 代表 UUP 已不提供此 build
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')][string]$Uuid
    )

    # 語言中立的更新包在 en-us 與其他語言之間相同；此處不另外指定語言
    $response = Get-WinMediaUupResponse -Json (Invoke-RestMethod -Uri ($script:UupGetUri + "id=$Uuid&lang=en-us&edition=professional") -UseBasicParsing)
    $files = Get-WinMediaUupProperty -Object $response -Name 'files'
    if (-not $files) { throw "UUP 檔案清單為空：$(Get-WinMediaUupError -Response $response)" }

    foreach ($p in $files.PSObject.Properties) {
        # 缺 sha1／url 的條目保留為空值，由下載端拒絕（避免單一條目讓整份清單失敗）
        [pscustomobject]@{
            Name = $p.Name
            Sha1 = ([string](Get-WinMediaUupProperty -Object $p.Value -Name 'sha1')).ToLowerInvariant()
            Url  = Get-WinMediaUupProperty -Object $p.Value -Name 'url'
        }
    }
}

function Assert-WinMediaUpdateUrl {
    # 所有下載共用的網址閘門：只接受 https、Microsoft／Windows Update 網域、更新包副檔名
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Url
    )

    $safe = ConvertTo-SanitizedUri -Uri $Url -AllowedSchemes 'https'
    if ($safe.Host -notmatch $script:MicrosoftHostPattern) { throw "網址不在允許的 Microsoft 網域：$($safe.Host)" }
    if ($safe.FileName -notmatch '\.(?i:msu|cab|exe|msixbundle|appx|msix)$') { throw "不允許的更新包副檔名：$($safe.FileName)" }
    return $safe
}

function Save-WinMediaUpdateFile {
    # 下載單一檔案並以 SHA-1 驗證；已存在且雜湊相符則略過；不符即刪除並中止
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingBrokenHashAlgorithms', '', Justification = 'Catalog 檔名與 UUP 每個檔案只提供 SHA-1；用於比對 Microsoft 發佈的雜湊，非安全用途')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string]$Sha1,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][hashtable]$Config
    )

    $safe = Assert-WinMediaUpdateUrl -Url $Uri
    # 檔名是寫入路徑的一部分：只允許單一葉節點、無 ..，且副檔名須與網址相同（信任邊界）
    if ($FileName -ne (Split-Path -Path $FileName -Leaf) -or $FileName -match '\.\.' -or $FileName -notmatch '(?i)\.(msu|cab)$') { throw "不允許的更新包檔名：$FileName" }
    if (-not [string]::Equals([IO.Path]::GetExtension($FileName), [IO.Path]::GetExtension($safe.FileName), [StringComparison]::OrdinalIgnoreCase)) { throw "檔名副檔名與網址不符：$FileName" }
    $target = Join-Path -Path $Destination -ChildPath $FileName
    if (Test-WinMediaFileHash -Path $target -Hash $Sha1 -Algorithm SHA1) {
        Write-WinMediaLog -Config $Config -Level Info -Message "已存在且 SHA-1 相符，略過：$FileName"
        return $target
    }

    # 逐跳重導向都必須符合同一份白名單（信任邊界，見 DESIGN「安全措施」）
    Invoke-WinMediaDownload -Uri $safe.Uri -Destination $target -Method $Method -AllowedHostPattern $script:MicrosoftHostPattern -Config $Config | Out-Null
    if (-not (Test-WinMediaFileHash -Path $target -Hash $Sha1 -Algorithm SHA1)) {
        Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
        throw "SHA-1 不符，已刪除：$FileName"
    }
    Write-WinMediaLog -Config $Config -Level Info -Message "已下載並通過 SHA-1 驗證：$FileName"
    return $target
}

function Save-WinMediaUpdate {
    <#
    .SYNOPSIS
        依 KB 編號下載 Windows 11 24H2 更新包到 PackageDir。
    .DESCRIPTION
        來源順序：Catalog（主要）→ UUP（備援與驗證）。
        - 指定 -Build 時，UUP 的 SHA-1 會與 Catalog 檔案交叉比對，不一致即中止；UUP 無法連線只記警告，仍以 Catalog 的 SHA-1 驗證。
        - Catalog 無結果時，若有 -Build 則改用 UUP 提供的下載網址，並以 UUP 的 SHA-1 驗證；沒有 -Build 則中止。
        下載方式由 Config.Download.Method 決定（WebRequest／Bits／Curl）。
    .PARAMETER KB
        KB 編號，例如 KB5044284。
    .PARAMETER Build
        完整 build 號，例如 26100.1882；用於 UUP 交叉驗證與備援。
    .EXAMPLE
        Save-WinMediaUpdate -KB KB5044284 -Build 26100.1882 -Config $config
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$KB,
        [string]$Build,
        [ValidateSet('amd64', 'arm64')][string]$Architecture = 'amd64',
        [Parameter(Mandatory)][hashtable]$Config
    )

    $number = ConvertTo-WinMediaKbNumber -KB $KB
    $dest = $Config.PackageDir
    if ([string]::IsNullOrWhiteSpace($dest)) { throw 'PackageDir 未設定，無法下載更新包。' }
    $method = if ($Config.Download -and $Config.Download.Method) { $Config.Download.Method } else { 'WebRequest' }
    New-Item -ItemType Directory -Path $dest -Force | Out-Null

    # UUP 輔助：只在有 build 時查詢；失敗不中止，改以 Catalog 的 SHA-1 驗證
    $uupFiles = @()
    $uuid = $null
    if ($Build) {
        try {
            $uuid = Get-WinMediaUupBuild -Build $Build -Architecture $Architecture
            $uupFiles = @(Get-WinMediaUupFile -Uuid $uuid -KB $KB -Architecture $Architecture)
        }
        catch {
            Write-WinMediaLog -Config $Config -Level Warning -Message "UUP 輔助查詢失敗，改以 Catalog SHA-1 驗證：$($_.Exception.Message)"
            $uupFiles = @()
        }
    }

    $saved = @()
    $catalog = @()
    try {
        $catalog = @(Find-WinMediaCatalogUpdate -KB $KB -Architecture $Architecture)
    }
    catch {
        Write-WinMediaLog -Config $Config -Level Warning -Message "Catalog 搜尋失敗：$($_.Exception.Message)"
    }

    foreach ($item in $catalog) {
        foreach ($file in @(Get-WinMediaCatalogFile -Guid $item.Guid)) {
            if (-not $file.Sha1) { throw "Catalog 檔名缺少 SHA-1，無法驗證：$($file.FileName)" }
            $key = ConvertTo-WinMediaUpdateKey -Name $file.FileName
            $reference = $uupFiles | Where-Object { (ConvertTo-WinMediaUpdateKey -Name $_.Name) -eq $key } | Select-Object -First 1
            if (-not $reference -and $uupFiles.Count -gt 0) {
                Write-WinMediaLog -Config $Config -Level Warning -Message "UUP 無對應檔案，僅以 Catalog SHA-1 驗證：$($file.FileName)"
            }
            if ($reference -and $reference.Sha1 -ne $file.Sha1) {
                throw "Catalog 與 UUP 的 SHA-1 不一致，已中止：$($file.FileName)"
            }
            $saved += Save-WinMediaUpdateFile -Uri $file.Uri -FileName $file.FileName -Sha1 $file.Sha1 -Destination $dest -Method $method -Config $Config
        }
    }

    # 備援：Catalog 沒有結果時才使用 UUP 的下載網址
    if ($saved.Count -eq 0) {
        if (-not $uuid) { throw "Catalog 找不到 KB$number，且未提供可用的 -Build 作為 UUP 備援。" }
        $uupLinks = @(Get-WinMediaUupFile -Uuid $uuid -KB $KB -Architecture $Architecture)
        if ($uupLinks.Count -eq 0) { throw "UUP 也找不到 KB$number 的檔案。" }
        Write-WinMediaLog -Config $Config -Level Warning -Message "Catalog 找不到 KB$number，改用 UUP 提供的網址下載。"
        foreach ($link in $uupLinks) {
            if (-not $link.Url) { throw "UUP 未提供下載網址：$($link.Name)" }
            if ([string]::IsNullOrEmpty($link.Sha1)) { throw "UUP 未提供 SHA-1，拒絕未經驗證的下載：$($link.Name)" }
            $saved += Save-WinMediaUpdateFile -Uri $link.Url -FileName $link.Name -Sha1 $link.Sha1 -Destination $dest -Method $method -Config $Config
        }
    }

    return $saved
}

function Find-WinMediaLearnKb {
    # Learn 只列出各通道最新 build，且更新較慢；僅作交叉檢查，不作為主要來源。回傳該 build 列的 KB，找不到回傳 $null
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Build
    )

    if ($Build -notmatch '^\d+\.\d+$') { throw "build 格式錯誤（應為 26100.1882）：$Build" }
    $html = (Invoke-WebRequest -Uri $script:LearnReleaseUri -UseBasicParsing).Content
    $pattern = '(?<![\d.])' + [regex]::Escape($Build) + '(?!\d)'
    foreach ($row in [regex]::Matches($html, '(?s)<tr[^>]*>.*?</tr>')) {
        if ($row.Value -match $pattern -and $row.Value -match 'help/(\d{7})') { return 'KB' + $Matches[1] }
    }
    return $null
}

function Get-WinMediaKbOfName {
    # 檔名中的 KB 編號（數字）；沒有 KB 回傳 $null
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name
    )

    $m = [regex]::Match($Name, '(?i)kb(\d{7})')
    if ($m.Success) { return [int]$m.Groups[1].Value }
    return $null
}

function Resolve-WinMediaCumulativeSet {
    # 從候選 .msu 中取出目標（KB 最大者）與其前置 checkpoint（KB 較小者）；只有一個時沒有 checkpoint
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Paths,
        [Parameter(Mandatory)][hashtable]$Config
    )

    $candidates = @($Paths | Where-Object { $_ -match '\.msu$' })
    if ($candidates.Count -eq 0) { return $null }
    $ranked = @()
    foreach ($path in $candidates) {
        $kb = Get-WinMediaKbOfName -Name (Split-Path -Path $path -Leaf)
        if ($null -eq $kb -and $candidates.Count -gt 1) { throw "多個累積更新但檔名缺少 KB 編號，無法判定 checkpoint：$(Split-Path -Path $path -Leaf)" }
        $ranked += [pscustomobject]@{ Path = $path; Kb = $kb }
    }
    $ordered = @($ranked | Sort-Object -Property Kb -Descending)
    $target = $ordered[0].Path
    $checkpoints = @($ordered | Select-Object -Skip 1 | ForEach-Object { $_.Path } | Sort-Object)
    foreach ($cp in $checkpoints) { Write-WinMediaLog -Config $Config -Level Info -Message "前置 checkpoint：$(Split-Path -Path $cp -Leaf)" }
    return [pscustomobject]@{ Target = $target; Checkpoints = $checkpoints }
}

function New-WinMediaUpdateStage {
    # 將目標與 checkpoint 放進獨立資料夾（DISM 只會在 -PackagePath 所在資料夾尋找 checkpoint）；同磁碟用硬連結避免重複佔用空間
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Checkpoints,
        [Parameter(Mandatory)][string]$StageDir,
        [Parameter(Mandatory)][hashtable]$Config
    )

    # 只清除本工具建立的 update-stage 目錄；內容由下方重新建立
    if ($PSCmdlet.ShouldProcess($StageDir, '重建更新包暫存資料夾')) {
        if (Test-Path -LiteralPath $StageDir) { Remove-Item -LiteralPath $StageDir -Recurse -Force }
        New-Item -ItemType Directory -Path $StageDir -Force | Out-Null
        foreach ($file in @($Checkpoints) + @($Target)) {
            $link = Join-Path -Path $StageDir -ChildPath (Split-Path -Path $file -Leaf)
            try {
                New-Item -ItemType HardLink -Path $link -Target $file -ErrorAction Stop | Out-Null
            }
            catch {
                # shortcut: 跨磁碟或檔案系統不支援硬連結時改為複製（會多佔一份空間，約 5 GB 級）
                Copy-Item -LiteralPath $file -Destination $link -Force
            }
        }
        Write-WinMediaLog -Config $Config -Level Info -Message "更新包暫存資料夾：$StageDir（目標與 $(@($Checkpoints).Count) 個 checkpoint）"
    }
    return (Join-Path -Path $StageDir -ChildPath (Split-Path -Path $Target -Leaf))
}

function Save-WinMediaBuildSet {
    # UUP 主要來源：依 build 下載整組 KB 檔案（目標、checkpoint、SafeOS、SetupDU、.NET）到 PackageDir；Learn 只做交叉檢查
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Build,
        [ValidateSet('amd64', 'arm64')][string]$Architecture = 'amd64',
        [Parameter(Mandatory)][hashtable]$Config
    )

    $dest = $Config.PackageDir
    if ([string]::IsNullOrWhiteSpace($dest)) { throw 'PackageDir 未設定，無法下載更新包。' }
    $method = if ($Config.Download -and $Config.Download.Method) { $Config.Download.Method } else { 'WebRequest' }
    $archToken = if ($Architecture -eq 'amd64') { 'x64' } else { 'arm64' }

    try {
        $uuid = Get-WinMediaUupBuild -Build $Build -Architecture $Architecture
        $entries = @(Get-WinMediaUupEntry -Uuid $uuid)
    }
    catch {
        throw "UUP 無法提供 build $Build（$($_.Exception.Message)）；UUP 會移除舊 build，請改在 Download.KB 指定 KB。"
    }
    $set = @($entries | Where-Object { $_.Name -match "(?i)^windows11\.0-kb\d{7}-$archToken(-[^.]+)?\.(msu|cab)$" })
    $msu = @($set | Where-Object { $_.Name -match "(?i)^windows11\.0-kb\d{7}-$archToken\.msu$" } |
        Sort-Object -Property @{ Expression = { Get-WinMediaKbOfName -Name $_.Name } } -Descending)
    if ($msu.Count -eq 0) { throw "UUP 的 build $Build 沒有 $archToken 累積更新（.msu）。" }
    $targetKb = 'KB' + (Get-WinMediaKbOfName -Name $msu[0].Name)

    # Learn 交叉檢查：不一致只警告；build 未列出（Learn 只列最新 build）為 Info
    try {
        $learnKb = Find-WinMediaLearnKb -Build $Build
        if (-not $learnKb) { Write-WinMediaLog -Config $Config -Level Info -Message "Learn 尚未列出 build $Build（僅列各通道最新 build），以 UUP 為準：$targetKb" }
        elseif ($learnKb -ne $targetKb) { Write-WinMediaLog -Config $Config -Level Warning -Message "UUP 與 Learn 的 KB 不一致（UUP：$targetKb，Learn：$learnKb），以 UUP 為準。" }
    }
    catch {
        Write-WinMediaLog -Config $Config -Level Warning -Message "Learn 交叉檢查失敗，僅以 UUP 為準：$($_.Exception.Message)"
    }

    $saved = @()
    foreach ($entry in $set) {
        if (-not $entry.Url) { throw "UUP 未提供下載網址：$($entry.Name)" }
        if ([string]::IsNullOrEmpty($entry.Sha1)) { throw "UUP 未提供 SHA-1，拒絕未經驗證的下載：$($entry.Name)" }
        $saved += Save-WinMediaUpdateFile -Uri $entry.Url -FileName $entry.Name -Sha1 $entry.Sha1 -Destination $dest -Method $method -Config $Config
    }
    # 與 $msu 相同的嚴格命名：排除帶後綴（例如 -ndp481）的 .msu，避免 .NET 套件被當成 LCU
    $savedMsu = @($saved | Where-Object { (Split-Path -Path $_ -Leaf) -match "(?i)^windows11\.0-kb\d{7}-$archToken\.msu$" })
    $resolved = Resolve-WinMediaCumulativeSet -Paths $savedMsu -Config $Config
    return [pscustomobject]@{
        TargetKb    = $targetKb
        Target      = $resolved.Target
        Checkpoints = $resolved.Checkpoints
        Files       = $saved
    }
}

Export-ModuleMember -Function Save-WinMediaUpdate, Save-WinMediaBuildSet, Resolve-WinMediaCumulativeSet, New-WinMediaUpdateStage, Find-WinMediaLearnKb
