#Requires -Version 5.1

BeforeAll {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\Modules\WinMediaUpdate.psm1') -Force
    $script:config = @{ LogLevel = 'Info'; OperationLog = ''; DebugTrace = 0; LogFile = (Join-Path -Path $TestDrive -ChildPath 'hardening.log'); PackageDir = (Join-Path -Path $TestDrive -ChildPath 'pkg'); Download = @{ Method = 'WebRequest' } }
}

Describe 'Save-WinMediaUpdateFile 檔名與副檔名閘門（信任邊界）' -Tag 'Unit' {
    It '拒絕路徑穿越、子目錄與非更新包副檔名，且不發出下載' {
        InModuleScope WinMediaUpdate -Parameters @{ Dest = $TestDrive; Cfg = $script:config } {
            param($Dest, $Cfg); $null = $Dest, $Cfg
            Mock Invoke-WinMediaDownload { }
            foreach ($name in '..\..\x.msu', 'a\b.msu', 'sub/x.msu', 'x.ps1', 'x.msu.exe') {
                { Save-WinMediaUpdateFile -Uri 'https://catalog.sf.dl.delivery.mp.microsoft.com/a.msu' -FileName $name -Sha1 'aa' -Destination $Dest -Method WebRequest -Config $Cfg } | Should -Throw
            }
            Should -Invoke -CommandName Invoke-WinMediaDownload -Times 0 -Exactly
        }
    }

    It '檔名副檔名與網址不符時拒絕' {
        InModuleScope WinMediaUpdate -Parameters @{ Dest = $TestDrive; Cfg = $script:config } {
            param($Dest, $Cfg); $null = $Dest, $Cfg
            Mock Invoke-WinMediaDownload { }
            { Save-WinMediaUpdateFile -Uri 'https://catalog.sf.dl.delivery.mp.microsoft.com/a.msu' -FileName 'x.cab' -Sha1 'aa' -Destination $Dest -Method WebRequest -Config $Cfg } | Should -Throw '*副檔名*'
            Should -Invoke -CommandName Invoke-WinMediaDownload -Times 0 -Exactly
        }
    }
}

Describe 'UUP 條目欄位缺漏的處理' -Tag 'Unit' {
    It '缺 sha1 的條目保留為空值，不讓整份清單失敗' {
        InModuleScope WinMediaUpdate {
            Mock Invoke-RestMethod { 'unused' }
            Mock Get-WinMediaUupResponse {
                [pscustomobject]@{ files = [pscustomobject]@{
                    'a.msu' = [pscustomobject]@{ url = 'https://catalog.sf.dl.delivery.mp.microsoft.com/a.msu' }
                    'b.msu' = [pscustomobject]@{ sha1 = 'AB'; url = 'https://catalog.sf.dl.delivery.mp.microsoft.com/b.msu' }
                } }
            }
            $entries = @(Get-WinMediaUupEntry -Uuid '89da9278-1ece-4c82-b791-d624d229924d')
            $entries.Count | Should -Be 2
            ($entries | Where-Object { $_.Name -eq 'a.msu' }).Sha1 | Should -BeNullOrEmpty
            ($entries | Where-Object { $_.Name -eq 'b.msu' }).Sha1 | Should -Be 'ab'
        }
    }

    It '缺 arch 的條目視為不符，不中止 build 選擇' {
        InModuleScope WinMediaUpdate {
            Mock Invoke-RestMethod { 'unused' }
            Mock Get-WinMediaUupResponse {
                [pscustomobject]@{ builds = [pscustomobject]@{
                    a = [pscustomobject]@{ build = '26100.9711'; title = 'Windows 11, version 24H2 (26100.9711)'; uuid = '11111111-1111-1111-1111-111111111111' }
                    c = [pscustomobject]@{ build = '26100.9711'; arch = 'amd64'; title = 'Windows 11, version 24H2 (26100.9711)'; uuid = 'ac94e557-eb76-4c8b-a064-0c72d6d3e09c' }
                } }
            }
            Get-WinMediaUupBuild -Build '26100.9711' -Architecture amd64 | Should -Be 'ac94e557-eb76-4c8b-a064-0c72d6d3e09c'
        }
    }
}

Describe 'Save-WinMediaBuildSet 完整性與命名（硬化）' -Tag 'Unit' {
    BeforeEach {
        Mock -ModuleName WinMediaUpdate Get-WinMediaUupBuild { '89da9278-1ece-4c82-b791-d624d229924d' }
        Mock -ModuleName WinMediaUpdate Find-WinMediaLearnKb { 'KB5127648' }
        Mock -ModuleName WinMediaUpdate Write-WinMediaLog { }
        Mock -ModuleName WinMediaUpdate Save-WinMediaUpdateFile { param($FileName, $Destination) Join-Path -Path $Destination -ChildPath $FileName }
    }

    It '缺 SHA-1 的條目在下載前拒絕' {
        Mock -ModuleName WinMediaUpdate Get-WinMediaUupEntry {
            @([pscustomobject]@{ Name = 'Windows11.0-KB5127648-x64.msu'; Sha1 = ''; Url = 'https://catalog.sf.dl.delivery.mp.microsoft.com/b.msu' })
        }
        { Save-WinMediaBuildSet -Build '26100.9711' -Architecture amd64 -Config $script:config } | Should -Throw '*SHA-1*'
        Should -Invoke -CommandName Save-WinMediaUpdateFile -ModuleName WinMediaUpdate -Times 0 -Exactly
    }

    It '帶後綴的 .msu（.NET 套件）不會成為目標或 checkpoint' {
        Mock -ModuleName WinMediaUpdate Get-WinMediaUupEntry {
            @(
                [pscustomobject]@{ Name = 'Windows11.0-KB5043080-x64.msu'; Sha1 = 'aa'; Url = 'https://catalog.sf.dl.delivery.mp.microsoft.com/a.msu' }
                [pscustomobject]@{ Name = 'Windows11.0-KB5127648-x64.msu'; Sha1 = 'bb'; Url = 'https://catalog.sf.dl.delivery.mp.microsoft.com/b.msu' }
                [pscustomobject]@{ Name = 'Windows11.0-KB5199999-x64-ndp481.msu'; Sha1 = 'cc'; Url = 'https://catalog.sf.dl.delivery.mp.microsoft.com/c.msu' }
            )
        }
        $set = Save-WinMediaBuildSet -Build '26100.9711' -Architecture amd64 -Config $script:config
        $set.TargetKb | Should -Be 'KB5127648'
        $set.Target | Should -BeLike '*Windows11.0-KB5127648-x64.msu'
        ($set.Checkpoints -join ';') | Should -Not -Match 'KB5199999'
    }
}
