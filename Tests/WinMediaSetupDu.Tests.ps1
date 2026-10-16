#Requires -Version 5.1

BeforeAll {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\Modules\WinMediaPackage.psm1') -Force
    $script:config = @{ LogLevel = 'Info'; OperationLog = ''; DebugTrace = 0; LogFile = (Join-Path -Path $TestDrive -ChildPath 'setupdu.log') }
    $script:cabHeader = [byte[]](0x4D, 0x53, 0x43, 0x46, 0x00, 0x00, 0x00, 0x00, 0x01)
    $script:mainText = Get-Content -LiteralPath (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Public\Invoke-WindowsMediaRefresh.ps1') -Raw
}

Describe 'Get-WinMediaPackageCategoryByContent（扁平 Setup DU cab）' -Tag 'Unit' {
    It '無 update.mum 且含 SetupPlatform.exe 與 SetupHost.exe 的 cab 分類為 SetupDU' {
        $pkgDir = Join-Path -Path $TestDrive -ChildPath 'pkg-du'
        $expandDir = Join-Path -Path $TestDrive -ChildPath 'expand-du'
        [IO.Directory]::CreateDirectory($pkgDir) | Out-Null
        [IO.Directory]::CreateDirectory($expandDir) | Out-Null
        $cab = Join-Path -Path $pkgDir -ChildPath 'Windows11.0-KB5127650-x64.cab'
        [IO.File]::WriteAllBytes($cab, $script:cabHeader)

        Mock -ModuleName WinMediaPackage Invoke-WinMediaExternal {
            $dest = $ArgumentList[2]
            [IO.File]::WriteAllText((Join-Path -Path $dest -ChildPath 'SetupPlatform.exe'), 'x')
            [IO.File]::WriteAllText((Join-Path -Path $dest -ChildPath 'SetupHost.exe'), 'x')
            [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
        }

        InModuleScope WinMediaPackage -Parameters @{ P = $cab; E = $expandDir; C = $script:config } {
            Get-WinMediaPackageCategoryByContent -Package $P -ExpandDir $E -Config $C
        } | Should -Be 'SetupDU'
    }

    It '含 update.mum（SafeOS DU）即使同時含安裝程式檔名，仍分類為 SafeOS' {
        $pkgDir = Join-Path -Path $TestDrive -ChildPath 'pkg-safeos'
        $expandDir = Join-Path -Path $TestDrive -ChildPath 'expand-safeos'
        [IO.Directory]::CreateDirectory($pkgDir) | Out-Null
        [IO.Directory]::CreateDirectory($expandDir) | Out-Null
        $cab = Join-Path -Path $pkgDir -ChildPath 'Windows11.0-KB5127654-x64.cab'
        [IO.File]::WriteAllBytes($cab, $script:cabHeader)

        Mock -ModuleName WinMediaPackage Invoke-WinMediaExternal {
            $dest = $ArgumentList[2]
            [IO.File]::WriteAllText((Join-Path -Path $dest -ChildPath 'SetupPlatform.exe'), 'x')
            [IO.File]::WriteAllText((Join-Path -Path $dest -ChildPath 'SetupHost.exe'), 'x')
            [IO.File]::WriteAllText((Join-Path -Path $dest -ChildPath 'update.mum'), '<assembly><package Package_for_SafeOSDU="1"/></assembly>')
            [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
        }

        InModuleScope WinMediaPackage -Parameters @{ P = $cab; E = $expandDir; C = $script:config } {
            Get-WinMediaPackageCategoryByContent -Package $P -ExpandDir $E -Config $C
        } | Should -Be 'SafeOS'
    }
}

Describe 'Setup DU 展開順序與目的地（文件第 26、27 列）' -Tag 'Unit' {
    It '-WhatIf 步驟清單的編號遞增（執行順序與清單一致）' {
        $nums = @([regex]::Matches($script:mainText, "(?m)^\s+'(\d+) ") | ForEach-Object { [int]$_.Groups[1].Value })
        $nums.Count | Should -BeGreaterThan 10
        $sorted = @($nums | Sort-Object)
        ($nums -join ',') | Should -Be ($sorted -join ',')
    }

    It '不再由 WinPE 覆寫媒體 setup 檔（ExtractSetup 已移除，方向改為媒體 → WinPE）' {
        $script:mainText.IndexOf("'ExtractSetup'") | Should -Be -1
    }

    It 'WinPE 同步（媒體 → 索引 2）位於 LCU 之後，避免 LCU 把檔案蓋回去' {
        $lcuPos = $script:mainText.IndexOf('-PackagePath $lcuStage')
        $syncPos = $script:mainText.IndexOf('Copy-WinMediaBootWimSources -MediaDir')
        $lcuPos | Should -BeGreaterThan -1
        $syncPos | Should -BeGreaterThan $lcuPos
    }

    It 'Setup DU 展開到暫存目錄並以 /U 規則複製進媒體，且早於 WinPE 同步（WinPE 的 setuphost 因此取得 DU 版本）' {
        $duPos = $script:mainText.IndexOf('''-F:*'', $setupDu, $duDir')
        $duCopyPos = $script:mainText.IndexOf('Copy-WinMediaSetupDuFiles -ExpandedDir $duDir -SourcesDir $sourcesDir')
        $syncPos = $script:mainText.IndexOf('Copy-WinMediaBootWimSources -MediaDir')
        $duPos | Should -BeGreaterThan -1
        $duCopyPos | Should -BeGreaterThan $duPos
        $duCopyPos | Should -BeLessThan $syncPos
    }

    It 'WinPE 同步在 boot 索引迴圈之後、Compress 之前（索引 2 已卸載，不掛載寫入）' {
        $loopPos = $script:mainText.IndexOf('foreach ($bootIndex in 1, 2)')
        $syncPos = $script:mainText.IndexOf('Copy-WinMediaBootWimSources -MediaDir')
        $compressPos = $script:mainText.IndexOf('Compress-WinMediaBootWim -BootWim')
        $syncPos | Should -BeGreaterThan $loopPos
        $syncPos | Should -BeLessThan $compressPos
    }

    It 'boot manager（第 28 列）仍在索引 2 掛載中執行（讀取 WinPE 的 bootmgfw.efi）' {
        $mountPos = $script:mainText.IndexOf("('boot-{0}' -f `$bootIndex)")
        $bootPos = $script:mainText.IndexOf("'bootmgfw.efi'")
        $mountPos | Should -BeGreaterThan -1
        $bootPos | Should -BeGreaterThan $mountPos
    }
}
