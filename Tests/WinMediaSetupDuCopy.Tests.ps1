#Requires -Version 5.1

BeforeAll {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\Modules\WinMediaBootFiles.psm1') -Force
    $script:config = @{ DebugTrace = 0; OperationLog = '' }
}

Describe 'Copy-WinMediaSetupDuFiles（convert-UUP 2349–2358 行的 /U 語意，不套用 /D）' -Tag 'Unit' {
    BeforeEach {
        $script:exp = Join-Path -Path $TestDrive -ChildPath ('exp-{0}' -f [guid]::NewGuid().ToString('N'))
        $script:src = Join-Path -Path $TestDrive -ChildPath ('src-{0}' -f [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:exp, $script:src -Force | Out-Null
    }

    It '根目錄檔案只覆蓋既有檔，不建立新檔' {
        Set-Content -LiteralPath (Join-Path $script:exp 'setuphost.exe') -Value 'DU'
        Set-Content -LiteralPath (Join-Path $script:exp 'newonly.dll') -Value 'DU'
        Set-Content -LiteralPath (Join-Path $script:src 'setuphost.exe') -Value 'OLD'
        (Get-Item -LiteralPath (Join-Path $script:src 'setuphost.exe')).LastWriteTimeUtc = (Get-Date).AddDays(-1).ToUniversalTime()

        Copy-WinMediaSetupDuFiles -ExpandedDir $script:exp -SourcesDir $script:src -Config $script:config

        Get-Content -LiteralPath (Join-Path $script:src 'setuphost.exe') | Should -Be 'DU'
        Test-Path -LiteralPath (Join-Path $script:src 'newonly.dll') | Should -BeFalse
    }

    It 'DU 時間早於媒體時仍覆蓋既有檔（不套用 /D，參考採用 DU 版本）' {
        Set-Content -LiteralPath (Join-Path $script:exp 'setupprep.exe') -Value 'DU'
        (Get-Item -LiteralPath (Join-Path $script:exp 'setupprep.exe')).LastWriteTimeUtc = (Get-Date).AddDays(-2).ToUniversalTime()
        Set-Content -LiteralPath (Join-Path $script:src 'setupprep.exe') -Value 'MEDIA'

        Copy-WinMediaSetupDuFiles -ExpandedDir $script:exp -SourcesDir $script:src -Config $script:config

        Get-Content -LiteralPath (Join-Path $script:src 'setupprep.exe') | Should -Be 'DU'
    }

    It '*.ini 即使媒體沒有也會複製' {
        Set-Content -LiteralPath (Join-Path $script:exp 'cversions.ini') -Value 'INI'

        Copy-WinMediaSetupDuFiles -ExpandedDir $script:exp -SourcesDir $script:src -Config $script:config

        Get-Content -LiteralPath (Join-Path $script:src 'cversions.ini') | Should -Be 'INI'
    }

    It '媒體已有該語言的 *.mui 時，整個語言資料夾都會複製' {
        New-Item -ItemType Directory -Path (Join-Path $script:exp 'sr-Latn-RS'), (Join-Path $script:src 'sr-Latn-RS') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:exp 'sr-Latn-RS\setupplatform.exe.mui') -Value 'DU'
        Set-Content -LiteralPath (Join-Path $script:exp 'sr-Latn-RS\acres.dll.mui') -Value 'DU'
        Set-Content -LiteralPath (Join-Path $script:src 'sr-Latn-RS\acres.dll.mui') -Value 'OLD'

        Copy-WinMediaSetupDuFiles -ExpandedDir $script:exp -SourcesDir $script:src -Config $script:config

        Get-Content -LiteralPath (Join-Path $script:src 'sr-Latn-RS\setupplatform.exe.mui') | Should -Be 'DU'
        Get-Content -LiteralPath (Join-Path $script:src 'sr-Latn-RS\acres.dll.mui') | Should -Be 'DU'
    }

    It '媒體沒有該語言的 *.mui 時，不建立語言資料夾' {
        New-Item -ItemType Directory -Path (Join-Path $script:exp 'ja-jp') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:exp 'ja-jp\setupplatform.exe.mui') -Value 'DU'

        Copy-WinMediaSetupDuFiles -ExpandedDir $script:exp -SourcesDir $script:src -Config $script:config

        Test-Path -LiteralPath (Join-Path $script:src 'ja-jp') | Should -BeFalse
    }

    It 'replacementmanifests 遞迴複製' {
        New-Item -ItemType Directory -Path (Join-Path $script:exp 'replacementmanifests\sub') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:exp 'replacementmanifests\sub\m.man') -Value 'MAN'

        Copy-WinMediaSetupDuFiles -ExpandedDir $script:exp -SourcesDir $script:src -Config $script:config

        Get-Content -LiteralPath (Join-Path $script:src 'replacementmanifests\sub\m.man') | Should -Be 'MAN'
    }

    It '其他子資料夾（名稱不含 -）一律忽略' {
        New-Item -ItemType Directory -Path (Join-Path $script:exp 'other') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:exp 'other\x.txt') -Value 'X'

        Copy-WinMediaSetupDuFiles -ExpandedDir $script:exp -SourcesDir $script:src -Config $script:config

        Test-Path -LiteralPath (Join-Path $script:src 'other') | Should -BeFalse
    }
}
