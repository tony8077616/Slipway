#Requires -Version 5.1

BeforeAll {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\Modules\WinMediaUpdate.psm1') -Force
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\Modules\WinMediaLangFod.psm1') -Force
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\Modules\WinMediaIndexInfo.psm1') -Force
    $script:config = @{ LogLevel = 'Info'; OperationLog = ''; DebugTrace = 0; LogFile = (Join-Path -Path $TestDrive -ChildPath 'cumulative.log'); PackageDir = (Join-Path -Path $TestDrive -ChildPath 'pkg'); DismProvider = 'Inbox'; DismLogLevel = 'WarningsInfo'; Download = @{ Method = 'WebRequest' } }

    # Learn 發行資訊頁的一列（24H2 通道、最新 build 26100.9711、KB 連結 help/5127648）
    $script:learnHtml = @"
<table><tbody>
<tr class="highlight">
<td>24H2</td>
<td align="left">General Availability Channel</td>
<td nowrap="">2024-10-01</td>
<td nowrap="">End of updates</td>
<td nowrap="">2027-10-12</td>
<td nowrap=""><a href="https://support.microsoft.com/help/5127648" target="_blank" data-linktype="external">2026-10 B</a></td>
<td nowrap="">2026-10-13</td>
<td nowrap="">26100.9711</td>
</tr>
</tbody></table>
"@
}

Describe 'Catalog 標題過濾（Find-WinMediaCatalogUpdate）' -Tag 'Unit' {
    It '接受舊標題（Version）與新標題（, version），排除 25H2、26H2 與 arm64' {
        $rows = @(
            [pscustomobject]@{ Guid = '11111111-1111-1111-1111-111111111111'; Title = '2026-10 Cumulative Update for Windows 11, version 24H2 for x64-based Systems (KB5127648) (26100.9711)' }
            [pscustomobject]@{ Guid = '22222222-2222-2222-2222-222222222222'; Title = '2024-10 Cumulative Update for Windows 11 Version 24H2 for x64-based Systems (KB5127648)' }
            [pscustomobject]@{ Guid = '33333333-3333-3333-3333-333333333333'; Title = '2026-10 Cumulative Update for Windows 11, version 25H2 for x64-based Systems (KB5127648) (26200.9711)' }
            [pscustomobject]@{ Guid = '44444444-4444-4444-4444-444444444444'; Title = '2026-10 Cumulative Update for Windows 11, version 26H2 for x64-based Systems (KB5127648) (26300.9711)' }
            [pscustomobject]@{ Guid = '55555555-5555-5555-5555-555555555555'; Title = '2026-10 Cumulative Update for Windows 11, version 24H2 for arm64-based Systems (KB5127648) (26100.9711)' }
        )
        InModuleScope WinMediaUpdate -Parameters @{ Rows = $rows } {
            param($Rows)
            $script:rowsFixture = $Rows
            Mock Invoke-WebRequest { [pscustomobject]@{ Content = '<html></html>' } }
            Mock ConvertFrom-WinMediaCatalogSearch { $script:rowsFixture }
            $hits = @(Find-WinMediaCatalogUpdate -KB 'KB5127648' -Architecture amd64)
            $hits.Count | Should -Be 2
            @($hits.Guid) | Should -Contain '11111111-1111-1111-1111-111111111111'
            @($hits.Guid) | Should -Contain '22222222-2222-2222-2222-222222222222'
        }
    }
}

Describe 'UUP 用戶端條目選擇（Get-WinMediaUupBuild）' -Tag 'Unit' {
    It '同一 build 號時選用戶端 "Windows 11, version" 條目，不選 Server' {
        InModuleScope WinMediaUpdate {
            Mock Invoke-RestMethod { 'unused' }
            Mock Get-WinMediaUupResponse {
                [pscustomobject]@{ builds = [pscustomobject]@{
                    s = [pscustomobject]@{ build = '26100.9711'; arch = 'amd64'; title = 'Windows Server 2025 (26100.9711)'; uuid = '649e1310-db2e-48d3-a5b4-7a6709653c94' }
                    c = [pscustomobject]@{ build = '26100.9711'; arch = 'amd64'; title = 'Windows 11, version 24H2 (26100.9711)'; uuid = 'ac94e557-eb76-4c8b-a064-0c72d6d3e09c' }
                } }
            }
            Get-WinMediaUupBuild -Build '26100.9711' -Architecture amd64 | Should -Be 'ac94e557-eb76-4c8b-a064-0c72d6d3e09c'
        }
    }
}

