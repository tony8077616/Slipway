#Requires -Version 5.1

Import-Module -Name (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'WinMediaRefresh.psd1') -Force

Describe 'Get-WinMediaWimlibSpec（wimlib 1.14.5 發行包）' -Tag 'Unit' {
    InModuleScope WinMediaWimlib {
        It 'AMD64 對應 x86_64 發行包與論壇公告 SHA-256' {
            $spec = Get-WinMediaWimlibSpec -Architecture 'AMD64'
            $spec.Architecture | Should -Be 'x86_64'
            $spec.FileName | Should -Be 'wimlib-1.14.5-windows-x86_64-bin.zip'
            $spec.Sha256 | Should -Be '2f446d6fa3866582175f1a22a7be198eeee0aec7aba5b4e04ad25c99eae2d265'
            $spec.Url | Should -Be 'https://wimlib.net/downloads/wimlib-1.14.5-windows-x86_64-bin.zip'
        }

        It 'ARM64 對應 aarch64 發行包' {
            (Get-WinMediaWimlibSpec -Architecture 'ARM64').Architecture | Should -Be 'aarch64'
        }

        It '不支援的架構中止' {
            { Get-WinMediaWimlibSpec -Architecture 'Itanium' } | Should -Throw '*不支援*'
        }
    }
}

Describe 'Test-WinMediaFileHash（SHA-256 校驗）' -Tag 'Unit' {
    InModuleScope WinMediaOperation {
        BeforeAll {
            $script:sample = Join-Path -Path $TestDrive -ChildPath 'sample.bin'
            [System.IO.File]::WriteAllText($script:sample, 'abc')
            $script:abcSha256 = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
        }

        It '雜湊相符時回傳 $true（大小寫不敏感）' {
            Test-WinMediaFileHash -Path $script:sample -Sha256 $script:abcSha256.ToUpperInvariant() | Should -BeTrue
        }

        It '雜湊不符時回傳 $false' {
            Test-WinMediaFileHash -Path $script:sample -Sha256 ('0' * 64) | Should -BeFalse
        }

        It '檔案不存在時回傳 $false' {
            Test-WinMediaFileHash -Path (Join-Path -Path $TestDrive -ChildPath 'none.bin') -Sha256 $script:abcSha256 | Should -BeFalse
        }
    }
}

Describe 'Resolve-WinMediaWimlib（手動指定與自動下載）' -Tag 'Unit' {
    InModuleScope WinMediaWimlib {
        BeforeEach {
            Mock Write-WinMediaLog { }
            Mock Invoke-WinMediaOperation { param([scriptblock]$ScriptBlock) & $ScriptBlock }
            Mock Invoke-WebRequest { }
        }

        It 'Wimlib.Path 指定的檔案已存在時直接使用，不下載' {
            $exe = Join-Path -Path $TestDrive -ChildPath 'manual\wimlib-imagex.exe'
            New-Item -ItemType Directory -Path (Split-Path -Parent $exe) -Force | Out-Null
            New-Item -ItemType File -Path $exe -Force | Out-Null
            $config = @{ Wimlib = @{ Path = $exe }; WorkDir = $TestDrive }

            Resolve-WinMediaWimlib -Config $config | Should -Be $exe
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        }

        It 'Wimlib.Path 指定但檔案不存在時，自動下載並校驗後解壓至該路徑' {
            $exe = Join-Path -Path $TestDrive -ChildPath 'auto\wimlib-imagex.exe'
            $config = @{ Wimlib = @{ Path = $exe }; WorkDir = $TestDrive }
            Mock Test-WinMediaFileHash { param([string]$Path) return ($Path -like '*downloads*') }
            Mock Expand-Archive { param([string]$DestinationPath)
                New-Item -ItemType File -Path (Join-Path -Path $DestinationPath -ChildPath 'wimlib-imagex.exe') -Force | Out-Null
            }

            Resolve-WinMediaWimlib -Config $config | Should -Be $exe
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly
            Should -Invoke Expand-Archive -Times 1 -Exactly
            Test-Path -LiteralPath $exe -PathType Leaf | Should -BeTrue
        }

        It '下載檔 SHA-256 不符時中止' {
            $exe = Join-Path -Path $TestDrive -ChildPath 'bad\wimlib-imagex.exe'
            $config = @{ Wimlib = @{ Path = $exe }; WorkDir = $TestDrive }
            Mock Test-WinMediaFileHash { return $false }

            { Resolve-WinMediaWimlib -Config $config } | Should -Throw '*SHA-256 不符*'
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly
        }
    }
}

