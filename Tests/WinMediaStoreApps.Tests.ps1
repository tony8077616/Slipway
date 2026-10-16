#Requires -Version 5.1

BeforeAll {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\Modules\WinMediaStoreApps.psm1') -Force
    $script:config = @{ DismProvider = 'Inbox'; DebugTrace = 0; OperationLog = ''; LogFile = (Join-Path -Path $TestDrive -ChildPath 'storeapps.log'); LogLevel = 'Info' }
    $script:msSubject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
}

Describe 'Test-WinMediaMicrosoftSignature（簽章判定）' -Tag 'Unit' {
    It 'Valid 且簽署者為 Microsoft Corporation 時通過' {
        Mock -ModuleName WinMediaStoreApps Get-AuthenticodeSignature {
            [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = $script:msSubject } }
        }
        InModuleScope WinMediaStoreApps {
            Test-WinMediaMicrosoftSignature -Path 'C:\x.msix' -Config @{ LogLevel = 'Info'; OperationLog = ''; DebugTrace = 0; LogFile = '' } | Should -BeTrue
        }
    }

    It '簽署者不是 Microsoft 時拒絕' {
        Mock -ModuleName WinMediaStoreApps Get-AuthenticodeSignature {
            [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Contoso, O=Contoso Ltd' } }
        }
        InModuleScope WinMediaStoreApps {
            Test-WinMediaMicrosoftSignature -Path 'C:\x.msix' -Config @{ LogLevel = 'Info'; OperationLog = ''; DebugTrace = 0; LogFile = '' } | Should -BeFalse
        }
    }

    It '簽章狀態非 Valid（例如雜湊不符）時拒絕' {
        Mock -ModuleName WinMediaStoreApps Get-AuthenticodeSignature {
            [pscustomobject]@{ Status = 'HashMismatch'; SignerCertificate = [pscustomobject]@{ Subject = $script:msSubject } }
        }
        InModuleScope WinMediaStoreApps {
            Test-WinMediaMicrosoftSignature -Path 'C:\x.msix' -Config @{ LogLevel = 'Info'; OperationLog = ''; DebugTrace = 0; LogFile = '' } | Should -BeFalse
        }
    }

    It '未簽章（無簽署者憑證）時拒絕' {
        Mock -ModuleName WinMediaStoreApps Get-AuthenticodeSignature {
            [pscustomobject]@{ Status = 'NotSigned'; SignerCertificate = $null }
        }
        InModuleScope WinMediaStoreApps {
            Test-WinMediaMicrosoftSignature -Path 'C:\x.msix' -Config @{ LogLevel = 'Info'; OperationLog = ''; DebugTrace = 0; LogFile = '' } | Should -BeFalse
        }
    }
}

Describe 'Resolve-WinMediaStoreAppSet（篩選）' -Tag 'Unit' {
    BeforeAll {
        $script:storeDir = Join-Path -Path $TestDrive -ChildPath 'StoreApps'
        New-Item -ItemType Directory -Path (Join-Path -Path $script:storeDir -ChildPath 'sub') -Force | Out-Null
        'Microsoft.VCLibs.140.00_14.0.30704.0_x64.appx', 'Microsoft.WindowsCalculator_11.2_x64.msixbundle', 'bad.appx', 'notes.txt' |
            ForEach-Object { New-Item -ItemType File -Path (Join-Path -Path $script:storeDir -ChildPath $_) -Force | Out-Null }
        New-Item -ItemType File -Path (Join-Path -Path $script:storeDir -ChildPath 'sub\Microsoft.WindowsStore_22.1_x64.msix') -Force | Out-Null
    }

    BeforeEach {
        Mock -ModuleName WinMediaStoreApps Get-AuthenticodeSignature {
            [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = $script:msSubject } }
        }
        Mock -ModuleName WinMediaStoreApps Get-AuthenticodeSignature {
            [pscustomobject]@{ Status = 'NotSigned'; SignerCertificate = $null }
        } -ParameterFilter { $LiteralPath -like '*bad.appx' }
    }

    It '框架與 app 分流，未通過簽章者與非套件副檔名不納入，並遞迴搜尋' {
        $set = Resolve-WinMediaStoreAppSet -Path $script:storeDir -Config $script:config
        @($set.Frameworks).Count | Should -Be 1
        @($set.Apps).Count | Should -Be 2
        @($set.Apps) | Where-Object { $_ -like '*bad.appx' } | Should -BeNullOrEmpty
        @($set.Apps) | Where-Object { $_ -like '*WindowsStore*' } | Should -Not -BeNullOrEmpty
    }

    It '路徑為空時兩組皆為空' {
        $set = Resolve-WinMediaStoreAppSet -Path '' -Config $script:config
        @($set.Frameworks).Count | Should -Be 0
        @($set.Apps).Count | Should -Be 0
    }
}

Describe 'Install-WinMediaStoreApp（注入參數）' -Tag 'Unit' {
    BeforeEach {
        $script:added = @()
        Mock -ModuleName WinMediaStoreApps Invoke-WinMediaDism { param([scriptblock]$ScriptBlock) & $ScriptBlock }
        Mock -ModuleName WinMediaStoreApps Add-AppxProvisionedPackage { $script:added += $PackagePath }
    }

    It '沒有同名授權檔時使用 -SkipLicense，並帶入框架依賴' {
        $app = Join-Path -Path $TestDrive -ChildPath 'nolic\Microsoft.WindowsCalculator.msixbundle'
        New-Item -ItemType Directory -Path (Split-Path -Path $app -Parent) -Force | Out-Null
        New-Item -ItemType File -Path $app -Force | Out-Null
        $set = [pscustomobject]@{ Frameworks = @('C:\fw\vclibs.appx'); Apps = @($app) }
        Install-WinMediaStoreApp -MountPath 'C:\mnt' -Set $set -Config $script:config
        Should -Invoke -CommandName Add-AppxProvisionedPackage -ModuleName WinMediaStoreApps -Times 1 -Exactly -ParameterFilter {
            $SkipLicense -and $DependencyPackagePath -contains 'C:\fw\vclibs.appx'
        }
    }

    It '有同名 .xml 授權檔時改用 -LicensePath' {
        $app = Join-Path -Path $TestDrive -ChildPath 'lic\WindowsStore.msix'
        New-Item -ItemType Directory -Path (Split-Path -Path $app -Parent) -Force | Out-Null
        New-Item -ItemType File -Path $app -Force | Out-Null
        New-Item -ItemType File -Path ([IO.Path]::ChangeExtension($app, '.xml')) -Force | Out-Null
        $set = [pscustomobject]@{ Frameworks = @(); Apps = @($app) }
        Install-WinMediaStoreApp -MountPath 'C:\mnt' -Set $set -Config $script:config
        Should -Invoke -CommandName Add-AppxProvisionedPackage -ModuleName WinMediaStoreApps -Times 1 -Exactly -ParameterFilter {
            $LicensePath -like '*WindowsStore.xml' -and -not $SkipLicense
        }
    }

    It '沒有 app 時不呼叫 DISM' {
        $set = [pscustomobject]@{ Frameworks = @(); Apps = @() }
        Install-WinMediaStoreApp -MountPath 'C:\mnt' -Set $set -Config $script:config
        Should -Invoke -CommandName Invoke-WinMediaDism -ModuleName WinMediaStoreApps -Times 0 -Exactly
    }
}