Describe 'Learn 交叉檢查（Find-WinMediaLearnKb）' -Tag 'Unit' {
    It '從該 build 的列取出 KB（help 連結）' {
        InModuleScope WinMediaUpdate -Parameters @{ Html = $script:learnHtml } {
            param($Html)
            $script:learnFixture = $Html
            Mock Invoke-WebRequest { [pscustomobject]@{ Content = $script:learnFixture } }
            Find-WinMediaLearnKb -Build '26100.9711' | Should -Be 'KB5127648'
        }
    }

    It 'Learn 未列出的 build 回傳 $null（不是錯誤）' {
        InModuleScope WinMediaUpdate -Parameters @{ Html = $script:learnHtml } {
            param($Html)
            $script:learnFixture = $Html
            Mock Invoke-WebRequest { [pscustomobject]@{ Content = $script:learnFixture } }
            Find-WinMediaLearnKb -Build '26100.1882' | Should -BeNullOrEmpty
        }
    }

    It 'build 只是前綴相同（26100.971 對 26100.9711）時回傳 $null' {
        InModuleScope WinMediaUpdate -Parameters @{ Html = $script:learnHtml } {
            param($Html)
            $script:learnFixture = $Html
            Mock Invoke-WebRequest { [pscustomobject]@{ Content = $script:learnFixture } }
            Find-WinMediaLearnKb -Build '26100.971' | Should -BeNullOrEmpty
        }
    }
}

Describe '累積更新集合（Resolve-WinMediaCumulativeSet）' -Tag 'Unit' {
    It 'KB 最大者為目標，較小者為 checkpoint，非 .msu 忽略' {
        $set = Resolve-WinMediaCumulativeSet -Paths @('C:\x\Windows11.0-KB5127648-x64.msu', 'C:\x\Windows11.0-KB5043080-x64.msu', 'C:\x\readme.txt') -Config $script:config
        $set.Target | Should -BeLike '*KB5127648*'
        @($set.Checkpoints).Count | Should -Be 1
        @($set.Checkpoints)[0] | Should -BeLike '*KB5043080*'
    }

    It '只有一個累積更新時沒有 checkpoint' {
        $set = Resolve-WinMediaCumulativeSet -Paths @('C:\x\custom.msu') -Config $script:config
        $set.Target | Should -Be 'C:\x\custom.msu'
        @($set.Checkpoints).Count | Should -Be 0
    }

    It '多個累積更新但檔名缺 KB 時中止（不猜測順序）' {
        { Resolve-WinMediaCumulativeSet -Paths @('C:\x\a.msu', 'C:\x\b.msu') -Config $script:config } | Should -Throw '*checkpoint*'
    }
}

Describe '暫存資料夾（New-WinMediaUpdateStage）' -Tag 'Unit' {
    It '只放入目標與 checkpoint，並清除先前內容' {
        $stage = Join-Path -Path $TestDrive -ChildPath 'update-stage'
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path -Path $stage -ChildPath 'old.msu') -Force | Out-Null
        $src = Join-Path -Path $TestDrive -ChildPath 'src'
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        $target = Join-Path -Path $src -ChildPath 'Windows11.0-KB5127648-x64.msu'
        $cp = Join-Path -Path $src -ChildPath 'Windows11.0-KB5043080-x64.msu'
        'a' | Set-Content -LiteralPath $target
        'b' | Set-Content -LiteralPath $cp
        $result = New-WinMediaUpdateStage -Target $target -Checkpoints @($cp) -StageDir $stage -Config $script:config
        (Get-ChildItem -LiteralPath $stage -File).Name | Sort-Object | Should -Be @('Windows11.0-KB5043080-x64.msu', 'Windows11.0-KB5127648-x64.msu')
        $result | Should -Be (Join-Path -Path $stage -ChildPath 'Windows11.0-KB5127648-x64.msu')
    }
}

