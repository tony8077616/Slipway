#Requires -Version 5.1

BeforeAll {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\Modules\WinMediaLangFod.psm1') -Force
    $script:config = @{ Languages = @('ja-JP', 'zh-TW'); DebugTrace = 0; OperationLog = ''; LogFile = (Join-Path -Path $TestDrive -ChildPath 'langfod.log'); LogLevel = 'Info'; DismProvider = 'Inbox'; DismLogLevel = 'WarningsInfo' }

    # 測試資料：語言包（一個保留、一個非設定語言、一個無語言標籤、一個非 .cab）
    $script:langDir = Join-Path -Path $TestDrive -ChildPath 'Lang'
    New-Item -ItemType Directory -Path $script:langDir -Force | Out-Null
    'Microsoft-Windows-Client-Language-Pack_x64_ja-jp.cab', 'Microsoft-Windows-Client-Language-Pack_x64_fr-fr.cab', 'Microsoft-Windows-Client-Language-Pack_x64_neutral.cab', 'readme.txt' |
        ForEach-Object { New-Item -ItemType File -Path (Join-Path -Path $script:langDir -ChildPath $_) -Force | Out-Null }

    # 測試資料：FoD（含語言中立、設定語言、非設定語言，並有子資料夾）
    $script:fodDir = Join-Path -Path $TestDrive -ChildPath 'Fod'
    New-Item -ItemType Directory -Path (Join-Path -Path $script:fodDir -ChildPath 'sub') -Force | Out-Null
    'Microsoft-Windows-LanguageFeatures-Basic-ja-jp-Package~31bf3856ad364e35~amd64~~.cab',
    'Microsoft-Windows-LanguageFeatures-Basic-fr-fr-Package~31bf3856ad364e35~amd64~~.cab',
    'Microsoft-Windows-NetFx3-OnDemand-Package~31bf3856ad364e35~amd64~~.cab' |
        ForEach-Object { New-Item -ItemType File -Path (Join-Path -Path $script:fodDir -ChildPath $_) -Force | Out-Null }
    New-Item -ItemType File -Path (Join-Path -Path $script:fodDir -ChildPath 'sub\Microsoft-Windows-Hello-Face-Package~31bf3856ad364e35~amd64~~.cab') -Force | Out-Null
}

Describe 'Get-WinMediaLanguageTag（語言標籤解析）' -Tag 'Unit' {
    It '從 LanguageFeatures 檔名取出語言標籤' {
        InModuleScope WinMediaLangFod {
            Get-WinMediaLanguageTag -FileName 'Microsoft-Windows-LanguageFeatures-Basic-ja-jp-Package~31bf3856ad364e35~amd64~~.cab' | Should -Be 'ja-jp'
        }
    }

    It '從 Client-Language-Pack 檔名取出語言標籤' {
        InModuleScope WinMediaLangFod {
            Get-WinMediaLanguageTag -FileName 'Microsoft-Windows-Client-Language-Pack_x64_ja-jp.cab' | Should -Be 'ja-jp'
        }
    }

    It '語言中立檔名回傳 $null' {
        InModuleScope WinMediaLangFod {
            Get-WinMediaLanguageTag -FileName 'Microsoft-Windows-NetFx3-OnDemand-Package~31bf3856ad364e35~amd64~~.cab' | Should -BeNullOrEmpty
        }
    }
}

Describe 'Resolve-WinMediaLangFodSet（篩選規則）' -Tag 'Unit' {
    It '語言包只保留設定語言' {
        $set = Resolve-WinMediaLangFodSet -LangPath $script:langDir -FodPath '' -Config $script:config
        @($set.LangPacks).Count | Should -Be 1
        Split-Path -Path @($set.LangPacks)[0] -Leaf | Should -Be 'Microsoft-Windows-Client-Language-Pack_x64_ja-jp.cab'
    }

    It 'FoD 保留語言中立與設定語言，並遞迴搜尋子資料夾' {
        $set = Resolve-WinMediaLangFodSet -LangPath '' -FodPath $script:fodDir -Config $script:config
        @($set.Fod).Count | Should -Be 2
        @($set.Fod) | Where-Object { $_ -like '*fr-fr*' } | Should -BeNullOrEmpty
        @($set.Fod) | Where-Object { $_ -like '*Hello-Face*' } | Should -Not -BeNullOrEmpty
    }

    It 'NetFx3 進入 Deferred（cleanup 之後才注入），不在 Fod 內' {
        $set = Resolve-WinMediaLangFodSet -LangPath '' -FodPath $script:fodDir -Config $script:config
        @($set.Deferred).Count | Should -Be 1
        @($set.Deferred)[0] | Should -BeLike '*NetFx3*'
        @($set.Fod) | Where-Object { $_ -like '*NetFx3*' } | Should -BeNullOrEmpty
    }

    It '路徑為空時兩組皆為空' {
        $set = Resolve-WinMediaLangFodSet -LangPath '' -FodPath '' -Config $script:config
        @($set.LangPacks).Count | Should -Be 0
        @($set.Fod).Count | Should -Be 0
    }
}

Describe 'Install-WinMediaLangFod（注入順序）' -Tag 'Unit' {
    BeforeEach {
        $script:installed = @()
        Mock -ModuleName WinMediaLangFod Invoke-WinMediaDism { param([scriptblock]$ScriptBlock) & $ScriptBlock }
        Mock -ModuleName WinMediaLangFod Add-WindowsPackage { $script:installed += $PackagePath }
    }

    It '語言包先於 FoD 注入' {
        $set = [pscustomobject]@{ LangPacks = @('C:\a\lp.cab'); Fod = @('C:\b\fod.cab') }
        Install-WinMediaLangFod -MountPath 'C:\mnt' -Set $set -Config $script:config
        $script:installed | Should -Be @('C:\a\lp.cab', 'C:\b\fod.cab')
    }

    It '沒有檔案時不呼叫 DISM' {
        $set = [pscustomobject]@{ LangPacks = @(); Fod = @() }
        Install-WinMediaLangFod -MountPath 'C:\mnt' -Set $set -Config $script:config
        Should -Invoke -CommandName Invoke-WinMediaDism -ModuleName WinMediaLangFod -Times 0 -Exactly
    }
}
