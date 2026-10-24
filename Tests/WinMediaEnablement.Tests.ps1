#Requires -Version 5.1

BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    Import-Module -Name (Join-Path -Path $script:root -ChildPath 'Modules\WinMediaPackage.psm1') -Force
    $script:cfg = @{ LogLevel = 'Verbose'; LogFile = (Join-Path -Path $TestDrive -ChildPath 'enable.log'); OperationLog = ''; DebugTrace = 0; DismProvider = 'Inbox' }
    $script:enableMum = 'Microsoft-Windows-Ge-Client-Server-26300-Version-Enablement-Package~31bf3856ad364e35~amd64~~10.0.26100.9544.mum'
    function New-EnablePackage {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = '測試輔助函式，只在 TestDrive 內建立檔案')]
        param([string]$Name, [string[]]$Files)
        $pkgDir = Join-Path -Path $TestDrive -ChildPath ('pkg-' + [guid]::NewGuid().ToString('N'))
        $expandDir = Join-Path -Path $TestDrive -ChildPath ('exp-' + [guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($pkgDir) | Out-Null
        [IO.File]::WriteAllBytes((Join-Path -Path $pkgDir -ChildPath $Name), [byte[]]@())
        $target = Join-Path -Path $expandDir -ChildPath $Name
        [IO.Directory]::CreateDirectory($target) | Out-Null
        foreach ($f in $Files) { [IO.File]::WriteAllText((Join-Path -Path $target -ChildPath $f), 'x') }
        return @{ PackageDir = $pkgDir; ExpandDir = $expandDir }
    }
}

Describe 'Get-WinMediaPackageCategory：26H2 啟用套件（eKB）分類' -Tag 'Unit' {
    It '含 update.mum 與啟用套件 mum 的 cab 分類為 Enablement，並記錄 cab 內的版本' {
        $p = New-EnablePackage -Name 'Windows11.0-KB5121794-x64.cab' -Files @('update.mum', $script:enableMum)
        $r = InModuleScope WinMediaPackage -Parameters @{ P = $p; C = $script:cfg } { Get-WinMediaPackageCategory -PackageDir $P.PackageDir -ExpandDir $P.ExpandDir -Config $C }
        @($r.Enablement | Where-Object { $_ }).Count | Should -Be 1
        @($r.Unclassified | Where-Object { $_ }).Count | Should -Be 0
        Get-Content -LiteralPath $script:cfg.LogFile -Raw | Should -Match '9544'
    }

    It '缺少 update.mum 時不判為 Enablement（仍為 Unclassified）' {
        $p = New-EnablePackage -Name 'Windows11.0-KB5121794-x64.cab' -Files @($script:enableMum)
        $r = InModuleScope WinMediaPackage -Parameters @{ P = $p; C = $script:cfg } { Get-WinMediaPackageCategory -PackageDir $P.PackageDir -ExpandDir $P.ExpandDir -Config $C }
        @($r.Enablement | Where-Object { $_ }).Count | Should -Be 0
        @($r.Unclassified | Where-Object { $_ }).Count | Should -Be 1
    }

    It '含 Package_for_SafeOSDU 時仍優先判為 SafeOS，不因啟用套件 mum 改判' {
        $p = New-EnablePackage -Name 'Windows11.0-KB5127654-x64.cab' -Files @('update.mum', $script:enableMum)
        Set-Content -LiteralPath (Join-Path -Path $p.ExpandDir -ChildPath 'Windows11.0-KB5127654-x64.cab\update.mum') -Value '<assembly><assemblyIdentity name="Package_for_SafeOSDU"/></assembly>' -Encoding utf8
        $r = InModuleScope WinMediaPackage -Parameters @{ P = $p; C = $script:cfg } { Get-WinMediaPackageCategory -PackageDir $P.PackageDir -ExpandDir $P.ExpandDir -Config $C }
        @($r.SafeOS | Where-Object { $_ }).Count | Should -Be 1
        @($r.Enablement | Where-Object { $_ }).Count | Should -Be 0
    }

    It '含巢狀 KB cab 與 SSU 時仍為 CombinedCU（LCU），不判為 Enablement' {
        $p = New-EnablePackage -Name 'Windows11.0-KB5127936-x64.msu' -Files @('update.mum', $script:enableMum, 'SSU-26100.9-x64.cab', 'Windows11.0-KB5127936-x64.cab')
        $r = InModuleScope WinMediaPackage -Parameters @{ P = $p; C = $script:cfg } { Get-WinMediaPackageCategory -PackageDir $P.PackageDir -ExpandDir $P.ExpandDir -Config $C }
        @($r.LCU | Where-Object { $_ }).Count | Should -Be 1
        @($r.Enablement | Where-Object { $_ }).Count | Should -Be 0
    }
}

