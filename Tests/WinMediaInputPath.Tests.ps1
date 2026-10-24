BeforeAll {
    Import-Module -Name (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'WinMediaRefresh.psd1') -Force
}

Describe '輸入資料夾集中於腳本目錄（Resolve-WinMediaInputPath）' -Tag 'Unit' {
    InModuleScope WinMediaPath {
        BeforeEach {
            # TestDrive 在同一檔案的測試間共用，每個測試用獨立子目錄避免殘留資料夾影響結果
            $script:root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $script:root -Force | Out-Null
            $script:cfg = @{
                PackageDir = ''
                Drivers    = @{ Path = '' }
                Lxp        = @{ Path = '' }
                Apps       = @{ CustomAppsList = '' }
            }
        }

        It 'PackageDir 留空時指向腳本目錄下的 Packages' {
            Resolve-WinMediaInputPath -RootDir $script:root -Config $script:cfg
            $script:cfg.PackageDir | Should -Be (Join-Path -Path $script:root -ChildPath 'Packages')
        }

        It '存在的 Drivers 與 Lxp 資料夾會被自動補上' {
            New-Item -ItemType Directory -Path (Join-Path -Path $script:root -ChildPath 'Drivers') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path -Path $script:root -ChildPath 'Lxp') -Force | Out-Null
            Resolve-WinMediaInputPath -RootDir $script:root -Config $script:cfg
            $script:cfg.Drivers.Path | Should -Be (Join-Path -Path $script:root -ChildPath 'Drivers')
            $script:cfg.Lxp.Path | Should -Be (Join-Path -Path $script:root -ChildPath 'Lxp')
        }

        It '資料夾不存在時維持停用（空白）' {
            Resolve-WinMediaInputPath -RootDir $script:root -Config $script:cfg
            $script:cfg.Drivers.Path | Should -BeNullOrEmpty
            $script:cfg.Lxp.Path | Should -BeNullOrEmpty
            $script:cfg.Apps.CustomAppsList | Should -BeNullOrEmpty
        }

        It '腳本目錄內的 CustomAppsList.txt 存在時自動啟用' {
            Set-Content -LiteralPath (Join-Path -Path $script:root -ChildPath 'CustomAppsList.txt') -Value 'Microsoft.Windows.Photos_8wekyb3d8bbwe'
            Resolve-WinMediaInputPath -RootDir $script:root -Config $script:cfg
            $script:cfg.Apps.CustomAppsList | Should -Be (Join-Path -Path $script:root -ChildPath 'CustomAppsList.txt')
        }

        It '設定檔已指定的路徑不被覆寫' {
            $script:cfg.PackageDir = 'E:\Custom\Pkgs'
            $script:cfg.Drivers.Path = 'E:\Drv'
            Resolve-WinMediaInputPath -RootDir $script:root -Config $script:cfg
            $script:cfg.PackageDir | Should -Be 'E:\Custom\Pkgs'
            $script:cfg.Drivers.Path | Should -Be 'E:\Drv'
        }
    }
}

Describe '舊設定檔缺 Lang／Fod／StoreApps（Resolve-WinMediaLegacyInputSection）' -Tag 'Unit' {
    InModuleScope WinMediaPath {
        It '缺鍵時補上空路徑，之後以 StrictMode 讀取 .Path 不拋錯' {
            $cfg = @{ PackageDir = ''; Drivers = @{ Path = '' }; Lxp = @{ Path = '' }; Apps = @{ CustomAppsList = '' } }
            Resolve-WinMediaLegacyInputSection -Config $cfg
            Set-StrictMode -Version 2.0
            { $cfg.Lang.Path } | Should -Not -Throw
            { $cfg.Fod.Path } | Should -Not -Throw
            { $cfg.StoreApps.Path } | Should -Not -Throw
            $cfg.Lang.Path | Should -BeNullOrEmpty
            $cfg.StoreApps.Path | Should -BeNullOrEmpty
        }

        It '已指定的 Lang 路徑不被覆寫' {
            $cfg = @{ Lang = @{ Path = 'D:\Lang' } }
            Resolve-WinMediaLegacyInputSection -Config $cfg
            $cfg.Lang.Path | Should -Be 'D:\Lang'
        }
    }

    It '主流程在 Lang／Fod／StoreApps 的 Clone 之前呼叫（AST）' {
        $file = Join-Path -Path $PSScriptRoot -ChildPath '..\Public\Invoke-WindowsMediaRefresh.ps1'
        $ast = [Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $file).Path, [ref]$null, [ref]$null)
        $calls = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Resolve-WinMediaLegacyInputSection' }, $true))
        $clone = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Value -eq 'Clone' -and $n.Expression.Extent.Text -eq '$Config.Lang' }, $true))
        $calls.Count | Should -Be 1
        $clone.Count | Should -Be 1
        $calls[0].Extent.StartOffset | Should -BeLessThan $clone[0].Extent.StartOffset
    }
}
