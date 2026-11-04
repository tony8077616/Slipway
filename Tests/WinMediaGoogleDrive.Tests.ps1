#Requires -Version 5.1

# Google Drive 雲端同步偵測（WinMediaPath）。訊號來源：HKCU:\Software\Google\DriveFS 的 PerAccountPreferences（JSON 字串）；
# per_account_preferences[].value.mount_point_path 為單一磁碟機字母（例如 G）。所有資料皆為合成資料，不讀取真實帳號。

BeforeAll {
    Import-Module -Name (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Modules\WinMediaPath.psm1') -Force

    function Invoke-InModule {
        param([scriptblock]$Script, [object[]]$ArgList = @())
        & (Get-Module -Name WinMediaPath) $Script @ArgList
    }
}

Describe 'Get-WinMediaCloudProvider：Google Drive 掛載根' -Tag 'Unit' {
    BeforeEach {
        Mock -ModuleName WinMediaPath Get-WinMediaGoogleDriveMountRoot { @('G:\') }
    }

    It 'tripwires resolve as mocks (Alias) in the WinMediaPath scope before the call' {
        $type = Invoke-InModule { (Get-Command -Name 'Get-WinMediaGoogleDriveMountRoot' -ErrorAction Stop).CommandType }
        $type | Should -Be 'Alias' -Because 'mock not live in WinMediaPath scope'
    }

    It '位於 Google Drive 掛載根之下時回傳 Google Drive' {
        Get-WinMediaCloudProvider -Path 'G:\WinMediaWork' | Should -Be 'Google Drive'
    }

    It '不在掛載根之下的路徑不回傳 Google Drive' {
        Get-WinMediaCloudProvider -Path 'H:\WinMediaWork' | Should -BeNullOrEmpty
    }

    It '讀不到掛載根（鍵不存在或解析失敗）時不回傳 Google Drive' {
        Mock -ModuleName WinMediaPath Get-WinMediaGoogleDriveMountRoot { @() }
        Get-WinMediaCloudProvider -Path 'G:\WinMediaWork' | Should -BeNullOrEmpty
    }
}

Describe 'Get-WinMediaGoogleDriveRootFromState：解析（合成 JSON）' -Tag 'Unit' {
    It '單一磁碟機字母轉為根路徑（G → G:\）' {
        $json = '{"per_account_preferences":[{"key":"k","value":{"mount_point_path":"G"}}]}'
        (Invoke-InModule { param($t) Get-WinMediaGoogleDriveRootFromState -Text $t } @($json)) -join ',' | Should -Be 'G:\'
    }

    It '接受 X: 與 X:\ 兩種寫法' {
        $json = '{"per_account_preferences":[{"key":"k","value":{"mount_point_path":"X:\\"}}]}'
        (Invoke-InModule { param($t) Get-WinMediaGoogleDriveRootFromState -Text $t } @($json)) -join ',' | Should -Be 'X:\'
        $jsonColon = '{"per_account_preferences":[{"key":"k","value":{"mount_point_path":"X:"}}]}'
        (Invoke-InModule { param($t) Get-WinMediaGoogleDriveRootFromState -Text $t } @($jsonColon)) -join ',' | Should -Be 'X:\'
    }

    It '非字母的值被忽略' {
        $json = '{"per_account_preferences":[{"key":"k","value":{"mount_point_path":"Gx"}}]}'
        @(Invoke-InModule { param($t) Get-WinMediaGoogleDriveRootFromState -Text $t } @($json)).Count | Should -Be 0
    }

    It '格式錯誤的 JSON 回傳空陣列而不丟錯' {
        { Invoke-InModule { param($t) Get-WinMediaGoogleDriveRootFromState -Text $t } @('{bad') } | Should -Not -Throw
        @(Invoke-InModule { param($t) Get-WinMediaGoogleDriveRootFromState -Text $t } @('{bad')).Count | Should -Be 0
    }

    It '某一筆格式不符時，其餘筆仍被解析' {
        $json = '{"per_account_preferences":[{"key":"a","value":"notobject"},{"key":"b","value":{"mount_point_path":"G"}}]}'
        (Invoke-InModule { param($t) Get-WinMediaGoogleDriveRootFromState -Text $t } @($json)) -join ',' | Should -Be 'G:\'
    }
}
