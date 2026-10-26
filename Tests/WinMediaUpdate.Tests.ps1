#Requires -Version 5.1

BeforeAll {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\Modules\WinMediaUpdate.psm1') -Force

    $script:catalogHtml = @"
<a id='a62b9737-1fe8-4df1-94b4-8ec61855a8d0_link' href='#'>
  2024-10 Cumulative Update for Windows 11 Version 24H2 for x64-based Systems (KB5044284)</a>
<a id='e25b84b6-b296-4bca-a2f1-91e179dc4acc_link' href='#'>2024-10 Cumulative Update for Windows 11 Version 24H2 for arm64-based Systems (KB5044284)</a>
<a id='11111111-2222-3333-4444-555555555555_link' href='#'>2024-10 Cumulative Update for Windows 11 Version 24H2 for x64-based Systems (KB9999999)</a>
"@

    $script:dialogHtml = @"
<script>
url = 'https://catalog.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/x/public/windows11.0-kb5044284-x64_d7eb7ceaa4798b92b988fd7dcc7c6bb39476ccf3.msu';
url = 'https://catalog.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/x/public/windows11.0-kb5044284-x64_d7eb7ceaa4798b92b988fd7dcc7c6bb39476ccf3.msu';
url = 'https://evil.example.com/windows11.0-kb1-x64_0000000000000000000000000000000000000000.msu';
url = 'https://catalog.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/x/public/readme.txt';
</script>
"@
}

Describe 'Catalog 解析（§2.1）' -Tag 'Unit' {
    It '搜尋結果只取 GUID 錨點並解碼標題' {
        $rows = @(InModuleScope WinMediaUpdate -Parameters @{ Html = $script:catalogHtml } {
            param($Html) ConvertFrom-WinMediaCatalogSearch -Html $Html
        })
        $rows.Count | Should -Be 3
        $rows[0].Guid | Should -Be 'a62b9737-1fe8-4df1-94b4-8ec61855a8d0'
        $rows[0].Title | Should -Match 'x64-based Systems \(KB5044284\)$'
    }

    It '對話框回應只保留 Microsoft 網域、副檔名白名單與去重後的網址，並取出 SHA-1' {
        $files = @(InModuleScope WinMediaUpdate -Parameters @{ Html = $script:dialogHtml } {
            param($Html) ConvertFrom-WinMediaCatalogDialog -Html $Html
        })
        $files.Count | Should -Be 1
        $files[0].FileName | Should -Be 'windows11.0-kb5044284-x64_d7eb7ceaa4798b92b988fd7dcc7c6bb39476ccf3.msu'
        $files[0].Sha1 | Should -Be 'd7eb7ceaa4798b92b988fd7dcc7c6bb39476ccf3'
    }

    It '不符合 KB 格式時中止' {
        { Save-WinMediaUpdate -KB 'KB5044284; drop' -Config @{ PackageDir = 'C:\x' } } | Should -Throw '*格式錯誤*'
    }

    It 'GUID 格式不正確時拒絕（避免拼入請求）' {
        { InModuleScope WinMediaUpdate { Get-WinMediaCatalogFile -Guid 'bad; drop' } } | Should -Throw
    }

    It 'Find 只保留 KB 與 x64 相符且為 24H2 的項目' {
        $items = @(InModuleScope WinMediaUpdate -Parameters @{ Html = $script:catalogHtml } {
            param($Html)
            $script:fixture = $Html
            Mock Invoke-WebRequest { [pscustomobject]@{ Content = $script:fixture } }
            Find-WinMediaCatalogUpdate -KB 'KB5044284' -Architecture amd64
        })
        $items.Count | Should -Be 1
        $items[0].Guid | Should -Be 'a62b9737-1fe8-4df1-94b4-8ec61855a8d0'
    }
}

