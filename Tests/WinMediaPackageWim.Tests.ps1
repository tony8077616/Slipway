#Requires -Version 5.1

BeforeAll {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\Modules\WinMediaPackage.psm1') -Force
    $script:config = @{ LogLevel = 'Info'; OperationLog = ''; DebugTrace = 0; LogFile = (Join-Path -Path $TestDrive -ChildPath 'pkgwim.log') }
    $script:wimHeader = [byte[]](0x4D, 0x53, 0x57, 0x49, 0x4D, 0x00, 0x00, 0x00, 0x01)
    $script:cabHeader = [byte[]](0x4D, 0x53, 0x43, 0x46, 0x00, 0x00, 0x00, 0x00, 0x01)
}

Describe 'Test-WinMediaWimFile（檔頭判斷）' -Tag 'Unit' {
    It 'MSWIM 檔頭回傳 $true' {
        $path = Join-Path -Path $TestDrive -ChildPath 'wim-head.msu'
        [IO.File]::WriteAllBytes($path, $script:wimHeader)
        InModuleScope WinMediaPackage -Parameters @{ P = $path } { Test-WinMediaWimFile -Path $P } | Should -BeTrue
    }

    It 'MSCF（cab）檔頭回傳 $false' {
        $path = Join-Path -Path $TestDrive -ChildPath 'cab-head.cab'
        [IO.File]::WriteAllBytes($path, $script:cabHeader)
        InModuleScope WinMediaPackage -Parameters @{ P = $path } { Test-WinMediaWimFile -Path $P } | Should -BeFalse
    }

    It '不足 8 位元組的檔案回傳 $false（不丟例外）' {
        $path = Join-Path -Path $TestDrive -ChildPath 'short.msu'
        [IO.File]::WriteAllBytes($path, [byte[]](0x4D, 0x53))
        InModuleScope WinMediaPackage -Parameters @{ P = $path } { Test-WinMediaWimFile -Path $P } | Should -BeFalse
    }
}

Describe 'Expand-WinMediaPackageToDir（依格式選擇展開工具）' -Tag 'Unit' {
    BeforeEach {
        Mock -ModuleName WinMediaPackage Invoke-WinMediaWimlib { [pscustomobject]@{ ExitCode = 0 } }
        Mock -ModuleName WinMediaPackage Invoke-WinMediaExternal { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
    }

    It 'WIM 格式使用 wimlib extract，且不呼叫 expand.exe' {
        $path = Join-Path -Path $TestDrive -ChildPath 'kb-wim.msu'
        [IO.File]::WriteAllBytes($path, $script:wimHeader)
        $dest = Join-Path -Path $TestDrive -ChildPath 'dest-wim'
        InModuleScope WinMediaPackage -Parameters @{ P = $path; D = $dest; C = $script:config } {
            Expand-WinMediaPackageToDir -Package $P -Target $D -Config $C
        } | Should -BeTrue
        Should -Invoke -CommandName Invoke-WinMediaWimlib -ModuleName WinMediaPackage -ParameterFilter { $ArgumentList[0] -eq 'extract' -and $ArgumentList -contains ('--dest-dir=' + $dest) } -Times 1 -Exactly
        Should -Invoke -CommandName Invoke-WinMediaExternal -ModuleName WinMediaPackage -Times 0 -Exactly
    }

    It 'CAB 格式維持 expand.exe，不呼叫 wimlib' {
        $path = Join-Path -Path $TestDrive -ChildPath 'kb-cab.cab'
        [IO.File]::WriteAllBytes($path, $script:cabHeader)
        $dest = Join-Path -Path $TestDrive -ChildPath 'dest-cab'
        InModuleScope WinMediaPackage -Parameters @{ P = $path; D = $dest; C = $script:config } {
            Expand-WinMediaPackageToDir -Package $P -Target $D -Config $C
        } | Should -BeTrue
        Should -Invoke -CommandName Invoke-WinMediaExternal -ModuleName WinMediaPackage -ParameterFilter { $FilePath -eq 'expand.exe' } -Times 1 -Exactly
        Should -Invoke -CommandName Invoke-WinMediaWimlib -ModuleName WinMediaPackage -Times 0 -Exactly
    }

    It 'wimlib 失敗時回傳 $false 並記錄警告，讓呼叫端清除半成品目錄' {
        Mock -ModuleName WinMediaPackage Invoke-WinMediaWimlib { throw 'wimlib 模擬失敗' }
        $path = Join-Path -Path $TestDrive -ChildPath 'bad-wim.msu'
        [IO.File]::WriteAllBytes($path, $script:wimHeader)
        $dest = Join-Path -Path $TestDrive -ChildPath 'dest-bad'
        InModuleScope WinMediaPackage -Parameters @{ P = $path; D = $dest; C = $script:config } {
            Expand-WinMediaPackageToDir -Package $P -Target $D -Config $C
        } | Should -BeFalse
        (Get-Content -LiteralPath $script:config.LogFile -Raw -Encoding UTF8) | Should -Match 'wimlib 展開失敗'
    }
}

Describe 'Get-WinMediaPackageCategoryByContent（WIM 格式 .msu）' -Tag 'Unit' {
    It 'WIM 格式的 .msu 展開後依內容分類為 LCU（不呼叫 expand.exe 讀取複本）' {
        $pkgDir = Join-Path -Path $TestDrive -ChildPath 'pkg-wim'
        $expandDir = Join-Path -Path $TestDrive -ChildPath 'expand-wim'
        [IO.Directory]::CreateDirectory($pkgDir) | Out-Null
        [IO.Directory]::CreateDirectory($expandDir) | Out-Null
        $msu = Join-Path -Path $pkgDir -ChildPath 'Windows11.0-KB5127648-x64.msu'
        [IO.File]::WriteAllBytes($msu, $script:wimHeader)

        Mock -ModuleName WinMediaPackage Invoke-WinMediaWimlib {
            $dest = ($ArgumentList | Where-Object { $_ -like '--dest-dir=*' }) -replace '^--dest-dir=', ''
            [IO.File]::WriteAllText((Join-Path -Path $dest -ChildPath 'Windows11.0-KB5127648-x64.cab'), 'payload')
            [IO.File]::WriteAllText((Join-Path -Path $dest -ChildPath 'update.mum'), '<assembly><assemblyIdentity name="Package_for_RollupFix"/></assembly>')
            [pscustomobject]@{ ExitCode = 0 }
        }
        Mock -ModuleName WinMediaPackage Invoke-WinMediaExternal { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }

        InModuleScope WinMediaPackage -Parameters @{ P = $msu; E = $expandDir; C = $script:config } {
            Get-WinMediaPackageCategoryByContent -Package $P -ExpandDir $E -Config $C
        } | Should -Be 'LCU'
        Should -Invoke -CommandName Invoke-WinMediaWimlib -ModuleName WinMediaPackage -Times 1 -Exactly
        Should -Invoke -CommandName Invoke-WinMediaExternal -ModuleName WinMediaPackage -ParameterFilter { $ArgumentList[1] -like '*.msu' } -Times 0 -Exactly
    }
}
