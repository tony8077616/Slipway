#Requires -Version 5.1

BeforeAll {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\Modules\WinMediaDefender.psm1') -Force
}

Describe 'Add-WinMediaDefenderExclusion（只回傳本次新增的路徑）' -Tag 'Unit' {
    It '已存在的排除（忽略大小寫與結尾反斜線）不納入回傳，也不重複加入' {
        Mock -ModuleName WinMediaDefender Get-MpPreference { [pscustomobject]@{ ExclusionPath = @('D:\WinMediaWork\') } }
        Mock -ModuleName WinMediaDefender Add-MpPreference { }

        $added = Add-WinMediaDefenderExclusion -Path @('d:\winmediawork', 'D:\MountUUP')

        $added | Should -Be @('D:\MountUUP')
        Should -Invoke -CommandName Add-MpPreference -ModuleName WinMediaDefender -Times 1 -Exactly
    }

    It '同一批次內重複的路徑只加一次' {
        Mock -ModuleName WinMediaDefender Get-MpPreference { [pscustomobject]@{ ExclusionPath = @() } }
        Mock -ModuleName WinMediaDefender Add-MpPreference { }

        $added = Add-WinMediaDefenderExclusion -Path @('D:\WinMediaOut', 'D:\WinMediaOut\')

        $added.Count | Should -Be 1
        Should -Invoke -CommandName Add-MpPreference -ModuleName WinMediaDefender -Times 1 -Exactly
    }

    It 'Add-MpPreference 失敗時只警告，不中止，也不列入回傳' {
        Mock -ModuleName WinMediaDefender Get-MpPreference { [pscustomobject]@{ ExclusionPath = @() } }
        Mock -ModuleName WinMediaDefender Add-MpPreference { throw '存取被拒' }
        Mock -ModuleName WinMediaDefender Write-Warning { }

        $added = Add-WinMediaDefenderExclusion -Path @('D:\WinMediaWork')

        $added.Count | Should -Be 0
        Should -Invoke -CommandName Write-Warning -ModuleName WinMediaDefender -Times 1 -Exactly
    }

    It '無法讀取既有排除時整批略過，不新增、也不回傳（避免結束時移除使用者的永久排除）' {
        Mock -ModuleName WinMediaDefender Get-MpPreference { throw 'Tamper Protection' }
        Mock -ModuleName WinMediaDefender Add-MpPreference { }
        Mock -ModuleName WinMediaDefender Write-Warning { }

        $added = Add-WinMediaDefenderExclusion -Path @('D:\WinMediaWork')

        $added.Count | Should -Be 0
        Should -Invoke -CommandName Add-MpPreference -ModuleName WinMediaDefender -Times 0 -Exactly
    }

    It 'Get-MpPreference 回傳 N/A 字串時視為無法讀取，整批略過' {
        Mock -ModuleName WinMediaDefender Get-MpPreference { [pscustomobject]@{ ExclusionPath = @('N/A: Tamper Protection is enabled') } }
        Mock -ModuleName WinMediaDefender Add-MpPreference { }
        Mock -ModuleName WinMediaDefender Write-Warning { }

        $added = Add-WinMediaDefenderExclusion -Path @('D:\WinMediaWork')

        $added.Count | Should -Be 0
        Should -Invoke -CommandName Add-MpPreference -ModuleName WinMediaDefender -Times 0 -Exactly
    }

    It '路徑含空字串時不拋出參數錯誤，且略過該項' {
        Mock -ModuleName WinMediaDefender Get-MpPreference { [pscustomobject]@{ ExclusionPath = @() } }
        Mock -ModuleName WinMediaDefender Add-MpPreference { }

        { $script:emptyAdded = Add-WinMediaDefenderExclusion -Path @('', 'D:\MountUUP') } | Should -Not -Throw

        $script:emptyAdded | Should -Be @('D:\MountUUP')
    }
}

Describe '主流程接線：Defender 排除於開工前加入、結束時還原' -Tag 'Unit' {
    BeforeAll {
        $script:mainText = Get-Content -LiteralPath (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Public\Invoke-WindowsMediaRefresh.ps1') -Raw
    }

    It '加入排除位於 ShouldProcess 之後，且只加入工作目錄（不含 PackageDir）' {
        $should = $script:mainText.IndexOf('$PSCmdlet.ShouldProcess')
        $add = $script:mainText.IndexOf('Add-WinMediaDefenderExclusion')
        $should | Should -BeGreaterThan -1
        $add | Should -BeGreaterThan $should
        $script:mainText.Substring($add, 200) | Should -Not -Match 'PackageDir'
    }

    It '主體以 try 包住，finally 還原本次新增的排除' {
        $try = $script:mainText.IndexOf("    try {`r`n")
        $finally = $script:mainText.LastIndexOf('finally {')
        $try | Should -BeGreaterThan -1
        $finally | Should -BeGreaterThan $try
        $script:mainText.Substring($finally) | Should -Match 'Remove-WinMediaDefenderExclusion -Path \$defenderAdded'
    }
}

Describe 'Remove-WinMediaDefenderExclusion（失敗只警告）' -Tag 'Unit' {
    It '逐一移除傳入的路徑' {
        Mock -ModuleName WinMediaDefender Remove-MpPreference { }

        Remove-WinMediaDefenderExclusion -Path @('D:\WinMediaWork', 'D:\MountUUP')

        Should -Invoke -CommandName Remove-MpPreference -ModuleName WinMediaDefender -Times 2 -Exactly
    }

    It '移除失敗時只警告，不拋出例外（供 finally 呼叫）' {
        Mock -ModuleName WinMediaDefender Remove-MpPreference { throw '存取被拒' }
        Mock -ModuleName WinMediaDefender Write-Warning { }

        { Remove-WinMediaDefenderExclusion -Path @('D:\WinMediaWork') } | Should -Not -Throw
        Should -Invoke -CommandName Write-Warning -ModuleName WinMediaDefender -Times 1 -Exactly
    }

    It '空清單不呼叫 Remove-MpPreference' {
        Mock -ModuleName WinMediaDefender Remove-MpPreference { }

        Remove-WinMediaDefenderExclusion -Path @()

        Should -Invoke -CommandName Remove-MpPreference -ModuleName WinMediaDefender -Times 0 -Exactly
    }
}

Describe 'Defender 排除狀態檔（審查第 15 則：程序被強制結束後仍可還原）' -Tag 'Unit' {
    AfterEach { $env:SLIPWAY_TEST_STATE = $null }

    It 'Add 在 Add-MpPreference 之前寫入狀態檔，且只列出本次要新增的項目（不含使用者原有排除）' {
        $stateFile = Join-Path -Path $TestDrive -ChildPath 'add-state.json'
        $env:SLIPWAY_TEST_STATE = $stateFile
        Mock -ModuleName WinMediaDefender Get-MpPreference { [pscustomobject]@{ ExclusionPath = @('D:\UserOwn') } }
        Mock -ModuleName WinMediaDefender Add-MpPreference { if (-not (Test-Path -LiteralPath $env:SLIPWAY_TEST_STATE)) { throw '狀態檔尚未寫入' } }

        $added = Add-WinMediaDefenderExclusion -Path @('d:\userown', 'D:\WinMediaWork') -StatePath $stateFile

        $added | Should -Be @('D:\WinMediaWork')
        @(Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json) | Should -Be @('D:\WinMediaWork')
        Should -Invoke -CommandName Add-MpPreference -ModuleName WinMediaDefender -Times 1 -Exactly
    }

    It 'Restore 只移除狀態檔列出的項目，移除後刪除狀態檔，不碰使用者原有排除' {
        $stateFile = Join-Path -Path $TestDrive -ChildPath 'restore-state.json'
        Set-Content -LiteralPath $stateFile -Value (ConvertTo-Json -InputObject @('D:\WinMediaWork', 'D:\MountUUP'))
        Mock -ModuleName WinMediaDefender Remove-MpPreference { }
        Mock -ModuleName WinMediaDefender Get-MpPreference { [pscustomobject]@{ ExclusionPath = @('D:\UserOwn', 'D:\WinMediaWork', 'D:\MountUUP') } }

        Restore-WinMediaDefenderExclusion -StatePath $stateFile -Confirm:$false

        Should -Invoke -CommandName Remove-MpPreference -ModuleName WinMediaDefender -Times 2 -Exactly
        Should -Invoke -CommandName Remove-MpPreference -ModuleName WinMediaDefender -Times 0 -Exactly -ParameterFilter { $ExclusionPath -eq 'D:\UserOwn' }
        Test-Path -LiteralPath $stateFile | Should -BeFalse
    }

    It '沒有狀態檔時 Restore 什麼都不做，不呼叫任何 Defender cmdlet' {
        $stateFile = Join-Path -Path $TestDrive -ChildPath 'absent-state.json'
        Mock -ModuleName WinMediaDefender Remove-MpPreference { }
        Mock -ModuleName WinMediaDefender Get-MpPreference { }

        Restore-WinMediaDefenderExclusion -StatePath $stateFile -Confirm:$false

        Should -Invoke -CommandName Remove-MpPreference -ModuleName WinMediaDefender -Times 0 -Exactly
        Should -Invoke -CommandName Get-MpPreference -ModuleName WinMediaDefender -Times 0 -Exactly
    }

    It '狀態檔損毀時警告並保留檔案，不移除任何排除' {
        $stateFile = Join-Path -Path $TestDrive -ChildPath 'bad-state.json'
        Set-Content -LiteralPath $stateFile -Value '{not json'
        Mock -ModuleName WinMediaDefender Remove-MpPreference { }
        Mock -ModuleName WinMediaDefender Write-Warning { }

        { Restore-WinMediaDefenderExclusion -StatePath $stateFile -Confirm:$false } | Should -Not -Throw

        Should -Invoke -CommandName Remove-MpPreference -ModuleName WinMediaDefender -Times 0 -Exactly
        Should -Invoke -CommandName Write-Warning -ModuleName WinMediaDefender -Times 1 -Exactly
        Test-Path -LiteralPath $stateFile | Should -BeTrue
    }

    It 'Remove 指定 StatePath 時，移除排除後刪除狀態檔' {
        $stateFile = Join-Path -Path $TestDrive -ChildPath 'remove-state.json'
        Set-Content -LiteralPath $stateFile -Value (ConvertTo-Json -InputObject @('D:\WinMediaWork'))
        Mock -ModuleName WinMediaDefender Remove-MpPreference { }

        Remove-WinMediaDefenderExclusion -Path @('D:\WinMediaWork') -StatePath $stateFile -Confirm:$false

        Should -Invoke -CommandName Remove-MpPreference -ModuleName WinMediaDefender -Times 1 -Exactly
        Test-Path -LiteralPath $stateFile | Should -BeFalse
    }

    It '主流程在加入排除之前先呼叫 Restore-WinMediaDefenderExclusion（AST）' {
        $mainPath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Public\Invoke-WindowsMediaRefresh.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($mainPath, [ref]$null, [ref]$null)
        $restore = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Restore-WinMediaDefenderExclusion' }, $true))
        $add = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Add-WinMediaDefenderExclusion' }, $true))
        $restore.Count | Should -BeGreaterThan 0
        $restore[0].Extent.StartOffset | Should -BeLessThan $add[0].Extent.StartOffset
    }
}
