#Requires -Version 5.1

BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    # 順序：先匯入組合模組，最後匯入 WinMediaPath（與 Update-WindowsMedia.ps1 相同；組合模組內會以 -Force 重新匯入 WinMediaPath）
    Import-Module -Name (Join-Path -Path $script:root -ChildPath 'Modules\WinMediaWorkspace.psm1') -Force
    Import-Module -Name (Join-Path -Path $script:root -ChildPath 'Modules\WinMediaPath.psm1') -Force

    function Get-WorkspaceFixture {
        $base = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        $fixture = @{
            Base      = $base
            MountDir  = Join-Path -Path $base -ChildPath 'mnt'
            WorkDir   = Join-Path -Path $base -ChildPath 'w'
            OutputDir = Join-Path -Path $base -ChildPath 'out'
            Config    = @{ LogLevel = 'Error'; OperationLog = ''; DebugTrace = 0; LogFile = (Join-Path -Path $base -ChildPath 'cleanup.log') }
        }
        New-Item -ItemType Directory -Path $fixture.MountDir, $fixture.WorkDir, $fixture.OutputDir -Force | Out-Null
        return $fixture
    }
}

Describe 'Parallel: WorkSubDirs（Step 12c 登記）' -Tag 'Unit' {
    It 'Parallel: WorkSubDirs includes the parallel root so -IncludeWorkDir can clear it' {
        $dirs = & (Get-Module -Name WinMediaWorkspace) { $script:WorkSubDirs }
        $dirs | Should -Contain 'parallel'
    }
}

Describe 'Get-WinMediaWorkspaceChildAction（狀態到動作，Step 11）' -Tag 'Unit' {
    It '<Name>（狀態 <State>，空資料夾 <Empty>）→ <Expect>' -ForEach @(
        @{ Name = 'install-1'; State = 'OK'; Empty = $false; Expect = 'Clear' }
        @{ Name = 'boot-2'; State = 'Invalid'; Empty = $false; Expect = 'Clear' }
        @{ Name = 'winre'; State = 'NeedsRemount'; Empty = $false; Expect = 'Remount' }
        @{ Name = 'winre-src'; State = 'Unknown'; Empty = $true; Expect = 'RemoveEmpty' }
        @{ Name = 'spp-check'; State = 'Unknown'; Empty = $false; Expect = 'WarnNotEmpty' }
        @{ Name = 'install-1'; State = 'Unknown'; Empty = $false; Expect = 'WarnNotEmpty' }
        @{ Name = 'Documents'; State = 'OK'; Empty = $false; Expect = 'Skip' }
    ) {
        Get-WinMediaWorkspaceChildAction -Name $Name -State $State -IsEmpty $Empty | Should -Be $Expect
    }
}

