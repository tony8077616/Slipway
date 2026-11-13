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

    It '巢狀 cab 展開失敗時移除半成品目錄並回傳 Unknown，下次重跑會重新展開' {
        $pkgDir = Join-Path -Path $TestDrive -ChildPath 'pkg-nested-fail'
        $expandDir = Join-Path -Path $TestDrive -ChildPath 'expand-nested-fail'
        [IO.Directory]::CreateDirectory($pkgDir) | Out-Null
        [IO.Directory]::CreateDirectory($expandDir) | Out-Null
        $msu = Join-Path -Path $pkgDir -ChildPath 'Windows11.0-KB9999999-x64.msu'
        [IO.File]::WriteAllBytes($msu, $script:cabHeader)
        $target = Join-Path -Path $expandDir -ChildPath 'Windows11.0-KB9999999-x64.msu'

        Mock -ModuleName WinMediaPackage Expand-WinMediaPackageToDir {
            if ($Package -notlike '*.msu') { return $false }
            [IO.File]::WriteAllText((Join-Path -Path $Target -ChildPath 'inner.cab'), 'payload')
            return $true
        }

        InModuleScope WinMediaPackage -Parameters @{ P = $msu; E = $expandDir; C = $script:config } {
            Get-WinMediaPackageCategoryByContent -Package $P -ExpandDir $E -Config $C
        } | Should -Be 'Unknown'
        Test-Path -LiteralPath $target | Should -BeFalse
        InModuleScope WinMediaPackage -Parameters @{ P = $msu; E = $expandDir; C = $script:config } {
            Get-WinMediaPackageCategoryByContent -Package $P -ExpandDir $E -Config $C
        } | Out-Null
        Should -Invoke -CommandName Expand-WinMediaPackageToDir -ModuleName WinMediaPackage -ParameterFilter { $Package -like '*.msu' } -Times 2 -Exactly
    }
}

Describe 'Get-WinMediaPackageVersion（Rollup／SSU 的 identity 版本）' -Tag 'Unit' {
    BeforeEach {
        $script:verRoot = Join-Path -Path $TestDrive -ChildPath ('ver-' + [guid]::NewGuid().ToString('N'))
        $script:verExpand = Join-Path -Path $script:verRoot -ChildPath 'expand'
        [IO.Directory]::CreateDirectory($script:verExpand) | Out-Null
    }

    It 'CombinedCU 內的 SSU：從 nested-<cab> 目錄的 update.mum 讀出 Package_for_ServicingStack 版本' {
        $msuDir = Join-Path -Path $script:verExpand -ChildPath 'Windows11.0-KB5127936-x64.msu'
        $nested = Join-Path -Path $msuDir -ChildPath 'nested-SSU-26100.9815-x64.cab'
        [IO.Directory]::CreateDirectory($nested) | Out-Null
        [IO.File]::WriteAllText((Join-Path -Path $nested -ChildPath 'update.mum'), '<assembly><assemblyIdentity name="Package_for_ServicingStack_9815" version="26100.9815.1.3" processorArchitecture="amd64" /></assembly>')
        $pkg = Join-Path -Path $msuDir -ChildPath 'SSU-26100.9815-x64.cab'
        Get-WinMediaPackageVersion -Package $pkg -ExpandDir $script:verExpand -Kind 'ServicingStack' | Should -Be ([version]'26100.9815.1.3')
    }

    It 'LCU msu：從 ExpandDir 下同名目錄的 update.mum 讀出 Package_for_RollupFix 版本' {
        $msu = Join-Path -Path $script:verRoot -ChildPath 'Windows11.0-KB5127936-x64.msu'
        $leafDir = Join-Path -Path $script:verExpand -ChildPath 'Windows11.0-KB5127936-x64.msu'
        [IO.Directory]::CreateDirectory($leafDir) | Out-Null
        [IO.File]::WriteAllText((Join-Path -Path $leafDir -ChildPath 'update.mum'), '<assembly><assemblyIdentity name="Package_for_RollupFix" version="26100.9818.1.42" processorArchitecture="amd64" /></assembly>')
        Get-WinMediaPackageVersion -Package $msu -ExpandDir $script:verExpand -Kind 'RollupFix' | Should -Be ([version]'26100.9818.1.42')
    }

    It '找不到對應 identity 時回傳 $null' {
        $msu = Join-Path -Path $script:verRoot -ChildPath 'Windows11.0-KB1111111-x64.msu'
        Get-WinMediaPackageVersion -Package $msu -ExpandDir $script:verExpand -Kind 'RollupFix' | Should -BeNullOrEmpty
    }
}

