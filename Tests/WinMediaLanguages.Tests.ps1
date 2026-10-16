#Requires -Version 5.1

BeforeAll {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\Modules\WinMediaBootFiles.psm1') -Force
    $script:config = @{ DebugTrace = 0; OperationLog = '' }
}

Describe 'Get-WinMediaEffectiveLanguage（媒體偵測與 Config.Languages 取聯集）' -Tag 'Unit' {
    BeforeEach {
        $script:media = Join-Path -Path $TestDrive -ChildPath ('media-{0}' -f [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:media 'sources\zh-tw') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:media 'sources\zh-tw\acres.dll.mui') -Value 'MUI'
    }

    It '偵測到的語言與設定重複（大小寫不同）時只保留一個' {
        $result = Get-WinMediaEffectiveLanguage -MediaDir $script:media -Languages @('zh-TW', 'ja-JP')

        @($result | Where-Object { $_ -eq 'zh-tw' }).Count | Should -Be 1
        $result | Should -Contain 'ja-jp'
    }

    It '設定為空時只使用偵測結果' {
        $result = Get-WinMediaEffectiveLanguage -MediaDir $script:media -Languages @()

        $result | Should -Be @('zh-tw')
    }

    It 'lang.ini 的 [Available UI Languages] 只列基礎語言時，其他含 mui 的語言資料夾不列入' {
        New-Item -ItemType Directory -Path (Join-Path $script:media 'sources\ca-es') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:media 'sources\ca-es\acres.dll.mui') -Value 'MUI'
        Set-Content -LiteralPath (Join-Path $script:media 'sources\lang.ini') -Value @('[Available UI Languages]', 'zh-tw = 3', '', '[Fallback Languages]', 'zh-tw = en-us')

        $result = Get-WinMediaEffectiveLanguage -MediaDir $script:media -Languages @()

        $result | Should -Be @('zh-tw')
    }

    It '沒有 mui 的語言資料夾不列入' {
        New-Item -ItemType Directory -Path (Join-Path $script:media 'sources\fr-fr') -Force | Out-Null

        $result = Get-WinMediaEffectiveLanguage -MediaDir $script:media -Languages @()

        $result | Should -Not -Contain 'fr-fr'
    }

    It '偵測與設定都為空時，以主流程的呼叫形式傳入同步函式不會出現繫結錯誤' {
        $empty = Join-Path -Path $TestDrive -ChildPath ('empty-{0}' -f [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        $wimList = Join-Path -Path $TestDrive -ChildPath ('wl-{0}.txt' -f [guid]::NewGuid().ToString('N'))
        $muiList = Join-Path -Path $TestDrive -ChildPath ('ml-{0}.txt' -f [guid]::NewGuid().ToString('N'))
        Set-Content -LiteralPath $wimList -Value @('setuphost.exe')
        Set-Content -LiteralPath $muiList -Value @('acres.dll.mui')
        Mock -ModuleName WinMediaBootFiles Invoke-WinMediaWimlib { throw '不應呼叫 wimlib' }

        { Copy-WinMediaBootWimSources -MediaDir $empty -WimPath 'x.wim' -Index 2 -WimListPath $wimList -MuiListPath $muiList -Languages (Get-WinMediaEffectiveLanguage -MediaDir $empty -Languages @()) -Config $script:config } | Should -Not -Throw
    }
}

Describe 'Remove-WinMediaExtraLanguage（移除未選取的額外語言資料夾）' -Tag 'Unit' {
    BeforeEach {
        $script:media = Join-Path -Path $TestDrive -ChildPath ('prune-{0}' -f [guid]::NewGuid().ToString('N'))
        $script:sources = Join-Path -Path $script:media -ChildPath 'sources'
        foreach ($name in 'zh-TW', 'ca-es', 'vi-vn') {
            New-Item -ItemType Directory -Path (Join-Path $script:sources $name) -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $script:sources "$name\acres.dll.mui") -Value 'MUI'
        }
        New-Item -ItemType Directory -Path (Join-Path $script:sources 'fr-fr') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:sources 'lang.ini') -Value @('[Available UI Languages]', 'zh-tw = 3')
    }

    It '保留 lang.ini 基礎語言與設定語言，移除其餘含 mui 的語言資料夾' {
        Remove-WinMediaExtraLanguage -MediaDir $script:media -Languages @('zh-TW') -Config $script:config

        Test-Path -LiteralPath (Join-Path $script:sources 'zh-TW') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:sources 'ca-es') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:sources 'vi-vn') | Should -BeFalse
    }

    It '沒有 mui 的語言資料夾不動' {
        Remove-WinMediaExtraLanguage -MediaDir $script:media -Languages @('zh-TW') -Config $script:config

        Test-Path -LiteralPath (Join-Path $script:sources 'fr-fr') | Should -BeTrue
    }

    It '設定語言也要保留（即使 lang.ini 沒列）' {
        Remove-WinMediaExtraLanguage -MediaDir $script:media -Languages @('ca-ES') -Config $script:config

        Test-Path -LiteralPath (Join-Path $script:sources 'ca-es') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:sources 'vi-vn') | Should -BeFalse
    }

    It '主流程於複製媒體與清除唯讀之後、Setup DU 之前呼叫裁剪' {
        $mainText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\Public\Invoke-WindowsMediaRefresh.ps1') -Raw
        $copyPos = $mainText.IndexOf("'CopyMedia'")
        $prunePos = $mainText.IndexOf('Remove-WinMediaExtraLanguage -MediaDir $mediaDir')
        $duPos = $mainText.IndexOf("'-F:*', `$setupDu")

        $prunePos | Should -BeGreaterThan $copyPos
        $prunePos | Should -BeLessThan $duPos
    }

    It '保留集合為空時不刪除任何語言資料夾' {
        Set-Content -LiteralPath (Join-Path $script:sources 'lang.ini') -Value @('[Available UI Languages]', 'ja-jp = 3')

        Remove-WinMediaExtraLanguage -MediaDir $script:media -Languages @() -Config $script:config

        Test-Path -LiteralPath (Join-Path $script:sources 'ca-es') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:sources 'zh-TW') | Should -BeTrue
    }

    It '沒有 sources 資料夾時不拋錯' {
        $none = Join-Path -Path $TestDrive -ChildPath ('none-{0}' -f [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $none -Force | Out-Null

        { Remove-WinMediaExtraLanguage -MediaDir $none -Languages @('zh-TW') -Config $script:config } | Should -Not -Throw
    }
}