Describe '依 build 整組下載（Save-WinMediaBuildSet）' -Tag 'Unit' {
    BeforeEach {
        Mock -ModuleName WinMediaUpdate Get-WinMediaUupBuild { '89da9278-1ece-4c82-b791-d624d229924d' }
        Mock -ModuleName WinMediaUpdate Get-WinMediaUupEntry {
            @(
                [pscustomobject]@{ Name = 'Windows11.0-KB5043080-x64.msu'; Sha1 = 'aa'; Url = 'https://catalog.sf.dl.delivery.mp.microsoft.com/a.msu' }
                [pscustomobject]@{ Name = 'Windows11.0-KB5127648-x64.msu'; Sha1 = 'bb'; Url = 'https://catalog.sf.dl.delivery.mp.microsoft.com/b.msu' }
                [pscustomobject]@{ Name = 'Windows11.0-KB5127650-x64.cab'; Sha1 = 'cc'; Url = 'https://catalog.sf.dl.delivery.mp.microsoft.com/c.cab' }
                [pscustomobject]@{ Name = 'Windows11.0-KB5127648-arm64.msu'; Sha1 = 'dd'; Url = 'https://catalog.sf.dl.delivery.mp.microsoft.com/d.msu' }
                [pscustomobject]@{ Name = 'Microsoft-Windows-Client-LanguagePack-ja-jp.cab'; Sha1 = 'ee'; Url = 'https://catalog.sf.dl.delivery.mp.microsoft.com/e.cab' }
            )
        }
        Mock -ModuleName WinMediaUpdate Save-WinMediaUpdateFile { param($FileName, $Destination) Join-Path -Path $Destination -ChildPath $FileName }
        Mock -ModuleName WinMediaUpdate Write-WinMediaLog { }
    }

    It '只下載 x64 的 KB 檔案（排除 arm64、語言包），目標為最大 KB 的 .msu，較小者為 checkpoint' {
        Mock -ModuleName WinMediaUpdate Find-WinMediaLearnKb { 'KB5127648' }
        $set = Save-WinMediaBuildSet -Build '26100.9711' -Architecture amd64 -Config $script:config
        $set.TargetKb | Should -Be 'KB5127648'
        $set.Target | Should -BeLike '*Windows11.0-KB5127648-x64.msu'
        @($set.Checkpoints).Count | Should -Be 1
        @($set.Checkpoints)[0] | Should -BeLike '*KB5043080*'
        @($set.Files).Count | Should -Be 3
        Should -Invoke -CommandName Save-WinMediaUpdateFile -ModuleName WinMediaUpdate -Times 3 -Exactly
    }

    It 'Learn 與 UUP 不一致時只警告，不中止' {
        Mock -ModuleName WinMediaUpdate Find-WinMediaLearnKb { 'KB9999999' }
        { Save-WinMediaBuildSet -Build '26100.9711' -Architecture amd64 -Config $script:config } | Should -Not -Throw
        Should -Invoke -CommandName Write-WinMediaLog -ModuleName WinMediaUpdate -ParameterFilter { $Level -eq 'Warning' -and $Message -match '不一致' } -Times 1 -Exactly
    }

    It 'Learn 尚未列出該 build 時只記 Info，不產生警告' {
        Mock -ModuleName WinMediaUpdate Find-WinMediaLearnKb { $null }
        Save-WinMediaBuildSet -Build '26100.9711' -Architecture amd64 -Config $script:config | Out-Null
        Should -Invoke -CommandName Write-WinMediaLog -ModuleName WinMediaUpdate -ParameterFilter { $Level -eq 'Warning' } -Times 0 -Exactly
        Should -Invoke -CommandName Write-WinMediaLog -ModuleName WinMediaUpdate -ParameterFilter { $Level -eq 'Info' -and $Message -match '尚未列出' } -Times 1 -Exactly
    }

    It 'UUP 已不提供此 build（EMPTY_FILELIST）時給出明確錯誤並建議改用 Download.KB' {
        Mock -ModuleName WinMediaUpdate Get-WinMediaUupEntry { throw 'UUP 檔案清單為空：EMPTY_FILELIST' }
        { Save-WinMediaBuildSet -Build '26100.1882' -Architecture amd64 -Config $script:config } | Should -Throw '*Download.KB*'
    }
}

