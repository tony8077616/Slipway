#Requires -Version 5.1

# Step 12 修正（審查 A3／A6）：平行索引工作程序的 log 併入父程序，以及空間檢查訊息。
# 只使用 TestDrive 內的檔案；不啟動程序、不呼叫 DISM。

BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    $script:helperFile = Join-Path $script:root 'Public\Invoke-WinMediaParallelInstall.ps1'
    Import-Module -Name (Join-Path $script:root 'WinMediaRefresh.psd1') -Force

    function Invoke-InModule {
        param([scriptblock]$Script, [object[]]$ArgList = @())
        & (Get-Module -Name WinMediaRefresh) $Script @ArgList
    }

    function Write-TestText {
        param([string]$Path, [string]$Text)
        New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
        [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
    }
}

Describe 'Parallel job log merge' -Tag 'Unit' {
    It 'Parallel: 工作程序的 LogFile 與 OperationLog 依序附加到父程序的同名檔案，前面加分隔標題' {
        $dir = Join-Path $TestDrive 'merge-ok'
        $childLog = Join-Path $dir 'idx2\worker.log'
        $childOp = Join-Path $dir 'idx2\OperationLog.txt'
        $parentLog = Join-Path $dir 'parent.log'
        $parentOp = Join-Path $dir 'parent-op.txt'
        Write-TestText -Path $childLog -Text "child-log-line`r`n"
        Write-TestText -Path $childOp -Text "child-op-line`r`n"
        Write-TestText -Path $parentLog -Text "parent-first`r`n"

        Invoke-InModule { param($jc, $i, $pc) Merge-WinMediaParallelJobLog -JobConfig $jc -Index $i -Config $pc } @(
            @{ LogFile = $childLog; OperationLog = $childOp }, 2, @{ LogFile = $parentLog; OperationLog = $parentOp })

        $log = [IO.File]::ReadAllText($parentLog)
        $log | Should -Match 'parent-first'
        $log | Should -Match 'child-log-line'
        $log | Should -Match '平行索引 2'
        ([IO.File]::ReadAllText($parentOp)) | Should -Match 'child-op-line'
    }

    It 'Parallel: 來源不存在或為空、父程序未設定 OperationLog 時略過，不拋出例外' {
        $dir = Join-Path $TestDrive 'merge-skip'
        $parentLog = Join-Path $dir 'parent.log'
        $parentOp = Join-Path $dir 'parent-op.txt'
        $emptyLog = Join-Path $dir 'idx3\worker.log'
        Write-TestText -Path $emptyLog -Text ''

        {
            Invoke-InModule { param($jc, $i, $pc) Merge-WinMediaParallelJobLog -JobConfig $jc -Index $i -Config $pc } @(
                @{ LogFile = (Join-Path $dir 'missing\worker.log'); OperationLog = (Join-Path $dir 'missing\OperationLog.txt') }, 3, @{ LogFile = $parentLog; OperationLog = '' })
            Invoke-InModule { param($jc, $i, $pc) Merge-WinMediaParallelJobLog -JobConfig $jc -Index $i -Config $pc } @(
                @{ LogFile = $emptyLog; OperationLog = '' }, 3, @{ LogFile = $parentLog; OperationLog = '' })
        } | Should -Not -Throw

        Test-Path -LiteralPath $parentLog | Should -BeFalse
        Test-Path -LiteralPath $parentOp | Should -BeFalse
    }

    It 'Parallel: 併入位於 Invoke-WinMediaParallelRun 的 finally 區塊內，因此失敗的索引也會併入（AST）' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:helperFile, [ref]$null, [ref]$null)
        $tries = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.TryStatementAst] }, $true))
        $hit = @($tries | Where-Object { @($_.Body.FindAll({ param($c) $c -is [System.Management.Automation.Language.CommandAst] -and $c.GetCommandName() -eq 'Invoke-WinMediaParallelRun' }, $true)).Count -gt 0 })
        $hit.Count | Should -Be 1
        @($hit[0].Finally.FindAll({ param($c) $c -is [System.Management.Automation.Language.CommandAst] -and $c.GetCommandName() -eq 'Merge-WinMediaParallelJobLog' }, $true)).Count | Should -Be 1
    }

    It 'Parallel: 空間檢查訊息標明估計未實測、不含更新檔解壓縮展開，且無法讀取的可用空間有明確寫法' {
        $src = [IO.File]::ReadAllText($script:helperFile)
        $src | Should -Match '未實測，不含更新檔解壓縮展開'
        $src | Should -Match '無法讀取'
        $src | Should -Match '可用空間可能不足'
    }
}
