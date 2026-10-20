#Requires -Version 5.1

BeforeAll {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\WinMediaRefresh.psd1') -Force
    $script:defaults = Import-PowerShellDataFile -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..\Config\Default.psd1')
}

Describe 'WorkDir 預設值（空白 = 工具所在磁碟根目錄\WinMediaWork）' -Tag 'Unit' {
    It 'WorkDir 為空時套用工具磁碟根目錄，不停在「必須為絕對路徑」的錯誤' {
        Mock -ModuleName WinMediaRefresh Resolve-WinMediaMountDir { throw "WORKDIR=$WorkDir" }
        $cfg = $script:defaults.Clone()
        $cfg.WorkDir = ''
        $cfg.MountDir = ''
        $root = [System.IO.Path]::GetPathRoot((Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..')).Path)
        $expected = Join-Path -Path $root -ChildPath 'WinMediaWork'
        { Invoke-WindowsMediaRefresh -SourceIso 'D:\nonexistent.iso' -Config $cfg -Confirm:$false } |
            Should -Throw ('*WORKDIR={0}*' -f $expected)
    }
}

Describe '操作紀錄格式（OperationLog 每行須含完整欄位）' -Tag 'Unit' {
    It 'Invoke-WinMediaOperation 寫出的行同時含 category=、operation= 與 result=' {
        Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\PSModules\Common\WinMediaOperation.psm1') -Force
        $log = Join-Path -Path $TestDrive -ChildPath 'op.log'
        $cfg = @{ DebugTrace = 0; OperationLog = $log }
        Invoke-WinMediaOperation -Category File -Operation 'ExtractSetup' -Target 'C:\x' -Config $cfg -ScriptBlock { 1 } | Out-Null
        $line = Get-Content -LiteralPath $log -Encoding UTF8
        $line | Should -Match 'category=File'
        $line | Should -Match 'operation=ExtractSetup'
        $line | Should -Match 'result=success'
    }
}
