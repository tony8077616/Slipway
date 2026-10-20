#Requires -Version 5.1

BeforeAll {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\WinMediaRefresh.psd1') -Force
    $script:rootModule = Get-Module -Name WinMediaRefresh
}

Describe '根模組匯入：公開函式可解析的共用指令（實機曾因缺少匯入而中止）' -Tag 'Unit' {
    It 'Invoke-WindowsMediaRefresh 在根模組範圍內可解析 Test-PathWithin' {
        & $script:rootModule { Get-Command -Name Test-PathWithin -ErrorAction SilentlyContinue } | Should -Not -BeNullOrEmpty
    }

    It 'Invoke-WindowsMediaRefresh 在根模組範圍內可解析 ConvertTo-SanitizedPath' {
        & $script:rootModule { Get-Command -Name ConvertTo-SanitizedPath -ErrorAction SilentlyContinue } | Should -Not -BeNullOrEmpty
    }
}
