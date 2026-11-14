#Requires -Version 5.1

BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    Import-Module -Name (Join-Path -Path $script:root -ChildPath 'WinMediaRefresh.psd1') -Force
    $script:config = Import-PowerShellDataFile -LiteralPath (Join-Path -Path $script:root -ChildPath 'Config\Default.psd1')
    $script:config.WorkDir = Join-Path -Path $TestDrive -ChildPath 'work'
    $script:config.DismProvider = 'Inbox'
    $script:config.OptimizationTarget = 'Full'
    $script:config.LogFile = Join-Path -Path $TestDrive -ChildPath 'ekb.log'
    $script:config.OperationLog = ''
    $script:invokeImage = {
        param([hashtable]$p)
        & (Get-Module -Name WinMediaRefresh) { param($q) Invoke-WinMediaInstallIndexImageUpdate @q } $p
    }
}

Describe 'Invoke-WinMediaInstallIndexImageUpdate：啟用套件（eKB）安裝順序與條件' -Tag 'Unit' {
    BeforeEach {
        $script:ekbPath = 'C:\ekb\Windows11.0-KB5121794-x64.cab'
        $script:added = @()
        $script:imgArgs = @{
            mounted       = (Join-Path -Path $TestDrive -ChildPath 'mnt')
            ssu           = 'C:\pkg\ssu.cab'
            lcuStage      = 'C:\stage'
            langFod       = [pscustomobject]@{ LangPacks = @(); Fod = @(); Deferred = @() }
            dotNet        = $null
            enablement    = @([pscustomobject]@{ Path = $script:ekbPath; Editions = @('Microsoft-Windows-CoreEdition') })
            appxList      = $null
            storeSet      = [pscustomobject]@{ Frameworks = @(); Apps = @(); Hashes = @{} }
            lxpItems      = @()
            driverSet     = $null
            forceUnsigned = $false
            resetBaseOS   = $false
            common        = @{}
            IsFirstTarget = $false
            winreWim      = 'C:\winre.wim'
            Config        = $script:config
        }
        New-Item -ItemType Directory -Path $script:imgArgs.mounted -Force | Out-Null
        Mock -ModuleName WinMediaRefresh Invoke-WinMediaDism { param($ScriptBlock) & $ScriptBlock }
        Mock -ModuleName WinMediaRefresh Add-WindowsPackage { $script:added += [string]$PesterBoundParameters['PackagePath'] }
        Mock -ModuleName WinMediaRefresh Repair-WindowsImage { }
        Mock -ModuleName WinMediaRefresh Install-WinMediaLangFod { }
        Mock -ModuleName WinMediaRefresh Install-WinMediaDeferredFod { }
        Mock -ModuleName WinMediaRefresh Optimize-WinMediaImage { }
        Mock -ModuleName WinMediaRefresh Install-WinMediaStoreApp { }
        Mock -ModuleName WinMediaRefresh Invoke-WinMediaOperation { }
        Mock -ModuleName WinMediaRefresh Copy-Item { }
        Mock -ModuleName WinMediaRefresh Get-WinMediaBuildInfo { @{ Build = '26100.1' } }
        Mock -ModuleName WinMediaRefresh Get-Item { [pscustomobject]@{ VersionInfo = [pscustomobject]@{ FileVersion = '10.0.26100.1' } } }
    }

    It '適用時：eKB 安裝在 SSU 之後、LCU stage 之前' {
        Mock -ModuleName WinMediaRefresh Test-WinMediaEnablementApplicable { $true }
        & $script:invokeImage $script:imgArgs | Out-Null
        $script:added[0] | Should -Be 'C:\pkg\ssu.cab'
        $script:added[1] | Should -Be $script:ekbPath
        $script:added[2] | Should -Be 'C:\stage'
    }

    It '不適用時（Edition 未命中或 LTSC）：不安裝 eKB' {
        Mock -ModuleName WinMediaRefresh Test-WinMediaEnablementApplicable { $false }
        & $script:invokeImage $script:imgArgs | Out-Null
        $script:added | Should -Not -Contain $script:ekbPath
        $script:added | Should -Contain 'C:\stage'
    }

    It 'eKB 安裝失敗：拋出例外並中止，不繼續安裝 LCU（對齊 convert-UUP :errmount）' {
        Mock -ModuleName WinMediaRefresh Test-WinMediaEnablementApplicable { $true }
        Mock -ModuleName WinMediaRefresh Add-WindowsPackage {
            $script:added += [string]$PesterBoundParameters['PackagePath']
            if ([string]$PesterBoundParameters['PackagePath'] -eq $script:ekbPath) { throw 'DISM 0x800f0823' }
        }
        { & $script:invokeImage $script:imgArgs | Out-Null } | Should -Throw
        $script:added | Should -Not -Contain 'C:\stage'
    }
}

Describe 'enablement 接線：呼叫 ImageUpdate 時 -enablement 與 -appxList 是獨立參數（AST）' -Tag 'Unit' {
    BeforeAll {
        $script:root = Split-Path -Parent $PSScriptRoot
        function script:Get-CallParamName([string]$Path) {
            $errs = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
            $cmd = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-WinMediaInstallIndexImageUpdate' }, $true) | Select-Object -First 1
            if (-not $cmd) { return @() }
            return @($cmd.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } | ForEach-Object { $_.ParameterName })
        }
    }

    It 'Invoke-WinMediaInstallIndexUpdate 的呼叫包含獨立的 enablement 與 appxList' {
        $names = Get-CallParamName -Path (Join-Path -Path $script:root -ChildPath 'Public\Invoke-WinMediaInstallIndexUpdate.ps1')
        $names | Should -Contain 'enablement'
        $names | Should -Contain 'appxList'
    }

    It 'worker 的呼叫包含獨立的 enablement 與 appxList' {
        $names = Get-CallParamName -Path (Join-Path -Path $script:root -ChildPath 'Modules\WinMediaIndexWorker.psm1')
        $names | Should -Contain 'enablement'
        $names | Should -Contain 'appxList'
    }
}
