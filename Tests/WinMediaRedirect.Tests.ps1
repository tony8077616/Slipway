#Requires -Version 5.1

BeforeAll {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\PSModules\Common\WinMediaDownload.psm1') -Force
    $script:pattern = '(^|\.)(microsoft\.com|windowsupdate\.com)$'
    $script:config = @{ DebugTrace = 0; OperationLog = ''; LogLevel = 'Info'; LogFile = (Join-Path -Path $TestDrive -ChildPath 'redirect.log') }
}

Describe 'Resolve-WinMediaDownloadUri（逐跳重導向驗證）' -Tag 'Unit' {
    BeforeEach {
        # 保底：任何未預期的探測都直接失敗，避免連到真實網路
        Mock -ModuleName WinMediaDownload Get-WinMediaRedirectStep { throw "未預期的探測：$($Uri.AbsoluteUri)" }
        # 起點 302 → 允許的 CDN → 200
        Mock -ModuleName WinMediaDownload Get-WinMediaRedirectStep -ParameterFilter { $Uri.AbsolutePath -eq '/a.msu' } { [pscustomobject]@{ StatusCode = 302; Location = 'https://download.windowsupdate.com/b.msu' } }
        Mock -ModuleName WinMediaDownload Get-WinMediaRedirectStep -ParameterFilter { $Uri.AbsolutePath -eq '/b.msu' } { [pscustomobject]@{ StatusCode = 200; Location = $null } }
    }

    It '沿允許的主機重導向，回傳最終網址與各跳' {
        $result = Resolve-WinMediaDownloadUri -Uri 'https://catalog.sf.dl.delivery.mp.microsoft.com/a.msu' -AllowedHostPattern $script:pattern
        $result.Uri.AbsoluteUri | Should -Be 'https://download.windowsupdate.com/b.msu'
        @($result.Hops).Count | Should -Be 2
    }

    It '重導向到不允許的主機時中止，且不探測該主機' {
        Mock -ModuleName WinMediaDownload Get-WinMediaRedirectStep -ParameterFilter { $Uri.AbsolutePath -eq '/a.msu' } { [pscustomobject]@{ StatusCode = 302; Location = 'https://evil.example.com/x.msu' } }
        { Resolve-WinMediaDownloadUri -Uri 'https://catalog.sf.dl.delivery.mp.microsoft.com/a.msu' -AllowedHostPattern $script:pattern } | Should -Throw '*evil.example.com*'
        Should -Invoke -CommandName Get-WinMediaRedirectStep -ModuleName WinMediaDownload -ParameterFilter { $Uri.Host -eq 'evil.example.com' } -Times 0 -Exactly
    }

    It '任一跳為 http 時中止' {
        Mock -ModuleName WinMediaDownload Get-WinMediaRedirectStep -ParameterFilter { $Uri.AbsolutePath -eq '/a.msu' } { [pscustomobject]@{ StatusCode = 302; Location = 'http://download.windowsupdate.com/b.msu' } }
        { Resolve-WinMediaDownloadUri -Uri 'https://catalog.sf.dl.delivery.mp.microsoft.com/a.msu' -AllowedHostPattern $script:pattern } | Should -Throw '*https*'
    }

    It '相對 Location 以目前網址合成' {
        Mock -ModuleName WinMediaDownload Get-WinMediaRedirectStep -ParameterFilter { $Uri.AbsolutePath -eq '/a.msu' } { [pscustomobject]@{ StatusCode = 302; Location = '/b.msu' } }
        $result = Resolve-WinMediaDownloadUri -Uri 'https://catalog.sf.dl.delivery.mp.microsoft.com/a.msu' -AllowedHostPattern $script:pattern
        $result.Uri.AbsoluteUri | Should -Be 'https://catalog.sf.dl.delivery.mp.microsoft.com/b.msu'
    }

    It '超過最多跳數時中止（迴圈重導向）' {
        $loopUrl = 'https://catalog.sf.dl.delivery.mp.microsoft.com/a.msu'
        Mock -ModuleName WinMediaDownload Get-WinMediaRedirectStep -ParameterFilter { $Uri.AbsolutePath -eq '/a.msu' } { [pscustomobject]@{ StatusCode = 302; Location = $loopUrl } }
        { Resolve-WinMediaDownloadUri -Uri $loopUrl -AllowedHostPattern $script:pattern } | Should -Throw '*超過*'
    }
}

Describe 'Invoke-WinMediaDownload 使用最終網址且不自動跟隨' -Tag 'Unit' {
    BeforeEach {
        Mock -ModuleName WinMediaDownload Get-WinMediaRedirectStep { throw "未預期的探測：$($Uri.AbsoluteUri)" }
        Mock -ModuleName WinMediaDownload Invoke-WinMediaOperation { param([scriptblock]$ScriptBlock) & $ScriptBlock }
        Mock -ModuleName WinMediaDownload New-Item { }
        Mock -ModuleName WinMediaDownload Move-Item { }
        Mock -ModuleName WinMediaDownload Write-WinMediaLog { }
        Mock -ModuleName WinMediaDownload Get-WinMediaRedirectStep -ParameterFilter { $Uri.AbsolutePath -eq '/a.msu' } { [pscustomobject]@{ StatusCode = 302; Location = 'https://download.windowsupdate.com/b.msu' } }
        Mock -ModuleName WinMediaDownload Get-WinMediaRedirectStep -ParameterFilter { $Uri.AbsolutePath -eq '/b.msu' } { [pscustomobject]@{ StatusCode = 200; Location = $null } }
    }

    It 'WebRequest 以最終網址下載，並加上 -MaximumRedirection 0' {
        Mock -ModuleName WinMediaDownload Invoke-WebRequest { }
        Invoke-WinMediaDownload -Uri 'https://catalog.sf.dl.delivery.mp.microsoft.com/a.msu' -Destination (Join-Path -Path $TestDrive -ChildPath 'a.msu') -Method WebRequest -AllowedHostPattern $script:pattern -Config $script:config | Out-Null
        Should -Invoke -CommandName Invoke-WebRequest -ModuleName WinMediaDownload -ParameterFilter { $Uri -eq 'https://download.windowsupdate.com/b.msu' -and $MaximumRedirection -eq 0 } -Times 1 -Exactly
    }

    It 'curl 參數不含 -L，且使用最終網址' {
        Mock -ModuleName WinMediaDownload Invoke-WinMediaExternal { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
        Invoke-WinMediaDownload -Uri 'https://catalog.sf.dl.delivery.mp.microsoft.com/a.msu' -Destination (Join-Path -Path $TestDrive -ChildPath 'c.msu') -Method Curl -AllowedHostPattern $script:pattern -Config $script:config | Out-Null
        Should -Invoke -CommandName Invoke-WinMediaExternal -ModuleName WinMediaDownload -ParameterFilter { $ArgumentList -notcontains '-L' -and $ArgumentList -contains 'https://download.windowsupdate.com/b.msu' } -Times 1 -Exactly
    }
}
