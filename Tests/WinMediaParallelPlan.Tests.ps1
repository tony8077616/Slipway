#Requires -Version 5.1

# Step 12c-1 RED：平行處理計畫（Public\Get-WinMediaParallelPlan.ps1）。
# 實作尚未存在時，每個 It 先以「file missing」失敗；此檔不啟動任何子行程，也不執行 DISM／Mount／Start-Process。

BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    $script:planFile = Join-Path $script:root 'Public\Get-WinMediaParallelPlan.ps1'
    $script:manifest = Join-Path $script:root 'WinMediaRefresh.psd1'
    if (Test-Path -LiteralPath $script:manifest -PathType Leaf) {
        Import-Module -Name $script:manifest -Force
    }

    function Assert-PlanFilePresent {
        (Test-Path -LiteralPath $script:planFile -PathType Leaf) | Should -BeTrue -Because 'file missing: Get-WinMediaParallelPlan.ps1'
    }

    # 函式只被 dot-source 進根模組、未匯出，故於模組範圍內執行
    function Invoke-InModule {
        param([scriptblock]$Script, [object[]]$ArgList = @())
        & (Get-Module -Name WinMediaRefresh) $Script @ArgList
    }

    $script:SharedKeys = @('mountSwitches', 'Config', 'ssu', 'lcuStage', 'langFod', 'dotNet', 'enablement', 'appxList', 'storeSet', 'lxpItems', 'driverSet', 'forceUnsigned', 'resetBaseOS', 'common', 'winreWim')

    function Get-TestBaseJob {
        param([object]$Scratch = '<absent>', [object]$OperationLog = 'D:\Logs\OperationLog.txt')
        $config = @{
            LogDir       = 'D:\Logs'
            LogFile      = 'D:\Logs\main.log'
            OperationLog = $OperationLog
            MountDir     = 'D:\Mount'
            WorkDir      = 'D:\Work'
            DismProvider = 'Inbox'
            DismLogLevel = 'WarningsInfo'
            LogLevel     = 'Info'
        }
        if ($Scratch -ne '<absent>') { $config['ScratchDirectory'] = $Scratch }
        @{
            mountSwitches = @{}
            Config        = $config
            ssu           = 'ssu.msu'
            lcuStage      = 'lcu'
            langFod       = [pscustomobject]@{ Items = @() }
            dotNet        = $null
            enablement    = $null
            appxList      = 'appx'
            storeSet      = [pscustomobject]@{ Items = @() }
            lxpItems      = [object[]]@()
            driverSet     = [ordered]@{}
            forceUnsigned = $false
            resetBaseOS   = $false
            common        = @{}
            winreWim      = 'winre.wim'
            ExtraIgnored  = 'x'
        }
    }
}

Describe 'Parallel plan: static' {
    It 'Parallel plan file exists' {
        Assert-PlanFilePresent
    }

    It 'Parallel plan file has no forbidden commands (AST purity)' {
        Assert-PlanFilePresent
        if (-not (Get-Module -ListAvailable -Name DISM)) { Set-ItResult -Skipped -Because 'DISM 模組不存在於此環境'; return }
        Import-Module -Name DISM -ErrorAction Stop
        $dismNames = @((Get-Command -Module DISM).Name)
        $dismNames.Count | Should -BeGreaterThan 0
        $forbidden = @($dismNames) + @('Start-Process', 'Mount-WinMediaImage', 'Invoke-WinMediaDism', 'New-Item', 'Remove-Item', 'Copy-Item', 'Move-Item', 'Set-Content', 'Out-File', 'Export-Clixml', 'Use-WinMediaWorkDir', 'Get-WinMediaVolumeFreeSpaceGB', 'Get-Volume', 'Get-PSDrive')
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:planFile, [ref]$null, [ref]$null)
        $cmds = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))
        $names = @($cmds | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
        $hits = @($names | Where-Object { $forbidden -contains $_ })
        $hits.Count | Should -Be 0 -Because ('forbidden commands: ' + ($hits -join ', '))
    }
}