Describe 'Get-WinMediaMumXVersion（LCU msu 內的 MumX 容器版本）' -Tag 'Unit' {
    It '有 MUMX 檔頭且 byte[215] 為 ''1'' 時為 v1' {
        $path = Join-Path -Path $TestDrive -ChildPath 'mumx-v1.mumx.esd'
        $bytes = New-Object -TypeName byte[] -ArgumentList 216
        $bytes[208] = 0x4D; $bytes[209] = 0x55; $bytes[210] = 0x4D; $bytes[211] = 0x58
        $bytes[215] = 1
        [IO.File]::WriteAllBytes($path, $bytes)
        InModuleScope WinMediaPackage -Parameters @{ P = $path } { Get-WinMediaMumXVersion -Path $P } | Should -Be 1
    }

    It '有 MUMX 檔頭但 byte[215] 不含 ''1'' 時為 v2' {
        $path = Join-Path -Path $TestDrive -ChildPath 'mumx-v2.mumx.esd'
        $bytes = New-Object -TypeName byte[] -ArgumentList 216
        $bytes[208] = 0x4D; $bytes[209] = 0x55; $bytes[210] = 0x4D; $bytes[211] = 0x58
        $bytes[215] = 50
        [IO.File]::WriteAllBytes($path, $bytes)
        InModuleScope WinMediaPackage -Parameters @{ P = $path } { Get-WinMediaMumXVersion -Path $P } | Should -Be 2
    }

    It '沒有 MUMX 檔頭的 .mumx.??? 檔視為 v1（convert-UUP 2393 的 else 分支）' {
        $path = Join-Path -Path $TestDrive -ChildPath 'nomagic.mumx.esd'
        [IO.File]::WriteAllBytes($path, (New-Object -TypeName byte[] -ArgumentList 216))
        InModuleScope WinMediaPackage -Parameters @{ P = $path } { Get-WinMediaMumXVersion -Path $P } | Should -Be 1
    }

    It '無後綴的 .mumx 依 byte[7] 判斷：為 1 則 v1，否則 v2（convert-UUP 2397）' {
        $p1 = Join-Path -Path $TestDrive -ChildPath 'plain1.mumx'
        $p2 = Join-Path -Path $TestDrive -ChildPath 'plain2.mumx'
        $b1 = New-Object -TypeName byte[] -ArgumentList 16; $b1[7] = 1
        $b2 = New-Object -TypeName byte[] -ArgumentList 16; $b2[7] = 0
        [IO.File]::WriteAllBytes($p1, $b1)
        [IO.File]::WriteAllBytes($p2, $b2)
        InModuleScope WinMediaPackage -Parameters @{ P = $p1 } { Get-WinMediaMumXVersion -Path $P } | Should -Be 1
        InModuleScope WinMediaPackage -Parameters @{ P = $p2 } { Get-WinMediaMumXVersion -Path $P } | Should -Be 2
    }
}

Describe 'Get-WinMediaPackageCategoryByContent（Setup DU 的 defender 條件）' -Tag 'Unit' {
    BeforeEach {
        $script:setupDuRoot = Join-Path -Path $TestDrive -ChildPath ('setupdu-' + [guid]::NewGuid().ToString('N'))
        $script:setupDuPkgDir = Join-Path -Path $script:setupDuRoot -ChildPath 'pkg'
        $script:setupDuExpand = Join-Path -Path $script:setupDuRoot -ChildPath 'expand'
        [IO.Directory]::CreateDirectory($script:setupDuPkgDir) | Out-Null
        [IO.Directory]::CreateDirectory($script:setupDuExpand) | Out-Null
        $script:setupDuMsu = Join-Path -Path $script:setupDuPkgDir -ChildPath 'Windows11.0-KB5127650-x64.msu'
        [IO.File]::WriteAllBytes($script:setupDuMsu, $script:cabHeader)
        $script:setupDuTarget = Join-Path -Path $script:setupDuExpand -ChildPath 'Windows11.0-KB5127650-x64.msu'
        [IO.Directory]::CreateDirectory($script:setupDuTarget) | Out-Null
        [IO.File]::WriteAllText((Join-Path -Path $script:setupDuTarget -ChildPath 'SetupPlatform.exe'), 'x')
        [IO.File]::WriteAllText((Join-Path -Path $script:setupDuTarget -ChildPath 'SetupHost.exe'), 'x')
    }

    It '沒有 update.mum 且沒有 defender xml 的 SetupPlatform／SetupHost 套件判為 SetupDU' {
        InModuleScope WinMediaPackage -Parameters @{ P = $script:setupDuMsu; E = $script:setupDuExpand; C = $script:config } {
            Get-WinMediaPackageCategoryByContent -Package $P -ExpandDir $E -Config $C
        } | Should -Be 'SetupDU'
    }

    It '同樣的套件若含 defender xml 則不判為 SetupDU' {
        [IO.File]::WriteAllText((Join-Path -Path $script:setupDuTarget -ChildPath 'MpDefender.xml'), '<x/>')
        InModuleScope WinMediaPackage -Parameters @{ P = $script:setupDuMsu; E = $script:setupDuExpand; C = $script:config } {
            Get-WinMediaPackageCategoryByContent -Package $P -ExpandDir $E -Config $C
        } | Should -Be 'Unknown'
    }
}