Describe 'Invoke-WinMediaWorkspaceCleanup（模組函式；mock 以 -ModuleName WinMediaWorkspace）' -Tag 'Unit' {
    BeforeEach {
        Mock -ModuleName WinMediaWorkspace -CommandName Restore-WinMediaDefenderExclusion -MockWith { }
        Mock -ModuleName WinMediaWorkspace -CommandName Resolve-WinMediaDefenderStatePath -MockWith { Join-Path -Path $TestDrive -ChildPath 'no-such-state.json' }
        Mock -ModuleName WinMediaWorkspace -CommandName Get-WinMediaMountState -MockWith { 'Unknown' }
        Mock -ModuleName WinMediaWorkspace -CommandName Mount-WinMediaImage -MockWith { }
        Mock -ModuleName WinMediaWorkspace -CommandName Clear-WinMediaMount -MockWith { }
    }

    It 'NeedsRemount 且重新掛載成功：只以 -Remount 處理該子資料夾，不交給 Clear-WinMediaMount，空資料夾隨後移除' {
        $f = Get-WorkspaceFixture
        $child = Join-Path -Path $f.MountDir -ChildPath 'install-1'
        New-Item -ItemType Directory -Path $child -Force | Out-Null
        Mock -ModuleName WinMediaWorkspace -CommandName Get-WinMediaMountState -MockWith { 'NeedsRemount' }
        Invoke-WinMediaWorkspaceCleanup -MountDir $f.MountDir -WorkDir $f.WorkDir -OutputDir $f.OutputDir -Config $f.Config -Confirm:$false
        Should -Invoke -ModuleName WinMediaWorkspace -CommandName Mount-WinMediaImage -Times 1 -Exactly -ParameterFilter { $Remount -and $MountPath -like '*\install-1' }
        Should -Invoke -ModuleName WinMediaWorkspace -CommandName Clear-WinMediaMount -Times 0 -Exactly
        Test-Path -LiteralPath $child | Should -BeFalse
    }

    It 'Remount 失敗時改由 Clear-WinMediaMount 處理，且同一次呼叫仍包含其他可處理的子資料夾' {
        $f = Get-WorkspaceFixture
        New-Item -ItemType Directory -Path (Join-Path -Path $f.MountDir -ChildPath 'install-1'), (Join-Path -Path $f.MountDir -ChildPath 'boot-2') -Force | Out-Null
        Mock -ModuleName WinMediaWorkspace -CommandName Get-WinMediaMountState -ParameterFilter { $Path -like '*\install-1' } -MockWith { 'NeedsRemount' }
        Mock -ModuleName WinMediaWorkspace -CommandName Get-WinMediaMountState -ParameterFilter { $Path -like '*\boot-2' } -MockWith { 'OK' }
        Mock -ModuleName WinMediaWorkspace -CommandName Mount-WinMediaImage -MockWith { throw 'remount failed' }
        Invoke-WinMediaWorkspaceCleanup -MountDir $f.MountDir -WorkDir $f.WorkDir -OutputDir $f.OutputDir -Config $f.Config -Confirm:$false
        Should -Invoke -ModuleName WinMediaWorkspace -CommandName Mount-WinMediaImage -Times 1 -Exactly -ParameterFilter { $Remount -and $MountPath -like '*\install-1' }
        Should -Invoke -ModuleName WinMediaWorkspace -CommandName Clear-WinMediaMount -Times 1 -Exactly -ParameterFilter {
            (@($MountPath | Where-Object { $_ -like '*\install-1' })).Count -eq 1 -and (@($MountPath | Where-Object { $_ -like '*\boot-2' })).Count -eq 1
        }
    }

    It '允許清單外的資料夾不查詢狀態、不交給 Clear-WinMediaMount；允許清單內的 OK 資料夾才會被交給它' {
        $f = Get-WorkspaceFixture
        New-Item -ItemType Directory -Path (Join-Path -Path $f.MountDir -ChildPath 'Documents'), (Join-Path -Path $f.MountDir -ChildPath 'install-1') -Force | Out-Null
        Mock -ModuleName WinMediaWorkspace -CommandName Get-WinMediaMountState -MockWith { 'OK' }
        Invoke-WinMediaWorkspaceCleanup -MountDir $f.MountDir -WorkDir $f.WorkDir -OutputDir $f.OutputDir -Config $f.Config -Confirm:$false
        Should -Invoke -ModuleName WinMediaWorkspace -CommandName Get-WinMediaMountState -Times 0 -Exactly -ParameterFilter { $Path -like '*\Documents' }
        Should -Invoke -ModuleName WinMediaWorkspace -CommandName Clear-WinMediaMount -Times 1 -Exactly -ParameterFilter {
            @($MountPath).Count -eq 1 -and $MountPath[0] -like '*\install-1'
        }
    }

    It '-WhatIf 不掛載、不卸載登錄檔、不還原 Defender、不移除任何資料夾或狀態檔' {
        $f = Get-WorkspaceFixture
        $child = Join-Path -Path $f.MountDir -ChildPath 'install-1'
        New-Item -ItemType Directory -Path $child -Force | Out-Null
        $state = Join-Path -Path $f.WorkDir -ChildPath 'defender-state.json'
        Set-Content -LiteralPath $state -Value '{}' -Encoding ASCII
        Mock -ModuleName WinMediaWorkspace -CommandName Resolve-WinMediaDefenderStatePath -MockWith { Join-Path -Path $f.Base -ChildPath 'state-hash.json' }
        Mock -ModuleName WinMediaWorkspace -CommandName Get-WinMediaMountState -MockWith { 'NeedsRemount' }
        Invoke-WinMediaWorkspaceCleanup -MountDir $f.MountDir -WorkDir $f.WorkDir -OutputDir $f.OutputDir -Config $f.Config -WhatIf
        Should -Invoke -ModuleName WinMediaWorkspace -CommandName Mount-WinMediaImage -Times 0 -Exactly
        Should -Invoke -ModuleName WinMediaWorkspace -CommandName Clear-WinMediaMount -Times 0 -Exactly
        Should -Invoke -ModuleName WinMediaWorkspace -CommandName Restore-WinMediaDefenderExclusion -Times 0 -Exactly
        Test-Path -LiteralPath $child | Should -BeTrue
        Test-Path -LiteralPath $state | Should -BeTrue
    }

    It '對照組：同一份狀態檔不加 -WhatIf 時會還原 Defender 排除一次，且 StatePath 正確' {
        $f = Get-WorkspaceFixture
        $state = Join-Path -Path $f.WorkDir -ChildPath 'defender-state.json'
        Set-Content -LiteralPath $state -Value '{}' -Encoding ASCII
        Mock -ModuleName WinMediaWorkspace -CommandName Resolve-WinMediaDefenderStatePath -MockWith { Join-Path -Path $f.Base -ChildPath 'state-hash.json' }
        Invoke-WinMediaWorkspaceCleanup -MountDir $f.MountDir -WorkDir $f.WorkDir -OutputDir $f.OutputDir -Config $f.Config -Confirm:$false
        Should -Invoke -ModuleName WinMediaWorkspace -CommandName Restore-WinMediaDefenderExclusion -Times 1 -Exactly -ParameterFilter { $StatePath -eq $state }
    }

    It '狀態不明時：空資料夾移除、非空資料夾保留（不遞迴刪除）' {
        $f = Get-WorkspaceFixture
        $empty = Join-Path -Path $f.MountDir -ChildPath 'winre'
        $full = Join-Path -Path $f.MountDir -ChildPath 'winre-src'
        New-Item -ItemType Directory -Path $empty, $full -Force | Out-Null
        Set-Content -LiteralPath (Join-Path -Path $full -ChildPath 'keep.txt') -Value 'x' -Encoding ASCII
        Invoke-WinMediaWorkspaceCleanup -MountDir $f.MountDir -WorkDir $f.WorkDir -OutputDir $f.OutputDir -Config $f.Config -Confirm:$false
        Test-Path -LiteralPath $empty | Should -BeFalse
        Test-Path -LiteralPath (Join-Path -Path $full -ChildPath 'keep.txt') | Should -BeTrue
        Should -Invoke -ModuleName WinMediaWorkspace -CommandName Clear-WinMediaMount -Times 0 -Exactly
    }
}