Describe 'Parallel plan: count' {
    It 'Parallel count caps Requested at TargetCount' {
        Assert-PlanFilePresent
        $r = @(Invoke-InModule { param($a, $b) Get-WinMediaParallelCount -Requested $a -TargetCount $b } @(4, 2))
        $r.Count | Should -Be 1
        $r[0] | Should -Be 2
    }
    It 'Parallel count keeps Requested when below TargetCount' {
        Assert-PlanFilePresent
        $r = @(Invoke-InModule { param($a, $b) Get-WinMediaParallelCount -Requested $a -TargetCount $b } @(1, 5))
        $r[0] | Should -Be 1
    }
    It 'Parallel count floors Requested 0 to 1' {
        Assert-PlanFilePresent
        $r = @(Invoke-InModule { param($a, $b) Get-WinMediaParallelCount -Requested $a -TargetCount $b } @(0, 3))
        $r[0] | Should -Be 1
    }
    It 'Parallel count floors TargetCount 0 to 1' {
        Assert-PlanFilePresent
        $r = @(Invoke-InModule { param($a, $b) Get-WinMediaParallelCount -Requested $a -TargetCount $b } @(3, 0))
        $r[0] | Should -Be 1
    }
    It 'Parallel count returns Int32' {
        Assert-PlanFilePresent
        $r = @(Invoke-InModule { param($a, $b) Get-WinMediaParallelCount -Requested $a -TargetCount $b } @(2, 3))
        $r[0] | Should -BeOfType ([int])
    }
}