Describe 'Invoke-WinMediaWimlib（wimlib 專用入口）' -Tag 'Unit' {
    InModuleScope WinMediaWimlib {
        BeforeEach {
            Mock Write-WinMediaLog { }
            Mock Resolve-WinMediaWimlib { return 'C:\tools\wimlib-imagex.exe' }
        }

        It '以 wimlib 自身參數呼叫外部程式' {
            Mock Invoke-WinMediaExternal { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }

            Invoke-WinMediaWimlib -ArgumentList @('export', 'a.wim', 'all', 'b.esd') -Config @{} | Out-Null

            Should -Invoke Invoke-WinMediaExternal -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq 'C:\tools\wimlib-imagex.exe' -and $ArgumentList[0] -eq 'export' -and $ArgumentList[3] -eq 'b.esd'
            }
        }

        It '結束碼非 0 時中止' {
            Mock Invoke-WinMediaExternal { [pscustomobject]@{ ExitCode = 2; StdOut = ''; StdErr = 'bad' } }

            { Invoke-WinMediaWimlib -ArgumentList @('export') -Config @{} } | Should -Throw '*結束碼 2*'
        }
    }
}

Describe 'Install-WinMediaAdk（自動安裝 Deployment Tools）' -Tag 'Unit' {
    InModuleScope WinMediaAdk {
        BeforeEach {
            Mock Write-WinMediaLog { }
            Mock Invoke-WinMediaOperation { param([scriptblock]$ScriptBlock) & $ScriptBlock }
            Mock Invoke-WebRequest { }
            Mock Remove-Item { }
        }

        It 'AdkRoot 為空時中止' {
            { Install-WinMediaAdk -Config @{ AdkRoot = ''; WorkDir = $TestDrive } } | Should -Throw '*AdkRoot 未設定*'
        }

        It '簽章有效且為 Microsoft 時以 /quiet 安裝 DeploymentTools' {
            Mock Get-AuthenticodeSignature {
                [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation' } }
            }
            Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }

            Install-WinMediaAdk -Config @{ AdkRoot = 'C:\ADK'; WorkDir = $TestDrive }

            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
                $ArgumentList -match '/quiet' -and $ArgumentList -match 'OptionId\.DeploymentTools'
            }
        }

        It '非 Microsoft 簽章時中止' {
            Mock Get-AuthenticodeSignature {
                [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Someone Else, O=Other' } }
            }
            Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }

            { Install-WinMediaAdk -Config @{ AdkRoot = 'C:\ADK'; WorkDir = $TestDrive } } | Should -Throw '*非 Microsoft*'
            Should -Invoke Start-Process -Times 0 -Exactly
        }

        It '安裝程式結束碼非 0 或 3010 時中止' {
            Mock Get-AuthenticodeSignature {
                [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation' } }
            }
            Mock Start-Process { [pscustomobject]@{ ExitCode = 1603 } }

            { Install-WinMediaAdk -Config @{ AdkRoot = 'C:\ADK'; WorkDir = $TestDrive } } | Should -Throw '*1603*'
        }
    }
}

Describe 'Resolve-WinMediaAdk / Resolve-WinMediaOscdimg（缺少時自動安裝）' -Tag 'Unit' {
    InModuleScope WinMediaAdk {
        BeforeEach {
            Mock Write-WinMediaLog { }
        }

        It 'ADK DISM 已存在時不安裝' {
            $root = Join-Path -Path $TestDrive -ChildPath 'ADK-present'
            New-Item -ItemType Directory -Path (Join-Path -Path $root -ChildPath 'Deployment Tools\10\DISM') -Force | Out-Null
            New-Item -ItemType File -Path (Join-Path -Path $root -ChildPath 'Deployment Tools\10\DISM\Dism.psd1') -Force | Out-Null
            Mock Install-WinMediaAdk { }

            (Resolve-WinMediaAdk -Config @{ AdkRoot = $root }).Root | Should -Be (Join-Path -Path $root -ChildPath 'Deployment Tools\10\DISM')
            Should -Invoke Install-WinMediaAdk -Times 0 -Exactly
        }

        It 'ADK DISM 缺少時安裝一次後重新探測' {
            $root = Join-Path -Path $TestDrive -ChildPath 'ADK-missing'
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            Mock Install-WinMediaAdk { param([hashtable]$Config)
                $dir = Join-Path -Path $Config.AdkRoot -ChildPath 'Deployment Tools\amd64\DISM'
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
                New-Item -ItemType File -Path (Join-Path -Path $dir -ChildPath 'Dism.psd1') -Force | Out-Null
            }

            (Resolve-WinMediaAdk -Config @{ AdkRoot = $root }).Root | Should -Be (Join-Path -Path $root -ChildPath 'Deployment Tools\amd64\DISM')
            Should -Invoke Install-WinMediaAdk -Times 1 -Exactly
        }

        It '安裝後仍找不到 DISM 時中止' {
            $root = Join-Path -Path $TestDrive -ChildPath 'ADK-broken'
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            Mock Install-WinMediaAdk { }

            { Resolve-WinMediaAdk -Config @{ AdkRoot = $root } } | Should -Throw '*仍找不到 DISM*'
        }

        It 'oscdimg 缺少時安裝 ADK 後回傳路徑' {
            $root = Join-Path -Path $TestDrive -ChildPath 'ADK-oscdimg'
            Mock Install-WinMediaAdk { param([hashtable]$Config)
                $dir = Join-Path -Path $Config.AdkRoot -ChildPath 'Deployment Tools\amd64\Oscdimg'
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
                New-Item -ItemType File -Path (Join-Path -Path $dir -ChildPath 'oscdimg.exe') -Force | Out-Null
            }

            Resolve-WinMediaOscdimg -Config @{ AdkRoot = $root } | Should -BeLike '*oscdimg.exe'
            Should -Invoke Install-WinMediaAdk -Times 1 -Exactly
        }
    }
}