Describe 'UUP build 選擇與 Catalog 網址白名單' -Tag 'Unit' {
    It '同一 build 有多個架構時選取指定架構的 uuid' {
        $uuid = InModuleScope WinMediaUpdate {
            Mock Invoke-RestMethod {
                [pscustomobject]@{ response = [pscustomobject]@{ builds = [pscustomobject]@{
                    a = [pscustomobject]@{ build = '26100.1882'; arch = 'arm64'; title = 'Windows 11, version 24H2 (26100.1882)'; uuid = 'd0c7e4bd-ec05-44e0-9b4a-6c6b2a8be61e' }
                    b = [pscustomobject]@{ build = '26100.1882'; arch = 'amd64'; title = 'Windows 11, version 24H2 (26100.1882)'; uuid = '89da9278-1ece-4c82-b791-d624d229924d' }
                } } }
            }
            Get-WinMediaUupBuild -Build '26100.1882' -Architecture amd64
        }
        $uuid | Should -Be '89da9278-1ece-4c82-b791-d624d229924d'
    }

    It 'Catalog 下載網址接受 windowsupdate.com 網域' {
        $files = @(InModuleScope WinMediaUpdate -Parameters @{ Html = "<script>url = 'https://catalog.s.download.windowsupdate.com/c/x/windows11.0-kb5044284-x64_d7eb7ceaa4798b92b988fd7dcc7c6bb39476ccf3.msu';</script>" } {
            param($Html) ConvertFrom-WinMediaCatalogDialog -Html $Html
        })
        $files.Count | Should -Be 1
    }
}

Describe 'UUP 與 Catalog 的比對鍵' -Tag 'Unit' {
    It 'Catalog 檔名去掉 SHA-1 後與 UUP 檔名相同' {
        $catalogKey = InModuleScope WinMediaUpdate { ConvertTo-WinMediaUpdateKey -Name 'windows11.0-kb5044284-x64_d7eb7ceaa4798b92b988fd7dcc7c6bb39476ccf3.msu' }
        $uupKey = InModuleScope WinMediaUpdate { ConvertTo-WinMediaUpdateKey -Name 'Windows11.0-KB5044284-x64.msu' }
        $catalogKey | Should -Be $uupKey
    }
}

