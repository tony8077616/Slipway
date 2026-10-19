#Requires -Version 5.1

BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    Import-Module -Name (Join-Path -Path $script:root -ChildPath 'WinMediaRefresh.psd1') -Force
    Import-Module -Name (Join-Path -Path $script:root -ChildPath 'Modules\WinMediaLangFod.psm1') -Force
    Import-Module -Name (Join-Path -Path $script:root -ChildPath 'PSModules\Imaging\WinMediaImage.psm1') -Force
    $script:default = Import-PowerShellDataFile -LiteralPath (Join-Path -Path $script:root -ChildPath 'Config\Default.psd1')
    $script:cfg = @{ DismProvider = 'Inbox'; LogLevel = 'Info'; OperationLog = ''; DebugTrace = 0; DismLogLevel = 'Debug'; LogFile = (Join-Path -Path $TestDrive -ChildPath 'loglevel.log') }
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
        { Invoke-WindowsMediaRefresh -SourceIso 'D:\x.iso' -Config $bad -Confirm:$false } | Should -Throw '*DismLogLevel*'
    }
}

Describe 'DISM cmdlet 皆帶 -LogLevel' -Tag 'Unit' {
    It 'Mount-WinMediaImage 傳遞 -LogLevel 給 Mount／Dismount' {
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

    # 主流程需要真實映像，改為靜態檢查：每個 DISM cmdlet 呼叫行都含 -LogLevel
    It '<File> 每個 DISM cmdlet 呼叫都含 -LogLevel $Config.DismLogLevel' -ForEach @(
        @{ File = 'Public\Invoke-WindowsMediaRefresh.ps1'; Expected = 12 }
        @{ File = 'Modules\WinMediaLangFod.psm1'; Expected = 2 }
        @{ File = 'PSModules\Imaging\WinMediaImage.psm1'; Expected = 3 }
    ) {
        $lines = Get-Content -LiteralPath (Join-Path -Path $script:root -ChildPath $File)
        $calls = @($lines | Select-String -Pattern '^\s*(Add-WindowsPackage|Repair-WindowsImage|Remove-WindowsImage|Get-WindowsImage|Mount-WindowsImage|Dismount-WindowsImage)\s')
        $calls.Count | Should -Be $Expected
        @($calls | Where-Object { $_.Line -match '-LogLevel \$Config\.DismLogLevel' }).Count | Should -Be $Expected
    }

    # 全模組掃描：不手列 cmdlet，改由 Dism 模組取得完整清單，任何非測試檔的 DISM 呼叫缺 -LogLevel 即失敗
    It '所有非測試模組的 DISM cmdlet 呼叫都含 -LogLevel $Config.DismLogLevel' {
        Import-Module -Name DISM -ErrorAction Stop
        $names = (Get-Command -Module DISM).Name -join '|'
        $files = Get-ChildItem -LiteralPath @((Join-Path -Path $script:root -ChildPath 'Public'), (Join-Path -Path $script:root -ChildPath 'Modules'), (Join-Path -Path $script:root -ChildPath 'PSModules')) -Recurse -Include '*.ps1', '*.psm1' |
            Where-Object { $_.FullName -notmatch '\\Tests\\' }
        $missing = @()
        foreach ($file in $files) {
            $n = 0
            foreach ($line in (Get-Content -LiteralPath $file.FullName)) {
                $n++
                if ($line -match "^\s*($names)\b" -and $line -notmatch '-LogLevel \$Config\.DismLogLevel') { $missing += ('{0}:{1}' -f $file.Name, $n) }
            }
        }
        $missing | Should -BeNullOrEmpty
    }
}
