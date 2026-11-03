#Requires -Version 5.1

BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    Import-Module -Name (Join-Path -Path $script:root -ChildPath 'WinMediaRefresh.psd1') -Force
    $script:config = Import-PowerShellDataFile -LiteralPath (Join-Path -Path $script:root -ChildPath 'Config\Default.psd1')
    $script:config.WorkDir = Join-Path -Path $TestDrive -ChildPath 'work'
    $script:config.DismProvider = 'Inbox'
    $script:config.OptimizationTarget = 'Full'
    $script:config.LogFile = Join-Path -Path $TestDrive -ChildPath 'img.log'
    $script:config.OperationLog = ''
    $script:invokeImage = {
        param([hashtable]$p)
        & (Get-Module -Name WinMediaRefresh) { param($q) Invoke-WinMediaInstallIndexImageUpdate @q } $p
    }
    $script:invokeOuter = {
        param([hashtable]$p)
        & (Get-Module -Name WinMediaRefresh) { param($q) Invoke-WinMediaInstallIndexUpdate @q } $p
    }
}

Describe 'Invoke-WinMediaInstallIndexImageUpdate 行為（Step 12b-1，mock 版）' -Tag 'Unit' {
    BeforeEach {
        $script:imgArgs = @{
            mounted       = (Join-Path -Path $TestDrive -ChildPath 'mnt')
            ssu           = 'C:\pkg\ssu.msu'
            lcuStage      = 'C:\stage'
            langFod       = [pscustomobject]@{ LangPacks = @('C:\lp.cab'); Fod = @('C:\fod.cab'); Deferred = @('C:\def.cab') }
            dotNet        = 'C:\pkg\net.msu'
            appxList      = [pscustomobject]@{ Mode = 'Remove'; Names = @('Contoso.App') }
            storeSet      = [pscustomobject]@{ Frameworks = @('C:\fw.appx'); Apps = @('C:\app.appx'); Hashes = @{} }
            lxpItems      = @([pscustomobject]@{ PackagePath = 'C:\lxp.appx'; LicensePath = 'C:\lxp.xml'; Pfn = 'Lxp.Pfn' })
            driverSet     = [ordered]@{ OS = [pscustomobject]@{ Path = 'C:\drv\OS'; InfCount = 1; Targets = @{ Install = $true } } }
            forceUnsigned = $false
            resetBaseOS   = $false
            common        = @{}
            IsFirstTarget = $true
            winreWim      = 'C:\winre.wim'
            Config        = $script:config
        }
        New-Item -ItemType Directory -Path $script:imgArgs.mounted -Force | Out-Null
        Mock -ModuleName WinMediaRefresh Invoke-WinMediaDism { param($ScriptBlock) & $ScriptBlock; 'noise-dism' }
        Mock -ModuleName WinMediaRefresh Add-WindowsPackage { 'noise-add' }
        Mock -ModuleName WinMediaRefresh Repair-WindowsImage { 'noise-repair' }
        Mock -ModuleName WinMediaRefresh Add-WindowsDriver { throw '不應呼叫真實 DISM：Add-WindowsDriver' }
        Mock -ModuleName WinMediaRefresh Invoke-WinMediaOperation { 'noise-op' }
        Mock -ModuleName WinMediaRefresh Install-WinMediaLangFod { 'noise-lang' }
        Mock -ModuleName WinMediaRefresh Install-WinMediaDeferredFod { 'noise-deferred' }
        Mock -ModuleName WinMediaRefresh Optimize-WinMediaImage { 'noise-optimize' }
        Mock -ModuleName WinMediaRefresh Install-WinMediaDriver { 'noise-driver' }
        Mock -ModuleName WinMediaRefresh Install-WinMediaStoreApp { 'noise-store' }
        Mock -ModuleName WinMediaRefresh Install-WinMediaLxp { 'noise-lxp' }
        Mock -ModuleName WinMediaRefresh Remove-WinMediaAppx { 'noise-appx' }
        Mock -ModuleName WinMediaRefresh Get-WinMediaBuildInfo { @{ Build = '26100.1' } }
        Mock -ModuleName WinMediaRefresh Get-Item { [pscustomobject]@{ VersionInfo = [pscustomobject]@{ FileVersion = '10.0.26100.1' } } }
    }

    It '第一個目標索引：回傳單一物件，含 KernelVersion 與 BuildInfo，內部雜訊不混入回傳值' {
        $r = @(& $script:invokeImage $script:imgArgs)
        $r.Count | Should -Be 1
        $r[0].KernelVersion | Should -Be '10.0.26100.1'
        $r[0].BuildInfo.Build | Should -Be '26100.1'
        Should -Invoke -ModuleName WinMediaRefresh Install-WinMediaLangFod -Times 1 -Exactly
        Should -Invoke -ModuleName WinMediaRefresh Install-WinMediaDriver -Times 1 -Exactly
        Should -Invoke -ModuleName WinMediaRefresh Install-WinMediaStoreApp -Times 1 -Exactly
        Should -Invoke -ModuleName WinMediaRefresh Install-WinMediaLxp -Times 1 -Exactly
        Should -Invoke -ModuleName WinMediaRefresh Remove-WinMediaAppx -Times 1 -Exactly
        Should -Invoke -ModuleName WinMediaRefresh Optimize-WinMediaImage -Times 1 -Exactly
        Should -Invoke -ModuleName WinMediaRefresh Get-WinMediaBuildInfo -Times 1 -Exactly
        Should -Invoke -ModuleName WinMediaRefresh Install-WinMediaDeferredFod -Times 1 -Exactly
        Should -Invoke -ModuleName WinMediaRefresh Invoke-WinMediaOperation -Times 1 -Exactly
        Should -Invoke -ModuleName WinMediaRefresh Invoke-WinMediaDism -Times 4 -Exactly
    }

    It '非第一個目標索引：KernelVersion 與 BuildInfo 為 $null，且不呼叫 Get-WinMediaBuildInfo' {
        $script:imgArgs.IsFirstTarget = $false
        $r = @(& $script:invokeImage $script:imgArgs)
        $r.Count | Should -Be 1
        $r[0].KernelVersion | Should -BeNullOrEmpty
        $r[0].BuildInfo | Should -BeNullOrEmpty
        Should -Invoke -ModuleName WinMediaRefresh Get-WinMediaBuildInfo -Times 0 -Exactly
    }
}

