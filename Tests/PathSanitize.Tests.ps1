BeforeAll {
    Import-Module -Name (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'PSModules\Common\PathSanitize.psm1') -Force
}

Describe '一般檔案路徑淨化（ConvertTo-SanitizedPath）' -Tag 'Unit' {
    It '統一分隔符、收斂重複反斜線並去除尾端反斜線' {
        $r = ConvertTo-SanitizedPath -Path 'D:/Work//sub\\file\'
        $r.Path | Should -Be 'D:\Work\sub\file'
        $r.Kind | Should -Be 'Drive'
    }

    It '盤符根目錄保留結尾反斜線' {
        (ConvertTo-SanitizedPath -Path 'E:').Path | Should -Be 'E:\'
    }

    It '去除 FileSystem 提供者前綴' {
        (ConvertTo-SanitizedPath -Path 'Microsoft.PowerShell.Core\FileSystem::D:\Work').Path | Should -Be 'D:\Work'
        (ConvertTo-SanitizedPath -Path 'FileSystem::D:\Work').Path | Should -Be 'D:\Work'
    }

    It '相對與根相對路徑的種類正確' {
        (ConvertTo-SanitizedPath -Path 'mnt').Kind | Should -Be 'Relative'
        (ConvertTo-SanitizedPath -Path '\mnt').Kind | Should -Be 'RootRelative'
    }

    It '空白與僅含空白的路徑中止' {
        { ConvertTo-SanitizedPath -Path '   ' } | Should -Throw '*空白*'
    }

    It '拒絕上層參照（..）' {
        { ConvertTo-SanitizedPath -Path 'D:\a\..\b' } | Should -Throw '*上層參照*'
    }

    It '拒絕非法檔名字元與控制字元' {
        { ConvertTo-SanitizedPath -Path 'D:\a|b' } | Should -Throw '*非法字元*'
        { ConvertTo-SanitizedPath -Path "D:\a`tb" } | Should -Throw '*控制字元*'
    }

    It '拒絕段落結尾為點或空白的名稱' {
        { ConvertTo-SanitizedPath -Path 'D:\a\b. ' } | Should -Throw '*結尾*'
    }

    It '登錄機碼路徑不可進入檔案系統函式' {
        { ConvertTo-SanitizedPath -Path 'HKLM:\SOFTWARE\Test' } | Should -Throw '*登錄機碼*'
        { ConvertTo-SanitizedPath -Path 'Registry::HKEY_CURRENT_USER\Test' } | Should -Throw '*登錄機碼*'
    }

    It '網址不可進入檔案系統函式' {
        { ConvertTo-SanitizedPath -Path 'https://example.com/a.cab' } | Should -Throw '*網址*'
    }
}