Describe 'Parallel plan: space' {
    BeforeAll {
        $script:spaceCall = { param($p, $c, $e, $f) Get-WinMediaParallelSpaceWarning -Path $p -Count $c -EstimateGB $e -FreeSpaceGB $f }
    }
    It 'Parallel space groups same root case-insensitively' {
        Assert-PlanFilePresent
        $r = @(Invoke-InModule $script:spaceCall @(@('D:\x', 'd:\y'), 2, 30.0, @{ 'D:\' = 100.0 }))
        $r.Count | Should -Be 1
        $r[0].Root | Should -Be 'D:\'
    }
    It 'Parallel space computes RequiredGB as Count times EstimateGB' {
        Assert-PlanFilePresent
        $r = @(Invoke-InModule $script:spaceCall @(@('D:\x'), 2, 30.0, @{ 'D:\' = 100.0 }))
        $r[0].RequiredGB | Should -Be 60
    }
    It 'Parallel space is Ok when FreeGB equals required' {
        Assert-PlanFilePresent
        $r = @(Invoke-InModule $script:spaceCall @(@('D:\x'), 2, 30.0, @{ 'D:\' = 60.0 }))
        $r[0].Status | Should -Be 'Ok'
        $r[0].FreeGB | Should -Be 60
    }
    It 'Parallel space is Low when FreeGB is below required' {
        Assert-PlanFilePresent
        $r = @(Invoke-InModule $script:spaceCall @(@('D:\x'), 2, 30.0, @{ 'D:\' = 59.9 }))
        $r[0].Status | Should -Be 'Low'
    }
    It 'Parallel space is Ok when FreeGB exceeds required' {
        Assert-PlanFilePresent
        $r = @(Invoke-InModule $script:spaceCall @(@('D:\x'), 2, 30.0, @{ 'D:\' = 100.0 }))
        $r[0].Status | Should -Be 'Ok'
    }
    It 'Parallel space is Unknown when the root key is absent' {
        Assert-PlanFilePresent
        $r = @(Invoke-InModule $script:spaceCall @(@('D:\x'), 2, 30.0, @{ 'E:\' = 100.0 }))
        $r.Count | Should -Be 1
        $r[0].Status | Should -Be 'Unknown'
        $r[0].FreeGB | Should -BeNullOrEmpty
    }
    It 'Parallel space is Unknown when the value is null and entry is kept' {
        Assert-PlanFilePresent
        $r = @(Invoke-InModule $script:spaceCall @(@('D:\x'), 2, 30.0, @{ 'D:\' = $null }))
        $r.Count | Should -Be 1
        $r[0].Status | Should -Be 'Unknown'
        $r[0].FreeGB | Should -BeNullOrEmpty
    }
    It 'Parallel space skips blank paths' {
        Assert-PlanFilePresent
        $r = @(Invoke-InModule $script:spaceCall @(@('', '  '), 2, 30.0, @{ 'D:\' = 100.0 }))
        $r.Count | Should -Be 0
    }
    It 'Parallel space returns one entry per root in first-occurrence order' {
        Assert-PlanFilePresent
        $r = @(Invoke-InModule $script:spaceCall @(@('E:\a', 'D:\b', 'e:\c'), 1, 10.0, @{ 'D:\' = 100.0; 'E:\' = 100.0 }))
        $r.Count | Should -Be 2
        $r[0].Root | Should -Be 'E:\'
        $r[1].Root | Should -Be 'D:\'
    }
}

Describe 'Parallel plan: job' {
    BeforeAll {
        $script:jobCall = { param($b, $t, $r) Get-WinMediaParallelJob -BaseJob $b -Targets $t -ParallelRoot $r }
        $script:pRoot = 'D:\Work\parallel'
    }
    It 'Parallel job returns one entry per target with OriginalIndex' {
        Assert-PlanFilePresent
        $r = @(Invoke-InModule $script:jobCall @((Get-TestBaseJob), @(2, 3), $script:pRoot))
        $r.Count | Should -Be 2
        $r[0].OriginalIndex | Should -Be 2
        $r[1].OriginalIndex | Should -Be 3
        $r[0].IndexDir | Should -Be 'D:\Work\parallel\idx2'
        $r[1].IndexDir | Should -Be 'D:\Work\parallel\idx3'
    }
    It 'Parallel job has exactly the 19 expected keys' {
        Assert-PlanFilePresent
        $r = @(Invoke-InModule $script:jobCall @((Get-TestBaseJob), @(2, 3), $script:pRoot))
        $expected = @($script:SharedKeys + @('ImagePath', 'Index', 'MountPath', 'IsFirstTarget')) | Sort-Object
        $r.Count | Should -Be 2
        foreach ($item in $r) {
            $actual = @($item.Job.Keys | ForEach-Object { [string]$_ } | Sort-Object)
            $actual.Count | Should -Be 19
            ($actual -join ',') | Should -Be ($expected -join ',')
        }
    }
    It 'Parallel job marks IsFirstTarget only on the first job' {
        Assert-PlanFilePresent
        $r = @(Invoke-InModule $script:jobCall @((Get-TestBaseJob), @(3, 2), $script:pRoot))
        $r[0].Job['IsFirstTarget'] | Should -BeTrue
        $r[1].Job['IsFirstTarget'] | Should -BeFalse
    }
    It 'Parallel job sets ImagePath, Index and MountPath' {
        Assert-PlanFilePresent
        $r = @(Invoke-InModule $script:jobCall @((Get-TestBaseJob), @(2, 3), $script:pRoot))
        $r[0].Job['ImagePath'] | Should -Be 'D:\Work\parallel\idx2\install.wim'
        $r[1].Job['ImagePath'] | Should -Be 'D:\Work\parallel\idx3\install.wim'
        $r[0].Job['Index'] | Should -Be 1
        $r[1].Job['Index'] | Should -Be 1
        $r[0].Job['MountPath'] | Should -Be 'D:\Mount\install-2'
        $r[1].Job['MountPath'] | Should -Be 'D:\Mount\install-3'
    }
    It 'Parallel job gives each job its own log paths and leaves parent Config unchanged' {
        Assert-PlanFilePresent
        $base = Get-TestBaseJob
        $r = @(Invoke-InModule $script:jobCall @($base, @(2, 3), $script:pRoot))
        $r[0].Job['Config']['LogDir'] | Should -Be 'D:\Logs\idx2'
        $r[0].Job['Config']['LogFile'] | Should -Be 'D:\Logs\idx2\worker.log'
        $r[1].Job['Config']['LogFile'] | Should -Be 'D:\Logs\idx3\worker.log'
        $r[0].Job['Config']['LogFile'] | Should -Not -Be $r[1].Job['Config']['LogFile']
        $base['Config']['LogDir'] | Should -Be 'D:\Logs'
        $base['Config']['LogFile'] | Should -Be 'D:\Logs\main.log'
    }
    It 'Parallel job clones Config and common instead of sharing the parent objects' {
        Assert-PlanFilePresent
        $base = Get-TestBaseJob
        $r = @(Invoke-InModule $script:jobCall @($base, @(2, 3), $script:pRoot))
        $r.Count | Should -Be 2
        foreach ($item in $r) {
            [object]::ReferenceEquals($item.Job['Config'], $base['Config']) | Should -BeFalse
            [object]::ReferenceEquals($item.Job['common'], $base['common']) | Should -BeFalse
        }
        [object]::ReferenceEquals($r[0].Job['Config'], $r[1].Job['Config']) | Should -BeFalse
        [object]::ReferenceEquals($r[0].Job['common'], $r[1].Job['common']) | Should -BeFalse
        $base['common'].Count | Should -Be 0
    }
    It 'Parallel job keeps an empty OperationLog as is' {
        Assert-PlanFilePresent
        $r = @(Invoke-InModule $script:jobCall @((Get-TestBaseJob -OperationLog ''), @(2), $script:pRoot))
        $r[0].Job['Config']['OperationLog'] | Should -Be ''
    }
    It 'Parallel job keeps a null OperationLog as null' {
        Assert-PlanFilePresent
        $r = @(Invoke-InModule $script:jobCall @((Get-TestBaseJob -OperationLog $null), @(2), $script:pRoot))
        $r[0].Job['Config']['OperationLog'] | Should -BeNullOrEmpty
    }
    It 'Parallel job moves a non-empty OperationLog into the per-index log directory' {
        Assert-PlanFilePresent
        $r = @(Invoke-InModule $script:jobCall @((Get-TestBaseJob), @(2, 3), $script:pRoot))
        $r[0].Job['Config']['OperationLog'] | Should -Be 'D:\Logs\idx2\OperationLog.txt'
        $r[1].Job['Config']['OperationLog'] | Should -Be 'D:\Logs\idx3\OperationLog.txt'
    }
    It 'Parallel job adds no ScratchDirectory when the key is absent' {
        Assert-PlanFilePresent
        $r = @(Invoke-InModule $script:jobCall @((Get-TestBaseJob), @(2), $script:pRoot))
        $r[0].Job['Config'].ContainsKey('ScratchDirectory') | Should -BeFalse
        $r[0].Job['common'].ContainsKey('ScratchDirectory') | Should -BeFalse
    }
    It 'Parallel job adds no ScratchDirectory when the value is blank' {
        Assert-PlanFilePresent
        $r = @(Invoke-InModule $script:jobCall @((Get-TestBaseJob -Scratch ''), @(2), $script:pRoot))
        $r[0].Job['Config']['ScratchDirectory'] | Should -BeNullOrEmpty
        $r[0].Job['common'].ContainsKey('ScratchDirectory') | Should -BeFalse
    }
    It 'Parallel job suffixes ScratchDirectory per index in Config and common' {
        Assert-PlanFilePresent
        $base = Get-TestBaseJob -Scratch 'D:\Scratch'
        $r = @(Invoke-InModule $script:jobCall @($base, @(2, 3), $script:pRoot))
        $r[0].Job['Config']['ScratchDirectory'] | Should -Be 'D:\Scratch\idx2'
        $r[0].Job['common']['ScratchDirectory'] | Should -Be 'D:\Scratch\idx2'
        $r[1].Job['Config']['ScratchDirectory'] | Should -Be 'D:\Scratch\idx3'
        $r[1].Job['common']['ScratchDirectory'] | Should -Be 'D:\Scratch\idx3'
        $base['Config']['ScratchDirectory'] | Should -Be 'D:\Scratch'
        $base['common'].ContainsKey('ScratchDirectory') | Should -BeFalse
    }
    It 'Parallel job throws when a shared key is missing' {
        Assert-PlanFilePresent
        foreach ($key in $script:SharedKeys) {
            $base = Get-TestBaseJob
            $base.Remove($key)
            { Invoke-InModule $script:jobCall @($base, @(2), $script:pRoot) } | Should -Throw -Because "missing key $key"
        }
    }
    It 'Parallel job throws when Targets is empty' {
        Assert-PlanFilePresent
        { Invoke-InModule $script:jobCall @((Get-TestBaseJob), @(), $script:pRoot) } | Should -Throw
    }
}

Describe 'Parallel plan: merge' {
    BeforeAll {
        $script:mergeCall = { param($a, $t) Get-WinMediaParallelMergePlan -AllIndexes $a -Targets $t }
    }
    It 'Parallel merge returns ascending indexes with FromParallel flags' {
        Assert-PlanFilePresent
        $r = @(Invoke-InModule $script:mergeCall @(@(1, 2, 3, 4), @(3, 2)))
        $r.Count | Should -Be 4
        (@($r | ForEach-Object { $_.Index }) -join ',') | Should -Be '1,2,3,4'
        (@($r | Where-Object { $_.FromParallel } | ForEach-Object { $_.Index }) -join ',') | Should -Be '2,3'
    }
    It 'Parallel merge throws when Targets is empty' {
        Assert-PlanFilePresent
        { Invoke-InModule $script:mergeCall @(@(1, 2), @()) } | Should -Throw
    }
    It 'Parallel merge throws when Targets has duplicates' {
        Assert-PlanFilePresent
        { Invoke-InModule $script:mergeCall @(@(1, 2, 3), @(2, 2)) } | Should -Throw
    }
    It 'Parallel merge throws when a Target is not in AllIndexes' {
        Assert-PlanFilePresent
        { Invoke-InModule $script:mergeCall @(@(1, 2, 3), @(2, 9)) } | Should -Throw
    }
}
