#Requires -Version 5.1

BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    Import-Module -Name (Join-Path -Path $script:root -ChildPath 'WinMediaRefresh.psd1') -Force
    Import-Module -Name (Join-Path -Path $script:root -ChildPath 'Modules\WinMediaLangFod.psm1') -Force
    Import-Module -Name (Join-Path -Path $script:root -ChildPath 'PSModules\Imaging\WinMediaImage.psm1') -Force
    $script:default = Import-PowerShellDataFile -LiteralPath (Join-Path -Path $script:root -ChildPath 'Config\Default.psd1')
    $script:cfg = @{ DismProvider = 'Inbox'; LogLevel = 'Info'; OperationLog = ''; DebugTrace = 0; DismLogLevel = 'Debug'; LogFile = (Join-Path -Path $TestDrive -ChildPath 'loglevel.log') }
}

AfterAll {
    # 本檔多個 Describe 會設定相容狀態；檔案結束時清回，避免同一工作階段後續的管線略過相容匯入
    InModuleScope WinMediaDism { $global:WinMediaDismCompatSource = $null }
}

Describe 'DismLogLevel 設定與參數' -Tag 'Unit' {
    It '設定檔預設值為 WarningsInfo' {
        $script:default.DismLogLevel | Should -Be 'WarningsInfo'
    }

    It '參數拒絕數字 3 與 4' {
        { Invoke-WindowsMediaRefresh -SourceIso 'D:\x.iso' -Config $script:default -DismLogLevel 3 -WhatIf } | Should -Throw
        { Invoke-WindowsMediaRefresh -SourceIso 'D:\x.iso' -Config $script:default -DismLogLevel 4 -WhatIf } | Should -Throw
    }

    It '參數接受 Debug' {
        { Invoke-WindowsMediaRefresh -SourceIso 'D:\x.iso' -Config $script:default -DismLogLevel Debug -WhatIf } | Should -Not -Throw
    }

    It '設定檔值不是四個名稱之一時中止' {
        $bad = $script:default.Clone()
        $bad.DismLogLevel = '3'
        $bad.WorkDir = 'C:\WinMediaWorkLogLevelTest'
        { Invoke-WindowsMediaRefresh -SourceIso 'D:\x.iso' -Config $bad -Confirm:$false } | Should -Throw '*DismLogLevel 必須為*'
    }
}

Describe 'Resolve-WinMediaDismLogLevel（預設與驗證集中於 Keel）' -Tag 'Unit' {
    BeforeAll {
        Import-Module -Name (Join-Path -Path $script:root -ChildPath 'PSModules\Imaging\WinMediaDism.psm1') -Force
    }

    It '缺鍵時回傳 WarningsInfo' {
        Resolve-WinMediaDismLogLevel -Config @{} | Should -Be 'WarningsInfo'
    }

    It '合法名稱原樣回傳' {
        Resolve-WinMediaDismLogLevel -Config @{ DismLogLevel = 'Debug' } | Should -Be 'Debug'
    }

    It '數字與不在清單內的名稱拋出 DismLogLevel 錯誤' {
        { Resolve-WinMediaDismLogLevel -Config @{ DismLogLevel = '3' } } | Should -Throw '*DismLogLevel 必須為*'
        { Resolve-WinMediaDismLogLevel -Config @{ DismLogLevel = 'Verbose' } } | Should -Throw '*DismLogLevel 必須為*'
    }
}

