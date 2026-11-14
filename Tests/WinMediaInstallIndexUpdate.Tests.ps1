#Requires -Version 5.1

BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    $script:mainPath = Join-Path -Path $script:root -ChildPath 'Public\Invoke-WindowsMediaRefresh.ps1'
    $script:actionPath = Join-Path -Path $script:root -ChildPath 'Public\Invoke-WinMediaInstallIndexUpdate.ps1'
    $script:imagePath = Join-Path -Path $script:root -ChildPath 'Public\Invoke-WinMediaInstallIndexImageUpdate.ps1'
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

    It '映像檔與外層檔的步驟依序合併後，維持 12a 的先後順序（只有 ReplaceWinRE 與 CopyXmlLite 交換，且帶上 -Operation 值）' {
        Test-Path -LiteralPath $script:imagePath -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $script:actionPath -PathType Leaf | Should -BeTrue
        $watch = @('Add-WindowsPackage', 'Install-WinMediaLangFod', 'Repair-WindowsImage', 'Optimize-WinMediaImage', 'Install-WinMediaDeferredFod', 'Remove-WinMediaAppx', 'Install-WinMediaStoreApp', 'Install-WinMediaLxp', 'Install-WinMediaDriver', 'Get-WinMediaBuildInfo', 'Invoke-WinMediaOperation', 'Copy-WinMediaUpdatedBootFiles')
        $seen = @()
        foreach ($path in @($script:imagePath, $script:actionPath)) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
            $seen += @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
                Sort-Object { $_.Extent.StartOffset } |
                Where-Object { $watch -contains $_.GetCommandName() } |
                ForEach-Object {
                    $cmd = $_
                    $name = $cmd.GetCommandName()
                    if ($name -eq 'Invoke-WinMediaOperation') {
                        $els = @($cmd.CommandElements)
                        $op = ''
                        for ($i = 0; $i -lt $els.Count; $i++) {
                            if ($els[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and $els[$i].ParameterName -eq 'Operation') { $op = $els[$i + 1].Value }
                        }
                        $name = 'Invoke-WinMediaOperation:{0}' -f $op
                    }
                    $name
                })
        }
        ($seen -join ',') | Should -Be 'Add-WindowsPackage,Add-WindowsPackage,Install-WinMediaLangFod,Add-WindowsPackage,Repair-WindowsImage,Optimize-WinMediaImage,Install-WinMediaDeferredFod,Add-WindowsPackage,Remove-WinMediaAppx,Install-WinMediaStoreApp,Install-WinMediaLxp,Install-WinMediaDriver,Get-WinMediaBuildInfo,Invoke-WinMediaOperation:ReplaceWinRE,Invoke-WinMediaOperation:CopyXmlLite,Copy-WinMediaUpdatedBootFiles'
    }

    It '主流程呼叫點傳入函式的每一個參數，且以同名變數傳入（IsFirstTarget 例外）' {
        $fn = [System.Management.Automation.Language.Parser]::ParseFile($script:actionPath, [ref]$null, [ref]$null)
        $names = @($fn.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true).Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $names.Count | Should -Be 22
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

    It '外層函式本體沒有自由變數（參數、區域賦值、自動變數以外的讀取）' {
        $outer = [System.Management.Automation.Language.Parser]::ParseFile($script:actionPath, [ref]$null, [ref]$null)
        $fn = $outer.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true); $fn | Should -Not -BeNullOrEmpty -Because '找不到外層函式的 FunctionDefinitionAst'
        $params = @($fn.Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $assigned = @($fn.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] }, $true) | ForEach-Object { $_.Left.VariablePath.UserPath })
        $auto = @('_', 'null', 'true', 'false', 'PSItem', 'args', 'input', 'this', 'Matches', 'PSBoundParameters', 'LASTEXITCODE', 'Error', 'PSCmdlet')
        $reads = @($fn.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true) | ForEach-Object { $_.VariablePath.UserPath } | Sort-Object -Unique)
        $free = @($reads | Where-Object { $params -notcontains $_ -and $assigned -notcontains $_ -and $auto -notcontains $_ })
        ($free -join ',') | Should -Be ''
    }
}

