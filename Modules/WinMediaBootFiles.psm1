Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\PSModules\Common\WinMediaOperation.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\PSModules\Common\WinMediaProcess.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\PSModules\Imaging\WinMediaWimlib.psm1') -Force

function Copy-WinMediaBootFile {
    # 單一檔案複製：來源不存在時略過（回傳 $false），目標資料夾不存在時建立
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][hashtable]$Config
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { return $false }
    $targetDir = Split-Path -Path $Target -Parent
    if (-not (Test-Path -LiteralPath $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
    Invoke-WinMediaOperation -Category File -Operation 'BootFiles' -Target $Target -Config $Config -ScriptBlock {
        Copy-Item -LiteralPath $Source -Destination $Target -Force
    } | Out-Null
    return $true
}

function Copy-WinMediaUpdatedBootFiles {
    # 選項 UpdateBootFiles（對應 convert-UUP 的 UpdtBootFiles=1，3903–3930 行）
    # 來源是已套用 LCU 的安裝映像。回傳 $true 表示已使用 *_EX 開機檔；呼叫端據此跳過步驟 9 的 WinPE 開機管理員覆寫
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MountPath,
        [Parameter(Mandatory)][string]$MediaDir,
        [Parameter(Mandatory)][hashtable]$Config
    )

    $bootDir = Join-Path -Path $MountPath -ChildPath 'Windows\Boot'
    $efiDir = Join-Path -Path $bootDir -ChildPath 'EFI'
    $mediaBoot = Join-Path -Path $MediaDir -ChildPath 'efi\microsoft\boot'

    # 無論是否有 EX 都複製（convert-UUP 3904–3910 行）
    # 目標資料夾必須已存在才複製（convert-UUP 3904–3905 行的 if exist 條件）
    $policyDir = Join-Path -Path $efiDir -ChildPath 'CIPolicies'
    $cipDir = Join-Path -Path $mediaBoot -ChildPath 'cipolicies'
    if ((Test-Path -LiteralPath $policyDir) -and (Test-Path -LiteralPath $cipDir)) {
        Invoke-WinMediaOperation -Category File -Operation 'BootFiles' -Target $cipDir -Config $Config -ScriptBlock {
            Copy-Item -Path (Join-Path -Path $policyDir -ChildPath '*') -Destination $cipDir -Recurse -Force
        } | Out-Null
    }
    if (Test-Path -LiteralPath $mediaBoot) {
        Copy-WinMediaBootFile -Source (Join-Path -Path $efiDir -ChildPath 'winsipolicy.p7b') -Target (Join-Path -Path $mediaBoot -ChildPath 'winsipolicy.p7b') -Config $Config | Out-Null
    }
    $dvdEfi = Join-Path -Path $bootDir -ChildPath 'DVD\EFI\en-US'
    Copy-WinMediaBootFile -Source (Join-Path -Path $dvdEfi -ChildPath 'efisys.bin') -Target (Join-Path -Path $mediaBoot -ChildPath 'efisys.bin') -Config $Config | Out-Null
    Copy-WinMediaBootFile -Source (Join-Path -Path $dvdEfi -ChildPath 'efisys_noprompt.bin') -Target (Join-Path -Path $mediaBoot -ChildPath 'efisys_noprompt.bin') -Config $Config | Out-Null
    foreach ($name in 'boot.stl', 'boot.pnd.stl', 'memtest.efi') {
        Copy-WinMediaBootFile -Source (Join-Path -Path $efiDir -ChildPath $name) -Target (Join-Path -Path $mediaBoot -ChildPath $name) -Config $Config | Out-Null
    }

    $exDir = Join-Path -Path $bootDir -ChildPath 'EFI_EX'
    $hasEx = @(Get-ChildItem -LiteralPath $exDir -Filter '*_EX.efi' -File -ErrorAction SilentlyContinue).Count -gt 0
    if (-not $hasEx) { return $false }

    # 有 EX 檔時才覆蓋（convert-UUP 3916–3922 行）；每個目標檔只來自 EX 版本
    # 只覆蓋媒體上已存在的 UEFI 開機檔（x64 為 bootx64、ARM64 為 bootaa64），不建立不該有的檔案
    foreach ($name in 'bootx64.efi', 'bootaa64.efi', 'bootia32.efi', 'bootmgfw.efi') {
        $targetPath = Join-Path -Path $MediaDir -ChildPath ('efi\boot\{0}' -f $name)
        if (Test-Path -LiteralPath $targetPath -PathType Leaf) {
            Copy-WinMediaBootFile -Source (Join-Path -Path $exDir -ChildPath 'bootmgfw_EX.efi') -Target $targetPath -Config $Config | Out-Null
        }
    }
    $bootmgrSource = Join-Path -Path $exDir -ChildPath 'bootmgr_EX.efi'
    if (-not (Test-Path -LiteralPath $bootmgrSource)) { $bootmgrSource = Join-Path -Path $efiDir -ChildPath 'bootmgr.efi' }
    Copy-WinMediaBootFile -Source $bootmgrSource -Target (Join-Path -Path $MediaDir -ChildPath 'bootmgr.efi') -Config $Config | Out-Null
    # EX 版 efisys 位於 DVD_EX（convert-UUP 3919–3920 行）
    $dvdExEfi = Join-Path -Path $bootDir -ChildPath 'DVD_EX\EFI\en-US'
    Copy-WinMediaBootFile -Source (Join-Path -Path $dvdExEfi -ChildPath 'efisys_EX.bin') -Target (Join-Path -Path $mediaBoot -ChildPath 'efisys.bin') -Config $Config | Out-Null
    Copy-WinMediaBootFile -Source (Join-Path -Path $dvdExEfi -ChildPath 'efisys_noprompt_EX.bin') -Target (Join-Path -Path $mediaBoot -ChildPath 'efisys_noprompt.bin') -Config $Config | Out-Null

    # FONTS_EX 內 *_EX.ttf 去掉 _EX 後放入 fonts（convert-UUP 3921–3922 行）
    $fontsEx = Join-Path -Path $bootDir -ChildPath 'FONTS_EX'
    $fontsDir = Join-Path -Path $mediaBoot -ChildPath 'fonts'
    if (Test-Path -LiteralPath $fontsEx) {
        foreach ($font in @(Get-ChildItem -LiteralPath $fontsEx -File)) {
            $name = $font.Name -replace '_EX\.ttf$', '.ttf'
            Copy-WinMediaBootFile -Source $font.FullName -Target (Join-Path -Path $fontsDir -ChildPath $name) -Config $Config | Out-Null
        }
    }
    return $true
}