Describe 'DISM cmdlet 皆帶 -LogLevel' -Tag 'Unit' {
    BeforeAll {
        # pwsh 7 會自動載入原生 Dism（Get-Command 找得到），Mock 在模組範圍內無法綁定；改用同簽章樁函式，只在 pwsh 7 測試期間存在
        $script:stubbed = ($PSVersionTable.PSEdition -eq 'Core')
        if ($script:stubbed) {
            function global:Mount-WindowsImage { param($ImagePath, $Index, $Path, [switch]$ReadOnly, $LogLevel) }
            function global:Dismount-WindowsImage { param($Path, [switch]$Save, [switch]$Discard, $LogLevel) }
        }
    }
    AfterAll {
        InModuleScope WinMediaDism { $global:WinMediaDismCompatSource = $null }
        if ($script:stubbed) {
            Remove-Item -Path Function:\Mount-WindowsImage, Function:\Dismount-WindowsImage -ErrorAction SilentlyContinue
        }
    }

    It 'Mount-WinMediaImage 傳遞 -LogLevel 給 Mount／Dismount' {
        # 此測試只驗證 -LogLevel 傳到 Mount／Dismount；先標記為已相容匯入，避免 pwsh 7 下分派真的匯入 DISM
        InModuleScope WinMediaDism { $global:WinMediaDismCompatSource = 'DISM' }
        Mock -ModuleName WinMediaImage Mount-WindowsImage { } -ParameterFilter { $LogLevel -eq 'Debug' }
        Mock -ModuleName WinMediaImage Dismount-WindowsImage { } -ParameterFilter { $LogLevel -eq 'Debug' }
        Mount-WinMediaImage -ImagePath 'x.wim' -Index 1 -MountPath (Join-Path -Path $TestDrive -ChildPath 'mp') -Action { 'ok' } -Config $script:cfg | Out-Null
        Should -Invoke -ModuleName WinMediaImage Mount-WindowsImage -Times 1 -Exactly -ParameterFilter { $LogLevel -eq 'Debug' }
        Should -Invoke -ModuleName WinMediaImage Dismount-WindowsImage -Times 1 -Exactly -ParameterFilter { $LogLevel -eq 'Debug' }
    }

    It 'Install-WinMediaLangFod 傳遞 -LogLevel 給 Add-WindowsPackage' {
        Mock -ModuleName WinMediaLangFod Add-WindowsPackage { } -ParameterFilter { $LogLevel -eq 'Debug' }
        $set = [pscustomobject]@{ LangPacks = @('a.cab'); Fod = @('b.cab'); Deferred = @('c.cab') }
        Install-WinMediaLangFod -MountPath 'M:\x' -Set $set -Config $script:cfg
        Install-WinMediaDeferredFod -MountPath 'M:\x' -Set $set -Config $script:cfg
        Should -Invoke -ModuleName WinMediaLangFod Add-WindowsPackage -Times 3 -Exactly -ParameterFilter { $LogLevel -eq 'Debug' }
    }

    # AST 掃描：以 Dism 模組的完整 cmdlet 清單比對 CommandAst，不靠字串或行首位置；
    # 字串、註解、跨行續接與行中呼叫都能正確處理。參數值必須是 $Config.DismLogLevel。
    It '所有非測試模組的 DISM cmdlet 呼叫都以 -LogLevel $Config.DismLogLevel 傳入（AST）' {
        if (-not (Get-Module -ListAvailable -Name DISM)) {
            Set-ItResult -Skipped -Because 'DISM 模組不存在於此環境'
            return
        }
        Import-Module -Name DISM -ErrorAction Stop
        $names = @((Get-Command -Module DISM).Name)
        $files = Get-ChildItem -LiteralPath @((Join-Path -Path $script:root -ChildPath 'Public'), (Join-Path -Path $script:root -ChildPath 'Modules'), (Join-Path -Path $script:root -ChildPath 'PSModules')) -Recurse -File |
            Where-Object { $_.Extension -in '.ps1', '.psm1' -and $_.FullName -notmatch '\\Tests\\' }
        $missing = @()
        foreach ($file in $files) {
            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
            $errors | Should -BeNullOrEmpty
            $calls = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)
            foreach ($call in $calls) {
                $name = $call.GetCommandName()
                if (-not $name -or $names -notcontains $name) { continue }
                $elements = @($call.CommandElements)
                $index = [array]::FindIndex($elements, [System.Predicate[object]] { param($e) $e -is [System.Management.Automation.Language.CommandParameterAst] -and $e.ParameterName -eq 'LogLevel' })
                # -LogLevel $x 拆成兩個元素：值在參數後面的元素（或參數本身的 Argument，語法 -LogLevel:$x）
                $value = if ($index -lt 0) { $null } elseif ($elements[$index].Argument) { $elements[$index].Argument } elseif ($index + 1 -lt $elements.Count) { $elements[$index + 1] } else { $null }
                $ok = $value -and $value.Extent.Text -eq '$Config.DismLogLevel'
                if (-not $ok) { $missing += ('{0}:{1} {2}' -f $file.Name, $call.Extent.StartLineNumber, $name) }
            }
        }
        $missing | Should -BeNullOrEmpty
    }
}