Describe 'ESD 轉換與輸出的 wimlib／DISM 分流（§2.4）' -Tag 'Unit' {
    InModuleScope WinMediaEsd {
        BeforeEach {
            Mock Write-WinMediaLog { }
            Mock Invoke-WinMediaOperation { param([scriptblock]$ScriptBlock) & $ScriptBlock }
        }

        It 'Wimlib.Path 有指定時，ESD→WIM 只走 wimlib 參數，不呼叫 DISM' {
            $esd = Join-Path -Path $TestDrive -ChildPath 'in.esd'
            $wim = Join-Path -Path $TestDrive -ChildPath 'out.wim'
            [System.IO.File]::WriteAllText($esd, 'x')
            $config = @{ Wimlib = @{ Path = 'C:\w\wimlib-imagex.exe' }; DismProvider = 'Inbox'; LogDir = $TestDrive }
            Mock Invoke-WinMediaWimlib { param([string[]]$ArgumentList) New-Item -ItemType File -Path $ArgumentList[3] -Force | Out-Null }
            Mock Invoke-WinMediaDism { }

            Convert-WinMediaEsdToWim -SourceEsd $esd -DestinationWim $wim -Config $config

            Should -Invoke Invoke-WinMediaWimlib -Times 1 -Exactly -ParameterFilter {
                $ArgumentList[0] -eq 'export' -and $ArgumentList[1] -eq $esd -and $ArgumentList[2] -eq 'all' -and $ArgumentList[3] -eq $wim
            }
            Should -Invoke Invoke-WinMediaDism -Times 0 -Exactly
        }

        It 'Wimlib.Path 為空時，ESD→WIM 不呼叫 wimlib' {
            $esd = Join-Path -Path $TestDrive -ChildPath 'in2.esd'
            [System.IO.File]::WriteAllText($esd, 'x')
            $config = @{ Wimlib = @{ Path = '' }; DismProvider = 'Inbox'; LogDir = $TestDrive }
            Mock Invoke-WinMediaWimlib { }
            Mock Invoke-WinMediaDism { }

            { Convert-WinMediaEsdToWim -SourceEsd $esd -DestinationWim (Join-Path -Path $TestDrive -ChildPath 'o2.wim') -Config $config } |
                Should -Throw '*找不到輸出檔*'
            Should -Invoke Invoke-WinMediaWimlib -Times 0 -Exactly
        }

        It 'WIM→ESD 以 LZMS 與 solid 參數呼叫 wimlib 並移除來源 WIM' {
            $wim = Join-Path -Path $TestDrive -ChildPath 'src.wim'
            $esd = Join-Path -Path $TestDrive -ChildPath 'dst.esd'
            [System.IO.File]::WriteAllText($wim, 'x')
            Mock Invoke-WinMediaWimlib { }

            Export-WinMediaEsd -SourceWim $wim -DestinationEsd $esd -Config @{ Wimlib = @{ Path = '' }; LogDir = $TestDrive }

            Should -Invoke Invoke-WinMediaWimlib -Times 1 -Exactly -ParameterFilter {
                $ArgumentList -contains '--compress=LZMS' -and $ArgumentList -contains '--solid' -and $ArgumentList[1] -eq $wim
            }
            Test-Path -LiteralPath $wim | Should -BeFalse
        }
    }
}
