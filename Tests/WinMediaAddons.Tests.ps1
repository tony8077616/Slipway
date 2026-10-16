#Requires -Version 5.1

Import-Module -Name (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'WinMediaRefresh.psd1') -Force

Describe 'LXP 偵測與加入（§3.2、§5.5、§5.6）' -Tag 'Unit' {
    InModuleScope WinMediaLxp {
        BeforeAll {
            Add-Type -AssemblyName System.IO.Compression.FileSystem

            function Initialize-TestPackage {
                param([string]$Path, [hashtable]$Entries)
                New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
                $zip = [System.IO.Compression.ZipFile]::Open($Path, 'Create')
                try {
                    foreach ($name in $Entries.Keys) {
                        $entry = $zip.CreateEntry($name)
                        $writer = [IO.StreamWriter]::new($entry.Open())
                        try { $writer.Write($Entries[$name]) }
                        finally { $writer.Dispose() }
                    }
                }
                finally { $zip.Dispose() }
            }

            $script:manifest = '<?xml version="1.0" encoding="utf-8"?><Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"><Identity Name="Microsoft.LanguageExperiencePackja-JP" Publisher="CN=Microsoft" Version="1.0.0.0" /></Package>'
            $script:bundleManifest = '<?xml version="1.0" encoding="utf-8"?><Bundle xmlns="http://schemas.microsoft.com/appx/2013/bundle"><Identity Name="Microsoft.LanguageExperiencePackfr-FR" Publisher="CN=Microsoft" Version="1.0.0.0" /></Bundle>'
        }

        BeforeEach {
            Mock Write-WinMediaLog { }
            Mock Invoke-WinMediaOperation { param([scriptblock]$ScriptBlock) & $ScriptBlock }
            $script:cfg = @{ LogLevel = 'Info'; DebugTrace = 0 }
            $script:lxpRoot = Join-Path -Path $TestDrive -ChildPath ('lxp-' + [guid]::NewGuid().ToString('N'))
            $script:tempDir = Join-Path -Path $TestDrive -ChildPath ('tmp-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $script:tempDir -Force | Out-Null
        }

        It '遞迴找到 LanguageExperiencePack 的 appx' {
            Initialize-TestPackage -Path (Join-Path -Path $script:lxpRoot -ChildPath 'deep\LanguageExperiencePack.ja-JP.appx') -Entries @{ 'AppxManifest.xml' = $script:manifest; 'License.xml' = '<License/>' }
            $items = @(Resolve-WinMediaLxp -Path $script:lxpRoot -TempDir $script:tempDir -Config $script:cfg)
            $items.Count | Should -Be 1
            $items[0].PackagePath | Should -BeLike '*LanguageExperiencePack.ja-JP.appx'
        }

        It '忽略非 LXP 的 appx 與其他副檔名' {
            Initialize-TestPackage -Path (Join-Path -Path $script:lxpRoot -ChildPath 'OtherApp.appx') -Entries @{ 'AppxManifest.xml' = $script:manifest; 'License.xml' = '<License/>' }
            Initialize-TestPackage -Path (Join-Path -Path $script:lxpRoot -ChildPath 'LanguageExperiencePack.zip') -Entries @{ 'AppxManifest.xml' = $script:manifest; 'License.xml' = '<License/>' }
            @(Resolve-WinMediaLxp -Path $script:lxpRoot -TempDir $script:tempDir -Config $script:cfg).Count | Should -Be 0
        }

        It '從 zip 讀出 PFN 並解出 License.xml' {
            Initialize-TestPackage -Path (Join-Path -Path $script:lxpRoot -ChildPath 'LanguageExperiencePack.ja-JP.appx') -Entries @{ 'AppxManifest.xml' = $script:manifest; 'License.xml' = '<License>ja</License>' }
            $item = @(Resolve-WinMediaLxp -Path $script:lxpRoot -TempDir $script:tempDir -Config $script:cfg)[0]
            $item.Pfn | Should -Be 'Microsoft.LanguageExperiencePackja-JP_8wekyb3d8bbwe'
            Get-Content -LiteralPath $item.LicensePath -Raw | Should -Match '<License>ja</License>'
        }

        It 'bundle 以 AppxMetadata 下的 manifest 讀出 PFN' {
            Initialize-TestPackage -Path (Join-Path -Path $script:lxpRoot -ChildPath 'LanguageExperiencePack.fr-FR.appxbundle') -Entries @{ 'AppxMetadata/AppxBundleManifest.xml' = $script:bundleManifest; 'License.xml' = '<License/>' }
            $item = @(Resolve-WinMediaLxp -Path $script:lxpRoot -TempDir $script:tempDir -Config $script:cfg)[0]
            $item.Pfn | Should -Be 'Microsoft.LanguageExperiencePackfr-FR_8wekyb3d8bbwe'
        }

        It '缺 License.xml 時略過並寫入 Warning' {
            Initialize-TestPackage -Path (Join-Path -Path $script:lxpRoot -ChildPath 'LanguageExperiencePack.ja-JP.appx') -Entries @{ 'AppxManifest.xml' = $script:manifest }
            @(Resolve-WinMediaLxp -Path $script:lxpRoot -TempDir $script:tempDir -Config $script:cfg).Count | Should -Be 0
            Should -Invoke Write-WinMediaLog -ParameterFilter { $Level -eq 'Warning' -and $Message -like '*License.xml*' }
        }

        It 'Path 空白時回傳空陣列' {
            @(Resolve-WinMediaLxp -Path '' -TempDir $script:tempDir -Config $script:cfg).Count | Should -Be 0
        }

        It 'Install-WinMediaLxp 使用 Add-AppxProvisionedPackage 並帶入 Regions all' {
            Mock Invoke-WinMediaDism { param([scriptblock]$ScriptBlock) & $ScriptBlock }
            Mock Add-AppxProvisionedPackage { param($Path, $PackagePath, $LicensePath, $Regions) $null = $Path, $PackagePath, $LicensePath, $Regions }
            $item = [pscustomobject]@{ PackagePath = 'C:\x.appx'; LicensePath = 'C:\x.xml'; Pfn = 'P' }
            Install-WinMediaLxp -MountPath 'M:\m' -Lxp @($item) -Config @{ DismProvider = 'Inbox'; LogLevel = 'Info' }
            Should -Invoke Add-AppxProvisionedPackage -Times 1 -Exactly -ParameterFilter {
                $Path -eq 'M:\m' -and $PackagePath -eq 'C:\x.appx' -and $LicensePath -eq 'C:\x.xml' -and $Regions -eq 'all'
            }
        }
    }
}

Describe 'CustomAppsList 解析（§3.3、§5.7）' -Tag 'Unit' {
    InModuleScope WinMediaAppx {
        BeforeEach {
            Mock Write-WinMediaLog { }
            $script:cfg = @{ LogLevel = 'Info' }
            $script:listPath = Join-Path -Path $TestDrive -ChildPath ('list-' + [guid]::NewGuid().ToString('N') + '.txt')
        }

        It '忽略註解與空行、去除空白' {
            Set-Content -LiteralPath $script:listPath -Value @('# 註解', '', '  Microsoft.WindowsCalculator_8wekyb3d8bbwe  ', 'Microsoft.WindowsStore_8wekyb3d8bbwe')
            $list = Resolve-WinMediaAppxList -Path $script:listPath -Mode Remove -Config $script:cfg
            $list.Names | Should -Be @('Microsoft.WindowsCalculator_8wekyb3d8bbwe', 'Microsoft.WindowsStore_8wekyb3d8bbwe')
        }

        It '清單檔不存在時丟錯' {
            { Resolve-WinMediaAppxList -Path (Join-Path -Path $TestDrive -ChildPath 'missing.txt') -Mode Remove -Config $script:cfg } |
                Should -Throw '找不到 CustomAppsList*'
        }

        It 'Keep 模式清單為空時拒絕執行' {
            Set-Content -LiteralPath $script:listPath -Value @('# 只有註解')
            { Resolve-WinMediaAppxList -Path $script:listPath -Mode Keep -Config $script:cfg } | Should -Throw '*拒絕執行*'
        }

        It '路徑空白時回傳 $null' {
            Resolve-WinMediaAppxList -Path '' -Mode Remove -Config $script:cfg | Should -BeNullOrEmpty
        }
    }
}

Describe 'Appx 移除（§3.3、§5.8）' -Tag 'Unit' {
    InModuleScope WinMediaAppx {
        BeforeEach {
            Mock Write-WinMediaLog { }
            Mock Invoke-WinMediaDism { param([scriptblock]$ScriptBlock) & $ScriptBlock }
            Mock Remove-AppxProvisionedPackage { param($Path, $PackageName) $null = $Path, $PackageName }
            Mock Get-AppxProvisionedPackage {
                @(
                    [pscustomobject]@{ DisplayName = 'Microsoft.WindowsCalculator'; PackageName = 'Microsoft.WindowsCalculator_11.2409.4.0_x64__8wekyb3d8bbwe' }
                    [pscustomobject]@{ DisplayName = 'Microsoft.Windows.Photos'; PackageName = 'Microsoft.Windows.Photos_2024.1_x64__8wekyb3d8bbwe' }
                    [pscustomobject]@{ DisplayName = 'Microsoft.VCLibs.140.00'; PackageName = 'Microsoft.VCLibs.140.00_14.0_x64__8wekyb3d8bbwe' }
                    [pscustomobject]@{ DisplayName = 'Microsoft.LanguageExperiencePackja-JP'; PackageName = 'Microsoft.LanguageExperiencePackja-JP_1.0_neutral__8wekyb3d8bbwe' }
                    [pscustomobject]@{ DisplayName = 'Microsoft.WindowsStore'; PackageName = 'Microsoft.WindowsStore_22408.1401.0.0_x64__8wekyb3d8bbwe' }
                    [pscustomobject]@{ DisplayName = 'Microsoft.SecHealthUI'; PackageName = 'Microsoft.SecHealthUI_1000.26100.1.0_x64__8wekyb3d8bbwe' }
                    [pscustomobject]@{ DisplayName = 'Microsoft.HEVCVideoExtension'; PackageName = 'Microsoft.HEVCVideoExtension_2.0_x64__8wekyb3d8bbwe' }
                )
            }
            $script:cfg = @{ LogLevel = 'Info'; DismProvider = 'Inbox' }
        }

        It 'Remove 模式只移除清單內的 app' {
            $list = [pscustomobject]@{ Mode = 'Remove'; Names = @('Microsoft.WindowsCalculator_8wekyb3d8bbwe') }
            Remove-WinMediaAppx -MountPath 'M:\m' -AppxList $list -Config $script:cfg
            Should -Invoke Remove-AppxProvisionedPackage -Times 1 -Exactly -ParameterFilter {
                $PackageName -eq 'Microsoft.WindowsCalculator_11.2409.4.0_x64__8wekyb3d8bbwe'
            }
        }

        It 'Remove 模式的比對不分大小寫' {
            $list = [pscustomobject]@{ Mode = 'Remove'; Names = @('MICROSOFT.WINDOWSCALCULATOR_8WEKYB3D8BBWE') }
            Remove-WinMediaAppx -MountPath 'M:\m' -AppxList $list -Config $script:cfg
            Should -Invoke Remove-AppxProvisionedPackage -Times 1 -Exactly
        }

        It 'Keep 模式移除清單外的 app，但保留框架與語言套件' {
            $list = [pscustomobject]@{ Mode = 'Keep'; Names = @('Microsoft.Windows.Photos_8wekyb3d8bbwe') }
            Remove-WinMediaAppx -MountPath 'M:\m' -AppxList $list -Config $script:cfg
            Should -Invoke Remove-AppxProvisionedPackage -Times 1 -Exactly -ParameterFilter {
                $PackageName -eq 'Microsoft.WindowsCalculator_11.2409.4.0_x64__8wekyb3d8bbwe'
            }
            Should -Invoke Remove-AppxProvisionedPackage -Times 0 -Exactly -ParameterFilter { $PackageName -like '*VCLibs*' }
            Should -Invoke Remove-AppxProvisionedPackage -Times 0 -Exactly -ParameterFilter { $PackageName -like '*LanguageExperiencePack*' }
        }

        It 'Keep 模式保留 Store、安全性與編解碼套件（依 install.wim 盤點）' {
            $list = [pscustomobject]@{ Mode = 'Keep'; Names = @('Microsoft.Windows.Photos_8wekyb3d8bbwe') }
            Remove-WinMediaAppx -MountPath 'M:\m' -AppxList $list -Config $script:cfg
            Should -Invoke Remove-AppxProvisionedPackage -Times 0 -Exactly -ParameterFilter { $PackageName -like 'Microsoft.WindowsStore_*' }
            Should -Invoke Remove-AppxProvisionedPackage -Times 0 -Exactly -ParameterFilter { $PackageName -like 'Microsoft.SecHealthUI_*' }
            Should -Invoke Remove-AppxProvisionedPackage -Times 0 -Exactly -ParameterFilter { $PackageName -like 'Microsoft.HEVCVideoExtension_*' }
        }
    }
}

Describe '步驟 6 順序（§5.9）' -Tag 'Unit' {
    BeforeAll {
        $mainPath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Public\Invoke-WindowsMediaRefresh.ps1'
        $script:ast = [System.Management.Automation.Language.Parser]::ParseFile($mainPath, [ref]$null, [ref]$null)
        $script:commands = @($script:ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
        $script:step6Start = ($script:commands | Where-Object { $_.GetCommandName() -eq 'Remove-WinMediaAppx' }).Extent.StartOffset
        $script:step6Commands = @($script:commands | Where-Object { $_.Extent.StartOffset -ge $script:step6Start })
        $script:lcu = $script:commands | Where-Object { $_.GetCommandName() -eq 'Add-WindowsPackage' -and $_.Extent.Text -like '*$lcu*' } | Select-Object -First 1
    }

    It 'LCU → Appx 移除 → LXP 加入 → 驅動（Install）→ winre 複製 的順序正確' {
        $appx = $script:step6Commands | Where-Object { $_.GetCommandName() -eq 'Remove-WinMediaAppx' } | Select-Object -First 1
        $lxp = $script:step6Commands | Where-Object { $_.GetCommandName() -eq 'Install-WinMediaLxp' } | Select-Object -First 1
        $driver = $script:step6Commands | Where-Object {
            $_.GetCommandName() -eq 'Install-WinMediaDriver' -and $_.Extent.Text -like "*'Install'*"
        } | Select-Object -First 1
        $copy = $script:step6Commands | Where-Object { $_.Extent.Text -like '*ReplaceWinRE*' } | Select-Object -First 1
        foreach ($node in @($script:lcu, $appx, $lxp, $driver, $copy)) { $node | Should -Not -BeNullOrEmpty }
        $script:lcu.Extent.StartOffset | Should -BeLessThan $appx.Extent.StartOffset
        $appx.Extent.StartOffset | Should -BeLessThan $lxp.Extent.StartOffset
        $lxp.Extent.StartOffset | Should -BeLessThan $driver.Extent.StartOffset
        $driver.Extent.StartOffset | Should -BeLessThan $copy.Extent.StartOffset
    }
}