function Get-WinMediaWimHeader {
    # 以 wimlib info --header 讀取壓縮類型、可開機索引與映像數；壓縮類型由 Flags 的文字列判斷
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WimPath,
        [Parameter(Mandatory)][hashtable]$Config
    )

    $result = Invoke-WinMediaWimlib -ArgumentList @('info', $WimPath, '--header') -Config $Config
    $text = [string]$result.StdOut
    if ($text -match 'COMPRESS_LZMS is set') { $compression = 'LZMS' }
    elseif ($text -match 'COMPRESS_LZX is set') { $compression = 'LZX' }
    elseif ($text -match 'COMPRESS_XPRESS is set') { $compression = 'XPRESS' }
    elseif ($text -match 'WIM_HDR_FLAG_COMPRESSION is set') { throw "無法判斷 $WimPath 的壓縮類型。" }
    else { $compression = 'none' }
    if ($text -notmatch 'Boot Index\s*=\s*(\d+)') { throw "無法讀取 $WimPath 的 Boot Index。" }
    $bootIndex = [int]$Matches[1]
    if ($text -notmatch 'Image Count\s*=\s*(\d+)') { throw "無法讀取 $WimPath 的 Image Count。" }
    return [pscustomobject]@{ Compression = $compression; BootIndex = $bootIndex; ImageCount = [int]$Matches[1] }
}

