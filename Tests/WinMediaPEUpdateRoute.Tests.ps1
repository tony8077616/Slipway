#Requires -Version 5.1

BeforeAll {
    $script:pipelineFile = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..\Public\Invoke-WindowsMediaRefresh.ps1')).Path
    $script:defaults = Import-PowerShellDataFile -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..\Config\Default.psd1')
    $tokens = $null
    $parseErrors = $null
    $script:ast = [System.Management.Automation.Language.Parser]::ParseFile($script:pipelineFile, [ref]$tokens, [ref]$parseErrors)

    # 回傳包住指定 PackagePath 之 Add-WindowsPackage 的最近一層 if 條件文字（找不到時為空字串）
    function Get-AddPackageGuard {
        param([string]$PackagePathVariable)
        $pattern = '-PackagePath \$' + [regex]::Escape($PackagePathVariable) + '\b'
        $calls = $script:ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Add-WindowsPackage' -and
                $node.Extent.Text -match $pattern
            }, $true)
        foreach ($call in $calls) {
            $node = $call.Parent
            while ($node -and $node -isnot [System.Management.Automation.Language.IfStatementAst]) { $node = $node.Parent }
            [pscustomobject]@{ Line = $call.Extent.StartLineNumber; Guard = if ($node) { $node.Clauses[0].Item1.Extent.Text } else { '' } }
        }
    }
}

Describe 'WinPEUpdate 路線選項（SafeOS 為預設；Lcu 為 convert-UUP 路線）' -Tag 'Unit' {
    It 'Default.psd1 的預設值為 SafeOS' {
        $script:defaults.WinPEUpdate | Should -Be 'SafeOS'
    }

    It 'SafeOS DU 只在 WinPEUpdate 為 SafeOS 時套用到 WinRE' {
        $calls = @(Get-AddPackageGuard -PackagePathVariable 'safeOs')
        $calls.Count | Should -Be 1
        $calls[0].Guard | Should -Match "WinPEUpdate -eq 'SafeOS'"
    }

    It '最新 LCU（cumulative.Target）只在 WinPEUpdate 為 Lcu 時套用到開機索引' {
        $calls = @(Get-AddPackageGuard -PackagePathVariable 'cumulative.Target')
        $calls.Count | Should -BeGreaterThan 0
        foreach ($call in $calls) { $call.Guard | Should -Match "WinPEUpdate -eq 'Lcu'" }
    }

    It '設定檔缺少 WinPEUpdate 鍵時於 Clone 後補上 SafeOS' {
        $source = Get-Content -LiteralPath $script:pipelineFile -Raw
        $source | Should -Match 'ContainsKey\(.WinPEUpdate.\)'
    }

    It '驗證拒絕未知的 WinPEUpdate 值' {
        $source = Get-Content -LiteralPath $script:pipelineFile -Raw
        $source | Should -Match "WinPEUpdate -notin 'SafeOS', 'Lcu'"
    }
}
