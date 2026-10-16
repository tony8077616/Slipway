#Requires -Version 5.1

BeforeAll {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\PSModules\Common\WinMediaDownload.psm1') -Force
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\PSModules\Common\WinMediaOperation.psm1') -Force
    $script:config = @{ DebugTrace = 0; OperationLog = ''; LogLevel = 'Info' }
}

Describe 'Invoke-WinMediaDownload（下載傳輸）' -Tag 'Unit' {
    BeforeEach {
        Mock -ModuleName WinMediaDownload Invoke-WinMediaOperation { param([scriptblock]$ScriptBlock) & $ScriptBlock }
        Mock -ModuleName WinMediaDownload New-Item { }
        Mock -ModuleName WinMediaDownload Move-Item { }
        # 探測不得連到真實網路：預設回傳 200（無重導向）
        Mock -ModuleName WinMediaDownload Get-WinMediaRedirectStep { [pscustomobject]@{ StatusCode = 200; Location = $null } }
        Mock -ModuleName WinMediaDownload Write-WinMediaLog { }
    }

    It '拒絕非 https 的網址（file 協定）' {
        { Invoke-WinMediaDownload -Uri 'file:///C:/x.msu' -Destination (Join-Path $TestDrive 'a.msu') -Config $script:config } |
            Should -Throw '*協定*'
    }

    It 'WebRequest 先寫入 .partial，完成後改名為目標檔' {
        Mock -ModuleName WinMediaDownload Invoke-WebRequest { }
        $dest = Join-Path -Path $TestDrive -ChildPath 'a.msu'
        Invoke-WinMediaDownload -Uri 'https://example.com/a.msu' -Destination $dest -Method WebRequest -Config $script:config | Out-Null
        Should -Invoke -CommandName Invoke-WebRequest -ModuleName WinMediaDownload -ParameterFilter { $OutFile -like '*a.msu.partial' } -Times 1 -Exactly
        Should -Invoke -CommandName Move-Item -ModuleName WinMediaDownload -ParameterFilter { $LiteralPath -like '*a.msu.partial' } -Times 1 -Exactly
    }

    It 'Bits 以 JobId 輪詢直到 Transferred，再完成並改名' {
        Mock -ModuleName WinMediaDownload Start-BitsTransfer { [pscustomobject]@{ JobId = '11111111-2222-3333-4444-555555555555'; JobState = 'Queued' } }
        Mock -ModuleName WinMediaDownload Get-BitsTransfer { [pscustomobject]@{ JobId = '11111111-2222-3333-4444-555555555555'; JobState = 'Transferred' } }
        Mock -ModuleName WinMediaDownload Complete-WinMediaBitsJob { }
        Mock -ModuleName WinMediaDownload Start-Sleep { }
        Invoke-WinMediaDownload -Uri 'https://example.com/b.msu' -Destination (Join-Path $TestDrive 'b.msu') -Method Bits -Config $script:config | Out-Null
        Should -Invoke -CommandName Get-BitsTransfer -ModuleName WinMediaDownload -ParameterFilter { $JobId -eq '11111111-2222-3333-4444-555555555555' } -Times 1 -Exactly
        Should -Invoke -CommandName Complete-WinMediaBitsJob -ModuleName WinMediaDownload -Times 1 -Exactly
        Should -Invoke -CommandName Move-Item -ModuleName WinMediaDownload -Times 1 -Exactly
    }

    It 'Curl 失敗時中止且不改名' {
        Mock -ModuleName WinMediaDownload Invoke-WinMediaExternal { [pscustomobject]@{ ExitCode = 6; StdOut = ''; StdErr = 'could not resolve host' } }
        { Invoke-WinMediaDownload -Uri 'https://example.com/a.msu' -Destination (Join-Path $TestDrive 'b.msu') -Method Curl -Config $script:config } |
            Should -Throw '*curl*'
        Should -Invoke -CommandName Move-Item -ModuleName WinMediaDownload -Times 0 -Exactly
    }
}

Describe 'Test-WinMediaFileHash（SHA-1 與 SHA-256）' -Tag 'Unit' {
    It 'SHA-1 相符時回傳 $true（大小寫不敏感）' {
        $path = Join-Path -Path $TestDrive -ChildPath 'abc.bin'
        [IO.File]::WriteAllText($path, 'abc')
        # SHA-1 僅作完整性比對（Catalog 檔名提供的雜湊），非安全用途
        $algorithm = 'SHA1'
        Test-WinMediaFileHash -Path $path -Hash 'A9993E364706816ABA3E25717850C26C9CD0D89D' -Algorithm $algorithm | Should -BeTrue
    }

    It '沿用 -Sha256 參數名稱時仍可運作（既有呼叫端）' {
        $path = Join-Path -Path $TestDrive -ChildPath 'abc2.bin'
        [IO.File]::WriteAllText($path, 'abc')
        Test-WinMediaFileHash -Path $path -Sha256 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad' | Should -BeTrue
    }
}