function Compress-WinMediaBootWim {
    # 步驟 9 之後：export 全部索引（--boot 保留可開機索引、沿用原壓縮類型）再 optimize，取代原檔
    # 對應 convert-UUP 的 wimlib export／optimize（約 1047 與 1162 行）；暫存檔放在 WorkDir，不留在 sources 內
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BootWim,
        [Parameter(Mandatory)][hashtable]$Config
    )

    $before = Get-WinMediaWimHeader -WimPath $BootWim -Config $Config
    $tmp = Join-Path -Path $Config.WorkDir -ChildPath 'boot-optimized.wim'
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    $compressArg = if ($before.Compression -eq 'none') { '--compress=none' } else { '--compress={0}' -f $before.Compression }
    Invoke-WinMediaOperation -Category File -Operation 'OptimizeBootWim' -Target $BootWim -Config $Config -ScriptBlock {
        Invoke-WinMediaWimlib -ArgumentList @('export', $BootWim, 'all', $tmp, '--boot', $compressArg) -Config $Config | Out-Null
        Invoke-WinMediaWimlib -ArgumentList @('optimize', $tmp) -Config $Config | Out-Null
    } | Out-Null

    $after = Get-WinMediaWimHeader -WimPath $tmp -Config $Config
    if ($after.BootIndex -ne $before.BootIndex -or $after.ImageCount -ne $before.ImageCount) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw "boot.wim 最佳化後索引不一致：可開機索引 $($before.BootIndex)→$($after.BootIndex)，映像數 $($before.ImageCount)→$($after.ImageCount)。"
    }
    Move-Item -LiteralPath $tmp -Destination $BootWim -Force
}

function Copy-WinMediaSetupDuFiles {
    # 對應 convert-UUP 2349–2358 行：根目錄檔案 xcopy /U，只覆蓋媒體上既有的檔；*.ini 不限既有檔
    # 不套用 /D（比較時間戳）：實測 SetupPlatform 輸入為 9443、DU 為 9685，但 DU 的時間（09-10）早於輸入（09-13），參考採用的是 DU 版本
    # 語言子資料夾（名稱含 -）只在媒體已有該語言的 *.mui 時整個複製；replacementmanifests 遞迴複製；其餘子資料夾忽略
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ExpandedDir,
        [Parameter(Mandatory)][string]$SourcesDir,
        [Parameter(Mandatory)][hashtable]$Config
    )

    foreach ($file in @(Get-ChildItem -LiteralPath $ExpandedDir -File)) {
        $target = Join-Path -Path $SourcesDir -ChildPath $file.Name
        $exists = Test-Path -LiteralPath $target -PathType Leaf
        $copy = $exists -or ($file.Extension -eq '.ini')
        if ($copy) {
            Invoke-WinMediaOperation -Category File -Operation 'SetupDu' -Target $target -Config $Config -ScriptBlock {
                Copy-Item -LiteralPath $file.FullName -Destination $target -Force
            } | Out-Null
        }
    }

    foreach ($dir in @(Get-ChildItem -LiteralPath $ExpandedDir -Directory)) {
        $target = Join-Path -Path $SourcesDir -ChildPath $dir.Name
        if ($dir.Name -eq 'replacementmanifests') {
            [IO.Directory]::CreateDirectory($target) | Out-Null
            Invoke-WinMediaOperation -Category File -Operation 'SetupDu' -Target $target -Config $Config -ScriptBlock {
                Copy-Item -Path (Join-Path -Path $dir.FullName -ChildPath '*') -Destination $target -Recurse -Force
            } | Out-Null
        }
        elseif ($dir.Name -match '-' -and @(Get-ChildItem -LiteralPath $target -Filter '*.mui' -File -ErrorAction SilentlyContinue).Count -gt 0) {
            Invoke-WinMediaOperation -Category File -Operation 'SetupDu' -Target $target -Config $Config -ScriptBlock {
                Copy-Item -Path (Join-Path -Path $dir.FullName -ChildPath '*') -Destination $target -Force
            } | Out-Null
        }
    }
}