Describe 'Resolve-WinMediaScriptDefault（參數 → 設定檔 → 腳本所在磁碟根目錄）' -Tag 'Unit' {
    It '<Value> / <Config> → <Expect>' -ForEach @(
        @{ Value = 'D:\a'; Config = 'D:\b'; Expect = 'D:\a' }
        @{ Value = ''; Config = 'D:\b'; Expect = 'D:\b' }
        @{ Value = ''; Config = ''; Expect = 'C:\WinMediaWork' }
    ) {
        Resolve-WinMediaScriptDefault -Value $Value -ConfigValue $Config -RootDir 'C:\repo' -ChildName 'WinMediaWork' | Should -Be $Expect
    }
}

Describe 'Clear-WindowsMediaWorkspace.ps1（根目錄腳本）' -Tag 'Unit' {
    BeforeAll {
        $script:cleanupScript = Join-Path -Path $script:root -ChildPath 'Clear-WindowsMediaWorkspace.ps1'
    }

    It 'WorkDir 為網路路徑時於提權前丟出中文訊息' {
        Mock Start-Process { }
        { & $script:cleanupScript -WorkDir '\\server\share\w' -MountDir (Join-Path -Path $TestDrive -ChildPath 'mnt-unc') -OutputDir (Join-Path -Path $TestDrive -ChildPath 'out-unc') } |
            Should -Throw '*WorkDir 不支援網路路徑*'
        Should -Invoke Start-Process -Times 0 -Exactly
    }

    It '-WhatIf 不呼叫 Start-Process（不提權）' {
        Mock Start-Process { }
        $f = Get-WorkspaceFixture
        & $script:cleanupScript -WorkDir $f.WorkDir -MountDir $f.MountDir -OutputDir $f.OutputDir -WhatIf | Out-Null
        Should -Invoke Start-Process -Times 0 -Exactly
    }

    It '主流程與根目錄腳本都以 Resolve-WinMediaScriptDefault 計算 WorkDir（Defender 狀態檔雜湊需一致）' {
        $entry = Get-Content -LiteralPath (Join-Path -Path $script:root -ChildPath 'Update-WindowsMedia.ps1') -Raw
        $cleanup = Get-Content -LiteralPath $script:cleanupScript -Raw
        $pattern = 'Resolve-WinMediaScriptDefault -Value \$WorkDir -ConfigValue \$config\.WorkDir -RootDir \$PSScriptRoot -ChildName ''WinMediaWork'''
        $entry | Should -Match $pattern
        $cleanup | Should -Match $pattern
    }
}
Describe 'Invoke-WinMediaWorkspaceCleanup：根目錄相對 WorkDir（8a60680 回歸）' -Tag 'Unit' {
    It '根目錄相對的 WorkDir 在查 Defender 狀態檔與 AllowedPath 前已正規化為完整路徑' {
        $f = Get-WorkspaceFixture
        $rel = $f.WorkDir.Substring($TestDrive.TrimEnd('\').Length)
        $relMount = $f.MountDir.Substring($TestDrive.TrimEnd('\').Length)
        $relOut = $f.OutputDir.Substring($TestDrive.TrimEnd('\').Length)
        $stateFile = Join-Path -Path $f.Base -ChildPath 'state-hash.json'
        Set-Content -LiteralPath $stateFile -Value '[]' -Encoding ASCII
        Mock -ModuleName WinMediaWorkspace -CommandName Resolve-WinMediaDefenderStatePath { Join-Path -Path $f.Base -ChildPath 'state-hash.json' }
        Mock -ModuleName WinMediaWorkspace -CommandName Restore-WinMediaDefenderExclusion { }
        Push-Location -LiteralPath 'TestDrive:\'
        try {
            Invoke-WinMediaWorkspaceCleanup -MountDir $relMount -WorkDir $rel -OutputDir $relOut -Config $f.Config -Confirm:$false
        }
        finally {
            Pop-Location
        }
        Should -Invoke -ModuleName WinMediaWorkspace -CommandName Resolve-WinMediaDefenderStatePath -Times 1 -Exactly -ParameterFilter { $WorkDir -eq $f.WorkDir }
        Should -Invoke -ModuleName WinMediaWorkspace -CommandName Restore-WinMediaDefenderExclusion -Times 1 -Exactly -ParameterFilter { @($AllowedPath) -contains $f.WorkDir -and @($AllowedPath) -contains $f.MountDir -and @($AllowedPath) -contains $f.OutputDir }
    }

    It 'Defender 狀態檔鍵不變：D:\WinMediaWork 的鍵為 UTF-8 大寫路徑 SHA-256 的前 16 碼（與既有檔案相容）' {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes('D:\WINMEDIAWORK')) } finally { $sha.Dispose() }
        $key = (-join ($hash | ForEach-Object { $_.ToString('x2') })).Substring(0, 16)
        Resolve-WinMediaDefenderStatePath -WorkDir 'D:\WinMediaWork' | Should -Match ([regex]::Escape($key) + '\.json$')
    }
}
Describe 'Resolve-WinMediaMountDir：根目錄相對 WorkDir 的預設掛載目錄（8a60680 回歸）' -Tag 'Unit' {
    It '根目錄相對 WorkDir 的預設掛載目錄依 WorkDir 所在磁碟（非系統磁碟）' {
        Mock -ModuleName WinMediaPath -CommandName Get-Volume { [pscustomobject]@{ FileSystem = 'NTFS' } }
        $type = & (Get-Module -Name WinMediaPath) { (Get-Command -Name 'Get-Volume' -ErrorAction Stop).CommandType }
        $type | Should -Be 'Alias' -Because 'Get-Volume mock not live in WinMediaPath scope'
        $drive = Split-Path -Path $TestDrive -Qualifier
        Push-Location -LiteralPath 'TestDrive:\'
        try {
            Resolve-WinMediaMountDir -WorkDir '\w' | Should -Be ($drive + '\MountUUP')
            Should -Invoke -ModuleName WinMediaPath -CommandName Get-Volume -Times 1 -Exactly -ParameterFilter { $DriveLetter -eq $drive.Substring(0, 1) }
        }
        finally {
            Pop-Location
        }
    }
}
