#Requires -Version 5.1

BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    Import-Module -Name (Join-Path -Path $script:root -ChildPath 'WinMediaRefresh.psd1') -Force
    Import-Module -Name (Join-Path -Path $script:root -ChildPath 'Modules\WinMediaPath.psm1') -Force
    $script:defaults = Import-PowerShellDataFile -LiteralPath (Join-Path -Path $script:root -ChildPath 'Config\Default.psd1')

    function Get-AstNode {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Type', Justification = 'FindAll 的 scriptblock 使用，PSSA 無法追蹤')]
        param([string]$Path, [type]$Type)
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        return @($ast.FindAll({ param($n) $n -is $Type }, $true))
    }
}

Describe 'Resolve-WinMediaOutputPlan 的 .esd 來源規則（Step 10d）' -Tag 'Unit' {
    It 'OutputFormat=<Format> OutputForm=[<Form>] 的 .esd 來源解析為 Image，AutoImage=<Auto>' -ForEach @(
        @{ Format = 'WIM'; Form = ''; Auto = $true }
        @{ Format = 'ESD'; Form = ''; Auto = $true }
        @{ Format = 'WIM'; Form = 'Image'; Auto = $false }
        @{ Format = 'ESD'; Form = 'Image'; Auto = $false }
    ) {
        $plan = Resolve-WinMediaOutputPlan -OutputFormat $Format -OutputForm $Form -SourceKind 'Esd'
        $plan.OutputForm | Should -Be 'Image'
        $plan.AutoImage | Should -Be $Auto
        $plan.NeedsOscdimg | Should -BeFalse
        $plan.NeedsWimlib | Should -BeTrue
    }

    It 'OutputFormat=<Format> OutputForm=[<Form>] 的 .esd 來源明確指定 Iso 或 Folder 時丟出' -ForEach @(
        @{ Format = 'WIM'; Form = 'Iso' }
        @{ Format = 'WIM'; Form = 'Folder' }
        @{ Format = 'ESD'; Form = 'Iso' }
        @{ Format = 'ESD'; Form = 'Folder' }
    ) {
        { Resolve-WinMediaOutputPlan -OutputFormat $Format -OutputForm $Form -SourceKind 'Esd' } | Should -Throw '*只允許 OutputForm=Image*'
    }
}

Describe 'Copy-WinMediaEsdSource（Step 10d）' -Tag 'Unit' {
    BeforeAll {
        $script:copyCfg = @{ LogLevel = 'Error'; OperationLog = ''; DebugTrace = 0; LogFile = (Join-Path -Path $TestDrive -ChildPath 'copy.log') }
    }

    It '複製後原始檔位元組不變，副本可寫（來源為唯讀時亦同）' {
        $src = Join-Path -Path $TestDrive -ChildPath 'user-src.esd'
        Set-Content -LiteralPath $src -Value 'esd-bytes' -Encoding ASCII
        (Get-Item -LiteralPath $src).IsReadOnly = $true
        try {
            $work = Join-Path -Path $TestDrive -ChildPath 'w-copy'
            $dst = Join-Path -Path $work -ChildPath 'media\sources\install.esd'
            $wim = Join-Path -Path $work -ChildPath 'media\sources\install.wim'
            Copy-WinMediaEsdSource -SourcePath $src -DestinationPath $dst -WimPath $wim -WorkDir $work -Config $script:copyCfg
            Get-Content -LiteralPath $src -Raw | Should -Be "esd-bytes`r`n"
            (Get-Item -LiteralPath $dst).IsReadOnly | Should -BeFalse
        }
        finally {
            (Get-Item -LiteralPath $src).IsReadOnly = $false
        }
    }

    It '目的地位於 WorkDir 之外時丟出中文訊息，且不複製' {
        $src = Join-Path -Path $TestDrive -ChildPath 'user-src2.esd'
        Set-Content -LiteralPath $src -Value 'x' -Encoding ASCII
        $work = Join-Path -Path $TestDrive -ChildPath 'w-outside'
        $outside = Join-Path -Path $TestDrive -ChildPath 'outside.esd'
        { Copy-WinMediaEsdSource -SourcePath $src -DestinationPath $outside -WimPath (Join-Path -Path $work -ChildPath 'x.wim') -WorkDir $work -Config $script:copyCfg } |
            Should -Throw '*必須位於 WorkDir 內*'
        Test-Path -LiteralPath $outside | Should -BeFalse
    }
}

