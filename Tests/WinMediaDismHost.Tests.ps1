#Requires -Version 5.1

$script:isCore = ($PSVersionTable.PSEdition -eq 'Core')

BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    Import-Module -Name (Join-Path -Path $script:root -ChildPath 'PSModules\Imaging\WinMediaDism.psm1') -Force
    $script:cfg = @{ LogLevel = 'Verbose'; LogFile = (Join-Path -Path $TestDrive -ChildPath 'dism-host.log'); OperationLog = ''; DebugTrace = 0; DismProvider = 'Inbox'; DismLogLevel = 'WarningsInfo'; DismUseWindowsPowerShell = $true }
    $script:adkModule = 'C:\ADK\Deployment Tools\amd64\DISM\Dism.psd1'
    $script:isCore = ($PSVersionTable.PSEdition -eq 'Core')
}

Describe 'DismUseWindowsPowerShell 設定鍵的解析' -Tag 'Unit' {
    It '缺鍵時預設為 $true' {
        Resolve-WinMediaDismUseWindowsPowerShell -Config @{} | Should -BeTrue
    }

    It '明確設為 $false 時回傳 $false' {
        Resolve-WinMediaDismUseWindowsPowerShell -Config @{ DismUseWindowsPowerShell = $false } | Should -BeFalse
    }
}

Describe 'Test-WinMediaDismHost：開關檢查（Inbox 與 ADK 相同）' -Tag 'Unit' {
    It 'Windows PowerShell 5.1（Desktop）不做任何檢查' {
        Mock -ModuleName WinMediaDism Test-WinMediaDismCore { $false }
        $off = $script:cfg.Clone()
        $off.DismUseWindowsPowerShell = $false
        { Test-WinMediaDismHost -Provider 'ADK' -Config $off } | Should -Not -Throw
    }

    It 'pwsh 7 且設定為關閉時，Inbox 中止並指出設定鍵' {
        Mock -ModuleName WinMediaDism Test-WinMediaDismCore { $true }
        $off = $script:cfg.Clone()
        $off.DismUseWindowsPowerShell = $false
        { Test-WinMediaDismHost -Provider 'Inbox' -Config $off } | Should -Throw '*DismUseWindowsPowerShell*'
    }

    It 'pwsh 7 且設定為關閉時，ADK 也中止並指出設定鍵' {
        Mock -ModuleName WinMediaDism Test-WinMediaDismCore { $true }
        $off = $script:cfg.Clone()
        $off.DismUseWindowsPowerShell = $false
        { Test-WinMediaDismHost -Provider 'ADK' -Config $off } | Should -Throw '*DismUseWindowsPowerShell*'
    }

    It 'pwsh 7 且設定為開啟時，Inbox 與 ADK 都通過' {
        Mock -ModuleName WinMediaDism Test-WinMediaDismCore { $true }
        { Test-WinMediaDismHost -Provider 'Inbox' -Config $script:cfg } | Should -Not -Throw
        { Test-WinMediaDismHost -Provider 'ADK' -Config $script:cfg } | Should -Not -Throw
    }
}

