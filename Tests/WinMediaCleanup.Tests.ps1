#Requires -Version 5.1

BeforeAll {
    Import-Module -Name (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'WinMediaRefresh.psd1') -Force
}

Describe 'Remove-WinMediaCleanupDir（清理失敗只記警告）' -Tag 'Unit' {
    InModuleScope WinMediaPath {
        BeforeEach {
            $script:cfg = @{ LogLevel = 'Error'; OperationLog = ''; DebugTrace = 0; LogFile = (Join-Path -Path $TestDrive -ChildPath 'cleanup.log') }
        }

        It '目錄刪不掉時只寫警告，不往外拋' {
            Mock Remove-WinMediaWorkDir { throw '存取被拒' }
            Mock Write-Warning {}
            { Remove-WinMediaCleanupDir -Path 'D:\WinMediaWork\media' -Config $script:cfg -Confirm:$false } | Should -Not -Throw
            Should -Invoke Write-Warning -Times 1 -Exactly
        }

        It '可指定自訂刪除動作（掛載目錄以 Remove-Item 清除）' {
            $dir = Join-Path -Path $TestDrive -ChildPath 'mount-x'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Remove-WinMediaCleanupDir -Path $dir -Config $script:cfg -Remove { Remove-Item -LiteralPath $Path -Recurse -Force } -Confirm:$false
            Test-Path -LiteralPath $dir | Should -BeFalse
        }
    }

    It '主流程清理段改用 Remove-WinMediaCleanupDir，且不直接呼叫 Remove-WinMediaWorkDir（AST）' {
        $mainPath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Public\Invoke-WindowsMediaRefresh.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($mainPath, [ref]$null, [ref]$null)
        $helper = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Remove-WinMediaCleanupDir' }, $true))
        $direct = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Remove-WinMediaWorkDir' }, $true))
        $helper.Count | Should -BeGreaterThan 0
        $direct.Count | Should -Be 0
    }
}
