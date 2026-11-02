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

    It '主流程呼叫點傳入函式的每一個參數，且以同名變數傳入（IsFirstTarget 例外）' {
        $fn = [System.Management.Automation.Language.Parser]::ParseFile($script:actionPath, [ref]$null, [ref]$null)
        $names = @($fn.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true).Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $names.Count | Should -Be 21
        $call = @($script:mainAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-WinMediaInstallIndexUpdate' }, $true))
        $call.Count | Should -Be 1
        $el = @($call[0].CommandElements)
        $bound = @{}
        for ($i = 1; $i -lt $el.Count; $i++) {
            if ($el[$i] -is [System.Management.Automation.Language.CommandParameterAst]) {
                $bound[$el[$i].ParameterName] = if ($el[$i].Argument) { $el[$i].Argument } else { $el[$i + 1] }
            }
        }
        foreach ($name in $names) {
            $bound.ContainsKey($name) | Should -BeTrue -Because "呼叫點缺少 -$name"
            if ($name -eq 'IsFirstTarget') { $bound[$name].Extent.Text | Should -Be '($index -eq $targets[0])' }
            else { $bound[$name].VariablePath.UserPath | Should -Be $name -Because "-$name 應以 `$$name 傳入" }
        }
    }

    It '根模組範圍可解析 Invoke-WinMediaInstallIndexUpdate（漏掉 dot-source 時會在此失敗）' {
        Import-Module -Name (Join-Path -Path $script:root -ChildPath 'WinMediaRefresh.psd1') -Force
        & (Get-Module -Name WinMediaRefresh) { Get-Command -Name Invoke-WinMediaInstallIndexUpdate -ErrorAction SilentlyContinue } | Should -Not -BeNullOrEmpty
    }
}
