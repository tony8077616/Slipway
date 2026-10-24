#Requires -Version 5.1

BeforeAll {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\Modules\WinMediaIndexInfo.psm1') -Force
    $script:full = @{
        DisplayVersion = '26H2'; Build = '26300'; Revision = '9807'; BranchUpper = 'GE_RELEASE'
        Edition = 'CLIENTMULTI'; Arch = 'amd64'; BuildType = 'fre'; Languages = @('zh-tw'); Timestamp = '20261021-081543'
    }
}

Describe 'New-WinMediaOutputName' -Tag 'Unit' {
    It '完整輸入組出目標檔名' {
        New-WinMediaOutputName @script:full | Should -BeExactly 'WinMedia_26H2_26300.9807.GE_RELEASE_CLIENTMULTI_X64FRE_ZH-TW_20261021-081543.iso'
    }

    It '缺 DisplayVersion 時省略該段' {
        $p = $script:full.Clone(); $p.DisplayVersion = ''
        New-WinMediaOutputName @p | Should -BeExactly 'WinMedia_26300.9807.GE_RELEASE_CLIENTMULTI_X64FRE_ZH-TW_20261021-081543.iso'
    }

    It '單一版本用 CLIENT 加 EditionId' {
        $p = $script:full.Clone(); $p.Edition = 'CLIENTPROFESSIONAL'
        New-WinMediaOutputName @p | Should -BeExactly 'WinMedia_26H2_26300.9807.GE_RELEASE_CLIENTPROFESSIONAL_X64FRE_ZH-TW_20261021-081543.iso'
    }

    It 'arm64 寫成 ARM64FRE' {
        $p = $script:full.Clone(); $p.Arch = 'arm64'
        New-WinMediaOutputName @p | Should -BeExactly 'WinMedia_26H2_26300.9807.GE_RELEASE_CLIENTMULTI_ARM64FRE_ZH-TW_20261021-081543.iso'
    }

    It '多語言寫 MULTI，沒有語言則省略' {
        $p = $script:full.Clone(); $p.Languages = @('zh-tw', 'en-us')
        New-WinMediaOutputName @p | Should -BeExactly 'WinMedia_26H2_26300.9807.GE_RELEASE_CLIENTMULTI_X64FRE_MULTI_20261021-081543.iso'
        $p.Languages = @()
        New-WinMediaOutputName @p | Should -BeExactly 'WinMedia_26H2_26300.9807.GE_RELEASE_CLIENTMULTI_X64FRE_20261021-081543.iso'
    }

    It '不符字元規則的段落被丟棄，缺 Build 退回舊格式' {
        $p = $script:full.Clone(); $p.DisplayVersion = 'bad/ver'
        New-WinMediaOutputName @p | Should -BeExactly 'WinMedia_26300.9807.GE_RELEASE_CLIENTMULTI_X64FRE_ZH-TW_20261021-081543.iso'
        New-WinMediaOutputName -Timestamp '20261021-081543' | Should -BeExactly 'WinMedia_20261021-081543.iso'
    }
}

Describe 'ConvertFrom-WinMediaRegQuery' -Tag 'Unit' {
    It '解析 reg query 固定文字，UBR 十六進位轉十進位' {
        $text = @(
            'HKEY_LOCAL_MACHINE\WinMedia_x\Microsoft\Windows NT\CurrentVersion',
            '    DisplayVersion    REG_SZ    26H2',
            '    UBR    REG_DWORD    0x264f',
            '    BuildBranch    REG_SZ    ge_release',
            '    CurrentBuild    REG_SZ    26300',
            '    BuildLabEx    REG_SZ    26100.1.amd64fre.ge_release.240331-1435'
        )
        $r = ConvertFrom-WinMediaRegQuery -Text $text
        $r.UBR | Should -Be 9807
        $r.DisplayVersion | Should -Be '26H2'
        $r.BuildBranch | Should -Be 'ge_release'
        $r.CurrentBuild | Should -Be '26300'
    }

    It '空輸入不拋錯，欄位為 null' {
        $r = ConvertFrom-WinMediaRegQuery -Text @()
        $r.UBR | Should -BeNullOrEmpty
        $r.DisplayVersion | Should -BeNullOrEmpty
    }
}

