#Requires -Version 5.1

BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    Import-Module -Name (Join-Path -Path $script:root -ChildPath 'Modules\WinMediaPath.psm1') -Force
    $script:entry = Join-Path -Path $script:root -ChildPath 'Update-WindowsMedia.ps1'
}

Describe 'Get-WinMediaRelaunchArgument（提權重新啟動引數）' -Tag 'Unit' {
    It '固定帶 -NoProfile、-ExecutionPolicy Bypass 與 -File' {
        $relaunch = Get-WinMediaRelaunchArgument -ScriptPath 'D:\Slipway\Update-WindowsMedia.ps1' -Bound @{}
        $relaunch | Should -Contain '-NoProfile'
        $relaunch | Should -Contain '-ExecutionPolicy'
        $relaunch | Should -Contain 'Bypass'
        $relaunch | Should -Contain '-File'
    }

    It 'switch 以 -Name:$true 形式傳遞' {
        $relaunch = Get-WinMediaRelaunchArgument -ScriptPath 'D:\Slipway\Update-WindowsMedia.ps1' -Bound @{ Force = [System.Management.Automation.SwitchParameter]$true }
        $relaunch | Should -Contain '-Force:$true'
    }

    It '-Confirm 與 -WhatIf 以 :$true 形式轉送（Update-WindowsMedia 直接傳入 PSBoundParameters）' {
        $relaunch = Get-WinMediaRelaunchArgument -ScriptPath 'D:\Slipway\Update-WindowsMedia.ps1' -Bound @{ Confirm = [System.Management.Automation.SwitchParameter]$true; WhatIf = [System.Management.Automation.SwitchParameter]$true }
        $relaunch | Should -Contain '-Confirm:$true'
        $relaunch | Should -Contain '-WhatIf:$true'
    }

    It '未設定的 switch 不傳' {
        $relaunch = Get-WinMediaRelaunchArgument -ScriptPath 'D:\Slipway\Update-WindowsMedia.ps1' -Bound @{ Force = [System.Management.Automation.SwitchParameter]$false }
        $relaunch | Should -Not -Contain '-Force:$true'
        $relaunch | Should -Not -Contain '-Force'
    }

    It '含空白的值加上雙引號' {
        $relaunch = Get-WinMediaRelaunchArgument -ScriptPath 'D:\Slipway\Update-WindowsMedia.ps1' -Bound @{ WorkDir = 'D:\My Work' } -PathKeys @('WorkDir')
        $relaunch | Should -Contain '"D:\My Work"'
    }

    It '路徑參數轉為絕對路徑' {
        $relaunch = Get-WinMediaRelaunchArgument -ScriptPath 'Update-WindowsMedia.ps1' -Bound @{ ConfigPath = 'Config\Default.psd1' } -PathKeys @('ConfigPath')
        $index = [array]::IndexOf($relaunch, '-ConfigPath')
        $index | Should -BeGreaterThan -1
        $relaunch[$index + 1] | Should -Match '^"?[A-Za-z]:\\'
    }

    It '非路徑的值原樣傳遞' {
        $relaunch = Get-WinMediaRelaunchArgument -ScriptPath 'D:\Slipway\Update-WindowsMedia.ps1' -Bound @{ DismLogLevel = 'Debug' }
        $index = [array]::IndexOf($relaunch, '-DismLogLevel')
        $relaunch[$index + 1] | Should -Be 'Debug'
    }
}

Describe 'Update-WindowsMedia.ps1 入口：網路檢查與 -WhatIf（Elevation）' -Tag 'Unit' {
    It 'WorkDir 為網路路徑時於提權前丟出中文訊息' {
        { & $script:entry -SourceIso 'D:\x.iso' -WorkDir '\\server\share\w' -OutputDir (Join-Path -Path $TestDrive -ChildPath 'out') } |
            Should -Throw '*WorkDir 不支援網路路徑*'
    }

    It 'SourceIso 為網路路徑時於提權前丟出中文訊息' {
        { & $script:entry -SourceIso '\\server\share\x.iso' -WorkDir (Join-Path -Path $TestDrive -ChildPath 'w') -OutputDir (Join-Path -Path $TestDrive -ChildPath 'out') } |
            Should -Throw '*SourceIso 不支援網路路徑*'
    }

    It 'OutputDir 為網路路徑時丟出中文訊息' {
        { & $script:entry -SourceIso 'D:\x.iso' -WorkDir (Join-Path -Path $TestDrive -ChildPath 'w') -OutputDir '\\server\share\o' } |
            Should -Throw '*OutputDir 不支援網路路徑*'
    }

    It '提權判斷的條件先排除 $WhatIfPreference（AST；腳本的 Import-Module -Force 會清掉 runtime mock）' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:entry, [ref]$null, [ref]$null)
        $gates = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -match 'Test-WinMediaAdministrator' }, $true))
        $gates.Count | Should -Be 1
        $gates[0].Clauses[0].Item1.Extent.Text | Should -Match '-not \$WhatIfPreference'
        $gateBody = $gates[0].Clauses[0].Item2.Extent
        $starts = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Start-Process' }, $true))
        $starts.Count | Should -BeGreaterThan 0
        foreach ($s in $starts) {
            $s.Extent.StartOffset | Should -BeGreaterOrEqual $gateBody.StartOffset
            $s.Extent.EndOffset | Should -BeLessOrEqual $gateBody.EndOffset
        }
    }

    It '-WhatIf 不觸發提權（不呼叫 Start-Process）' {
        Mock Start-Process { }
        & $script:entry -SourceIso 'D:\x.iso' -WorkDir (Join-Path -Path $TestDrive -ChildPath 'w') -OutputDir (Join-Path -Path $TestDrive -ChildPath 'out') -WhatIf | Out-Null
        Should -Invoke Start-Process -Times 0 -Exactly
    }
}
