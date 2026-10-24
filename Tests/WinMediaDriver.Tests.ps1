#Requires -Version 5.1

Import-Module -Name (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'WinMediaRefresh.psd1') -Force

Describe 'Resolve-WinMediaForceUnsigned（Drivers.ForceUnsigned 必須為布林）' -Tag 'Unit' {
    InModuleScope WinMediaDriver {
        It '字串 ''false'' 直接中止，不靜默轉為 $true' {
            { Resolve-WinMediaForceUnsigned -Config @{ Drivers = @{ ForceUnsigned = 'false' } } } | Should -Throw '*必須*布林*'
        }

        It '布林 $true 與 $false 原樣回傳' {
            Resolve-WinMediaForceUnsigned -Config @{ Drivers = @{ ForceUnsigned = $true } } | Should -BeTrue
            Resolve-WinMediaForceUnsigned -Config @{ Drivers = @{ ForceUnsigned = $false } } | Should -BeFalse
        }

        It '缺鍵時視為 $false（安全預設）' {
            Resolve-WinMediaForceUnsigned -Config @{ Drivers = @{ Path = '' } } | Should -BeFalse
        }
    }
}

Describe '主流程接線：ForceUnsigned 經 Resolve-WinMediaForceUnsigned（AST）' -Tag 'Unit' {
    It '主流程呼叫 Resolve-WinMediaForceUnsigned，且不再以 [bool] 強制轉型 Drivers.ForceUnsigned' {
        $mainPath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Public\Invoke-WindowsMediaRefresh.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($mainPath, [ref]$null, [ref]$null)
        $resolve = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Resolve-WinMediaForceUnsigned' }, $true))
        $cast = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ConvertExpressionAst] -and $n.Extent.Text -match 'Drivers\.ForceUnsigned' }, $true))
        $resolve.Count | Should -Be 1
        $cast.Count | Should -Be 0
    }
}