function Get-WinMediaListEntry {
    # 讀取清單檔：去除前後空白，忽略空行與 # 開頭的註解
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    Get-Content -LiteralPath $Path -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
}

function Copy-WinMediaBootWimSources {
    # 對應 convert-UUP bin\boot-wim.txt（約 1130–1145 行）：媒體 sources\ 內列在 bootwim.txt 的檔案覆蓋 WinPE 索引 2 的同名檔（媒體 → WinPE）
    # bootmui.txt 的語言 mui 依語言資料夾（小寫）處理；媒體沒有的檔案略過（convert-UUP 的 if exist）
    # 另加入媒體根目錄 setup.exe 與 sources\inf\setup.cfg（convert-UUP 同一份清單的 add 行）
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MediaDir,
        [Parameter(Mandatory)][string]$WimPath,
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][string]$WimListPath,
        [Parameter(Mandatory)][string]$MuiListPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Languages,
        [Parameter(Mandatory)][hashtable]$Config
    )

    # 不掛載 WinPE：實機 alert.gif 的 ACL 只給 Administrators 讀取（TrustedInstaller 擁有），Copy-Item 會被拒絕。
    # 改用 wimlib update（convert-UUP boot-wim.txt 的 add 行），與參考實作同一路徑；wimlib add 會覆寫既有檔案（已實驗確認）。
    $mediaSources = Join-Path -Path $MediaDir -ChildPath 'sources'
    $pairs = New-Object System.Collections.Generic.List[object]
    foreach ($name in @(Get-WinMediaListEntry -Path $WimListPath)) {
        $pairs.Add([pscustomobject]@{ Source = (Join-Path -Path $mediaSources -ChildPath $name); Dest = ('\sources\{0}' -f $name) })
    }
    foreach ($lang in $Languages) {
        $langDir = $lang.ToLowerInvariant()
        foreach ($name in @(Get-WinMediaListEntry -Path $MuiListPath)) {
            $pairs.Add([pscustomobject]@{ Source = (Join-Path -Path $mediaSources -ChildPath (Join-Path -Path $langDir -ChildPath $name)); Dest = ('\sources\{0}\{1}' -f $langDir, $name) })
        }
    }
    $pairs.Add([pscustomobject]@{ Source = (Join-Path -Path $MediaDir -ChildPath 'setup.exe'); Dest = '\setup.exe' })
    $pairs.Add([pscustomobject]@{ Source = (Join-Path -Path $mediaSources -ChildPath 'inf\setup.cfg'); Dest = '\sources\inf\setup.cfg' })

    Invoke-WinMediaBootWimAdd -WimPath $WimPath -Index $Index -Pairs $pairs.ToArray() -Config $Config
}