Describe 'install 索引映像部分（Step 12b-1，純抽取）' -Tag 'Unit' {
    BeforeAll {
        $script:imageAst = $null
        $script:imageParams = @()
        if (Test-Path -LiteralPath $script:imagePath -PathType Leaf) {
            $script:imageAst = [System.Management.Automation.Language.Parser]::ParseFile($script:imagePath, [ref]$null, [ref]$null)
            $script:imageParams = @($script:imageAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true).Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        }
        $bootText = Get-Content -LiteralPath (Join-Path -Path $script:root -ChildPath 'Modules\WinMediaBootFiles.psm1') -Raw
        $script:bootExports = @()
        if ($bootText -match 'Export-ModuleMember -Function (.+)') {
            $script:bootExports = @($Matches[1] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }
    }

    It '映像函式檔存在於 Public\，且定義 Invoke-WinMediaInstallIndexImageUpdate' {
        Test-Path -LiteralPath $script:imagePath -PathType Leaf | Should -BeTrue
        @($script:imageAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-WinMediaInstallIndexImageUpdate' }, $true)).Count | Should -Be 1
    }

    It '映像函式不呼叫 WinMediaBootFiles 匯出的任何函式' {
        $script:imageAst | Should -Not -BeNullOrEmpty -Because '映像函式檔不存在'
        $script:bootExports.Count | Should -BeGreaterThan 5
        $calls = @($script:imageAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
        @($calls | Where-Object { $script:bootExports -contains $_ }).Count | Should -Be 0
    }

    It '映像函式的參數與本體都不使用媒體相關變數（mediaDir、sourcesDir、isEsdSource、installKernel、buildInfo、bootEx）' {
        $script:imageAst | Should -Not -BeNullOrEmpty -Because '映像函式檔不存在'
        $forbidden = @('mediaDir', 'sourcesDir', 'isEsdSource', 'installKernel', 'buildInfo', 'bootEx')
        @($script:imageParams | Where-Object { $forbidden -contains $_ }).Count | Should -Be 0
        $used = @($script:imageAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true) | ForEach-Object { $_.VariablePath.UserPath })
        @($used | Where-Object { $forbidden -contains $_ }).Count | Should -Be 0
    }

    It '映像函式本體沒有自由變數（FREE 守衛；序列路徑的動態作用域會讓未宣告的變數悄悄讀到主檔的值）' {
        $script:imageAst | Should -Not -BeNullOrEmpty -Because '映像函式檔不存在'
        $fn = $script:imageAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true); $fn | Should -Not -BeNullOrEmpty -Because '找不到映像函式的 FunctionDefinitionAst'
        $params = @($fn.Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $assigned = @($fn.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] }, $true) | ForEach-Object { $_.Left.VariablePath.UserPath })
        $auto = @('_', 'null', 'true', 'false', 'PSItem', 'args', 'input', 'this', 'Matches', 'PSBoundParameters', 'LASTEXITCODE', 'Error', 'PSCmdlet')
        $reads = @($fn.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true) | ForEach-Object { $_.VariablePath.UserPath } | Sort-Object -Unique)
        $free = @($reads | Where-Object { $params -notcontains $_ -and $assigned -notcontains $_ -and $auto -notcontains $_ })
        ($free -join ',') | Should -Be ''
    }

    It '映像函式不重新賦值任何參數（REASSIGN 守衛）' {
        $script:imageAst | Should -Not -BeNullOrEmpty -Because '映像函式檔不存在'
        $fn = $script:imageAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true); $fn | Should -Not -BeNullOrEmpty -Because '找不到映像函式的 FunctionDefinitionAst'
        $params = @($fn.Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $re = @($fn.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and $params -contains $n.Left.VariablePath.UserPath }, $true) | ForEach-Object { $_.Extent.Text })
        ($re -join ' | ') | Should -Be ''
    }

    It '外層函式以同名變數呼叫映像函式，且傳入映像函式宣告的每個參數' {
        $outer = [System.Management.Automation.Language.Parser]::ParseFile($script:actionPath, [ref]$null, [ref]$null)
        $calls = @($outer.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-WinMediaInstallIndexImageUpdate' }, $true))
        $calls.Count | Should -Be 1
        $el = @($calls[0].CommandElements)
        $bound = @{}
        for ($i = 1; $i -lt $el.Count; $i++) {
            if ($el[$i] -is [System.Management.Automation.Language.CommandParameterAst]) {
                $bound[$el[$i].ParameterName] = if ($el[$i].Argument) { $el[$i].Argument } else { $el[$i + 1] }
            }
        }
        $script:imageParams.Count | Should -BeGreaterThan 10
        foreach ($name in $script:imageParams) {
            $bound.ContainsKey($name) | Should -BeTrue -Because "外層呼叫映像函式缺少 -$name"
            $bound[$name].VariablePath.UserPath | Should -Be $name -Because "-$name 應以 `$$name 傳入"
        }
    }
}