Describe 'Save-WinMediaUpdate（Catalog 優先、UUP 輔助與驗證）' -Tag 'Unit' {
    BeforeAll {
        $script:sha1 = 'd7eb7ceaa4798b92b988fd7dcc7c6bb39476ccf3'
        $script:catalogFileName = 'windows11.0-kb5044284-x64_d7eb7ceaa4798b92b988fd7dcc7c6bb39476ccf3.msu'
    }

    BeforeEach {
        $script:config = @{ PackageDir = (Join-Path -Path $TestDrive -ChildPath ('pkg-' + [guid]::NewGuid().ToString('N'))); Download = @{ Method = 'WebRequest' }; LogLevel = 'Info' }
        Mock -ModuleName WinMediaUpdate Write-WinMediaLog { }
        Mock -ModuleName WinMediaUpdate Remove-Item { }
        Mock -ModuleName WinMediaUpdate Test-WinMediaMicrosoftSignature { $true }
        Mock -ModuleName WinMediaUpdate Invoke-WinMediaDownload { }
        Mock -ModuleName WinMediaUpdate Get-WinMediaCatalogFile {
            @([pscustomobject]@{ FileName = $script:catalogFileName; Uri = 'https://catalog.sf.dl.delivery.mp.microsoft.com/a.msu'; Sha1 = $script:sha1 })
        }
        Mock -ModuleName WinMediaUpdate Find-WinMediaCatalogUpdate {
            @([pscustomobject]@{ Guid = 'a62b9737-1fe8-4df1-94b4-8ec61855a8d0'; Title = 'x' })
        }
    }

    It 'Catalog 下載後 SHA-1 相符即回傳路徑' {
        $state = @{ calls = 0 }
        Mock -ModuleName WinMediaUpdate Test-WinMediaFileHash { $state.calls++; return ($state.calls -gt 1) }
        $saved = @(Save-WinMediaUpdate -KB 'KB5044284' -Config $script:config)
        $saved.Count | Should -Be 1
        $saved[0] | Should -BeLike "*$script:catalogFileName"
        Should -Invoke -CommandName Invoke-WinMediaDownload -ModuleName WinMediaUpdate -Times 1 -Exactly
    }

    It 'Catalog 下載後 SHA-1 不符時刪除並中止' {
        Mock -ModuleName WinMediaUpdate Test-WinMediaFileHash { $false }
        { Save-WinMediaUpdate -KB 'KB5044284' -Config $script:config } | Should -Throw '*SHA-1 不符*'
        Should -Invoke -CommandName Remove-Item -ModuleName WinMediaUpdate -Times 1 -Exactly
    }

    It 'UUP 的 SHA-1 與 Catalog 不一致時在下載前中止' {
        Mock -ModuleName WinMediaUpdate Get-WinMediaUupBuild { 'b6e1a3c4-0000-4000-8000-000000000000' }
        Mock -ModuleName WinMediaUpdate Get-WinMediaUupFile {
            @([pscustomobject]@{ Name = 'Windows11.0-KB5044284-x64.msu'; Sha1 = 'ffffffffffffffffffffffffffffffffffffffff'; Url = 'https://download.windowsupdate.com/x.msu' })
        }
        { Save-WinMediaUpdate -KB 'KB5044284' -Build '26100.1882' -Config $script:config } | Should -Throw '*不一致*'
        Should -Invoke -CommandName Invoke-WinMediaDownload -ModuleName WinMediaUpdate -Times 0 -Exactly
    }

    It 'UUP 查詢失敗時只記警告，仍以 Catalog SHA-1 驗證' {
        Mock -ModuleName WinMediaUpdate Get-WinMediaUupBuild { throw 'UUP 逾時' }
        $state = @{ calls = 0 }
        Mock -ModuleName WinMediaUpdate Test-WinMediaFileHash { $state.calls++; return ($state.calls -gt 1) }
        $saved = @(Save-WinMediaUpdate -KB 'KB5044284' -Build '26100.1882' -Config $script:config)
        $saved.Count | Should -Be 1
        Should -Invoke -CommandName Write-WinMediaLog -ModuleName WinMediaUpdate -ParameterFilter { $Level -eq 'Warning' } -Times 1 -Exactly
    }

    It 'Catalog 沒有結果且有 Build 時，改用 UUP 提供的網址' {
        Mock -ModuleName WinMediaUpdate Find-WinMediaCatalogUpdate { @() }
        Mock -ModuleName WinMediaUpdate Get-WinMediaUupBuild { 'b6e1a3c4-0000-4000-8000-000000000000' }
        Mock -ModuleName WinMediaUpdate Get-WinMediaUupFile {
            @([pscustomobject]@{ Name = 'Windows11.0-KB5044284-x64.msu'; Sha1 = $script:sha1; Url = 'https://download.windowsupdate.com/x.msu' })
        }
        $state = @{ calls = 0 }
        Mock -ModuleName WinMediaUpdate Test-WinMediaFileHash { $state.calls++; return ($state.calls -gt 1) }
        $saved = @(Save-WinMediaUpdate -KB 'KB5044284' -Build '26100.1882' -Config $script:config)
        $saved.Count | Should -Be 1
        Should -Invoke -CommandName Invoke-WinMediaDownload -ModuleName WinMediaUpdate -ParameterFilter { $Uri -eq 'https://download.windowsupdate.com/x.msu' } -Times 1 -Exactly
    }

    It 'Catalog 沒有結果且沒有 Build 時中止' {
        Mock -ModuleName WinMediaUpdate Find-WinMediaCatalogUpdate { @() }
        { Save-WinMediaUpdate -KB 'KB5044284' -Config $script:config } | Should -Throw '*-Build*'
    }

    It 'UUP 備援網址若不是 https 則拒絕下載' {
        Mock -ModuleName WinMediaUpdate Find-WinMediaCatalogUpdate { @() }
        Mock -ModuleName WinMediaUpdate Get-WinMediaUupBuild { 'b6e1a3c4-0000-4000-8000-000000000000' }
        Mock -ModuleName WinMediaUpdate Get-WinMediaUupFile {
            @([pscustomobject]@{ Name = 'Windows11.0-KB5044284-x64.msu'; Sha1 = $script:sha1; Url = 'http://download.windowsupdate.com/x.msu' })
        }
        { Save-WinMediaUpdate -KB 'KB5044284' -Build '26100.1882' -Config $script:config } | Should -Throw '*協定*'
        Should -Invoke -CommandName Invoke-WinMediaDownload -ModuleName WinMediaUpdate -Times 0 -Exactly
    }

    It 'UUP 備援網址不在 Microsoft 網域時拒絕下載' {
        Mock -ModuleName WinMediaUpdate Find-WinMediaCatalogUpdate { @() }
        Mock -ModuleName WinMediaUpdate Get-WinMediaUupBuild { 'b6e1a3c4-0000-4000-8000-000000000000' }
        Mock -ModuleName WinMediaUpdate Get-WinMediaUupFile {
            @([pscustomobject]@{ Name = 'Windows11.0-KB5044284-x64.msu'; Sha1 = $script:sha1; Url = 'https://evil.example.com/x.msu' })
        }
        { Save-WinMediaUpdate -KB 'KB5044284' -Build '26100.1882' -Config $script:config } | Should -Throw '*網域*'
        Should -Invoke -CommandName Invoke-WinMediaDownload -ModuleName WinMediaUpdate -Times 0 -Exactly
    }

    It 'UUP 無對應檔案時記錄警告，改以 Catalog SHA-1 驗證' {
        Mock -ModuleName WinMediaUpdate Get-WinMediaUupBuild { 'b6e1a3c4-0000-4000-8000-000000000000' }
        Mock -ModuleName WinMediaUpdate Get-WinMediaUupFile {
            @([pscustomobject]@{ Name = 'Other-KB1111111-x64.msu'; Sha1 = 'ffffffffffffffffffffffffffffffffffffffff'; Url = 'https://download.windowsupdate.com/o.msu' })
        }
        $state = @{ calls = 0 }
        Mock -ModuleName WinMediaUpdate Test-WinMediaFileHash { $state.calls++; return ($state.calls -gt 1) }
        $saved = @(Save-WinMediaUpdate -KB 'KB5044284' -Build '26100.1882' -Config $script:config)
        $saved.Count | Should -Be 1
        Should -Invoke -CommandName Write-WinMediaLog -ModuleName WinMediaUpdate -ParameterFilter { $Level -eq 'Warning' -and $Message -like '*無對應*' } -Times 1 -Exactly
    }

    It 'PackageDir 未設定時中止' {
        { Save-WinMediaUpdate -KB 'KB5044284' -Config @{ PackageDir = ''; Download = @{ Method = 'WebRequest' } } } | Should -Throw '*PackageDir*'
    }
}