Describe 'Invoke-WinMediaInstallIndexUpdate 外層函式的回寫（Step 12b-1）' -Tag 'Unit' {
    BeforeEach {
        $script:outerArgs = @{
            mounted       = 'C:\mnt'
            ssu           = 'C:\pkg\ssu.msu'
            lcuStage      = 'C:\stage'
            langFod       = $null
            dotNet        = $null
            appxList      = $null
            storeSet      = $null
            lxpItems      = @()
            driverSet     = $null
            forceUnsigned = $false
            resetBaseOS   = $false
            common        = @{}
            IsFirstTarget = $true
            sourcesDir    = 'C:\media\sources'
            winreWim      = 'C:\winre.wim'
            isEsdSource   = $false
            mediaDir      = 'C:\media'
            Config        = $script:config
            installKernel = @{ Version = $null }
            buildInfo     = @{ Info = $null }
            bootEx        = @{ Applied = $false }
        }
        Mock -ModuleName WinMediaRefresh Invoke-WinMediaInstallIndexImageUpdate {
            if ([bool]$PesterBoundParameters['IsFirstTarget']) {
                [pscustomobject]@{ KernelVersion = 'K1'; BuildInfo = @{ Build = 'B1' } }
            }
            else {
                [pscustomobject]@{ KernelVersion = $null; BuildInfo = $null }
            }
        }
        Mock -ModuleName WinMediaRefresh Invoke-WinMediaOperation { }
        Mock -ModuleName WinMediaRefresh Copy-WinMediaUpdatedBootFiles { $true }
    }

    It '第一個目標寫入 installKernel 與 buildInfo；第二個目標不覆蓋它們（同一組 hashtable 依序呼叫）' {
        & $script:invokeOuter $script:outerArgs
        $script:outerArgs.IsFirstTarget = $false
        & $script:invokeOuter $script:outerArgs
        $script:outerArgs.installKernel.Version | Should -Be 'K1'
        $script:outerArgs.buildInfo.Info.Build | Should -Be 'B1'
        $script:outerArgs.bootEx.Applied | Should -BeTrue
        Should -Invoke -ModuleName WinMediaRefresh Invoke-WinMediaInstallIndexImageUpdate -Times 2 -Exactly
    }
}
