#Requires -Version 5.1

BeforeAll {
    Import-Module -Name (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'WinMediaRefresh.psd1') -Force
    $script:mainPath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Public\Invoke-WindowsMediaRefresh.ps1'
    $script:ast = [System.Management.Automation.Language.Parser]::ParseFile($script:mainPath, [ref]$null, [ref]$null)
}

Describe 'Resolve-WinMediaResetBaseOS（ResetBaseOS 必須為布林）' -Tag 'Unit' {
    InModuleScope WinMediaUpdate {
        It '字串 ''false'' 直接中止，不靜默轉為 $true' {
            { Resolve-WinMediaResetBaseOS -Config @{ ResetBaseOS = 'false' } } | Should -Throw '*必須*布林*'
        }

        It '布林 $true 與 $false 原樣回傳' {
            Resolve-WinMediaResetBaseOS -Config @{ ResetBaseOS = $true } | Should -BeTrue
            Resolve-WinMediaResetBaseOS -Config @{ ResetBaseOS = $false } | Should -BeFalse
        }

        It '缺鍵時視為 $false（預設行為不變）' {
            Resolve-WinMediaResetBaseOS -Config @{ } | Should -BeFalse
        }
    }
}

Describe 'ResetBaseOS 接線（AST）' -Tag 'Unit' {
    It '主流程以 Resolve-WinMediaResetBaseOS 取得設定值' {
        $calls = @($script:ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Resolve-WinMediaResetBaseOS' }, $true))
        $calls.Count | Should -Be 1
    }

    It 'install.wim 的 cleanup（Repair-WindowsImage）以 -ResetBase:$resetBaseOS 傳入' {
        $repairs = @($script:ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Repair-WindowsImage' }, $true))
        $wired = @($repairs | Where-Object {
            $p = @($_.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'ResetBase' })
            $p.Count -eq 1 -and $p[0].Argument -is [System.Management.Automation.Language.VariableExpressionAst] -and $p[0].Argument.VariablePath.UserPath -eq 'resetBaseOS'
        })
        $wired.Count | Should -Be 1
    }

    It 'WinRE 的 cleanup 仍由 ResetBase 控制，不受 ResetBaseOS 影響' {
        $repairs = @($script:ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Repair-WindowsImage' }, $true))
        $winre = @($repairs | Where-Object { $_.Extent.Text -match '\$Config\.ResetBase\b(?!OS)' })
        $winre.Count | Should -Be 1
    }
}