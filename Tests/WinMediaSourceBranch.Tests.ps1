#Requires -Version 5.1

# 來源分支（Step 13）：ISO 來源在找不到 install.wim 時的行為。
# 管理員檢查以 mock 通過；所有寫入／外部副作用的命令都 mock 成無作用或 tripwire（呼叫即丟錯）。
# ISO 掛載以 New-PSDrive（Global）對應到 TestDrive 內的資料夾，letter 避開已使用的磁碟機字母。

BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    Import-Module -Name (Join-Path -Path $script:root -ChildPath 'WinMediaRefresh.psd1') -Force

    function Invoke-InModule {
        param([scriptblock]$Script, [object[]]$ArgList = @())
        & (Get-Module -Name WinMediaRefresh) $Script @ArgList
    }

    function Get-SourceBranchConfig {
        param([string]$Root)
        $cfg = Import-PowerShellDataFile -LiteralPath (Join-Path -Path $script:root -ChildPath 'Config\Default.psd1')
        $cfg.WorkDir = Join-Path -Path $Root -ChildPath 'work'
        $cfg.MountDir = Join-Path -Path $Root -ChildPath 'mnt'
        $cfg.OutputDir = Join-Path -Path $Root -ChildPath 'out'
        $cfg.LogDir = Join-Path -Path $Root -ChildPath 'logs'
        $cfg.LogFile = Join-Path -Path $Root -ChildPath 'logs\main.log'
        $cfg.OperationLog = Join-Path -Path $Root -ChildPath 'logs\OperationLog.txt'
        $cfg.PackageDir = Join-Path -Path $Root -ChildPath 'packages'
        $cfg.ScratchDirectory = ''
        $cfg.DefenderExclusions = $false
        $cfg.DismProvider = 'Inbox'
        $cfg
    }

    function Get-FreeDriveLetter {
        $used = @(Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Name })
        $used += @([IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1) })
        $candidates = 'Y', 'X', 'W', 'V', 'U', 'T', 'S', 'R', 'Q', 'P', 'N', 'K', 'J', 'I', 'H', 'G', 'F', 'E', 'D'
        [string]($candidates | Where-Object { $_ -notin $used } | Select-Object -First 1)
    }
}

