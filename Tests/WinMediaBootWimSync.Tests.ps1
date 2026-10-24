#Requires -Version 5.1

BeforeAll {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\Modules\WinMediaBootFiles.psm1') -Force
    $script:config = @{ DebugTrace = 0; OperationLog = '' }
}

Describe 'Copy-WinMediaBootWimSources（convert-UUP bootwim.txt／bootmui.txt：媒體 → WinPE 索引 2，wimlib update 經 stdin）' -Tag 'Unit' {
    BeforeEach {
        $script:media = Join-Path -Path $TestDrive -ChildPath ('media-{0}' -f [guid]::NewGuid().ToString('N'))
        $script:wim = Join-Path -Path $TestDrive -ChildPath ('boot-{0}.wim' -f [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:media 'sources\zh-tw'), (Join-Path $script:media 'sources\inf') -Force | Out-Null
        $script:wimList = Join-Path -Path $TestDrive -ChildPath ('bootwim-{0}.txt' -f [guid]::NewGuid().ToString('N'))
        $script:muiList = Join-Path -Path $TestDrive -ChildPath ('bootmui-{0}.txt' -f [guid]::NewGuid().ToString('N'))
        Set-Content -LiteralPath $script:wimList -Value @('# 註解', 'setuphost.exe', '', 'missing.dll')
        Set-Content -LiteralPath $script:muiList -Value @('acres.dll.mui', 'absent.mui')
        # 記錄每次 wimlib 呼叫的參數與 stdin 指令內容（stdin 檔在呼叫結束後會被刪除，所以在 mock 內讀取）
        $script:WimCalls = New-Object System.Collections.ArrayList
        $script:WimStdin = New-Object System.Collections.ArrayList
        Mock -ModuleName WinMediaBootFiles Invoke-WinMediaWimlib {
            $null = $script:WimCalls.Add(($ArgumentList -join ' '))
            if ($StandardInputPath) { $null = $script:WimStdin.Add([System.IO.File]::ReadAllText($StandardInputPath)) }
            [pscustomobject]@{ ExitCode = 0 }
        }
    }

    AfterEach {
        Remove-Variable -Name WimCalls, WimStdin -Scope Global -ErrorAction SilentlyContinue
    }

    It '只為媒體存在的清單檔案產生 add 指令，目標為 WIM 內的 \sources\' {
        Set-Content -LiteralPath (Join-Path $script:media 'sources\setuphost.exe') -Value 'MEDIA'

        Copy-WinMediaBootWimSources -MediaDir $script:media -WimPath $script:wim -Index 2 -WimListPath $script:wimList -MuiListPath $script:muiList -Languages @('zh-TW') -Config $script:config

        $stdin = $script:WimStdin -join "`n"
        $stdin | Should -Match ([regex]::Escape("add '{0}' '\sources\setuphost.exe'" -f (Join-Path $script:media 'sources\setuphost.exe')))
        $stdin | Should -Not -Match 'missing\.dll'
    }

    It 'wimlib 以 update <wim> 2 執行，指令經 stdin 傳入（wimlib 只接受一次 --command）' {
        Set-Content -LiteralPath (Join-Path $script:media 'sources\setuphost.exe') -Value 'MEDIA'

        Copy-WinMediaBootWimSources -MediaDir $script:media -WimPath $script:wim -Index 2 -WimListPath $script:wimList -MuiListPath $script:muiList -Languages @('zh-TW') -Config $script:config

        $script:WimCalls.Count | Should -Be 1
        $script:WimCalls[0] | Should -Be ('update {0} 2' -f $script:wim)
        $script:WimStdin.Count | Should -Be 1
    }

    It '不以 Copy-Item 覆寫 WinPE（映像內 ACL 會拒絕 Administrators 寫入）' {
        Set-Content -LiteralPath (Join-Path $script:media 'sources\setuphost.exe') -Value 'MEDIA'
        Mock -ModuleName WinMediaBootFiles Copy-Item { }

        Copy-WinMediaBootWimSources -MediaDir $script:media -WimPath $script:wim -Index 2 -WimListPath $script:wimList -MuiListPath $script:muiList -Languages @('zh-TW') -Config $script:config

        Should -Invoke -CommandName Copy-Item -ModuleName WinMediaBootFiles -Times 0 -Exactly
    }

    It '語言 mui 依語言資料夾（小寫）產生指令，媒體沒有的略過' {
        Set-Content -LiteralPath (Join-Path $script:media 'sources\zh-tw\acres.dll.mui') -Value 'MUI'

        Copy-WinMediaBootWimSources -MediaDir $script:media -WimPath $script:wim -Index 2 -WimListPath $script:wimList -MuiListPath $script:muiList -Languages @('zh-TW') -Config $script:config

        $stdin = $script:WimStdin -join "`n"
        $stdin | Should -Match "'\\sources\\zh-tw\\acres\.dll\.mui'"
        $stdin | Should -Not -Match 'absent\.mui'
    }

    It '加入媒體根目錄 setup.exe 與 sources\inf\setup.cfg' {
        Set-Content -LiteralPath (Join-Path $script:media 'setup.exe') -Value 'ROOT'
        Set-Content -LiteralPath (Join-Path $script:media 'sources\inf\setup.cfg') -Value 'CFG'

        Copy-WinMediaBootWimSources -MediaDir $script:media -WimPath $script:wim -Index 2 -WimListPath $script:wimList -MuiListPath $script:muiList -Languages @('zh-TW') -Config $script:config

        $stdin = $script:WimStdin -join "`n"
        $stdin | Should -Match "'\\setup\.exe'"
        $stdin | Should -Match "'\\sources\\inf\\setup\.cfg'"
    }

    It '大量指令仍只呼叫一次 wimlib（stdin 不受命令列長度限制）' {
        $names = 1..45 | ForEach-Object { 'f{0:D2}.dll' -f $_ }
        Set-Content -LiteralPath $script:wimList -Value $names
        foreach ($n in $names) { Set-Content -LiteralPath (Join-Path $script:media "sources\$n") -Value 'M' }

        Copy-WinMediaBootWimSources -MediaDir $script:media -WimPath $script:wim -Index 2 -WimListPath $script:wimList -MuiListPath $script:muiList -Languages @() -Config $script:config

        $script:WimCalls.Count | Should -Be 1
        @($script:WimStdin[0] -split "`n" | Where-Object { $_ }).Count | Should -Be 45
    }

    It '沒有任何媒體檔案時不呼叫 wimlib' {
        Copy-WinMediaBootWimSources -MediaDir $script:media -WimPath $script:wim -Index 2 -WimListPath $script:wimList -MuiListPath $script:muiList -Languages @('zh-TW') -Config $script:config

        $script:WimCalls.Count | Should -Be 0
    }
}
