#Requires -Version 5.1

BeforeAll {
    Import-Module -Name (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Modules\WinMediaPath.psm1') -Force
}

Describe 'WinMediaPath 網路路徑政策' -Tag 'Unit' {
    It 'UNC 路徑為網路路徑' {
        Test-WinMediaNetworkPath -Path '\\server\share\pkg' | Should -BeTrue
    }

    It '\\?\UNC\ 形式為網路路徑' {
        Test-WinMediaNetworkPath -Path '\\?\UNC\server\share\pkg' | Should -BeTrue
    }

    It 'PowerShell 提供者前綴後的 UNC 為網路路徑' {
        Test-WinMediaNetworkPath -Path 'Microsoft.PowerShell.Core\FileSystem::\\server\share' | Should -BeTrue
    }

    It '本機磁碟路徑不是網路路徑' {
        Test-WinMediaNetworkPath -Path $TestDrive | Should -BeFalse
    }

    It '空字串不是網路路徑' {
        Test-WinMediaNetworkPath -Path '' | Should -BeFalse
    }

    It '不存在的磁碟機代號不丟 DriveNotFound，視為本機路徑' {
        Test-WinMediaNetworkPath -Path 'Q:\x' | Should -BeFalse
        { Assert-WinMediaScratchPath -ScratchDirectory 'Q:\s' -MountDir 'Q:\Mount' -WorkDir 'Q:\Work' } | Should -Not -Throw
        Get-WinMediaCloudProvider -Path 'Q:\x' | Should -BeNullOrEmpty
    }

    It 'Assert-WinMediaLocalPath 對 UNC 丟出含名稱與路徑的中文訊息' {
        { Assert-WinMediaLocalPath -Path '\\server\share' -Name 'WorkDir' } | Should -Throw '*WorkDir 不支援網路路徑*'
    }

    It '對應到網路磁碟機的磁碟區為網路路徑（磁碟資訊經由可 mock 的包裝取得）' {
        Mock -ModuleName WinMediaPath Get-WinMediaDriveInfo { [pscustomobject]@{ DriveType = [System.IO.DriveType]::Network } }
        Test-WinMediaNetworkPath -Path 'Q:\x' | Should -BeTrue
        { Assert-WinMediaLocalPath -Path 'Q:\x' -Name 'WorkDir' } | Should -Throw '*WorkDir 不支援網路路徑*'
    }

    It 'Assert-WinMediaLocalPath 對本機路徑不丟出' {
        { Assert-WinMediaLocalPath -Path $TestDrive -Name 'WorkDir' } | Should -Not -Throw
    }
}

Describe 'WinMediaPath 雲端路徑偵測' -Tag 'Unit' {
    BeforeEach {
        $script:oldOneDrive = $env:OneDrive
        $env:OneDrive = 'D:\Users\tester\OneDrive'
    }

    AfterEach {
        $env:OneDrive = $script:oldOneDrive
    }

    It '位於 OneDrive 資料夾之下回傳 OneDrive' {
        Get-WinMediaCloudProvider -Path 'D:\Users\tester\OneDrive\pkg' | Should -Be 'OneDrive'
    }

    It '比對不分大小寫' {
        Get-WinMediaCloudProvider -Path 'd:\users\TESTER\onedrive\x' | Should -Be 'OneDrive'
    }

    It '前綴相似但不同資料夾不誤判（OneDriveArchive）' {
        Get-WinMediaCloudProvider -Path 'D:\Users\tester\OneDriveArchive' | Should -BeNullOrEmpty
    }

    It '不在雲端資料夾內回傳空值' {
        Get-WinMediaCloudProvider -Path 'D:\Work' | Should -BeNullOrEmpty
    }
}

Describe 'WinMediaPath ScratchDirectory 檢查' -Tag 'Unit' {
    It '獨立的本機路徑通過' {
        { Assert-WinMediaScratchPath -ScratchDirectory 'D:\Scratch' -MountDir 'D:\Mount' -WorkDir 'D:\Work' } | Should -Not -Throw
    }

    It '位於 MountDir 之內丟出' {
        { Assert-WinMediaScratchPath -ScratchDirectory 'D:\Mount\s' -MountDir 'D:\Mount' -WorkDir 'D:\Work' } | Should -Throw '*MountDir*'
    }

    It '與 MountDir 相同也丟出' {
        { Assert-WinMediaScratchPath -ScratchDirectory 'D:\Mount' -MountDir 'D:\Mount' -WorkDir 'D:\Work' } | Should -Throw '*MountDir*'
    }

    It '位於 WorkDir\media 之內丟出' {
        { Assert-WinMediaScratchPath -ScratchDirectory 'D:\Work\media\x' -MountDir 'D:\Mount' -WorkDir 'D:\Work' } | Should -Throw '*WorkDir\media*'
    }

    It '位於 WorkDir 但不在 media 之內通過' {
        { Assert-WinMediaScratchPath -ScratchDirectory 'D:\Work\scratch' -MountDir 'D:\Mount' -WorkDir 'D:\Work' } | Should -Not -Throw
    }

    It '網路路徑丟出' {
        { Assert-WinMediaScratchPath -ScratchDirectory '\\server\s' -MountDir 'D:\Mount' -WorkDir 'D:\Work' } | Should -Throw '*網路路徑*'
    }
}

Describe 'WinMediaPath 管理員、磁碟區與可用空間' -Tag 'Unit' {
    It 'Test-WinMediaAdministrator 回傳布林值' {
        Test-WinMediaAdministrator | Should -BeOfType [bool]
    }

    It 'Get-WinMediaVolumeFreeSpaceGB 對系統磁碟回傳正數' {
        Get-WinMediaVolumeFreeSpaceGB -Path ($env:SystemDrive + '\') | Should -BeGreaterThan 0
    }

    It 'Test-WinMediaNtfsVolume 對系統磁碟回傳布林值' {
        Test-WinMediaNtfsVolume -Path ($env:SystemDrive + '\') | Should -BeOfType [bool]
    }
}
