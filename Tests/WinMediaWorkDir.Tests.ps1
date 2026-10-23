#Requires -Version 5.1

BeforeAll {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\Modules\WinMediaPath.psm1') -Force
}

Describe 'Use-WinMediaWorkDir / Remove-WinMediaWorkDir（Must 1：只清除本工具登記過的目錄）' -Tag 'Unit' {
    It '不存在時建立目錄並登記' {
        $p = Join-Path -Path $TestDrive -ChildPath 'new-media'
        Use-WinMediaWorkDir -Path $p
        Test-Path -LiteralPath $p -PathType Container | Should -BeTrue
        Test-Path -LiteralPath "$p.winmedia-owned" | Should -BeTrue
    }

    It '已登記的目錄（上次失敗留下）會先清空再使用' {
        $p = Join-Path -Path $TestDrive -ChildPath 'leftover'
        Use-WinMediaWorkDir -Path $p
        Set-Content -LiteralPath (Join-Path -Path $p -ChildPath 'old.txt') -Value 'stale'
        Use-WinMediaWorkDir -Path $p
        @(Get-ChildItem -LiteralPath $p -Force).Count | Should -Be 0
    }

    It '未登記且非空的既有目錄直接拒絕，內容保留' {
        $p = Join-Path -Path $TestDrive -ChildPath 'personal'
        New-Item -ItemType Directory -Path $p -Force | Out-Null
        Set-Content -LiteralPath (Join-Path -Path $p -ChildPath 'photo.txt') -Value 'keep'
        { Use-WinMediaWorkDir -Path $p } | Should -Throw -ExpectedMessage '*不是本工具建立*'
        Test-Path -LiteralPath (Join-Path -Path $p -ChildPath 'photo.txt') | Should -BeTrue
        Test-Path -LiteralPath "$p.winmedia-owned" | Should -BeFalse
    }

    It '未登記但為空的既有目錄會被登記後使用' {
        $p = Join-Path -Path $TestDrive -ChildPath 'empty-dir'
        New-Item -ItemType Directory -Path $p -Force | Out-Null
        Use-WinMediaWorkDir -Path $p
        Test-Path -LiteralPath "$p.winmedia-owned" | Should -BeTrue
    }

    It 'Remove 只刪除已登記的目錄與登記檔，未登記的目錄保留' {
        $owned = Join-Path -Path $TestDrive -ChildPath 'owned'
        Use-WinMediaWorkDir -Path $owned
        Set-Content -LiteralPath (Join-Path -Path $owned -ChildPath 'f.txt') -Value 'x'
        $foreign = Join-Path -Path $TestDrive -ChildPath 'foreign'
        New-Item -ItemType Directory -Path $foreign -Force | Out-Null
        Set-Content -LiteralPath (Join-Path -Path $foreign -ChildPath 'photo.txt') -Value 'keep'
        Remove-WinMediaWorkDir -Path $owned
        Remove-WinMediaWorkDir -Path $foreign
        Test-Path -LiteralPath $owned | Should -BeFalse
        Test-Path -LiteralPath "$owned.winmedia-owned" | Should -BeFalse
        Test-Path -LiteralPath (Join-Path -Path $foreign -ChildPath 'photo.txt') | Should -BeTrue
    }
}

Describe 'Assert-WinMediaOutputDir（Must 2：成品目錄不得位於會被清理或掛載的目錄之下）' -Tag 'Unit' {
    It 'OutputDir 位於會被清理的 media 之下時拋錯' {
        $work = Join-Path -Path $TestDrive -ChildPath 'work-a'
        $media = Join-Path -Path $work -ChildPath 'media'
        { Assert-WinMediaOutputDir -OutputDir (Join-Path -Path $media -ChildPath 'out') -ProtectedDir @($media, (Join-Path -Path $work -ChildPath 'winre')) } | Should -Throw -ExpectedMessage '*位於工作或掛載目錄之下*'
    }

    It 'OutputDir 位於 WorkDir 底下但不在保護目錄內時不拋錯' {
        $work = Join-Path -Path $TestDrive -ChildPath 'work-b'
        $media = Join-Path -Path $work -ChildPath 'media'
        { Assert-WinMediaOutputDir -OutputDir (Join-Path -Path $work -ChildPath 'out') -ProtectedDir @($media) } | Should -Not -Throw
    }
}

Describe 'Resolve-WinMediaLogFile（Must 4：LogFile 留空時寫入 LogDir）' -Tag 'Unit' {
    It 'LogFile 留空時回傳 LogDir\WinMediaRefresh.log' {
        $logDir = Join-Path -Path $TestDrive -ChildPath 'logs-x'
        $path = Resolve-WinMediaLogFile -Config @{ LogFile = ''; LogDir = $logDir; WorkDir = $TestDrive }
        $path | Should -BeExactly (Join-Path -Path $logDir -ChildPath 'WinMediaRefresh.log')
    }

    It 'LogFile 已指定時原樣回傳' {
        $explicit = Join-Path -Path $TestDrive -ChildPath 'custom.log'
        Resolve-WinMediaLogFile -Config @{ LogFile = $explicit; LogDir = (Join-Path -Path $TestDrive -ChildPath 'x'); WorkDir = $TestDrive } | Should -BeExactly $explicit
    }

    It 'LogDir 留空時由 WorkDir\logs 推導' {
        $work = Join-Path -Path $TestDrive -ChildPath 'work-log'
        Resolve-WinMediaLogFile -Config @{ LogFile = ''; LogDir = ''; WorkDir = $work } | Should -BeExactly (Join-Path -Path $work -ChildPath 'logs\WinMediaRefresh.log')
    }
}

Describe 'Resolve-WinMediaLogFile 缺鍵的設定檔（StrictMode 下不得拋錯）' -Tag 'Unit' {
    It '設定只有 WorkDir 時回傳 WorkDir\logs\WinMediaRefresh.log' {
        $work = Join-Path -Path $TestDrive -ChildPath 'work-missing-keys'
        Resolve-WinMediaLogFile -Config @{ WorkDir = $work } | Should -BeExactly (Join-Path -Path $work -ChildPath 'logs\WinMediaRefresh.log')
    }
}

Describe '主流程接線（Must 1、2、4）' -Tag 'Unit' {
    It '主流程呼叫 4 個新 helper，且清理時不再直接 Remove-Item 工作子目錄變數 $dir' {
        $mainPath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Public\Invoke-WindowsMediaRefresh.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($mainPath, [ref]$null, [ref]$null)
        $names = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
        foreach ($name in 'Resolve-WinMediaLogFile', 'Assert-WinMediaOutputDir', 'Use-WinMediaWorkDir', 'Remove-WinMediaWorkDir') { $names | Should -Contain $name }
        $direct = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Remove-Item' -and $n.Extent.Text -match '\$dir\b' }, $true))
        $direct.Count | Should -Be 0
    }
}