Describe 'Test-WinMediaPathOverlap（§3.4）' -Tag 'Unit' {
    InModuleScope WinMediaPath {
        It '完全獨立的路徑通過' {
            { Test-WinMediaPathOverlap -Paths @{ PackageDir = 'D:\pkg'; WorkDir = 'D:\work' } } | Should -Not -Throw
        }

        It '相等的路徑丟錯' {
            { Test-WinMediaPathOverlap -Paths @{ PackageDir = 'D:\x'; Drivers = 'D:\x\' } } | Should -Throw '*重疊*'
        }

        It '驅動位於 PackageDir 內丟錯' {
            { Test-WinMediaPathOverlap -Paths @{ PackageDir = 'D:\pkg'; Drivers = 'D:\pkg\drv' } } | Should -Throw '*重疊*'
        }

        It '驅動與 LXP 互相重疊丟錯' {
            { Test-WinMediaPathOverlap -Paths @{ Drivers = 'D:\a'; Lxp = 'D:\a\lxp' } } | Should -Throw '*重疊*'
        }

        It 'LXP 位於 WorkDir 內丟錯' {
            { Test-WinMediaPathOverlap -Paths @{ WorkDir = 'D:\work'; Lxp = 'D:\work\lxp' } } | Should -Throw '*重疊*'
        }

        It '只是前綴相同的兄弟資料夾不算重疊' {
            { Test-WinMediaPathOverlap -Paths @{ PackageDir = 'D:\pkg'; Drivers = 'D:\pkg2' } } | Should -Not -Throw
        }

        It '空白路徑略過' {
            { Test-WinMediaPathOverlap -Paths @{ PackageDir = 'D:\pkg'; Drivers = ''; Lxp = $null } } | Should -Not -Throw
        }
    }
}

Describe 'Resolve-WinMediaDriverSet（§3.1）' -Tag 'Unit' {
    InModuleScope WinMediaDriver {
        BeforeAll {
            function Initialize-DriverFixture {
                param([string]$Root, [string[]]$States)
                foreach ($state in $States) {
                    $dir = Join-Path -Path $Root -ChildPath (Join-Path -Path $state -ChildPath 'sub')
                    New-Item -ItemType Directory -Path $dir -Force | Out-Null
                    Set-Content -LiteralPath (Join-Path -Path $dir -ChildPath 'driver.inf') -Value '[Version]'
                }
            }
        }

        BeforeEach {
            Mock Write-WinMediaLog { }
            $script:cfg = @{ LogLevel = 'Info'; Drivers = @{ ForceUnsigned = $false } }
        }

        It '路徑空白時回傳 $null' {
            Resolve-WinMediaDriverSet -Path '' -Config $script:cfg | Should -BeNullOrEmpty
        }

        It '路徑不存在時丟錯' {
            { Resolve-WinMediaDriverSet -Path (Join-Path -Path $TestDrive -ChildPath 'none') -Config $script:cfg } |
                Should -Throw '找不到驅動程式資料夾*'
        }

        It '根目錄的 .inf 寫入 Warning 且不被使用' {
            $root = Join-Path -Path $TestDrive -ChildPath 'rootinf'
            Initialize-DriverFixture -Root $root -States 'ALL'
            Set-Content -LiteralPath (Join-Path -Path $root -ChildPath 'root.inf') -Value '[Version]'
            $set = Resolve-WinMediaDriverSet -Path $root -Config $script:cfg
            $set.Keys | Should -Be @('ALL')
            Should -Invoke Write-WinMediaLog -ParameterFilter { $Level -eq 'Warning' -and $Message -like '*根目錄*' }
        }

        It 'ALL 子資料夾對應 WinRE、Install、Boot' {
            $root = Join-Path -Path $TestDrive -ChildPath 'all'
            Initialize-DriverFixture -Root $root -States 'ALL'
            $set = Resolve-WinMediaDriverSet -Path $root -Config $script:cfg
            $set.ALL.Targets.WinRE | Should -BeTrue
            $set.ALL.Targets.Install | Should -BeTrue
            $set.ALL.Targets.Boot | Should -BeTrue
        }

        It 'WinPE 子資料夾不對應 Install' {
            $root = Join-Path -Path $TestDrive -ChildPath 'winpe'
            Initialize-DriverFixture -Root $root -States 'WinPE'
            $set = Resolve-WinMediaDriverSet -Path $root -Config $script:cfg
            $set.WinPE.Targets.WinRE | Should -BeTrue
            $set.WinPE.Targets.Install | Should -BeFalse
            $set.WinPE.Targets.Boot | Should -BeTrue
        }

        It 'OS 子資料夾只對應 Install' {
            $root = Join-Path -Path $TestDrive -ChildPath 'os'
            Initialize-DriverFixture -Root $root -States 'OS'
            $set = Resolve-WinMediaDriverSet -Path $root -Config $script:cfg
            $set.OS.Targets.WinRE | Should -BeFalse
            $set.OS.Targets.Install | Should -BeTrue
            $set.OS.Targets.Boot | Should -BeFalse
        }

        It '缺少的子資料夾寫入 Warning 並略過' {
            $root = Join-Path -Path $TestDrive -ChildPath 'partial'
            Initialize-DriverFixture -Root $root -States 'OS'
            $set = Resolve-WinMediaDriverSet -Path $root -Config $script:cfg
            $set.Keys | Should -Be @('OS')
            Should -Invoke Write-WinMediaLog -ParameterFilter { $Level -eq 'Warning' -and $Message -like "*'ALL'*" }
        }

        It '三種狀態皆無 .inf 時回傳 $null' {
            $root = Join-Path -Path $TestDrive -ChildPath 'empty'
            New-Item -ItemType Directory -Path (Join-Path -Path $root -ChildPath 'ALL') -Force | Out-Null
            Resolve-WinMediaDriverSet -Path $root -Config $script:cfg | Should -BeNullOrEmpty
        }

        It '遞迴計入深層子資料夾的 .inf' {
            $root = Join-Path -Path $TestDrive -ChildPath 'deep'
            Initialize-DriverFixture -Root $root -States 'ALL'
            $deep = Join-Path -Path $root -ChildPath 'ALL\a\b\c'
            New-Item -ItemType Directory -Path $deep -Force | Out-Null
            Set-Content -LiteralPath (Join-Path -Path $deep -ChildPath 'deep.inf') -Value '[Version]'
            $set = Resolve-WinMediaDriverSet -Path $root -Config $script:cfg
            $set.ALL.InfCount | Should -Be 2
        }

        It 'ForceUnsigned 開啟時寫入 Warning' {
            $root = Join-Path -Path $TestDrive -ChildPath 'unsigned'
            Initialize-DriverFixture -Root $root -States 'ALL'
            $script:cfg.Drivers.ForceUnsigned = $true
            Resolve-WinMediaDriverSet -Path $root -Config $script:cfg | Out-Null
            Should -Invoke Write-WinMediaLog -ParameterFilter { $Level -eq 'Warning' -and $Message -like '*ForceUnsigned*' }
        }
    }
}

Describe 'Install-WinMediaDriver（§3.1、§5.4）' -Tag 'Unit' {
    InModuleScope WinMediaDriver {
        BeforeEach {
            Mock Write-WinMediaLog { }
            Mock Invoke-WinMediaDism { param([scriptblock]$ScriptBlock) & $ScriptBlock }
            Mock Add-WindowsDriver { param($Path, $Driver, [switch]$Recurse, [switch]$ForceUnsigned) $null = $Path, $Driver, $Recurse, $ForceUnsigned }
            $script:cfg = @{ LogLevel = 'Info'; DismProvider = 'Inbox'; DismLogLevel = 'Debug'; Drivers = @{ ForceUnsigned = $false } }
            $script:root = Join-Path -Path $TestDrive -ChildPath ('set-' + [guid]::NewGuid().ToString('N'))
            foreach ($state in 'ALL', 'WinPE', 'OS') {
                New-Item -ItemType Directory -Path (Join-Path -Path $script:root -ChildPath $state) -Force | Out-Null
                Set-Content -LiteralPath (Join-Path -Path $script:root -ChildPath (Join-Path -Path $state -ChildPath 'd.inf')) -Value '[Version]'
            }
            $script:full = Resolve-WinMediaDriverSet -Path $script:root -Config $script:cfg
        }

        It 'ALL 狀態在 WinRE、Install、Boot 各注入一次' {
            $set = @{ ALL = $script:full.ALL }
            foreach ($target in 'WinRE', 'Install', 'Boot') {
                Install-WinMediaDriver -MountPath 'M:\m' -Target $target -DriverSet $set -ForceUnsigned $false -Config $script:cfg
            }
            Should -Invoke Add-WindowsDriver -Times 3 -Exactly
        }

        It 'WinPE 狀態不注入 Install 目標' {
            $set = @{ WinPE = $script:full.WinPE }
            Install-WinMediaDriver -MountPath 'M:\m' -Target 'Install' -DriverSet $set -ForceUnsigned $false -Config $script:cfg
            Should -Invoke Add-WindowsDriver -Times 0 -Exactly
        }

        It 'WinPE 狀態注入 WinRE 與 Boot' {
            $set = @{ WinPE = $script:full.WinPE }
            Install-WinMediaDriver -MountPath 'M:\m' -Target 'WinRE' -DriverSet $set -ForceUnsigned $false -Config $script:cfg
            Install-WinMediaDriver -MountPath 'M:\m' -Target 'Boot' -DriverSet $set -ForceUnsigned $false -Config $script:cfg
            Should -Invoke Add-WindowsDriver -Times 2 -Exactly -ParameterFilter { $Driver -like '*WinPE*' }
        }

        It 'OS 狀態只注入 Install 目標' {
            $set = @{ OS = $script:full.OS }
            Install-WinMediaDriver -MountPath 'M:\m' -Target 'WinRE' -DriverSet $set -ForceUnsigned $false -Config $script:cfg
            Install-WinMediaDriver -MountPath 'M:\m' -Target 'Install' -DriverSet $set -ForceUnsigned $false -Config $script:cfg
            Should -Invoke Add-WindowsDriver -Times 1 -Exactly -ParameterFilter { $Driver -like '*OS*' }
        }

        It 'ForceUnsigned 為 false 時不傳遞未簽章旗標' {
            $set = @{ OS = $script:full.OS }
            Install-WinMediaDriver -MountPath 'M:\m' -Target 'Install' -DriverSet $set -ForceUnsigned $false -Config $script:cfg
            Should -Invoke Add-WindowsDriver -Times 1 -Exactly -ParameterFilter { -not $ForceUnsigned.IsPresent }
        }

        It 'ForceUnsigned 為 true 時傳遞未簽章旗標' {
            $set = @{ OS = $script:full.OS }
            Install-WinMediaDriver -MountPath 'M:\m' -Target 'Install' -DriverSet $set -ForceUnsigned $true -Config $script:cfg
            Should -Invoke Add-WindowsDriver -Times 1 -Exactly -ParameterFilter { $ForceUnsigned.IsPresent }
        }
    }
}

Describe 'Invoke-WindowsMediaRefresh 驅動注入位置（§5.9）' -Tag 'Unit' {
    BeforeAll {
        $script:mainPath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Public\Invoke-WindowsMediaRefresh.ps1'
        $script:ast = [System.Management.Automation.Language.Parser]::ParseFile($script:mainPath, [ref]$null, [ref]$null)
        $script:commands = @($script:ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
        $script:driverCalls = @($script:commands | Where-Object { $_.GetCommandName() -eq 'Install-WinMediaDriver' })
    }

    It '驅動注入呼叫共三處' {
        $script:driverCalls.Count | Should -Be 3
    }

    It '三處分別對應 WinRE、Install、Boot' {
        $targets = foreach ($call in $script:driverCalls) {
            $elements = @($call.CommandElements | ForEach-Object { $_.Extent.Text })
            $index = [array]::IndexOf($elements, '-Target')
            $index | Should -BeGreaterOrEqual 0
            $elements[$index + 1].Trim("'")
        }
        $targets | Should -Be @('WinRE', 'Install', 'Boot')
    }

    It 'WinRE 驅動注入位於 winre 的 Repair 之後' {
        $repair = $script:commands | Where-Object { $_.GetCommandName() -eq 'Repair-WindowsImage' } | Select-Object -First 1
        $script:driverCalls[0].Extent.StartOffset | Should -BeGreaterThan $repair.Extent.StartOffset
    }

    It 'Boot 驅動注入位於 boot 索引 1、2 的 Repair 之後，且早於 WinPE 同步（媒體 → 索引 2）' {
        $boot = $script:driverCalls[2].Extent.StartOffset
        $lastRepair = @($script:commands | Where-Object { $_.GetCommandName() -eq 'Repair-WindowsImage' -and $_.Extent.StartOffset -lt $boot }) | Select-Object -Last 1
        $lastRepair | Should -Not -BeNullOrEmpty
        $sync = $script:commands | Where-Object { $_.GetCommandName() -eq 'Copy-WinMediaBootWimSources' } | Select-Object -First 1
        $boot | Should -BeLessThan $sync.Extent.StartOffset
    }
}

Describe 'Default.psd1 新設定鍵（§5.1）' -Tag 'Unit' {
    BeforeAll {
        $script:defaults = Import-PowerShellDataFile -LiteralPath (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Config\Default.psd1')
    }

    It 'Drivers、Lxp、Apps 預設為停用或 Remove' {
        $script:defaults.Drivers.Path | Should -Be ''
        $script:defaults.Drivers.ForceUnsigned | Should -BeFalse
        $script:defaults.Lxp.Path | Should -Be ''
        $script:defaults.Apps.CustomAppsList | Should -Be ''
        $script:defaults.Apps.CustomListMode | Should -Be 'Remove'
    }

    It '舊鍵 Recurse 與 Targets 不存在' {
        $script:defaults.Drivers.ContainsKey('Recurse') | Should -BeFalse
        $script:defaults.Drivers.ContainsKey('Targets') | Should -BeFalse
    }
}