Describe '輸出檔名接線（主流程）' -Tag 'Unit' {
    It '$nameArgs 的賦值是獨立語句，且位於 New-WinMediaOutputName 呼叫之前' {
        $mainPath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Public\Invoke-WindowsMediaRefresh.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($mainPath, [ref]$null, [ref]$null)
        $assign = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$nameArgs' }, $true))
        $call = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'New-WinMediaOutputName' }, $true))
        $assign.Count | Should -BeGreaterThan 0
        $call.Count | Should -Be 1
        $assign[0].Extent.StartOffset | Should -BeLessThan $call[0].Extent.StartOffset
    }
}

Describe 'Get-WinMediaBuildInfo 失敗時降級' -Tag 'Unit' {
    It '掛載點不存在時不拋例外，回傳空值' {
        $cfg = @{ LogLevel = 'Info'; LogFile = (Join-Path -Path $TestDrive -ChildPath 'wm.log'); OperationLog = (Join-Path -Path $TestDrive -ChildPath 'op.txt'); DebugTrace = 0; DismProvider = 'Inbox'; DismLogLevel = 'WarningsInfo'; DismUseWindowsPowerShell = $true }
        $missing = Join-Path -Path $TestDrive -ChildPath 'none'
        { Get-WinMediaBuildInfo -MountPath $missing -WorkDir $TestDrive -Config $cfg } | Should -Not -Throw
        Get-WinMediaBuildInfo -MountPath $missing -WorkDir $TestDrive -Config $cfg | Should -BeNullOrEmpty
    }

    It '載入失敗時仍嘗試卸載、清除暫存資料夾，且複製 LOG1 與 LOG2' {
        $mount = Join-Path -Path $TestDrive -ChildPath 'mnt-fail'
        $cfgDir = Join-Path -Path $mount -ChildPath 'Windows\System32\config'
        New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path -Path $cfgDir -ChildPath 'SOFTWARE') -Value 'hive'
        $log1 = Join-Path -Path $cfgDir -ChildPath 'SOFTWARE.LOG1'
        Set-Content -LiteralPath $log1 -Value 'log1'
        [System.IO.File]::SetAttributes($log1, 'Hidden')
        $work = Join-Path -Path $TestDrive -ChildPath 'work-fail'
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $cfg = @{ LogLevel = 'Info'; LogFile = (Join-Path -Path $TestDrive -ChildPath 'wm-fail.log'); OperationLog = (Join-Path -Path $TestDrive -ChildPath 'op.txt'); DebugTrace = 0; DismProvider = 'Inbox'; DismLogLevel = 'WarningsInfo'; DismUseWindowsPowerShell = $true }
        Mock -ModuleName WinMediaIndexInfo Invoke-WinMediaExternal {
            param($FilePath, $ArgumentList, $Config)
            $null = $FilePath, $Config
            Add-Content -LiteralPath (Join-Path -Path $TestDrive -ChildPath 'calls-fail.txt') -Value $ArgumentList[0]
            if ($ArgumentList[0] -eq 'load') {
                $copy = $ArgumentList[2]
                Set-Content -LiteralPath (Join-Path -Path $TestDrive -ChildPath 'seen-fail.txt') -Value ('{0}|{1}|{2}' -f (Test-Path -LiteralPath $copy), (Test-Path -LiteralPath ($copy + '.LOG1')), (Test-Path -LiteralPath ($copy + '.LOG2')))
                throw 'mock wrapper'
            }
            [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'mock' }
        }
        Get-WinMediaBuildInfo -MountPath $mount -WorkDir $work -Config $cfg | Should -BeNullOrEmpty
        (Get-Content -LiteralPath (Join-Path -Path $TestDrive -ChildPath 'seen-fail.txt') -Raw).Trim() | Should -BeExactly 'True|True|False'
        (Get-Content -LiteralPath (Join-Path -Path $TestDrive -ChildPath 'calls-fail.txt')) -join ',' | Should -BeExactly 'load,unload'
        (Get-Content -LiteralPath (Join-Path -Path $TestDrive -ChildPath 'wm-fail.log') -Raw) | Should -Not -Match 'reg unload'
        @(Get-ChildItem -LiteralPath $work -Force).Count | Should -Be 0
    }

    It '成功路徑：讀出版本欄位，依序 load、query、unload，並清除暫存資料夾' {
        $mount = Join-Path -Path $TestDrive -ChildPath 'mnt-ok'
        $cfgDir = Join-Path -Path $mount -ChildPath 'Windows\System32\config'
        New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path -Path $cfgDir -ChildPath 'SOFTWARE') -Value 'hive'
        foreach ($name in 'SOFTWARE.LOG1', 'SOFTWARE.LOG2') {
            $f = Join-Path -Path $cfgDir -ChildPath $name
            Set-Content -LiteralPath $f -Value 'log'
            [System.IO.File]::SetAttributes($f, 'Hidden')
        }
        $work = Join-Path -Path $TestDrive -ChildPath 'work-ok'
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $cfg = @{ LogLevel = 'Info'; LogFile = (Join-Path -Path $TestDrive -ChildPath 'wm.log'); OperationLog = (Join-Path -Path $TestDrive -ChildPath 'op.txt'); DebugTrace = 0; DismProvider = 'Inbox'; DismLogLevel = 'WarningsInfo'; DismUseWindowsPowerShell = $true }
        Mock -ModuleName WinMediaIndexInfo Invoke-WinMediaExternal {
            param($FilePath, $ArgumentList, $Config)
            $null = $FilePath, $Config
            Add-Content -LiteralPath (Join-Path -Path $TestDrive -ChildPath 'calls-ok.txt') -Value $ArgumentList[0]
            if ($ArgumentList[0] -eq 'load') {
                $copy = $ArgumentList[2]
                Set-Content -LiteralPath (Join-Path -Path $TestDrive -ChildPath 'seen-ok.txt') -Value ('{0}|{1}|{2}' -f (Test-Path -LiteralPath $copy), (Test-Path -LiteralPath ($copy + '.LOG1')), (Test-Path -LiteralPath ($copy + '.LOG2')))
            }
            if ($ArgumentList[0] -eq 'query') {
                return [pscustomobject]@{ ExitCode = 0; StdOut = "HKEY_LOCAL_MACHINE\WinMedia_x\Microsoft\Windows NT\CurrentVersion`r`n    DisplayVersion    REG_SZ    26H2`r`n    CurrentBuild    REG_SZ    26300"; StdErr = '' }
            }
            [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
        }
        $r = Get-WinMediaBuildInfo -MountPath $mount -WorkDir $work -Config $cfg
        $r.DisplayVersion | Should -BeExactly '26H2'
        $r.CurrentBuild | Should -BeExactly '26300'
        (Get-Content -LiteralPath (Join-Path -Path $TestDrive -ChildPath 'seen-ok.txt') -Raw).Trim() | Should -BeExactly 'True|True|True'
        (Get-Content -LiteralPath (Join-Path -Path $TestDrive -ChildPath 'calls-ok.txt')) -join ',' | Should -BeExactly 'load,query,unload'
        @(Get-ChildItem -LiteralPath $work -Force).Count | Should -Be 0
    }
}

Describe '索引數不一致時的檔名警告（主流程）' -Tag 'Unit' {
    It '更新索引數少於映像索引數時記 Warning' {
        $mainPath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Public\Invoke-WindowsMediaRefresh.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($mainPath, [ref]$null, [ref]$null)
        $ifs = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -match '^\$targets\.Count -lt @\(\$images\)\.Count$' }, $true))
        $ifs.Count | Should -Be 1
        $warn = @($ifs[0].Clauses[0].Item2.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Write-WinMediaLog' -and $n.Extent.Text -match '-Level Warning' }, $true))
        $warn.Count | Should -Be 1
    }
}
