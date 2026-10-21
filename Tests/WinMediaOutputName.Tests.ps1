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
        New-WinMediaOutputName @p | Should -Not -Match 'bad'
        New-WinMediaOutputName -Timestamp '20261021-081543' | Should -Be 'WinMedia_20261021-081543.iso'
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
}
