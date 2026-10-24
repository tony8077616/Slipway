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
            Remove-WinMediaCleanupDir -Path $dir -Config $script:cfg -Remove { param($p) Remove-Item -LiteralPath $p -Recurse -Force } -Confirm:$false
            Test-Path -LiteralPath $dir | Should -BeFalse
        }

        It '主流程（WinMediaRefresh 模組內）傳入的 -Remove 能刪除掛載目錄（作用域回歸）' {
            $dir = Join-Path -Path $TestDrive -ChildPath 'mount-scope'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $cfg = @{ LogLevel = 'Error'; OperationLog = ''; DebugTrace = 0; LogFile = (Join-Path -Path $TestDrive -ChildPath 'scope.log') }
            Mock -ModuleName WinMediaPath Write-Warning {}
            # 與 Public\Invoke-WindowsMediaRefresh.ps1 步驟 12 相同：scriptblock 建立於 WinMediaRefresh 模組，helper 位於 WinMediaPath
            InModuleScope WinMediaRefresh -Parameters @{ D = $dir; C = $cfg } {
                param($D, $C)
                Remove-WinMediaCleanupDir -Path $D -Config $C -Remove { param($p) Remove-Item -LiteralPath $p -Recurse -Force } -Confirm:$false
            }
            Test-Path -LiteralPath $dir | Should -BeFalse
            Should -Invoke -CommandName Write-Warning -ModuleName WinMediaPath -Times 0 -Exactly
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

    It '主流程傳給 -Remove 的 scriptblock 有 param 區塊，且不引用外部的 $Path（作用域守護）' {
        $mainPath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Public\Invoke-WindowsMediaRefresh.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($mainPath, [ref]$null, [ref]$null)
        $calls = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Remove-WinMediaCleanupDir' }, $true))
        $calls.Count | Should -BeGreaterThan 0
        foreach ($call in $calls) {
            $bind = @($call.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'Remove' })
            if ($bind.Count -eq 0) { continue }
            $block = $call.CommandElements[$call.CommandElements.IndexOf($bind[0]) + 1]
            $block | Should -BeOfType ([System.Management.Automation.Language.ScriptBlockExpressionAst])
            $block.ScriptBlock.ParamBlock | Should -Not -BeNullOrEmpty
            $outer = @($block.ScriptBlock.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.UserPath -eq 'Path' }, $true))
            $outer.Count | Should -Be 0
        }
    }
}