Describe 'DismLogLevel 缺鍵的舊設定檔（相容性）' -Tag 'Unit' {
    It 'Mount-WinMediaImage 缺鍵時由 wrapper 補上 WarningsInfo 再傳給 Mount／Dismount' {
        # 只驗證缺鍵時的 -LogLevel 預設；先標記為已相容匯入，避免 pwsh 7 下分派真的匯入 DISM
        InModuleScope WinMediaDism { $global:WinMediaDismCompatSource = 'DISM' }
        $noKey = $script:cfg.Clone()
        [void]$noKey.Remove('DismLogLevel')
        Mock -ModuleName WinMediaImage Mount-WindowsImage { } -ParameterFilter { $LogLevel -eq 'WarningsInfo' }
        Mock -ModuleName WinMediaImage Dismount-WindowsImage { } -ParameterFilter { $LogLevel -eq 'WarningsInfo' }
        Mount-WinMediaImage -ImagePath 'x.wim' -Index 1 -MountPath (Join-Path -Path $TestDrive -ChildPath 'mp2') -Action { 'ok' } -Config $noKey | Out-Null
        Should -Invoke -ModuleName WinMediaImage Mount-WindowsImage -Times 1 -Exactly -ParameterFilter { $LogLevel -eq 'WarningsInfo' }
        Should -Invoke -ModuleName WinMediaImage Dismount-WindowsImage -Times 1 -Exactly -ParameterFilter { $LogLevel -eq 'WarningsInfo' }
    }

    It '主流程缺鍵時通過 DismLogLevel 檢查，在解析掛載目錄時才停下（不解析磁碟根目錄的 MountUUP）' {
        Mock -ModuleName WinMediaRefresh Resolve-WinMediaMountDir { throw 'REACHED_MOUNTDIR' }
        $noKey = $script:default.Clone()
        [void]$noKey.Remove('DismLogLevel')
        { Invoke-WindowsMediaRefresh -SourceIso 'C:\__none.iso' -Config $noKey -WorkDir $TestDrive -Confirm:$false } | Should -Throw '*REACHED_MOUNTDIR*'
    }

    It '主流程的 -DismLogLevel 參數可覆寫缺鍵的設定' {
        Mock -ModuleName WinMediaRefresh Resolve-WinMediaMountDir { throw 'REACHED_MOUNTDIR' }
        $noKey = $script:default.Clone()
        [void]$noKey.Remove('DismLogLevel')
        { Invoke-WindowsMediaRefresh -SourceIso 'C:\__none.iso' -Config $noKey -WorkDir $TestDrive -DismLogLevel Debug -Confirm:$false } | Should -Throw '*REACHED_MOUNTDIR*'
    }

    It '主流程的 DismLogLevel 為 Verbose 時在掛載前中止' {
        $bad = $script:default.Clone()
        $bad.DismLogLevel = 'Verbose'
        { Invoke-WindowsMediaRefresh -SourceIso 'C:\__none.iso' -Config $bad -WorkDir $TestDrive -Confirm:$false } | Should -Throw '*DismLogLevel 必須為*'
    }
}