Describe 'Windows 長路徑與 UNC（\\?\、\\server\share）' -Tag 'Unit' {
    It '\\?\ 前綴的磁碟路徑去除前綴並記錄為 Drive' {
        $r = ConvertTo-SanitizedPath -Path '\\?\C:\Very\Long'
        $r.Path | Should -Be 'C:\Very\Long'
        $r.Kind | Should -Be 'Drive'
    }

    It '\\?\UNC\ 前綴還原為一般 UNC 形式' {
        $r = ConvertTo-SanitizedPath -Path '\\?\UNC\server\share\dir\f.cab'
        $r.Path | Should -Be '\\server\share\dir\f.cab'
        $r.Kind | Should -Be 'UNC'
    }

    It 'UNC 路徑保留伺服器與共用名稱' {
        $r = ConvertTo-SanitizedPath -Path '\\server\share\x'
        $r.Path | Should -Be '\\server\share\x'
        $r.Kind | Should -Be 'UNC'
    }

    It 'UNC 缺少共用名稱時中止' {
        { ConvertTo-SanitizedPath -Path '\\server' } | Should -Throw '*伺服器與共用名稱*'
    }

    It '超過 MAX_PATH 的路徑提供 LongPath（\\?\）形式' {
        $deep = 'D:\' + ('a' * 200) + '\' + ('b' * 80)
        $r = ConvertTo-SanitizedPath -Path $deep
        $r.LongPath | Should -Be ('\\?\' + $deep)
    }

    It '短路徑不產生 LongPath' {
        (ConvertTo-SanitizedPath -Path 'D:\short').LongPath | Should -BeNullOrEmpty
    }

    It '\\.\ 裝置命名空間一律拒絕' {
        { ConvertTo-SanitizedPath -Path '\\.\PhysicalDrive0' } | Should -Throw '*裝置命名空間*'
    }
}

Describe '登錄機碼路徑淨化（ConvertTo-SanitizedRegistryPath）' -Tag 'Unit' {
    It 'PowerShell 的 HKLM:\ 形式轉為三種表示法' {
        $r = ConvertTo-SanitizedRegistryPath -Path 'HKLM:\SOFTWARE\Microsoft\Windows'
        $r.Hive | Should -Be 'HKEY_LOCAL_MACHINE'
        $r.SubKey | Should -Be 'SOFTWARE\Microsoft\Windows'
        $r.ProviderPath | Should -Be 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows'
        $r.RegExePath | Should -Be 'HKLM\SOFTWARE\Microsoft\Windows'
        $r.PsDrivePath | Should -Be 'HKLM:\SOFTWARE\Microsoft\Windows'
    }

    It 'Registry:: 提供者形式與長名稱根可被接受' {
        $r = ConvertTo-SanitizedRegistryPath -Path 'Registry::HKEY_CURRENT_USER\Software\X'
        $r.Hive | Should -Be 'HKEY_CURRENT_USER'
        $r.RegExePath | Should -Be 'HKCU\Software\X'
    }

    It '只有根機碼時 SubKey 為空' {
        $r = ConvertTo-SanitizedRegistryPath -Path 'HKLM:'
        $r.Hive | Should -Be 'HKEY_LOCAL_MACHINE'
        $r.SubKey | Should -BeNullOrEmpty
        $r.ProviderPath | Should -Be 'Registry::HKEY_LOCAL_MACHINE'
    }

    It '未知的登錄機碼根中止' {
        { ConvertTo-SanitizedRegistryPath -Path 'HKXX:\Foo' } | Should -Throw '*未知的登錄機碼根*'
    }

    It '登錄機碼路徑不可含上層參照' {
        { ConvertTo-SanitizedRegistryPath -Path 'HKLM:\SOFTWARE\..\SYSTEM' } | Should -Throw '*上層參照*'
    }
}

Describe '網址淨化（ConvertTo-SanitizedUri）' -Tag 'Unit' {
    It 'https 網址取得檔名並保留主機與路徑' {
        $r = ConvertTo-SanitizedUri -Uri 'https://wimlib.net/downloads/wimlib-1.14.5-windows-x86_64-bin.zip'
        $r.Scheme | Should -Be 'https'
        $r.Host | Should -Be 'wimlib.net'
        $r.FileName | Should -Be 'wimlib-1.14.5-windows-x86_64-bin.zip'
    }

    It '移除 userinfo（帳號與密碼）後才用於紀錄' {
        $r = ConvertTo-SanitizedUri -Uri 'ftp://user:secret@files.example.com/pkg/update.cab'
        $r.SafeUri | Should -Not -Match 'secret'
        $r.SafeUri | Should -Not -Match 'user:'
        $r.SafeUri | Should -Match 'files\.example\.com'
    }

    It 'ftp 為預設允許的協定' {
        (ConvertTo-SanitizedUri -Uri 'ftp://files.example.com/a.cab').Scheme | Should -Be 'ftp'
    }

    It '不允許的協定（file、javascript）中止' {
        { ConvertTo-SanitizedUri -Uri 'file:///C:/Windows/win.ini' } | Should -Throw '*不允許的網址協定*'
        { ConvertTo-SanitizedUri -Uri 'javascript:alert(1)' } | Should -Throw
    }

    It '相對網址與含空白的網址中止' {
        { ConvertTo-SanitizedUri -Uri '/relative/path' } | Should -Throw '*有效的絕對網址*'
        { ConvertTo-SanitizedUri -Uri 'https://example.com/a b' } | Should -Throw '*空白*'
    }

    It '檔名中的非法字元被替換，無檔名時回退為 download' {
        (ConvertTo-SanitizedUri -Uri 'https://example.com/a%3Ab.cab').FileName | Should -Be 'a_b.cab'
        (ConvertTo-SanitizedUri -Uri 'https://example.com/').FileName | Should -Be 'download'
    }

    It 'ConvertTo-LogSafePath 對網址移除帳密，對無效網址不丟錯' {
        ConvertTo-LogSafePath -Value 'ftp://u:p@host/x.cab' | Should -Not -Match ':p@'
        ConvertTo-LogSafePath -Value 'https://[bad' | Should -Be '<無效網址>'
        ConvertTo-LogSafePath -Value 'D:\plain' | Should -Be 'D:\plain'
    }
}

Describe '路徑比對（Get-ComparablePath、Test-PathWithin）' -Tag 'Unit' {
    It '比對路徑統一小寫並補結尾反斜線' {
        Get-ComparablePath -Path 'D:\Pkg' | Should -Be 'd:\pkg\'
    }

    It '相同路徑或子路徑視為位於其下（不分大小寫）' {
        Test-PathWithin -Child 'D:\Pkg' -Parent 'd:\pkg' | Should -BeTrue
        Test-PathWithin -Child 'D:\Pkg\sub\x' -Parent 'D:\Pkg' | Should -BeTrue
    }

    It '路徑段邊界：D:\pkg2 不位於 D:\pkg 之下' {
        Test-PathWithin -Child 'D:\pkg2' -Parent 'D:\pkg' | Should -BeFalse
    }

    It '空白路徑不位於任何路徑之下' {
        Test-PathWithin -Child '' -Parent 'D:\pkg' | Should -BeFalse
    }

    It '\\?\ 前綴與一般形式比對結果相同' {
        Test-PathWithin -Child '\\?\D:\pkg\x' -Parent 'D:\pkg' | Should -BeTrue
    }
}