Describe 'NetFx3 延後注入（Install-WinMediaDeferredFod）' -Tag 'Unit' {
    It 'Deferred 清單中的套件由 Add-WindowsPackage 注入' {
        Mock -ModuleName WinMediaLangFod Invoke-WinMediaDism { param($Provider, $Config, [scriptblock]$ScriptBlock) $null = $Provider, $Config; & $ScriptBlock }
        Mock -ModuleName WinMediaLangFod Add-WindowsPackage { }
        $set = [pscustomobject]@{ LangPacks = @(); Fod = @('C:\f\other.cab'); Deferred = @('C:\f\NetFx3.cab') }
        Install-WinMediaDeferredFod -MountPath 'C:\mnt' -Set $set -Config $script:config
        Should -Invoke -CommandName Add-WindowsPackage -ModuleName WinMediaLangFod -Times 1 -Exactly -ParameterFilter { $PackagePath -like '*NetFx3*' }
        Should -Invoke -CommandName Add-WindowsPackage -ModuleName WinMediaLangFod -Times 0 -Exactly -ParameterFilter { $PackagePath -like '*other*' }
    }
}

Describe 'Get-WinMediaIndexInfo（逐索引補查欄位）' -Tag 'Unit' {
    BeforeEach {
        # Invoke-WinMediaDism 改為實際執行 ScriptBlock，讓 Get-WindowsImage 的兩種呼叫都能被區分
        Mock -ModuleName WinMediaIndexInfo Invoke-WinMediaDism { param($Provider, $Config, [scriptblock]$ScriptBlock) $null = $Provider, $Config; & $ScriptBlock }
        Mock -ModuleName WinMediaIndexInfo Get-WindowsImage {
            [pscustomobject]@{ ImageIndex = 1; ImageName = 'Windows 11 Pro' }
        } -ParameterFilter { $null -eq $Index }
        Mock -ModuleName WinMediaIndexInfo Get-WindowsImage {
            [pscustomobject]@{ ImageIndex = 1; ImageName = 'Windows 11 Pro'; Architecture = 9; Build = 26100; EditionId = 'Professional' }
        } -ParameterFilter { $Index -eq 1 }
    }

    It 'Basic 物件缺欄位時逐索引補 Build、EditionId、Architecture' {
        $info = @(Get-WinMediaIndexInfo -ImagePath 'C:\x\install.wim' -Config $script:config)
        $info[0].Build | Should -Be 26100
        $info[0].EditionId | Should -Be 'Professional'
        $info[0].Architecture | Should -Be 'amd64'
    }

    It '架構代碼 12 對應 arm64' {
        Mock -ModuleName WinMediaIndexInfo Get-WindowsImage { [pscustomobject]@{ ImageIndex = 1; ImageName = 'x'; Architecture = 12; Build = 26100; EditionId = 'Professional' } } -ParameterFilter { $Index -eq 1 }
        (Get-WinMediaIndexInfo -ImagePath 'C:\x\install.wim' -Config $script:config)[0].Architecture | Should -Be 'arm64'
    }

    It '不支援的架構代碼中止' {
        Mock -ModuleName WinMediaIndexInfo Get-WindowsImage { [pscustomobject]@{ ImageIndex = 1; ImageName = 'x'; Architecture = 5; Build = 26100; EditionId = 'Professional' } } -ParameterFilter { $Index -eq 1 }
        { Get-WinMediaIndexInfo -ImagePath 'C:\x\install.wim' -Config $script:config } | Should -Throw '*不支援的映像架構代碼*'
    }
}