function Invoke-WinMediaBootWimAdd {
    # 對應 convert-UUP boot-wim.txt 的 add 行：來源不存在者略過；wimlib 的 update 只接受標準輸入的指令，寫入暫存檔後經 stdin 傳入
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WimPath,
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Pairs,
        [Parameter(Mandatory)][hashtable]$Config
    )

    $lines = @($Pairs | Where-Object { Test-Path -LiteralPath $_.Source -PathType Leaf } | ForEach-Object {
            "add '{0}' '{1}'" -f $_.Source, $_.Dest
        })
    if ($lines.Count -eq 0) { return }
    # --command 只能給一次（實機已確認），因此寫入暫存檔後經 stdin 傳入
    $commandFile = [System.IO.Path]::GetTempFileName()
    try {
        # shortcut: 指令檔以 ASCII 寫入，路徑含非 ASCII 字元（例如 WorkDir 位於中文目錄）時 wimlib 會找不到檔案並明確報錯；需要時改為無 BOM 的 UTF-8 並確認 wimlib 的 stdin 編碼
        Set-Content -LiteralPath $commandFile -Value $lines -Encoding ASCII
        Invoke-WinMediaOperation -Category File -Operation 'WinPESync' -Target ('{0} index {1}' -f $WimPath, $Index) -Config $Config -ScriptBlock {
            Invoke-WinMediaWimlib -ArgumentList @('update', $WimPath, [string]$Index) -Config $Config -StandardInputPath $commandFile
        } | Out-Null
    }
    finally {
        Remove-Item -LiteralPath $commandFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-WinMediaEffectiveLanguage {
    # 媒體偵測的語言（sources\<語言>\ 且含 .mui）與 Config.Languages 取聯集；不分大小寫去重，設定為空時只用偵測結果
    # 基礎語言優先取自 sources\lang.ini 的 [Available UI Languages]（consumer ISO 會夾帶其他語言的 mui，不能全取）；沒有 lang.ini 時才退回含 mui 的語言資料夾
    # shortcut: lang.ini 缺少 [Available UI Languages] 時會退回全部含 mui 的資料夾；多語言 ISO 的 lang.ini 格式若不同需再確認
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MediaDir,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Languages
    )

    $sources = Join-Path -Path $MediaDir -ChildPath 'sources'
    $withMui = @()
    if (Test-Path -LiteralPath $sources -PathType Container) {
        $withMui = @(Get-ChildItem -LiteralPath $sources -Directory | Where-Object {
                $_.Name -match '^[a-zA-Z]{2,3}-[a-zA-Z0-9-]+$' -and (Get-ChildItem -LiteralPath $_.FullName -Filter '*.mui' -File | Select-Object -First 1)
            } | ForEach-Object { $_.Name })
    }

    $detected = $withMui
    $langIni = Join-Path -Path $sources -ChildPath 'lang.ini'
    if (Test-Path -LiteralPath $langIni -PathType Leaf) {
        $inSection = $false
        $available = @()
        foreach ($line in (Get-Content -LiteralPath $langIni)) {
            $text = $line.Trim()
            if ($text -match '^\[') { $inSection = ($text -eq '[Available UI Languages]'); continue }
            if ($inSection -and $text -match '^([^=\s]+)\s*=') { $available += $Matches[1] }
        }
        if ($available.Count -gt 0) {
            $detected = @($withMui | Where-Object { $available -contains $_.ToLowerInvariant() })
        }
    }
    return ,@(@($detected) + @($Languages) | Where-Object { $_ } | Sort-Object -Unique)
}

function Remove-WinMediaExtraLanguage {
    # 媒體複製後移除不在保留集合（Get-WinMediaEffectiveLanguage）內的語言資料夾，使媒體與 WinPE 的語言一致；只刪含 .mui 的語言資料夾
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MediaDir,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Languages,
        [Parameter(Mandatory)]$Config
    )

    $sources = Join-Path -Path $MediaDir -ChildPath 'sources'
    if (-not (Test-Path -LiteralPath $sources -PathType Container)) { return }
    $keep = Get-WinMediaEffectiveLanguage -MediaDir $MediaDir -Languages $Languages
    # 保留集合為空時無從判斷哪些是額外語言，寧可不刪（lang.ini 列的語言都沒有資料夾、且 Languages 也為空）
    if (@($keep).Count -eq 0) { return }
    $extra = @(Get-ChildItem -LiteralPath $sources -Directory | Where-Object {
            $_.Name -match '^[a-zA-Z]{2,3}-[a-zA-Z0-9-]+$' -and $keep -notcontains $_.Name -and (Get-ChildItem -LiteralPath $_.FullName -Filter '*.mui' -File | Select-Object -First 1)
        })
    foreach ($dir in $extra) {
        Invoke-WinMediaOperation -Category File -Operation 'PruneLanguage' -Target $dir.FullName -Config $Config -ScriptBlock {
            Remove-Item -LiteralPath $dir.FullName -Recurse -Force
        } | Out-Null
    }
}

