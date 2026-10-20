#Requires -Version 5.1

BeforeAll {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\Modules\WinMediaUpdate.psm1') -Force
    $script:mainPath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Public\Invoke-WindowsMediaRefresh.ps1'
    $script:text = Get-Content -LiteralPath $script:mainPath -Raw
    $script:ast = [System.Management.Automation.Language.Parser]::ParseFile($script:mainPath, [ref]$null, [ref]$null)
    $script:cmds = @($script:ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
    $script:config = @{ LogLevel = 'Info'; OperationLog = ''; DebugTrace = 0; LogFile = (Join-Path -Path $TestDrive -ChildPath 'wiring.log'); PackageDir = (Join-Path -Path $TestDrive -ChildPath 'pkg'); Download = @{ Method = 'WebRequest' } }

    # 回傳第一個符合名稱、位於 $After 之後的指令起始位置；找不到回傳 -1
    function script:Get-CommandOffset {
        param([string]$Name, [int]$After = -1, [string]$TextLike = '*')
        $hit = $script:cmds | Where-Object { $_.GetCommandName() -eq $Name -and $_.Extent.StartOffset -gt $After -and $_.Extent.Text -like $TextLike } | Select-Object -First 1
        if ($hit) { return $hit.Extent.StartOffset }
        return -1
    }
}

Describe '主流程接線：Build 路徑' -Tag 'Unit' {
    It 'Build 分支先於 KB 分支，且 Save-WinMediaBuildSet 位於 Build 分支內' {
        $build = $script:text.IndexOf('if ($Config.Download.Build)')
        $kb = $script:text.IndexOf('elseif ($Config.Download.KB)')
        $build | Should -BeGreaterThan -1
        $kb | Should -BeGreaterThan $build
        $save = Get-CommandOffset -Name 'Save-WinMediaBuildSet'
        $save | Should -BeGreaterThan $build
        $save | Should -BeLessThan $kb
    }

    It '下載（Save-WinMediaBuildSet）先於分類（Get-WinMediaPackageCategory），新檔案才會被分類' {
        $save = Get-CommandOffset -Name 'Save-WinMediaBuildSet'
        $category = Get-CommandOffset -Name 'Get-WinMediaPackageCategory'
        $save | Should -BeGreaterThan -1
        $category | Should -BeGreaterThan $save
    }

    It 'Build 路徑採用 $buildSet 的 Target 與 Checkpoints，不對資料夾重新判定' {
        $script:text | Should -Match '\$buildSet\.Target'
        $script:text | Should -Match '\$buildSet\.Checkpoints'
    }

    It 'SSU 展開目錄與主流程比對使用同一命名（含副檔名的套件檔名）' {
        $packageText = Get-Content -LiteralPath (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Modules\WinMediaPackage.psm1') -Raw
        $packageText | Should -Match 'ChildPath \$package\.Name'
        $script:text | Should -Match '-like "\*\\\$escapedTarget\\\*"'
    }

    It 'Build 路徑只採用本次下載的 SafeOS、SetupDU、.NET、LCU（不沿用 PackageDir 殘留檔案）' {
        $script:text | Should -Match "foreach \(\`$key in 'SafeOS', 'SetupDU', 'DotNetCU', 'LCU', 'Checkpoint'\)"
        $script:text | Should -Match '\$setNames -contains'
        $script:text | Should -Match 'Build 路徑不回退至 PackageDir'
    }

    It 'CBS catch 判斷 HResult -2146498554 與訊息 0x800f0806' {
        $script:text | Should -Match 'HResult -ne -2146498554'
        $script:text | Should -Match '0x800f0806'
    }
}

Describe 'ISO 開機參數（依架構分流，與 convert-UUP 對齊）' -Tag 'Unit' {
    It 'ARM64 只使用 UEFI 開機項（-bootdata:1），不引用 etfsboot.com' {
        $script:text | Should -Match "-bootdata:1#pEF,e,b"
        $script:text | Should -Match "if \(\`$architecture -eq 'arm64'\)"
    }

    It 'x64 維持 BIOS＋UEFI 雙開機（-bootdata:2），並檢查兩個開機檔存在' {
        $script:text | Should -Match '-bootdata:2#p0,e,b'
        $script:text | Should -Match 'boot\\etfsboot\.com'
        $script:text | Should -Match 'efi\\microsoft\\boot\\efisys\.bin'
        $script:text | Should -Match '找不到 BIOS 開機檔'
        $script:text | Should -Match '找不到 UEFI 開機檔'
    }

    It '索引目標一律包成陣列（單一索引時 if 運算式會展開成純量，StrictMode 下 .Count 會中止）' {
        $script:text | Should -Match '\$targets = @\(if \(@\(\$Config\.Indexes\)\.Count -gt 0\)'
    }

    It 'WinPE 同步以媒體 sources 為來源、boot.wim 索引 2 為目標，以 wimlib 寫入（convert-UUP bootwim.txt 同向）' {
        $script:text | Should -Match 'Copy-WinMediaBootWimSources -MediaDir \$mediaDir -WimPath \$bootWim -Index 2'
    }

    It '掛載前自動建立掛載點目錄（DISM 不會建立；缺少時回報「系統找不到指定的檔案」）' {
        $imageText = Get-Content -LiteralPath (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'PSModules\Imaging\WinMediaImage.psm1') -Raw
        $imageText | Should -Match 'if \(\$createdMountDir\) \{ New-Item -ItemType Directory -Path \$MountPath'
    }

    It '清除唯讀屬性只套用於檔案（DirectoryInfo 沒有 IsReadOnly，StrictMode 下會中止）' {
        $script:text | Should -Match 'Get-ChildItem -LiteralPath \$mediaDir -Recurse -Force -File \| ForEach-Object \{ \$_\.IsReadOnly = \$false \}'
    }

    It 'oscdimg 參數包含 -o（去除重複檔案）' {
        $script:text | Should -Match "'-o', '-u2', '-udfver102'"
    }
}

Describe 'install.wim 步驟順序（§5.9，重排後）' -Tag 'Unit' {
    It 'SSU → 語言包 → LCU（$lcuStage）→ cleanup → NetFx3 → .NET CU → Appx 移除' {
        $lang = Get-CommandOffset -Name 'Install-WinMediaLangFod'
        $lang | Should -BeGreaterThan -1
        # install.wim 迴圈內的 SSU 為 $lang 之前最後一個 $ssu 的 Add（WinRE 區塊的同名呼叫位於更前面）
        $ssuNode = @($script:cmds | Where-Object { $_.GetCommandName() -eq 'Add-WindowsPackage' -and $_.Extent.Text -like '*$ssu*' -and $_.Extent.StartOffset -lt $lang }) | Select-Object -Last 1
        $ssuNode | Should -Not -BeNullOrEmpty
        $ssu = $ssuNode.Extent.StartOffset
        $ssu | Should -BeLessThan $lang
        $lcu = Get-CommandOffset -Name 'Add-WindowsPackage' -After $lang -TextLike '*$lcuStage*'
        $cleanup = Get-CommandOffset -Name 'Repair-WindowsImage' -After $lcu -TextLike '*StartComponentCleanup*'
        $deferred = Get-CommandOffset -Name 'Install-WinMediaDeferredFod' -After $cleanup
        $dotNet = Get-CommandOffset -Name 'Add-WindowsPackage' -After $deferred -TextLike '*$dotNet*'
        $appx = Get-CommandOffset -Name 'Remove-WinMediaAppx' -After $dotNet
        foreach ($offset in @($lcu, $cleanup, $deferred, $dotNet, $appx)) { $offset | Should -BeGreaterThan -1 }
        $lang | Should -BeLessThan $lcu
        $lcu | Should -BeLessThan $cleanup
        $cleanup | Should -BeLessThan $deferred
        $deferred | Should -BeLessThan $dotNet
        $dotNet | Should -BeLessThan $appx
    }
}

Describe 'Build 路徑信任邊界' -Tag 'Unit' {
    It '非 Microsoft 網域的網址在下載前中止（Save-WinMediaUpdateFile 真實執行）' {
        Mock -ModuleName WinMediaUpdate Get-WinMediaUupBuild { '89da9278-1ece-4c82-b791-d624d229924d' }
        Mock -ModuleName WinMediaUpdate Get-WinMediaUupEntry {
            @([pscustomobject]@{ Name = 'Windows11.0-KB5127648-x64.msu'; Sha1 = 'bb'; Url = 'https://evil.example.com/b.msu' })
        }
        Mock -ModuleName WinMediaUpdate Write-WinMediaLog { }
        Mock -ModuleName WinMediaUpdate Find-WinMediaLearnKb { $null }
        Mock -ModuleName WinMediaUpdate Invoke-WebRequest { throw '不應發出網路要求' }
        { Save-WinMediaBuildSet -Build '26100.9711' -Architecture amd64 -Config $script:config } | Should -Throw '*網域*'
        Should -Invoke -CommandName Invoke-WebRequest -ModuleName WinMediaUpdate -Times 0 -Exactly
    }
}