Describe 'Invoke-WindowsMediaRefresh 的 .esd 來源（Step 10d，哨兵於 Assert-WinMediaOutputDir）' -Tag 'Unit' {
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
        $script:esdCfg = $script:defaults.Clone()
        $script:esdCfg.DefenderExclusions = $false
        $script:esdCfg.PackageDir = Join-Path -Path $TestDrive -ChildPath 'pkg'
        New-Item -ItemType Directory -Path $script:esdCfg.PackageDir -Force | Out-Null
        $script:esdSource = Join-Path -Path $TestDrive -ChildPath 'source.esd'
        New-Item -ItemType File -Path $script:esdSource -Force | Out-Null
    }

    It '明確指定 Iso 的 .esd 來源在計畫階段丟出，早於 wimlib 解析' {
        $cfg = $script:esdCfg.Clone()
        $cfg.OutputFormat = 'WIM'
        $cfg.OutputForm = 'Iso'
        { Invoke-WindowsMediaRefresh -SourceIso $script:esdSource -Config $cfg -WorkDir (Join-Path -Path $TestDrive -ChildPath 'w') -OutputDir (Join-Path -Path $TestDrive -ChildPath 'out') } |
            Should -Throw '*只允許 OutputForm=Image*'
        Should -Invoke -ModuleName WinMediaRefresh -CommandName Resolve-WinMediaWimlib -Times 0 -Exactly
    }

    It '未指定 OutputForm 的 .esd 來源：警告、改用 Image，並到達哨兵（不呼叫 oscdimg）' {
        $cfg = $script:esdCfg.Clone()
        $cfg.OutputFormat = 'WIM'
        $cfg.OutputForm = ''
        $message = $null
        $warnings = $null
        try {
            Invoke-WindowsMediaRefresh -SourceIso $script:esdSource -Config $cfg -WorkDir (Join-Path -Path $TestDrive -ChildPath 'w') -OutputDir (Join-Path -Path $TestDrive -ChildPath 'out') -WarningVariable warnings -WarningAction SilentlyContinue
        }
        catch {
            $message = $_.Exception.Message
        }
        $message | Should -BeLike '*SENTINEL*'
        "$warnings" | Should -BeLike '*改輸出 Image*'
        Should -Invoke -ModuleName WinMediaRefresh -CommandName Resolve-WinMediaOscdimg -Times 0 -Exactly
        Should -Invoke -ModuleName WinMediaRefresh -CommandName Resolve-WinMediaWimlib -Times 2 -Exactly
    }

    It '來源位於 WorkDir\media 之內時於哨兵之前丟出' {
        $work = Join-Path -Path $TestDrive -ChildPath 'w-media'
        $inMedia = Join-Path -Path $work -ChildPath 'media\source.esd'
        New-Item -ItemType File -Path $inMedia -Force | Out-Null
        $cfg = $script:esdCfg.Clone()
        $cfg.OutputFormat = 'WIM'
        $cfg.OutputForm = ''
        { Invoke-WindowsMediaRefresh -SourceIso $inMedia -Config $cfg -WorkDir $work -OutputDir (Join-Path -Path $TestDrive -ChildPath 'out') } |
            Should -Throw '*工作子目錄之內*'
    }

    It '來源即 OutputDir\install.esd 時於哨兵之前丟出，不會被匯出覆寫' {
        $out = Join-Path -Path $TestDrive -ChildPath 'out-same'
        New-Item -ItemType Directory -Path $out -Force | Out-Null
        $same = Join-Path -Path $out -ChildPath 'install.esd'
        New-Item -ItemType File -Path $same -Force | Out-Null
        $cfg = $script:esdCfg.Clone()
        $cfg.OutputFormat = 'WIM'
        $cfg.OutputForm = ''
        { Invoke-WindowsMediaRefresh -SourceIso $same -Config $cfg -WorkDir (Join-Path -Path $TestDrive -ChildPath 'w-same') -OutputDir $out } |
            Should -Throw '*來源與輸出相同*'
    }
}

Describe 'Convert-WinMediaEsdToWim 只轉換副本（AST，Step 10d）' -Tag 'Unit' {
    It '所有 Convert-WinMediaEsdToWim 的 -SourceEsd 都是 $installEsd（不直接轉換使用者的來源）' {
        $files = @(Get-ChildItem -LiteralPath (Join-Path -Path $script:root -ChildPath 'Public') -Filter '*.ps1' -File) + @(Get-ChildItem -LiteralPath (Join-Path -Path $script:root -ChildPath 'Modules') -Filter '*.psm1' -File)
        $sites = @()
        foreach ($file in $files) {
            foreach ($cmd in (Get-AstNode -Path $file.FullName -Type ([System.Management.Automation.Language.CommandAst]))) {
                if ($cmd.GetCommandName() -ne 'Convert-WinMediaEsdToWim') { continue }
                $elements = @($cmd.CommandElements)
                for ($i = 0; $i -lt $elements.Count; $i++) {
                    if ($elements[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and $elements[$i].ParameterName -eq 'SourceEsd') {
                        $sites += [pscustomobject]@{ File = $file.Name; Value = $elements[$i + 1].Extent.Text }
                    }
                }
            }
        }
        $sites.Count | Should -BeGreaterOrEqual 1
        @($sites | Where-Object { $_.Value -ne '$installEsd' }).Count | Should -Be 0
    }
}