function Get-WinMediaBootBackground {
    # convert-UUP set_bkimg（1171–1176 行）：依序取第一個存在於 sources\ 的背景圖；沒有則回傳 $null
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SourcesDir)

    foreach ($name in 'background_cli.bmp', 'background_svr.bmp', 'background_cli.png', 'background_svr.png', 'winpe.jpg') {
        if (Test-Path -LiteralPath (Join-Path -Path $SourcesDir -ChildPath $name) -PathType Leaf) { return $name }
    }
    return $null
}

function Get-WinMediaBootSoftwareCommand {
    # convert-UUP 1104–1116、1151–1154 行的 WinPE 登錄值；$Hive 為已載入的根鍵。每列為 @(動作, 鍵, 值名稱, 型別, 資料)，刪除列只有前三項
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet(1, 2)][int]$Index,
        [Parameter(Mandatory)][string]$Hive
    )

    $version = "$Hive\Microsoft\Windows NT\CurrentVersion"
    $winpe = "$version\WinPE"
    $rows = New-Object System.Collections.Generic.List[object]
    if ($Index -eq 1) {
        $rows.Add(@('add', $version, 'SystemRoot', 'REG_SZ', 'X:\$windows.~bt\Windows'))
        $rows.Add(@('add', $winpe, 'InstRoot', 'REG_SZ', 'X:\$windows.~bt\'))
        $rows.Add(@('add', $winpe, 'CustomBackground', 'REG_EXPAND_SZ', '%SystemRoot%\System32\winre.jpg'))
    }
    else {
        $rows.Add(@('add', $winpe, 'CustomBackground', 'REG_EXPAND_SZ', '%SystemRoot%\System32\setup.bmp'))
    }
    $rows.Add(@('delete', $winpe, 'CustomShell'))
    return $rows.ToArray()
}

function Set-WinMediaBootSoftware {
    # 從 WinPE 索引取出 SOFTWARE，以 reg.exe 載入暫存根鍵後套用 Get-WinMediaBootSoftwareCommand，卸載後回傳暫存 hive 路徑（convert-UUP 以 offlinereg 處理同一組值）
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = '只寫入掛載中映像或本次工作目錄的暫存檔與暫存登錄根鍵，不變更系統狀態；寫入動作由 Invoke-WinMediaOperation 或 Invoke-WinMediaWimlib 負責記錄')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WimPath,
        [Parameter(Mandatory)][ValidateSet(1, 2)][int]$Index,
        [Parameter(Mandatory)][hashtable]$Config
    )

    $dir = Join-Path -Path $Config.WorkDir -ChildPath ('boot-software-{0}' -f $Index)
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Invoke-WinMediaWimlib -ArgumentList @('extract', $WimPath, [string]$Index, '\Windows\System32\config\SOFTWARE', ('--dest-dir={0}' -f $dir), '--no-acls', '--no-attributes') -Config $Config | Out-Null
    $hive = Join-Path -Path $dir -ChildPath 'SOFTWARE'
    $root = 'HKLM\WinMediaBootSW'
    $load = Invoke-WinMediaExternal -FilePath 'reg.exe' -ArgumentList @('load', $root, $hive) -Config $Config
    if ($load.ExitCode -ne 0) { throw "載入 SOFTWARE 失敗：$($load.StdErr)" }
    try {
        foreach ($row in Get-WinMediaBootSoftwareCommand -Index $Index -Hive $root) {
            if ($row[0] -eq 'add') {
                $result = Invoke-WinMediaExternal -FilePath 'reg.exe' -ArgumentList @('add', $row[1], '/v', $row[2], '/t', $row[3], '/d', $row[4], '/f') -Config $Config
                if ($result.ExitCode -ne 0) { throw "寫入 $($row[2]) 失敗：$($result.StdErr)" }
            }
            else {
                # 值不存在時 reg delete 會失敗；convert-UUP 同樣忽略
                Invoke-WinMediaExternal -FilePath 'reg.exe' -ArgumentList @('delete', $row[1], '/v', $row[2], '/f') -Config $Config | Out-Null
            }
        }
    }
    finally {
        Invoke-WinMediaExternal -FilePath 'reg.exe' -ArgumentList @('unload', $root) -Config $Config | Out-Null
    }
    return $hive
}