Describe 'Invoke-WinMediaDism：pwsh 7 的先檢查、再匯入' -Tag 'Unit' {
    BeforeEach {
        InModuleScope WinMediaDism { $script:DismCompatSource = $null }
        Mock -ModuleName WinMediaDism Import-WinMediaDismCompat { }
        Mock -ModuleName WinMediaDism Remove-WinMediaDismLoaded { }
        Mock -ModuleName WinMediaDism Get-WinMediaDismLoaded { $null }
        Mock -ModuleName WinMediaDism Test-WinMediaDismCore { $true }
        Mock -ModuleName WinMediaDism Invoke-WinMediaOperation { $ScriptBlock.Invoke() }
        Mock -ModuleName WinMediaDism Resolve-WinMediaAdk { [pscustomobject]@{ Root = 'C:\ADK'; ModulePath = $script:adkModule; DismExe = 'C:\ADK\dism.exe' } }
    }

    It 'Windows PowerShell 5.1 不呼叫相容匯入' {
        Mock -ModuleName WinMediaDism Test-WinMediaDismCore { $false }
        Invoke-WinMediaDism -Provider 'Inbox' -ScriptBlock { 'ok' } -Config $script:cfg | Should -Be 'ok'
        Should -Invoke -ModuleName WinMediaDism Import-WinMediaDismCompat -Times 0 -Exactly
    }

    It 'pwsh 7 Inbox：尚未載入時匯入一次（來源為 DISM），多次呼叫不重複匯入' {
        Invoke-WinMediaDism -Provider 'Inbox' -ScriptBlock { 'a' } -Config $script:cfg | Out-Null
        Invoke-WinMediaDism -Provider 'Inbox' -ScriptBlock { 'b' } -Config $script:cfg | Out-Null
        Should -Invoke -ModuleName WinMediaDism Import-WinMediaDismCompat -Times 1 -Exactly -ParameterFilter { $Source -eq 'DISM' }
    }

    It 'pwsh 7 ADK：先解析 ADK，再以 Dism.psd1 路徑匯入' {
        Invoke-WinMediaDism -Provider 'ADK' -ScriptBlock { 'a' } -Config $script:cfg | Out-Null
        Should -Invoke -ModuleName WinMediaDism Resolve-WinMediaAdk -Times 1 -Exactly
        Should -Invoke -ModuleName WinMediaDism Import-WinMediaDismCompat -Times 1 -Exactly -ParameterFilter { $Source -eq $script:adkModule }
    }

    It 'pwsh 7 且設定為關閉時，Inbox 與 ADK 都在匯入前中止' {
        $off = $script:cfg.Clone()
        $off.DismUseWindowsPowerShell = $false
        { Invoke-WinMediaDism -Provider 'Inbox' -ScriptBlock { 'a' } -Config $off } | Should -Throw '*DismUseWindowsPowerShell*'
        { Invoke-WinMediaDism -Provider 'ADK' -ScriptBlock { 'a' } -Config $off } | Should -Throw '*DismUseWindowsPowerShell*'
        Should -Invoke -ModuleName WinMediaDism Import-WinMediaDismCompat -Times 0 -Exactly
    }

    It '本工作階段已用相容模式載入同一來源時，不再重新匯入' {
        InModuleScope WinMediaDism { $script:DismCompatSource = 'DISM' }
        Invoke-WinMediaDism -Provider 'Inbox' -ScriptBlock { 'a' } -Config $script:cfg | Out-Null
        Should -Invoke -ModuleName WinMediaDism Import-WinMediaDismCompat -Times 0 -Exactly
    }

    It '已載入的 Dism 不是我們匯入的（原生自動載入）時，先移除再以相容模式匯入' {
        Mock -ModuleName WinMediaDism Get-WinMediaDismLoaded { [pscustomobject]@{ Name = 'Dism'; Path = 'C:\Windows\System32\WindowsPowerShell\v1.0\Modules\Dism\Dism.psd1' } }
        Invoke-WinMediaDism -Provider 'Inbox' -ScriptBlock { 'a' } -Config $script:cfg | Out-Null
        Should -Invoke -ModuleName WinMediaDism Remove-WinMediaDismLoaded -Times 1 -Exactly
        Should -Invoke -ModuleName WinMediaDism Import-WinMediaDismCompat -Times 1 -Exactly -ParameterFilter { $Source -eq 'DISM' }
    }

    It '同一工作階段中途由 Inbox 換成 ADK 時擲例外' {
        Invoke-WinMediaDism -Provider 'Inbox' -ScriptBlock { 'a' } -Config $script:cfg | Out-Null
        { Invoke-WinMediaDism -Provider 'ADK' -ScriptBlock { 'b' } -Config $script:cfg } | Should -Throw '*工作階段*'
    }

    It '回傳值只有 ScriptBlock 的結果，不混入匯入的輸出' {
        Mock -ModuleName WinMediaDism Import-WinMediaDismCompat { 'leak' }
        $r = @(Invoke-WinMediaDism -Provider 'Inbox' -ScriptBlock { 'only' } -Config $script:cfg)
        $r.Count | Should -Be 1
        $r[0] | Should -Be 'only'
    }
}

Describe 'Import-WinMediaDismCompat：匯入參數（僅 pwsh 7）' -Tag 'Unit' -Skip:(-not $script:isCore) {
    It 'Inbox 以 -Name DISM -UseWindowsPowerShell -Global -PassThru 匯入' {
        Mock -ModuleName WinMediaDism Import-Module { }
        InModuleScope WinMediaDism -Parameters @{ C = $script:cfg } { Import-WinMediaDismCompat -Config $C -Source 'DISM' }
        Should -Invoke -ModuleName WinMediaDism Import-Module -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'DISM' -and $UseWindowsPowerShell -and $Global -and $PassThru
        }
    }

    It 'ADK 以 Dism.psd1 路徑匯入' {
        Mock -ModuleName WinMediaDism Import-Module { }
        InModuleScope WinMediaDism -Parameters @{ C = $script:cfg; S = $script:adkModule } { Import-WinMediaDismCompat -Config $C -Source $S }
        Should -Invoke -ModuleName WinMediaDism Import-Module -Times 1 -Exactly -ParameterFilter {
            $Name -eq $script:adkModule -and $UseWindowsPowerShell
        }
    }

    It '相容匯入的警告不以警告串流顯示，改記為 Info 日誌' {
        Mock -ModuleName WinMediaDism Import-Module { Write-Warning '測試警告' }
        Mock -ModuleName WinMediaDism Write-WinMediaLog { }
        InModuleScope WinMediaDism -Parameters @{ C = $script:cfg } { Import-WinMediaDismCompat -Config $C -Source 'DISM' }
        Should -Invoke -ModuleName WinMediaDism Write-WinMediaLog -ParameterFilter { $Level -eq 'Info' -and $Message -like '*已知*測試警告*' }
    }
}