Describe 'Save-WinMediaUpdateFile Authenticode 驗證（UUP 網址與雜湊同源，信任邊界）' -Tag 'Unit' {
    # 未簽章但 SHA-1 正確的假檔案；簽章檢查走真實的 Test-WinMediaMicrosoftSignature
    It '下載完成後簽章無效：刪除檔案並拋出簽章錯誤' {
        InModuleScope WinMediaUpdate -Parameters @{ Dest = $TestDrive } {
            param($Dest)
            $cfg = @{ LogLevel = 'Info'; OperationLog = ''; DebugTrace = 0; LogFile = (Join-Path -Path $Dest -ChildPath 'sig.log'); Download = @{ Method = 'WebRequest' } }
            $bytes = [Text.Encoding]::ASCII.GetBytes('not a signed msu')
            $sha1 = [BitConverter]::ToString([Security.Cryptography.SHA1]::Create().ComputeHash($bytes)).Replace('-', '')
            Mock Invoke-WinMediaDownload { [IO.File]::WriteAllBytes($Destination, [Text.Encoding]::ASCII.GetBytes('not a signed msu')) }
            { Save-WinMediaUpdateFile -Uri 'https://download.windowsupdate.com/x.msu' -FileName 'x.msu' -Sha1 $sha1 -Destination $Dest -Method WebRequest -Config $cfg } | Should -Throw '*簽章*'
            Should -Invoke -CommandName Invoke-WinMediaDownload -Times 1 -Exactly
            Test-Path -LiteralPath (Join-Path -Path $Dest -ChildPath 'x.msu') | Should -BeFalse
        }
    }

    It '快取命中但簽章無效：拋出簽章錯誤且不刪除檔案，也不下載' {
        InModuleScope WinMediaUpdate -Parameters @{ Dest = $TestDrive } {
            param($Dest)
            $cfg = @{ LogLevel = 'Info'; OperationLog = ''; DebugTrace = 0; LogFile = (Join-Path -Path $Dest -ChildPath 'sig.log'); Download = @{ Method = 'WebRequest' } }
            $bytes = [Text.Encoding]::ASCII.GetBytes('user supplied unsigned cab')
            $sha1 = [BitConverter]::ToString([Security.Cryptography.SHA1]::Create().ComputeHash($bytes)).Replace('-', '')
            $cached = Join-Path -Path $Dest -ChildPath 'y.cab'
            [IO.File]::WriteAllBytes($cached, $bytes)
            Mock Invoke-WinMediaDownload { }
            { Save-WinMediaUpdateFile -Uri 'https://download.windowsupdate.com/y.cab' -FileName 'y.cab' -Sha1 $sha1 -Destination $Dest -Method WebRequest -Config $cfg } | Should -Throw '*簽章*'
            Should -Invoke -CommandName Invoke-WinMediaDownload -Times 0 -Exactly
            Test-Path -LiteralPath $cached | Should -BeTrue
        }
    }
}
