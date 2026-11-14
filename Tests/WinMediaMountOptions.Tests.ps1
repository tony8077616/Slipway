#Requires -Version 5.1

BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    Import-Module -Name (Join-Path -Path $script:root -ChildPath 'WinMediaRefresh.psd1') -Force
    Import-Module -Name (Join-Path -Path $script:root -ChildPath 'Modules\WinMediaPath.psm1') -Force
    $script:defaults = Import-PowerShellDataFile -LiteralPath (Join-Path -Path $script:root -ChildPath 'Config\Default.psd1')

    function Get-SourceFile {
        Get-ChildItem -LiteralPath (Join-Path -Path $script:root -ChildPath 'Public') -Filter '*.ps1' -File
        Get-ChildItem -LiteralPath (Join-Path -Path $script:root -ChildPath 'Modules') -Filter '*.psm1' -File
        Get-ChildItem -LiteralPath (Join-Path -Path $script:root -ChildPath 'PSModules\Imaging') -Filter '*.psm1' -File
    }

    function Get-AstNode {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Type', Justification = 'FindAll 的 scriptblock 使用，PSSA 無法追蹤')]
        param([string]$Path, [type]$Type)
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        return @($ast.FindAll({ param($n) $n -is $Type }, $true))
    }
}

Describe 'Get-WinMediaMountSwitch（可寫掛載的開關）' -Tag 'Unit' {
    It 'MountOptimize=<Opt>、MountCheckIntegrity=<Chk> 時 Optimize=<ExpOpt>、CheckIntegrity=<ExpChk>' -ForEach @(
        @{ Opt = $false; Chk = $false; ExpOpt = $false; ExpChk = $false }
        @{ Opt = $true; Chk = $false; ExpOpt = $true; ExpChk = $false }
        @{ Opt = $false; Chk = $true; ExpOpt = $false; ExpChk = $true }
        @{ Opt = $true; Chk = $true; ExpOpt = $true; ExpChk = $true }
    ) {
        $r = Get-WinMediaMountSwitch -Config @{ MountOptimize = $Opt; MountCheckIntegrity = $Chk }
        $r.ContainsKey('Optimize') | Should -Be $ExpOpt
        $r.ContainsKey('CheckIntegrity') | Should -Be $ExpChk
    }
}

Describe 'Resolve-WinMediaMountOption 布林驗證（Step 10c）' -Tag 'Unit' {
    It 'MountOptimize 為字串時拒絕（字串 ''false'' 為真值）' {
        { Resolve-WinMediaMountOption -Config @{ MountOptimize = 'false' } } | Should -Throw '*MountOptimize*'
    }

    It 'MountCheckIntegrity 為字串時拒絕' {
        { Resolve-WinMediaMountOption -Config @{ MountCheckIntegrity = 'true' } } | Should -Throw '*MountCheckIntegrity*'
    }
}