Describe 'Invoke-WindowsMediaRefresh: 來源分支（ISO 無 install.wim／install.esd，以及 .esd 來源）' -Tag 'Unit' {
    BeforeEach {
        $script:root2 = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        $isoDir = Join-Path -Path $script:root2 -ChildPath 'iso'
        New-Item -ItemType Directory -Path $isoDir -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path -Path $isoDir -ChildPath 'readme.txt') -Force | Out-Null
        $script:iso = Join-Path -Path $script:root2 -ChildPath 'src.iso'
        New-Item -ItemType File -Path $script:iso -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path -Path $script:root2 -ChildPath 'packages') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path -Path $script:root2 -ChildPath 'work') -Force | Out-Null

        $script:fakeDrive = Get-FreeDriveLetter
        New-PSDrive -Name $script:fakeDrive -PSProvider FileSystem -Root $isoDir -Scope Global | Out-Null
        Invoke-InModule { param($d) $script:fakeDrive = $d } @($script:fakeDrive)

        Mock -ModuleName WinMediaRefresh Test-WinMediaAdministrator { $true }
        Mock -ModuleName WinMediaRefresh Get-WinMediaCloudProvider { $null }
        Mock -ModuleName WinMediaRefresh Mount-WinMediaSourceIso { [pscustomobject]@{ DriveLetter = $script:fakeDrive; Mounted = $false } }
        Mock -ModuleName WinMediaRefresh Dismount-DiskImage { throw 'tripwire: Dismount-DiskImage' }
        Mock -ModuleName WinMediaRefresh Initialize-WinMediaWorkRoot { }
        Mock -ModuleName WinMediaRefresh Resolve-WinMediaDefenderStatePath { 'unused-state.json' }
        Mock -ModuleName WinMediaRefresh Restore-WinMediaDefenderExclusion { }
        Mock -ModuleName WinMediaRefresh Add-WinMediaDefenderExclusion { throw 'tripwire: Add-WinMediaDefenderExclusion' }
        Mock -ModuleName WinMediaRefresh Resolve-WinMediaWimlib { 'unused-wimlib' }
        Mock -ModuleName WinMediaRefresh Resolve-WinMediaOscdimg { 'unused-oscdimg' }
        Mock -ModuleName WinMediaRefresh Resolve-WinMediaAdk { throw 'tripwire: Resolve-WinMediaAdk' }
        Mock -ModuleName WinMediaRefresh Resolve-WinMediaDriverSet { @{} }
        Mock -ModuleName WinMediaRefresh Resolve-WinMediaAppxList { @() }
        Mock -ModuleName WinMediaRefresh Resolve-WinMediaLangFodSet { @{ LangPacks = @(); Fod = @() } }
        Mock -ModuleName WinMediaRefresh Resolve-WinMediaStoreAppSet { @() }
        Mock -ModuleName WinMediaRefresh Resolve-WinMediaLxp { @() }
        Mock -ModuleName WinMediaRefresh Use-WinMediaWorkDir { }
        Mock -ModuleName WinMediaRefresh Write-WinMediaLog { }
        Mock -ModuleName WinMediaRefresh Remove-WinMediaExtraLanguage { }
        Mock -ModuleName WinMediaRefresh Copy-WinMediaEsdSource { throw 'tripwire: Copy-WinMediaEsdSource' }
        Mock -ModuleName WinMediaRefresh Convert-WinMediaEsdToWim { throw 'tripwire: Convert-WinMediaEsdToWim' }
        Mock -ModuleName WinMediaRefresh Get-WinMediaIndexInfo { throw 'tripwire: Get-WinMediaIndexInfo' }
        Mock -ModuleName WinMediaRefresh Start-Process { throw 'tripwire: Start-Process' }
    }

    AfterEach {
        if ($script:fakeDrive) {
            Remove-PSDrive -Name $script:fakeDrive -Scope Global -Force -ErrorAction SilentlyContinue
        }
    }

    It 'tripwires resolve as mocks (Alias) in the WinMediaRefresh scope before the call' {
        foreach ($n in 'Test-WinMediaAdministrator', 'Mount-WinMediaSourceIso', 'Dismount-DiskImage', 'Convert-WinMediaEsdToWim', 'Copy-WinMediaEsdSource', 'Get-WinMediaIndexInfo', 'Add-WinMediaDefenderExclusion', 'Start-Process') {
            $type = Invoke-InModule { param($x) (Get-Command -Name $x -ErrorAction Stop).CommandType } @($n)
            $type | Should -Be 'Alias' -Because "mock not live in WinMediaRefresh scope: $n"
        }
    }

    It '只有 ISO（無 install.wim、無 install.esd）時丟出找不到 install.wim，且不轉換、不取得索引' {
        $cfg = Get-SourceBranchConfig -Root $script:root2
        { Invoke-WindowsMediaRefresh -SourceIso $script:iso -Config $cfg } | Should -Throw '*找不到 install.wim*'
        Should -Invoke -ModuleName WinMediaRefresh Mount-WinMediaSourceIso -Times 1 -Exactly
        Should -Invoke -ModuleName WinMediaRefresh Convert-WinMediaEsdToWim -Times 0 -Exactly
        Should -Invoke -ModuleName WinMediaRefresh Get-WinMediaIndexInfo -Times 0 -Exactly
        Should -Invoke -ModuleName WinMediaRefresh Dismount-DiskImage -Times 0 -Exactly
    }
    It '來源為 .esd 時：複製為 media\sources\install.esd，轉為 install.wim 一次，之後停在索引讀取' {
        Mock -ModuleName WinMediaRefresh Copy-WinMediaEsdSource {
            param($DestinationPath)
            $dir = Split-Path -Path $DestinationPath -Parent
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -LiteralPath $DestinationPath -Value 'esd'
        }
        Mock -ModuleName WinMediaRefresh Convert-WinMediaEsdToWim {
            param($DestinationWim)
            Set-Content -LiteralPath $DestinationWim -Value ''
        }
        $esd = Join-Path -Path $script:root2 -ChildPath 'src.esd'
        Set-Content -LiteralPath $esd -Value 'esd'
        $cfg = Get-SourceBranchConfig -Root $script:root2
        { Invoke-WindowsMediaRefresh -SourceIso $esd -Config $cfg } | Should -Throw '*tripwire: Get-WinMediaIndexInfo*'
        Should -Invoke -ModuleName WinMediaRefresh Copy-WinMediaEsdSource -Times 1 -Exactly
        Should -Invoke -ModuleName WinMediaRefresh Convert-WinMediaEsdToWim -Times 1 -Exactly -ParameterFilter { $SourceEsd -like '*\media\sources\install.esd' -and $DestinationWim -like '*\media\sources\install.wim' }
        Should -Invoke -ModuleName WinMediaRefresh Get-WinMediaIndexInfo -Times 1 -Exactly
        Should -Invoke -ModuleName WinMediaRefresh Mount-WinMediaSourceIso -Times 0 -Exactly
    }
    It 'ISO 內含 sources\install.wim：直接複製到 media，不轉換，之後停在索引讀取' {
        $wimSrc = Join-Path -Path $script:root2 -ChildPath 'iso\sources'
        New-Item -ItemType Directory -Path $wimSrc -Force | Out-Null
        Set-Content -LiteralPath (Join-Path -Path $wimSrc -ChildPath 'install.wim') -Value 'wim'
        New-Item -ItemType Directory -Path (Join-Path -Path $script:root2 -ChildPath 'work\media') -Force | Out-Null
        $cfg = Get-SourceBranchConfig -Root $script:root2
        { Invoke-WindowsMediaRefresh -SourceIso $script:iso -Config $cfg } | Should -Throw '*tripwire: Get-WinMediaIndexInfo*'
        Should -Invoke -ModuleName WinMediaRefresh Mount-WinMediaSourceIso -Times 1 -Exactly
        Should -Invoke -ModuleName WinMediaRefresh Convert-WinMediaEsdToWim -Times 0 -Exactly
        Should -Invoke -ModuleName WinMediaRefresh Copy-WinMediaEsdSource -Times 0 -Exactly
        Should -Invoke -ModuleName WinMediaRefresh Get-WinMediaIndexInfo -Times 1 -Exactly
        Should -Invoke -ModuleName WinMediaRefresh Dismount-DiskImage -Times 0 -Exactly
    }
}
