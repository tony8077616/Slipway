#Requires -Version 5.1

BeforeAll {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\Modules\WinMediaStoreApps.psm1') -Force
    $script:config = @{ DismProvider = 'Inbox'; DebugTrace = 0; OperationLog = ''; LogFile = (Join-Path -Path $TestDrive -ChildPath 'storeapps.log'); LogLevel = 'Info'; DismLogLevel = 'Debug' }
    $script:sha = { param([string]$File) $s = [Security.Cryptography.SHA256]::Create(); try { $fs = [IO.File]::OpenRead($File); try { -join ($s.ComputeHash($fs) | ForEach-Object { $_.ToString('x2') }) } finally { $fs.Dispose() } } finally { $s.Dispose() } }
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

    It '引號 CN 內夾帶 O=Microsoft Corporation 的假簽署者被拒' {
        $rsa = [System.Security.Cryptography.RSA]::Create(2048)
        $req = New-Object -TypeName System.Security.Cryptography.X509Certificates.CertificateRequest -ArgumentList 'CN="x, O=Microsoft Corporation, y", O=Evil', $rsa, ([System.Security.Cryptography.HashAlgorithmName]::SHA256), ([System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $script:quotedCert = $req.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(1))
        Mock -ModuleName WinMediaStoreApps Get-AuthenticodeSignature {
            [pscustomobject]@{ Status = 'Valid'; SignerCertificate = $script:quotedCert }
        }
        InModuleScope WinMediaStoreApps {
            Test-WinMediaMicrosoftSignature -Path 'C:\x.msix' -Config @{ LogLevel = 'Info'; OperationLog = ''; DebugTrace = 0; LogFile = '' } | Should -BeFalse
        }
    }

    It '換行注入：CN 值內嵌 CR/LF 與 O=Microsoft Corporation 的假簽署者被拒' -Skip:($PSVersionTable.PSEdition -ne 'Core') {
        $b = New-Object -TypeName System.Security.Cryptography.X509Certificates.X500DistinguishedNameBuilder
        $b.AddCommonName("x`r`nO=Microsoft Corporation`r`ny")
        $b.AddOrganizationName('Evil')
        $rsa = [System.Security.Cryptography.RSA]::Create(2048)
        $req = New-Object -TypeName System.Security.Cryptography.X509Certificates.CertificateRequest -ArgumentList $b.Build(), $rsa, ([System.Security.Cryptography.HashAlgorithmName]::SHA256), ([System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $script:nlCert = $req.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(1))
        Mock -ModuleName WinMediaStoreApps Get-AuthenticodeSignature {
            [pscustomobject]@{ Status = 'Valid'; SignerCertificate = $script:nlCert }
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
    It '回傳的 Set 記錄每個套件、框架與授權 xml 的 SHA-256' {
        $lic = Join-Path -Path $script:storeDir -ChildPath 'sub\Microsoft.WindowsStore_22.1_x64.xml'
        [IO.File]::WriteAllText($lic, 'license')
        $set = Resolve-WinMediaStoreAppSet -Path $script:storeDir -Config $script:config
        $set.PSObject.Properties.Name | Should -Contain 'Hashes'
        $all = @($set.Frameworks) + @($set.Apps) + @($lic)
        foreach ($p in $all) {
            $set.Hashes[$p] | Should -Be (& $script:sha $p)
        }
        $set.Hashes.ContainsKey((Join-Path -Path $script:storeDir -ChildPath 'bad.appx')) | Should -BeFalse
    }

    It '路徑為空時 Hashes 為空表（仍可通過 Install 的雜湊檢查）' {
        $set = Resolve-WinMediaStoreAppSet -Path '' -Config $script:config
        $set.PSObject.Properties.Name | Should -Contain 'Hashes'
        $set.Hashes.Count | Should -Be 0
    }
}

Describe 'Install-WinMediaStoreApp（注入參數）' -Tag 'Unit' {
    BeforeEach {
        $script:added = @()
        Mock -ModuleName WinMediaStoreApps Invoke-WinMediaDism { param([scriptblock]$ScriptBlock) & $ScriptBlock }
        Mock -ModuleName WinMediaStoreApps Add-AppxProvisionedPackage { $script:added += $PackagePath }
        # 建立真實檔案並以其目前內容算出 Hashes，模擬 Resolve 的回傳
        $script:newSet = {
            param([string]$Dir, [string]$AppName, [bool]$WithLicense, [bool]$WithFramework)
            New-Item -ItemType Directory -Path $Dir -Force | Out-Null
            $app = Join-Path -Path $Dir -ChildPath $AppName
            [IO.File]::WriteAllText($app, 'app')
            $hashes = @{ $app = (& $script:sha $app) }
            $fw = @()
            if ($WithFramework) {
                $fwPath = Join-Path -Path $Dir -ChildPath 'Microsoft.VCLibs.140.appx'
                [IO.File]::WriteAllText($fwPath, 'fw')
                $fw = @($fwPath)
                $hashes[$fwPath] = (& $script:sha $fwPath)
            }
            if ($WithLicense) {
                $lic = [IO.Path]::ChangeExtension($app, '.xml')
                [IO.File]::WriteAllText($lic, 'license')
                $hashes[$lic] = (& $script:sha $lic)
            }
            [pscustomobject]@{ Frameworks = $fw; Apps = @($app); Hashes = $hashes }
        }
    }

    It '沒有同名授權檔時使用 -SkipLicense，並帶入框架依賴' {
        $set = & $script:newSet (Join-Path -Path $TestDrive -ChildPath 'nolic') 'Microsoft.WindowsCalculator.msixbundle' $false $true
        Install-WinMediaStoreApp -MountPath 'C:\mnt' -Set $set -Config $script:config
        Should -Invoke -CommandName Add-AppxProvisionedPackage -ModuleName WinMediaStoreApps -Times 1 -Exactly -ParameterFilter {
            $SkipLicense -and $DependencyPackagePath -like '*Microsoft.VCLibs.140.appx'
        }
    }

    It '有同名 .xml 授權檔時改用 -LicensePath' {
        $set = & $script:newSet (Join-Path -Path $TestDrive -ChildPath 'lic') 'WindowsStore.msix' $true $false
        Install-WinMediaStoreApp -MountPath 'C:\mnt' -Set $set -Config $script:config
        Should -Invoke -CommandName Add-AppxProvisionedPackage -ModuleName WinMediaStoreApps -Times 1 -Exactly -ParameterFilter {
            $LicensePath -like '*WindowsStore.xml' -and -not $SkipLicense
        }
    }

    It '沒有 app 時不呼叫 DISM' {
        $set = [pscustomobject]@{ Frameworks = @(); Apps = @(); Hashes = @{} }
        Install-WinMediaStoreApp -MountPath 'C:\mnt' -Set $set -Config $script:config
        Should -Invoke -CommandName Invoke-WinMediaDism -ModuleName WinMediaStoreApps -Times 0 -Exactly
    }
}

Describe 'Install-WinMediaStoreApp（注入前重驗雜湊，fail-closed）' -Tag 'Unit' {
    BeforeEach {
        Mock -ModuleName WinMediaStoreApps Invoke-WinMediaDism { param([scriptblock]$ScriptBlock) & $ScriptBlock }
        Mock -ModuleName WinMediaStoreApps Add-AppxProvisionedPackage { }
        $script:dir = Join-Path -Path $TestDrive -ChildPath ('h' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:dir -Force | Out-Null
        $script:app = Join-Path -Path $script:dir -ChildPath 'Calc.msix'
        $script:fw = Join-Path -Path $script:dir -ChildPath 'Microsoft.VCLibs.140.appx'
        $script:lic = Join-Path -Path $script:dir -ChildPath 'Calc.xml'
        [IO.File]::WriteAllText($script:app, 'app')
        [IO.File]::WriteAllText($script:fw, 'fw')
        $script:hashes = @{ $script:app = (& $script:sha $script:app); $script:fw = (& $script:sha $script:fw) }
        $script:hSet = [pscustomobject]@{ Frameworks = @($script:fw); Apps = @($script:app); Hashes = $script:hashes }
    }

    It '沒有 Hashes 的 Set 一律拒絕，且不呼叫 DISM' {
        $old = [pscustomobject]@{ Frameworks = @(); Apps = @($script:app) }
        { Install-WinMediaStoreApp -MountPath 'C:\mnt' -Set $old -Config $script:config } | Should -Throw
        Should -Invoke -CommandName Invoke-WinMediaDism -ModuleName WinMediaStoreApps -Times 0 -Exactly
    }

    It 'app 在 Resolve 之後被換掉時拒絕' {
        [IO.File]::WriteAllText($script:app, 'tampered')
        { Install-WinMediaStoreApp -MountPath 'C:\mnt' -Set $script:hSet -Config $script:config } | Should -Throw
        Should -Invoke -CommandName Invoke-WinMediaDism -ModuleName WinMediaStoreApps -Times 0 -Exactly
    }

    It '框架在 Resolve 之後被換掉時拒絕' {
        [IO.File]::WriteAllText($script:fw, 'tampered')
        { Install-WinMediaStoreApp -MountPath 'C:\mnt' -Set $script:hSet -Config $script:config } | Should -Throw
        Should -Invoke -CommandName Invoke-WinMediaDism -ModuleName WinMediaStoreApps -Times 0 -Exactly
    }

    It '授權 xml 被換掉時拒絕' {
        [IO.File]::WriteAllText($script:lic, 'license')
        $script:hashes[$script:lic] = (& $script:sha $script:lic)
        [IO.File]::WriteAllText($script:lic, 'tampered')
        { Install-WinMediaStoreApp -MountPath 'C:\mnt' -Set $script:hSet -Config $script:config } | Should -Throw
        Should -Invoke -CommandName Invoke-WinMediaDism -ModuleName WinMediaStoreApps -Times 0 -Exactly
    }

    It 'Resolve 之後才出現的授權 xml 拒絕' {
        [IO.File]::WriteAllText($script:lic, 'late')
        { Install-WinMediaStoreApp -MountPath 'C:\mnt' -Set $script:hSet -Config $script:config } | Should -Throw
        Should -Invoke -CommandName Invoke-WinMediaDism -ModuleName WinMediaStoreApps -Times 0 -Exactly
    }

    It '雜湊一致時放行' {
        Install-WinMediaStoreApp -MountPath 'C:\mnt' -Set $script:hSet -Config $script:config
        Should -Invoke -CommandName Add-AppxProvisionedPackage -ModuleName WinMediaStoreApps -Times 1 -Exactly
    }
}