function New-WinMediaBootWimFromWinRE {
    # 以 WinRE 重建 boot.wim（convert-UUP BakISO 742–745 行、1104–1160 行）
    # 索引 1 = WinRE，名稱 PE、FLAGS=9；索引 2 = 索引 1 以 --boot 匯出，名稱 Setup、FLAGS=2。兩索引各自刪除 winpeshl.ini、寫入 SOFTWARE 與背景圖
    # SSU／LCU／驅動與 boot-wim.txt 清單不在此處理，分別由呼叫端的步驟 9 與其後的同步處理（LCU 之後才寫入，避免被覆蓋）
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = '只寫入掛載中映像或本次工作目錄的暫存檔與暫存登錄根鍵，不變更系統狀態；寫入動作由 Invoke-WinMediaOperation 或 Invoke-WinMediaWimlib 負責記錄')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WinreWim,
        [Parameter(Mandatory)][string]$BootWim,
        [Parameter(Mandatory)][string]$MediaDir,
        [Parameter(Mandatory)][string]$ArchName,
        [Parameter(Mandatory)][hashtable]$Config
    )

    $sourcesDir = Join-Path -Path $MediaDir -ChildPath 'sources'
    $bkName = Get-WinMediaBootBackground -SourcesDir $sourcesDir
    $bk = if ($bkName) { Join-Path -Path $sourcesDir -ChildPath $bkName } else { $null }
    $peName = 'Microsoft Windows PE ({0})' -f $ArchName
    $setupName = 'Microsoft Windows Setup ({0})' -f $ArchName

    Invoke-WinMediaOperation -Category File -Operation 'BootWimFromWinRE' -Target $BootWim -Config $Config -ScriptBlock {
        Copy-Item -LiteralPath $WinreWim -Destination $BootWim -Force
    } | Out-Null
    Invoke-WinMediaWimlib -ArgumentList @('info', $BootWim, '1', $peName, $peName, '--image-property', 'FLAGS=9') -Config $Config | Out-Null
    # WinRE 內含 winpeshl.ini，留著會開機進入復原殼層而非 Setup（convert-UUP 742–745 與 1121–1123 行皆刪除）
    Invoke-WinMediaWimlib -ArgumentList @('update', $BootWim, '1', "--command=delete '\Windows\system32\winpeshl.ini'") -Config $Config | Out-Null

    $software1 = Set-WinMediaBootSoftware -WimPath $BootWim -Index 1 -Config $Config
    $index1Pairs = @([pscustomobject]@{ Source = $software1; Dest = '\Windows\System32\config\SOFTWARE' })
    if ($bk -and -not (Test-Path -LiteralPath (Join-Path -Path $sourcesDir -ChildPath 'winre.jpg'))) {
        $index1Pairs += [pscustomobject]@{ Source = $bk; Dest = '\Windows\system32\winre.jpg' }
    }
    Invoke-WinMediaBootWimAdd -WimPath $BootWim -Index 1 -Pairs $index1Pairs -Config $Config

    Invoke-WinMediaWimlib -ArgumentList @('export', $WinreWim, '1', $BootWim, $setupName, $setupName, '--boot') -Config $Config | Out-Null
    Invoke-WinMediaWimlib -ArgumentList @('info', $BootWim, '2', '--image-property', 'FLAGS=2') -Config $Config | Out-Null
    Invoke-WinMediaWimlib -ArgumentList @('update', $BootWim, '2', "--command=delete '\Windows\system32\winpeshl.ini'") -Config $Config | Out-Null

    $software2 = Set-WinMediaBootSoftware -WimPath $BootWim -Index 2 -Config $Config
    $index2Pairs = New-Object System.Collections.Generic.List[object]
    $index2Pairs.Add([pscustomobject]@{ Source = $software2; Dest = '\Windows\System32\config\SOFTWARE' })
    if ($bk) {
        $index2Pairs.Add([pscustomobject]@{ Source = $bk; Dest = '\sources\background.bmp' })
        $index2Pairs.Add([pscustomobject]@{ Source = $bk; Dest = '\Windows\system32\setup.bmp' })
        if (-not (Test-Path -LiteralPath (Join-Path -Path $sourcesDir -ChildPath 'winpe.jpg'))) { $index2Pairs.Add([pscustomobject]@{ Source = $bk; Dest = '\Windows\system32\winpe.jpg' }) }
        if (-not (Test-Path -LiteralPath (Join-Path -Path $sourcesDir -ChildPath 'winre.jpg'))) { $index2Pairs.Add([pscustomobject]@{ Source = $bk; Dest = '\Windows\system32\winre.jpg' }) }
    }
    Invoke-WinMediaBootWimAdd -WimPath $BootWim -Index 2 -Pairs $index2Pairs.ToArray() -Config $Config

    # convert-UUP 於索引 2 匯出之後才對索引 1 加入 winpe.jpg（1160 行附近）
    if ($bk) {
        Invoke-WinMediaBootWimAdd -WimPath $BootWim -Index 1 -Pairs @([pscustomobject]@{ Source = $bk; Dest = '\Windows\system32\winpe.jpg' }) -Config $Config
    }

    # SOFTWARE 暫存目錄（含 reg 的 LOG 檔）在此清除；WorkDir 不在第 12 步的清理清單內
    foreach ($i in 1, 2) {
        Remove-Item -LiteralPath (Join-Path -Path $Config.WorkDir -ChildPath ('boot-software-{0}' -f $i)) -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-WinMediaKernelConsistency {
    # 步驟 9 守衛：開機索引 ntoskrnl 須等於安裝映像，或等於已套用 SafeOS DU 的 WinRE（Microsoft「用最近版本」規則，不要求與 LCU 同版）；其餘情況中止
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$BootKernel,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$WinreKernel,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$InstallKernel,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$WinreBaseKernel,
        [Parameter(Mandatory)][int]$BootIndex
    )
    if ($BootKernel -eq $InstallKernel) { return }
    # WinRE 基準版（套 SSU／SafeOS 前讀取）與套用後不同，代表 SafeOS DU 真的生效；SSU 不改 ntoskrnl
    if ($BootKernel -eq $WinreKernel -and $WinreKernel -ne $WinreBaseKernel) { return }
    throw "boot.wim 索引 $BootIndex 的 ntoskrnl 版本 $BootKernel 不符合規則（WinRE $WinreKernel，WinRE 基準 $WinreBaseKernel，安裝映像 $InstallKernel）。"
}

Export-ModuleMember -Function Test-WinMediaKernelConsistency, Copy-WinMediaUpdatedBootFiles, Compress-WinMediaBootWim, Copy-WinMediaSetupDuFiles, Copy-WinMediaBootWimSources, Get-WinMediaEffectiveLanguage, Remove-WinMediaExtraLanguage, Invoke-WinMediaBootWimAdd, Get-WinMediaBootBackground, Get-WinMediaBootSoftwareCommand, Set-WinMediaBootSoftware, New-WinMediaBootWimFromWinRE
