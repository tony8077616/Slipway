#Requires -Version 5.1

# Step 12c 登記（使用者於 2026-11-04 同意登記 WorkDir\parallel）：平行分支內登記並守衛，序列分支不變（AST，靜態）。
# 既有的路由 AST 測試在 WinMediaParallelInstall.Tests.ps1；本檔只鎖登記與守衛，不執行 DISM。

BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    $script:refreshFile = Join-Path $script:root 'Public\Invoke-WindowsMediaRefresh.ps1'
    $script:ast = [System.Management.Automation.Language.Parser]::ParseFile($script:refreshFile, [ref]$null, [ref]$null)
    $script:ifStmt = $script:ast.Find({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -match '\$parallelCount\s+-gt\s+1' }, $true)
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

    It 'Parallel: the branch guards SourceIso and OutputDir against the parallel root before registering' {
        $body = $script:ifStmt.Clauses[0].Item2.Extent.Text
        $guardIdx = $body.IndexOf('Test-PathWithin')
        $regIdx = $body.IndexOf('Use-WinMediaWorkDir')
        ($guardIdx -ge 0 -and $guardIdx -lt $regIdx) | Should -BeTrue -Because 'the guards must run before the folder is registered'
        ([regex]::Matches($body, 'Test-PathWithin[^\r\n]*\$parallelDir')).Count | Should -BeGreaterOrEqual 2
    }

    It 'Parallel: the serial else branch does not mention the parallel root' {
        $script:ifStmt.ElseClause | Should -Not -BeNullOrEmpty
        $script:ifStmt.ElseClause.Extent.Text | Should -Not -Match 'parallel'
    }
}
