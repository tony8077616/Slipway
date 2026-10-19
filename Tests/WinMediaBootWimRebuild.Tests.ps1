#Requires -Version 5.1

BeforeAll {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\Modules\WinMediaBootFiles.psm1') -Force
    $script:config = @{ DebugTrace = 0; OperationLog = ''; WorkDir = $env:TEMP }
}

Describe 'Get-WinMediaBootBackground（convert-UUP set_bkimg：依序取第一個存在的背景圖）' -Tag 'Unit' {
    BeforeEach {
        $script:src = Join-Path -Path $TestDrive -ChildPath ('sources-{0}' -f [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:src -Force | Out-Null
    }

    It '沒有背景圖時回傳 $null' {
        Get-WinMediaBootBackground -SourcesDir $script:src | Should -BeNullOrEmpty
    }

    It '同時存在多個時依 convert-UUP 順序取第一個（cli.bmp 優先於 winpe.jpg）' {
        foreach ($name in 'winpe.jpg', 'background_cli.bmp') { New-Item -ItemType File -Path (Join-Path $script:src $name) -Force | Out-Null }
        Get-WinMediaBootBackground -SourcesDir $script:src | Should -Be 'background_cli.bmp'
    }
}

Describe 'Get-WinMediaBootSoftwareCommand（convert-UUP 1104–1116、1151–1154 行的 WinPE 登錄值）' -Tag 'Unit' {
    It '索引 1 設定 SystemRoot、InstRoot 與 winre.jpg 背景，並刪除 CustomShell' {
        $rows = Get-WinMediaBootSoftwareCommand -Index 1 -Hive 'HKLM\T'
        ($rows | ForEach-Object { $_[2] }) -join ',' | Should -Be 'SystemRoot,InstRoot,CustomBackground,CustomShell'
        $rows[2][4] | Should -Be '%SystemRoot%\System32\winre.jpg'
        $rows[0][3] | Should -Be 'REG_SZ'
    }

    It '索引 2 只設定 setup.bmp 背景並刪除 CustomShell' {
        $rows = Get-WinMediaBootSoftwareCommand -Index 2 -Hive 'HKLM\T'
        ($rows | ForEach-Object { $_[2] }) -join ',' | Should -Be 'CustomBackground,CustomShell'
        $rows[0][4] | Should -Be '%SystemRoot%\System32\setup.bmp'
    }
}

Describe 'New-WinMediaBootWimFromWinRE（索引 1 為 WinRE 的 PE；索引 2 由 WinRE 匯出；兩索引皆刪除 winpeshl.ini）' -Tag 'Unit' {
    BeforeEach {
        $global:RebuildCalls = New-Object System.Collections.ArrayList
        $global:RebuildAdds = New-Object System.Collections.ArrayList
        $script:media = Join-Path -Path $TestDrive -ChildPath ('media-{0}' -f [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:media 'sources') -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $script:media 'sources\background_cli.bmp') -Force | Out-Null
        Mock -ModuleName WinMediaBootFiles Copy-Item { }
        Mock -ModuleName WinMediaBootFiles Invoke-WinMediaOperation { }
        Mock -ModuleName WinMediaBootFiles Invoke-WinMediaWimlib { $global:RebuildCalls.Add(($ArgumentList -join ' | ')) | Out-Null }
        Mock -ModuleName WinMediaBootFiles Set-WinMediaBootSoftware { 'C:\fake\SOFTWARE' }
        Mock -ModuleName WinMediaBootFiles Invoke-WinMediaBootWimAdd {
            $global:RebuildAdds.Add(('{0}:{1}' -f $Index, (($Pairs | ForEach-Object { $_.Dest }) -join ','))) | Out-Null
        }
        New-WinMediaBootWimFromWinRE -WinreWim 'C:\fake\winre.wim' -BootWim 'C:\fake\boot.wim' -MediaDir $script:media -ArchName 'x64' -Config $script:config
    }

    AfterEach {
        Remove-Variable -Name RebuildCalls, RebuildAdds -Scope Global -ErrorAction SilentlyContinue
    }

    It '索引 1 命名為 PE 並設 FLAGS=9，索引 2 以 --boot 從 WinRE 匯出並設 FLAGS=2' {
        $global:RebuildCalls | Should -Contain 'info | C:\fake\boot.wim | 1 | Microsoft Windows PE (x64) | Microsoft Windows PE (x64) | --image-property | FLAGS=9'
        $global:RebuildCalls | Should -Contain 'export | C:\fake\winre.wim | 1 | C:\fake\boot.wim | Microsoft Windows Setup (x64) | Microsoft Windows Setup (x64) | --boot'
        $global:RebuildCalls | Should -Contain 'info | C:\fake\boot.wim | 2 | --image-property | FLAGS=2'
    }

    It '兩個索引都刪除 winpeshl.ini，索引 1 的刪除在匯出之前，索引 2 的刪除在匯出之後' {
        $deletes = @($global:RebuildCalls | Where-Object { $_ -like '*--command=delete*winpeshl.ini*' })
        $deletes.Count | Should -Be 2
        $deletes[0] | Should -BeLike 'update | C:\fake\boot.wim | 1 *'
        $deletes[1] | Should -BeLike 'update | C:\fake\boot.wim | 2 *'
        [array]::IndexOf($global:RebuildCalls.ToArray(), $deletes[0]) | Should -BeLessThan ([array]::IndexOf($global:RebuildCalls.ToArray(), ($global:RebuildCalls | Where-Object { $_ -like 'export |*' })))
    }

    It '索引 1 寫入 SOFTWARE 與 winre.jpg、之後補 winpe.jpg；索引 2 寫入 SOFTWARE、背景圖與 setup.bmp' {
        $global:RebuildAdds | Should -Contain '1:\Windows\System32\config\SOFTWARE,\Windows\system32\winre.jpg'
        $global:RebuildAdds | Should -Contain '1:\Windows\system32\winpe.jpg'
        $index2 = @($global:RebuildAdds | Where-Object { $_ -like '2:*' })
        $index2 | Should -Match '\\sources\\background.bmp'
        $index2 | Should -Match '\\Windows\\system32\\setup.bmp'
    }
}
