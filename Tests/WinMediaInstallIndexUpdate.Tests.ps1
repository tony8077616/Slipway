#Requires -Version 5.1

BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    $script:mainPath = Join-Path -Path $script:root -ChildPath 'Public\Invoke-WindowsMediaRefresh.ps1'
    $script:actionPath = Join-Path -Path $script:root -ChildPath 'Public\Invoke-WinMediaInstallIndexUpdate.ps1'
    $script:mainAst = [System.Management.Automation.Language.Parser]::ParseFile($script:mainPath, [ref]$null, [ref]$null)
}

Describe 'install 索引更新抽出為函式（Step 12a，行為不變）' -Tag 'Unit' {
    It '主流程的 install 迴圈以 Invoke-WinMediaInstallIndexUpdate 取代內嵌的 Action，且只呼叫一次' {
        $calls = @($script:mainAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-WinMediaInstallIndexUpdate' }, $true))
        $calls.Count | Should -Be 1
    }

    It '函式定義於 Public\Invoke-WinMediaInstallIndexUpdate.ps1' {
        Test-Path -LiteralPath $script:actionPath -PathType Leaf | Should -BeTrue
    }

    It '函式內的套件與 DISM 步驟維持原本的先後順序' {
        Test-Path -LiteralPath $script:actionPath -PathType Leaf | Should -BeTrue
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:actionPath, [ref]$null, [ref]$null)
        $watch = @('Add-WindowsPackage', 'Install-WinMediaLangFod', 'Repair-WindowsImage', 'Optimize-WinMediaImage', 'Install-WinMediaDeferredFod', 'Remove-WinMediaAppx', 'Install-WinMediaStoreApp', 'Install-WinMediaLxp', 'Install-WinMediaDriver', 'Get-WinMediaBuildInfo', 'Invoke-WinMediaOperation', 'Copy-WinMediaUpdatedBootFiles')
        $seen = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
            Sort-Object { $_.Extent.StartOffset } |
            ForEach-Object { $_.GetCommandName() } |
            Where-Object { $watch -contains $_ })
        ($seen -join ',') | Should -Be 'Add-WindowsPackage,Install-WinMediaLangFod,Add-WindowsPackage,Repair-WindowsImage,Optimize-WinMediaImage,Install-WinMediaDeferredFod,Add-WindowsPackage,Remove-WinMediaAppx,Install-WinMediaStoreApp,Install-WinMediaLxp,Install-WinMediaDriver,Get-WinMediaBuildInfo,Invoke-WinMediaOperation,Invoke-WinMediaOperation,Copy-WinMediaUpdatedBootFiles'
    }

    It '根模組範圍可解析 Invoke-WinMediaInstallIndexUpdate（漏掉 dot-source 時會在此失敗）' {
        Import-Module -Name (Join-Path -Path $script:root -ChildPath 'WinMediaRefresh.psd1') -Force
        & (Get-Module -Name WinMediaRefresh) { Get-Command -Name Invoke-WinMediaInstallIndexUpdate -ErrorAction SilentlyContinue } | Should -Not -BeNullOrEmpty
    }
}