Describe 'Invoke-WindowsMediaRefresh 掛載守衛與 DISM 靜態檢查（Step 10c）' -Tag 'Unit' {
    BeforeEach {
        Mock -ModuleName WinMediaRefresh -CommandName Test-WinMediaAdministrator -MockWith { $true }
        Mock -ModuleName WinMediaRefresh -CommandName Test-WinMediaDismHost -MockWith { }
        Mock -ModuleName WinMediaRefresh -CommandName Resolve-WinMediaAdk -MockWith { }
        Mock -ModuleName WinMediaRefresh -CommandName Get-WinMediaVolumeFileSystem -MockWith { 'NTFS' }
        Mock -ModuleName WinMediaRefresh -CommandName Resolve-WinMediaWimlib -MockWith { 'C:\fake\wimlib-imagex.exe' }
        Mock -ModuleName WinMediaRefresh -CommandName Resolve-WinMediaOscdimg -MockWith { 'C:\fake\oscdimg.exe' }
        Mock -ModuleName WinMediaRefresh -CommandName Resolve-WinMediaDriverSet -MockWith { $null }
        Mock -ModuleName WinMediaRefresh -CommandName Resolve-WinMediaAppxList -MockWith { @() }
        Mock -ModuleName WinMediaRefresh -CommandName Resolve-WinMediaLangFodSet -MockWith { $null }
        Mock -ModuleName WinMediaRefresh -CommandName Resolve-WinMediaStoreAppSet -MockWith { $null }
        Mock -ModuleName WinMediaRefresh -CommandName Assert-WinMediaOutputDir -MockWith { throw 'SENTINEL' }
    }

    It 'NeedsRemount 的子資料夾：丟出指向清理腳本的訊息，並以子資料夾路徑查詢' {
        Mock -ModuleName WinMediaRefresh -CommandName Assert-WinMediaOutputDir -MockWith { }
        Mock -ModuleName WinMediaRefresh -CommandName Get-WinMediaMountState -MockWith { 'Unknown' }
        Mock -ModuleName WinMediaRefresh -CommandName Get-WinMediaMountState -ParameterFilter { $Path -like '*\install-1' } -MockWith { 'NeedsRemount' }
        $mnt = Join-Path -Path $TestDrive -ChildPath 'mnt-stale'
        New-Item -ItemType Directory -Path (Join-Path -Path $mnt -ChildPath 'install-1') -Force | Out-Null
        $iso = Join-Path -Path $TestDrive -ChildPath 'source.iso'
        New-Item -ItemType File -Path $iso -Force | Out-Null
        $cfg = $script:defaults.Clone()
        $cfg.DefenderExclusions = $false
        $cfg.PackageDir = Join-Path -Path $TestDrive -ChildPath 'pkg'
        New-Item -ItemType Directory -Path $cfg.PackageDir -Force | Out-Null
        { Invoke-WindowsMediaRefresh -SourceIso $iso -Config $cfg -MountDir $mnt -WorkDir (Join-Path -Path $TestDrive -ChildPath 'w') -OutputDir (Join-Path -Path $TestDrive -ChildPath 'out') } |
            Should -Throw '*NeedsRemount*'
        Should -Invoke -ModuleName WinMediaRefresh -CommandName Get-WinMediaMountState -ParameterFilter { $Path -like '*\install-1' } -Times 1 -Exactly
    }

    It '子資料夾狀態為 OK：維持非空掛載目錄的原訊息' {
        Mock -ModuleName WinMediaRefresh -CommandName Assert-WinMediaOutputDir -MockWith { }
        Mock -ModuleName WinMediaRefresh -CommandName Get-WinMediaMountState -MockWith { 'Unknown' }
        Mock -ModuleName WinMediaRefresh -CommandName Get-WinMediaMountState -ParameterFilter { $Path -like '*\install-1' } -MockWith { 'OK' }
        $mnt = Join-Path -Path $TestDrive -ChildPath 'mnt-ok'
        New-Item -ItemType Directory -Path (Join-Path -Path $mnt -ChildPath 'install-1') -Force | Out-Null
        $iso = Join-Path -Path $TestDrive -ChildPath 'source.iso'
        New-Item -ItemType File -Path $iso -Force | Out-Null
        $cfg = $script:defaults.Clone()
        $cfg.DefenderExclusions = $false
        $cfg.PackageDir = Join-Path -Path $TestDrive -ChildPath 'pkg'
        New-Item -ItemType Directory -Path $cfg.PackageDir -Force | Out-Null
        { Invoke-WindowsMediaRefresh -SourceIso $iso -Config $cfg -MountDir $mnt -WorkDir (Join-Path -Path $TestDrive -ChildPath 'w') -OutputDir (Join-Path -Path $TestDrive -ChildPath 'out') } |
            Should -Throw '*掛載目錄已存在且非空*'
        Should -Invoke -ModuleName WinMediaRefresh -CommandName Get-WinMediaMountState -ParameterFilter { $Path -like '*\install-1' } -Times 1 -Exactly
    }

    It '可寫掛載帶 @mountSwitches，唯讀與 Remount 不帶（AST）' {
        # 只掃本專案：Keel 的程式碼看不到 Slipway 的 $mountSwitches，掃到會無法在 Slipway 端修正
        $files = @(Get-ChildItem -LiteralPath (Join-Path -Path $script:root -ChildPath 'Public') -Filter '*.ps1' -File) + @(Get-ChildItem -LiteralPath (Join-Path -Path $script:root -ChildPath 'Modules') -Filter '*.psm1' -File)
        $sites = foreach ($file in $files) {
            foreach ($cmd in (Get-AstNode -Path $file.FullName -Type ([System.Management.Automation.Language.CommandAst]))) {
                if ($cmd.GetCommandName() -ne 'Mount-WinMediaImage') { continue }
                $names = @($cmd.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } | ForEach-Object { $_.ParameterName })
                $splats = @($cmd.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.VariableExpressionAst] -and $_.Splatted } | ForEach-Object { $_.VariablePath.UserPath })
                [pscustomobject]@{ File = $file.Name; Writable = -not ($names -contains 'ReadOnly' -or $names -contains 'Remount'); Splatted = ($splats -contains 'mountSwitches') }
            }
        }
        $sites = @($sites)
        $sites.Count | Should -BeGreaterThan 0
        @($sites | Where-Object { $_.Writable -and -not $_.Splatted }).Count | Should -Be 0
        @($sites | Where-Object { -not $_.Writable -and $_.Splatted }).Count | Should -Be 0
        @($sites | Where-Object { $_.Writable }).Count | Should -BeGreaterOrEqual 3
    }

    It 'DISM 呼叫的 @common／@mountExtra 只指向參數集含 ScratchDirectory 的 cmdlet 或定義該參數的包裝函式（AST）' {
        Import-Module -Name DISM -ErrorAction SilentlyContinue
        $common = [System.Management.Automation.PSCmdlet]::CommonParameters + [System.Management.Automation.PSCmdlet]::OptionalCommonParameters
        $files = @(Get-SourceFile)
        $functionParams = @{}
        $sites = @()
        foreach ($file in $files) {
            foreach ($fn in (Get-AstNode -Path $file.FullName -Type ([System.Management.Automation.Language.FunctionDefinitionAst]))) {
                if ($fn.Body.ParamBlock) {
                    $functionParams[$fn.Name] = @($fn.Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
                }
            }
            foreach ($cmd in (Get-AstNode -Path $file.FullName -Type ([System.Management.Automation.Language.CommandAst]))) {
                $splat = @($cmd.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.VariableExpressionAst] -and $_.Splatted } | ForEach-Object { $_.VariablePath.UserPath })
                if ($splat.Count -eq 0) { continue }
                # 納入條件：DISM cmdlet 上的任何 splat（含 Keel 的 @splat），或名為 common／mountExtra 的 splat
                $name = $cmd.GetCommandName()
                $isDism = [bool]$name -and @(Get-Command -Module DISM -Name $name -ErrorAction SilentlyContinue).Count -gt 0
                if (-not $isDism -and @($splat | Where-Object { $_ -in 'common', 'mountExtra' }).Count -eq 0) { continue }
                $sites += [pscustomobject]@{
                    File   = $file.Name
                    Name   = $cmd.GetCommandName()
                    Params = @($cmd.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } | ForEach-Object { $_.ParameterName } | Where-Object { $_ -notin $common })
                }
            }
        }
        $sites.Count | Should -BeGreaterThan 0
        $dismSites = 0
        foreach ($site in $sites) {
            [string]::IsNullOrEmpty($site.Name) | Should -BeFalse -Because "$($site.File): 無法解析指令名稱"
            $dism = @(Get-Command -Module DISM -Name $site.Name -ErrorAction SilentlyContinue)
            if ($dism.Count -gt 0) {
                $dismSites++
                $need = @($site.Params) + 'ScratchDirectory'
                $supported = @($dism[0].ParameterSets | Where-Object {
                        $set = $_
                        @($need | Where-Object { $set.Parameters.Name -notcontains $_ }).Count -eq 0
                    })
                $supported.Count | Should -BeGreaterThan 0 -Because "$($site.File): $($site.Name) 的任何參數集都不支援 ScratchDirectory 與 $($site.Params -join ',')"
            }
            else {
                $functionParams.ContainsKey($site.Name) | Should -BeTrue -Because "$($site.File): $($site.Name) 不是 DISM cmdlet，也不是定義於本專案的函式"
                $functionParams[$site.Name] | Should -Contain 'ScratchDirectory' -Because "$($site.File): 包裝函式 $($site.Name) 未宣告 ScratchDirectory"
            }
        }
        $dismSites | Should -BeGreaterThan 0
    }

    It 'Slipway 的每個 DISM 呼叫都 splat @common（AST；例外清單為空）' {
        Import-Module -Name DISM -ErrorAction SilentlyContinue
        $dismNames = @(Get-Command -Module DISM | ForEach-Object { $_.Name })
        # 例外格式：'檔名:cmdlet'，每筆需附理由；目前沒有例外
        $exempt = @()
        $files = @(Get-ChildItem -LiteralPath (Join-Path -Path $script:root -ChildPath 'Public') -Filter '*.ps1' -File) + @(Get-ChildItem -LiteralPath (Join-Path -Path $script:root -ChildPath 'Modules') -Filter '*.psm1' -File)
        $checked = 0
        $missing = @()
        foreach ($file in $files) {
            foreach ($cmd in (Get-AstNode -Path $file.FullName -Type ([System.Management.Automation.Language.CommandAst]))) {
                $name = $cmd.GetCommandName()
                if (-not $name -or $name -notin $dismNames) { continue }
                $checked++
                $splats = @($cmd.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.VariableExpressionAst] -and $_.Splatted } | ForEach-Object { $_.VariablePath.UserPath })
                if ($splats -notcontains 'common' -and $exempt -notcontains ('{0}:{1}' -f $file.Name, $name)) {
                    $missing += '{0}:{1} {2}' -f $file.Name, $cmd.Extent.StartLineNumber, $name
                }
            }
        }
        $checked | Should -BeGreaterOrEqual 20
        $missing | Should -BeNullOrEmpty
    }
}
