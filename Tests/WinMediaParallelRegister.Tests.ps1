#Requires -Version 5.1

# Step 12c 登記（使用者於 2026-11-04 同意登記 WorkDir\parallel）：平行分支內登記並守衛，序列分支不變（AST，靜態）。
# 既有的路由 AST 測試在 WinMediaParallelInstall.Tests.ps1；本檔只鎖登記與守衛，不執行 DISM。

BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    $script:refreshFile = Join-Path $script:root 'Public\Invoke-WindowsMediaRefresh.ps1'
    $script:ast = [System.Management.Automation.Language.Parser]::ParseFile($script:refreshFile, [ref]$null, [ref]$null)
    $script:ifStmt = $script:ast.Find({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -match '\$parallelCount\s+-gt\s+1' }, $true)
}

Describe 'Parallel: the path guards run early, before any WorkDir registration (AST, Q3 項目 4)' -Tag 'Unit' {
    BeforeAll {
        $script:earlyIfs = @($script:ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -match 'MountParallelCount\s+-gt\s+1' }, $true))
    }

    It 'Parallel: an early guard keyed on MountParallelCount -gt 1 exists and tests the parallel root' {
        $script:earlyIfs.Count | Should -BeGreaterOrEqual 1
        $script:earlyIfs[0].Clauses[0].Item2.Extent.Text | Should -Match 'Test-PathWithin'
    }

    It 'Parallel: the early guard comes before the first Use-WinMediaWorkDir call' {
        $uses = @($script:ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Use-WinMediaWorkDir' }, $true) | Sort-Object { $_.Extent.StartOffset })
        $uses.Count | Should -BeGreaterThan 0
        $script:earlyIfs.Count | Should -BeGreaterOrEqual 1
        $script:earlyIfs[0].Extent.StartOffset | Should -BeLessThan $uses[0].Extent.StartOffset
    }

    It 'Parallel: the early guard covers <Expr>' -ForEach @(
        @{ Expr = 'SourceIso' }
        @{ Expr = 'Config.OutputDir' }
        @{ Expr = 'mountDir' }
        @{ Expr = 'Config.LogDir' }
        @{ Expr = 'Config.LogFile' }
        @{ Expr = 'Config.OperationLog' }
        @{ Expr = 'Config.ScratchDirectory' }
    ) {
        $script:earlyIfs[0].Clauses[0].Item2.Extent.Text | Should -Match ('Test-PathWithin\s+-Child\s+\$' + [regex]::Escape($Expr) + '\s+-Parent\s+\$earlyParallelDir\b')
    }
}

Describe 'Parallel: refresh registers WorkDir\parallel only inside the parallel branch (AST)' -Tag 'Unit' {
    It 'Parallel: the $parallelCount -gt 1 branch exists' {
        $script:ifStmt | Should -Not -BeNullOrEmpty
    }

    It 'Parallel: the branch defines $parallelDir and registers it with Use-WinMediaWorkDir before the parallel install call' {
        $body = $script:ifStmt.Clauses[0].Item2.Extent.Text
        $body | Should -Match '\$parallelDir\s*='
        $body | Should -Match 'Use-WinMediaWorkDir'
        $body | Should -Match "'UseWorkDir'"
        $i = $body.IndexOf('Use-WinMediaWorkDir')
        $j = $body.IndexOf('Invoke-WinMediaParallelInstall')
        ($i -ge 0 -and $j -gt $i) | Should -BeTrue -Because 'registration must precede the parallel install'
    }

    It 'Parallel: the same $parallelDir is passed as -ParallelRoot' {
        $body = $script:ifStmt.Clauses[0].Item2.Extent.Text
        $body | Should -Match '-ParallelRoot\s+\(?\s*Join-Path[^\n]*\$parallelDir|-ParallelRoot\s+\$parallelDir'
    }

    It 'Parallel: the branch guards <Expr> against the parallel root before registering' -ForEach @(
        @{ Expr = '$SourceIso' }
        @{ Expr = '$Config.OutputDir' }
        @{ Expr = '$mountDir' }
        @{ Expr = '$Config.LogDir' }
        @{ Expr = '$Config.LogFile' }
        @{ Expr = '$Config.OperationLog' }
        @{ Expr = '$Config.ScratchDirectory' }
    ) {
        $body = $script:ifStmt.Clauses[0].Item2.Extent.Text
        $pattern = 'Test-PathWithin[^\r\n]*-Child\s+' + [regex]::Escape($Expr) + '\s+-Parent\s+\$parallelDir'
        $m = [regex]::Match($body, $pattern)
        $m.Success | Should -BeTrue -Because "no guard for $Expr against `$parallelDir"
        $m.Index | Should -BeLessThan $body.IndexOf('Use-WinMediaWorkDir') -Because "the $Expr guard must run before the folder is registered"
    }

    It 'Parallel: the serial else branch does not mention the parallel root' {
        $script:ifStmt.ElseClause | Should -Not -BeNullOrEmpty
        $script:ifStmt.ElseClause.Extent.Text | Should -Not -Match 'parallel'
    }
}
