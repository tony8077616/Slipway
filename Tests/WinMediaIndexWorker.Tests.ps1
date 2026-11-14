#Requires -Version 5.1

# Step 12b-2 RED：子行程索引 worker（Modules\WinMediaIndexWorker.psm1、Modules\WinMediaIndexWorkerEntry.ps1、Public\Start-WinMediaIndexWorker.ps1）。
# 實作尚未存在時，每個 It 先以「file missing」失敗；此檔不啟動任何子行程，也不執行真正的 DISM／reg／Start-Process。

BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    $script:workerFile = Join-Path -Path $script:root -ChildPath 'Modules\WinMediaIndexWorker.psm1'
    $script:entryFile = Join-Path -Path $script:root -ChildPath 'Modules\WinMediaIndexWorkerEntry.ps1'
    $script:starterFile = Join-Path -Path $script:root -ChildPath 'Public\Start-WinMediaIndexWorker.ps1'
    $script:imageFile = Join-Path -Path $script:root -ChildPath 'Public\Invoke-WinMediaInstallIndexImageUpdate.ps1'
    $script:validationFile = Join-Path -Path $script:root -ChildPath 'Tests\Invoke-Validation.ps1'
    $script:rootManifest = Join-Path -Path $script:root -ChildPath 'WinMediaRefresh.psd1'

    function Get-ScriptAst {
        param([string]$Path)
        [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    }

    # 以 AST 節點型別名稱（CommandAst 等）搜尋，避免到處寫完整命名空間
    function Find-Ast {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Type', Justification = '由 scriptblock 閉包使用，PSSA 無法追蹤')]
        param($Ast, [string]$Type, [scriptblock]$Filter = { $true })
        @($Ast.FindAll({ param($n) $n.GetType().Name -eq $Type }, $true) | Where-Object -FilterScript $Filter)
    }

    function Get-PsModulePathSegment {
        param($Ast)
        $assignment = Find-Ast -Ast $Ast -Type 'AssignmentStatementAst' -Filter { $_.Left.Extent.Text -match 'env:PSModulePath' } | Select-Object -First 1
        if ($null -eq $assignment) { return @() }
        $combine = Find-Ast -Ast $assignment.Right -Type 'InvokeMemberExpressionAst' -Filter { $_.Member.Value -eq 'Combine' }
        @($combine | ForEach-Object {
                $text = ($_.Arguments | ForEach-Object { $_.Extent.Text }) -join ','
                $text = ($text -replace '\s', '') -replace '"', "'"
                $text -replace [regex]::Escape('$docs'), "[Environment]::GetFolderPath('MyDocuments')"
            })
    }

    function Get-TestJob {
        param([bool]$IsFirstTarget = $true, [switch]$Minimal)
        $config = @{
            DismProvider = 'Inbox'
            DismLogLevel = 'WarningsInfo'
            WorkDir      = Join-Path -Path $TestDrive -ChildPath 'work'
            DebugTrace   = 0
            OperationLog = ''
            LogLevel     = 'Info'
            LogFile      = (Join-Path -Path $TestDrive -ChildPath 'worker.log')
        }
        if (-not $Minimal) { $config.OptimizationTarget = '' }
        # 不用 if 表達式：空陣列經過管線會被展開成 $null
        $lxpItems = $null
        if (-not $Minimal) { $lxpItems = [object[]]@() }
        @{
            ImagePath     = Join-Path -Path $TestDrive -ChildPath 'install.wim'
            Index         = 3
            MountPath     = Join-Path -Path $TestDrive -ChildPath 'mnt'
            mountSwitches = @{ CheckIntegrity = $true }
            ssu           = Join-Path -Path $TestDrive -ChildPath 'ssu.cab'
            lcuStage      = Join-Path -Path $TestDrive -ChildPath 'lcu'
            langFod       = [pscustomobject]@{ LangPacks = @(); Fod = @(); Deferred = @() }
            dotNet        = Join-Path -Path $TestDrive -ChildPath 'dotnet.msu'
            enablement    = @()
            appxList      = $null
            storeSet      = [pscustomobject]@{ Frameworks = @(); Apps = @(); Hashes = @{} }
            lxpItems      = $lxpItems
            driverSet     = [ordered]@{ ALL = @{ Path = (Join-Path -Path $TestDrive -ChildPath 'drv'); InfCount = 1; Targets = @('Install') } }
            forceUnsigned = $false
            resetBaseOS   = $false
            common        = @{ ScratchDirectory = Join-Path -Path $TestDrive -ChildPath 'scratch' }
            IsFirstTarget = $IsFirstTarget
            winreWim      = Join-Path -Path $TestDrive -ChildPath 'winre.wim'
            Config        = $config
        }
    }

    function Invoke-TestWorker {
        param([hashtable]$Job)
        # 只允許 result 寫在 TestDrive 底下（Export-Clixml 不做路徑檢查）
        if (-not $script:resultPath.StartsWith($TestDrive, [StringComparison]::OrdinalIgnoreCase)) {
            throw "tripwire: result path outside TestDrive: $($script:resultPath)"
        }
        Invoke-WinMediaIndexWorkerJob -Job $Job -ResultPath $script:resultPath
    }

    # root module 只在檔案存在時載入（Mock -ModuleName WinMediaRefresh 需要它）
    if (Test-Path -LiteralPath $script:rootManifest -PathType Leaf) {
        Import-Module -Name $script:rootManifest -Force
    }
}

Describe 'Parallel index worker：靜態結構（AST）' -Tag 'Unit' {
    It 'Parallel: Modules\WinMediaIndexWorker.psm1 存在' {
        (Test-Path -LiteralPath $script:workerFile -PathType Leaf) | Should -BeTrue -Because 'file missing: WinMediaIndexWorker.psm1'
    }

    It 'Parallel: Modules\WinMediaIndexWorkerEntry.ps1 存在' {
        (Test-Path -LiteralPath $script:entryFile -PathType Leaf) | Should -BeTrue -Because 'file missing: WinMediaIndexWorkerEntry.ps1'
    }

    It 'Parallel: Public\Start-WinMediaIndexWorker.ps1 存在' {
        (Test-Path -LiteralPath $script:starterFile -PathType Leaf) | Should -BeTrue -Because 'file missing: Start-WinMediaIndexWorker.ps1'
    }

    It 'Parallel: worker 的 import 清單剛好 12 個模組，且不含 BootFiles／Defender／Path／WinMediaRefresh' {
        (Test-Path -LiteralPath $script:workerFile -PathType Leaf) | Should -BeTrue -Because 'file missing: WinMediaIndexWorker.psm1'
        $ast = Get-ScriptAst -Path $script:workerFile
        $imports = Find-Ast -Ast $ast -Type 'CommandAst' -Filter { $_.GetCommandName() -eq 'Import-Module' }
        $imports.Count | Should -Be 12
        $text = ($imports | ForEach-Object { $_.Extent.Text }) -join "`n"
        foreach ($forbidden in 'WinMediaBootFiles', 'WinMediaDefender', 'WinMediaPath', 'WinMediaRefresh') {
            $text | Should -Not -Match $forbidden -Because "worker must not import $forbidden"
        }
        foreach ($expected in 'WinMediaLog.psm1', 'WinMediaOperation.psm1', 'WinMediaDism.psm1', 'WinMediaOptimize.psm1', 'WinMediaImage.psm1', 'WinMediaLangFod.psm1', 'WinMediaDriver.psm1', 'WinMediaLxp.psm1', 'WinMediaStoreApps.psm1', 'WinMediaAppx.psm1', 'WinMediaIndexInfo.psm1', 'WinMediaPackage.psm1') {
            $text | Should -Match ([regex]::Escape($expected)) -Because "worker must import $expected"
        }
    }

    It 'Parallel: entry 只有一個 Import-Module，且指向 WinMediaIndexWorker.psm1' {
        (Test-Path -LiteralPath $script:entryFile -PathType Leaf) | Should -BeTrue -Because 'file missing: WinMediaIndexWorkerEntry.ps1'
        $ast = Get-ScriptAst -Path $script:entryFile
        $imports = Find-Ast -Ast $ast -Type 'CommandAst' -Filter { $_.GetCommandName() -eq 'Import-Module' }
        $imports.Count | Should -Be 1
        $imports[0].Extent.Text | Should -Match ([regex]::Escape('WinMediaIndexWorker.psm1'))
    }

    It 'Parallel: entry 的 PSModulePath 四段與 Tests\Invoke-Validation.ps1 第 12-17 行相同且順序一致' {
        (Test-Path -LiteralPath $script:entryFile -PathType Leaf) | Should -BeTrue -Because 'file missing: WinMediaIndexWorkerEntry.ps1'
        $expected = @(Get-PsModulePathSegment -Ast (Get-ScriptAst -Path $script:validationFile))
        $expected.Count | Should -Be 4
        $entryAst = Get-ScriptAst -Path $script:entryFile
        $actual = @(Get-PsModulePathSegment -Ast $entryAst)
        $actual -join "`n" | Should -Be ($expected -join "`n")
        $entryAst.Extent.Text | Should -Match 'PSEdition' -Because 'PSModulePath reset applies to Windows PowerShell 5.1 only'
    }

    It 'Parallel: worker 與 entry 都沒有 Start-Process 命令' {
        (Test-Path -LiteralPath $script:workerFile -PathType Leaf) | Should -BeTrue -Because 'file missing: WinMediaIndexWorker.psm1'
        (Test-Path -LiteralPath $script:entryFile -PathType Leaf) | Should -BeTrue -Because 'file missing: WinMediaIndexWorkerEntry.ps1'
        foreach ($file in $script:workerFile, $script:entryFile) {
            $hits = Find-Ast -Ast (Get-ScriptAst -Path $file) -Type 'CommandAst' -Filter { $_.GetCommandName() -eq 'Start-Process' }
            $hits.Count | Should -Be 0 -Because "no Start-Process in $file"
        }
    }

    It 'Parallel: worker／entry／starter 使用的內建 cmdlet 參數都存在於本機 Get-Command（抓 Import-Clixml -Depth）' {
        (Test-Path -LiteralPath $script:workerFile -PathType Leaf) | Should -BeTrue -Because 'file missing: WinMediaIndexWorker.psm1'
        (Test-Path -LiteralPath $script:entryFile -PathType Leaf) | Should -BeTrue -Because 'file missing: WinMediaIndexWorkerEntry.ps1'
        (Test-Path -LiteralPath $script:starterFile -PathType Leaf) | Should -BeTrue -Because 'file missing: Start-WinMediaIndexWorker.ps1'
        $builtin = 'Import-Clixml', 'Export-Clixml', 'Import-Module', 'Start-Process', 'Join-Path', 'Split-Path', 'Test-Path', 'New-Item', 'Write-Error', 'Out-String', 'Remove-Item'
        $bad = foreach ($file in $script:workerFile, $script:entryFile, $script:starterFile) {
            foreach ($cmdAst in Find-Ast -Ast (Get-ScriptAst -Path $file) -Type 'CommandAst' -Filter { $_.GetCommandName() -in $builtin }) {
                $name = $cmdAst.GetCommandName()
                $known = (Get-Command -Name $name).Parameters
                $aliases = @($known.Values | ForEach-Object { $_.Aliases })
                foreach ($param in $cmdAst.CommandElements | Where-Object { $_.GetType().Name -eq 'CommandParameterAst' }) {
                    $pn = $param.ParameterName
                    $ok = $known.ContainsKey($pn) -or ($pn -in $aliases) -or (@($known.Keys | Where-Object { $_ -like "$pn*" }).Count -gt 0)
                    if (-not $ok) { '{0} -{1} ({2})' -f $name, $pn, (Split-Path -Leaf $file) }
                }
            }
        }
        @($bad) | Should -BeNullOrEmpty -Because 'unknown parameters on built-in cmdlets'
    }

    It 'Parallel: worker、entry 與映像函式不呼叫 BootFiles、Defender、Invoke-WindowsMediaRefresh 或清空 WorkDir 的函式（AST）' {
        (Test-Path -LiteralPath $script:workerFile -PathType Leaf) | Should -BeTrue -Because 'file missing: WinMediaIndexWorker.psm1'
        (Test-Path -LiteralPath $script:entryFile -PathType Leaf) | Should -BeTrue -Because 'file missing: WinMediaIndexWorkerEntry.ps1'
        $exports = @{}
        foreach ($m in 'WinMediaBootFiles', 'WinMediaDefender') {
            $em = Find-Ast -Ast (Get-ScriptAst -Path (Join-Path -Path $script:root -ChildPath "Modules\$m.psm1")) -Type 'CommandAst' -Filter { $_.GetCommandName() -eq 'Export-ModuleMember' }
            $exports[$m] = @($em | ForEach-Object { Find-Ast -Ast $_ -Type 'StringConstantExpressionAst' -Filter { $_.Value -like '*-WinMedia*' } } | ForEach-Object { $_.Value })
        }
        $exports['WinMediaBootFiles'].Count | Should -BeGreaterThan 5
        $exports['WinMediaDefender'].Count | Should -BeGreaterThan 0
        $forbidden = @($exports.Values | ForEach-Object { $_ }) + 'Invoke-WindowsMediaRefresh', 'Remove-WinMediaCleanupDir', 'Remove-WinMediaWorkDir', 'Use-WinMediaWorkDir', 'Initialize-WinMediaWorkRoot'
        $hits = foreach ($f in $script:workerFile, $script:entryFile, $script:imageFile) {
            Find-Ast -Ast (Get-ScriptAst -Path $f) -Type 'CommandAst' -Filter { $_.GetCommandName() -in $forbidden } | ForEach-Object { '{0}:{1}' -f (Split-Path -Leaf $f), $_.GetCommandName() }
        }
        @($hits) | Should -BeNullOrEmpty
    }

    It 'Parallel: worker 與 entry 都不指派 $global:WinMediaDismCompatSource' {
        (Test-Path -LiteralPath $script:workerFile -PathType Leaf) | Should -BeTrue -Because 'file missing: WinMediaIndexWorker.psm1'
        (Test-Path -LiteralPath $script:entryFile -PathType Leaf) | Should -BeTrue -Because 'file missing: WinMediaIndexWorkerEntry.ps1'
        foreach ($file in $script:workerFile, $script:entryFile) {
            $hits = Find-Ast -Ast (Get-ScriptAst -Path $file) -Type 'AssignmentStatementAst' -Filter { $_.Left.Extent.Text -match 'WinMediaDismCompatSource' }
            $hits.Count | Should -Be 0 -Because "compat state is initialised by the module on import ($file)"
        }
    }
}

Describe 'Parallel index worker：Invoke-WinMediaIndexWorkerJob 行為（全部 mock，無真實 DISM）' -Tag 'Unit' {
    BeforeAll {
        if (Test-Path -LiteralPath $script:workerFile -PathType Leaf) {
            Import-Module -Name $script:workerFile -Force

            # mock 本體的參數值一律從 $PesterBoundParameters 取
            Mock -ModuleName WinMediaIndexWorker Invoke-WinMediaDism { & $PesterBoundParameters['ScriptBlock'] }
            Mock -ModuleName WinMediaIndexWorker Mount-WinMediaImage {
                $script:resultSeenInAction = Test-Path -LiteralPath $script:resultPath
                & $PesterBoundParameters['Action'] (Join-Path -Path $TestDrive -ChildPath 'mnt')
            }
            Mock -ModuleName WinMediaIndexWorker Add-WindowsPackage { }
            Mock -ModuleName WinMediaIndexWorker Repair-WindowsImage { }
            Mock -ModuleName WinMediaIndexWorker Add-WindowsDriver { throw 'tripwire: Add-WindowsDriver must not run' }
            Mock -ModuleName WinMediaIndexWorker Invoke-WinMediaOperation { }
            Mock -ModuleName WinMediaIndexWorker Install-WinMediaLangFod { }
            Mock -ModuleName WinMediaIndexWorker Install-WinMediaDeferredFod { }
            Mock -ModuleName WinMediaIndexWorker Optimize-WinMediaImage { }
            Mock -ModuleName WinMediaIndexWorker Install-WinMediaDriver { $script:capturedDriverKeys = @($PesterBoundParameters['DriverSet'].Keys) }
            Mock -ModuleName WinMediaIndexWorker Install-WinMediaStoreApp { }
            Mock -ModuleName WinMediaIndexWorker Install-WinMediaLxp { }
            Mock -ModuleName WinMediaIndexWorker Remove-WinMediaAppx { }
            Mock -ModuleName WinMediaIndexWorker Test-WinMediaEnablementApplicable { $false }
            Mock -ModuleName WinMediaIndexWorker Get-WinMediaBuildInfo { @{ Build = '26100.1' } }
            Mock -ModuleName WinMediaIndexWorker Get-Item { [pscustomobject]@{ VersionInfo = [pscustomobject]@{ FileVersion = '10.0.26100.1' } } }
            # 其餘會改檔案的內建 cmdlet：路徑不在 TestDrive 下就中止
            Mock -ModuleName WinMediaIndexWorker New-Item {
                if (-not ([string]$PesterBoundParameters['Path']).StartsWith($TestDrive, [StringComparison]::OrdinalIgnoreCase)) { throw "tripwire: New-Item outside TestDrive: $($PesterBoundParameters['Path'])" }
            }
            Mock -ModuleName WinMediaIndexWorker Copy-Item {
                if (-not ([string]$PesterBoundParameters['Destination']).StartsWith($TestDrive, [StringComparison]::OrdinalIgnoreCase)) { throw "tripwire: Copy-Item outside TestDrive: $($PesterBoundParameters['Destination'])" }
            }

            # SAFETY GATE：worker 與映像函式用到的 DISM／Slipway／Keel 命令，在 worker 模組範圍內都必須已被 mock 成 Alias
            if ($null -eq (Get-Module -Name WinMediaRefresh)) { throw 'safety gate: WinMediaRefresh root module is not loaded' }
            $imageAst = Get-ScriptAst -Path $script:imageFile
            $workerAst = Get-ScriptAst -Path $script:workerFile
            $exclude = @('Write-WinMediaLog')
            foreach ($parsed in $workerAst, $imageAst) {
                $exclude += @(Find-Ast -Ast $parsed -Type 'FunctionDefinitionAst' | ForEach-Object { $_.Name })
            }
            $builtinSet = 'Join-Path', 'Export-Clixml', 'Import-Clixml', 'New-Item', 'Test-Path', 'Copy-Item', 'Get-Item', 'Split-Path'
            $names = @(
                @(Find-Ast -Ast $workerAst -Type 'CommandAst') + @(Find-Ast -Ast $imageAst -Type 'CommandAst') |
                    ForEach-Object { $_.GetCommandName() } |
                    Where-Object { $_ -and $_ -notin $exclude -and $_ -notin $builtinSet } |
                    Sort-Object -Unique
            )
            $offenders = foreach ($n in $names) {
                $rootCmd = & (Get-Module -Name WinMediaRefresh) { param($c) Get-Command -Name $c -ErrorAction SilentlyContinue | Select-Object -First 1 } $n
                if ($null -ne $rootCmd -and $rootCmd.CommandType -ne 'Function' -and $rootCmd.Source -ne 'Dism') { continue }
                $inWorker = & (Get-Module -Name WinMediaIndexWorker) { param($c) Get-Command -Name $c -ErrorAction SilentlyContinue | Select-Object -First 1 } $n
                if ("$($inWorker.CommandType)" -ne 'Alias') { '{0}={1}' -f $n, $inWorker.CommandType }
            }
            if (@($offenders).Count -gt 0) {
                throw ('safety gate: commands not mocked in WinMediaIndexWorker scope: ' + (@($offenders) -join ', '))
            }
        }
    }

    BeforeEach {
        $script:resultSeenInAction = $null
        $script:capturedDriverKeys = $null
        $script:resultPath = Join-Path -Path $TestDrive -ChildPath ('out-{0}\result.clixml' -f [guid]::NewGuid().ToString('N'))
        $null = [System.IO.Directory]::CreateDirectory((Split-Path -Parent $script:resultPath))
    }

    It 'Parallel: worker 模組只匯出 Invoke-WinMediaIndexWorkerJob' {
        (Test-Path -LiteralPath $script:workerFile -PathType Leaf) | Should -BeTrue -Because 'file missing: WinMediaIndexWorker.psm1'
        $exported = @((Get-Module -Name WinMediaIndexWorker).ExportedCommands.Keys)
        $exported.Count | Should -Be 1
        $exported[0] | Should -Be 'Invoke-WinMediaIndexWorkerJob'
    }

    It 'Parallel: 單一索引（含 dotNet）時 DISM 包裝 4 次、Add-WindowsPackage 3 次、Repair-WindowsImage 1 次' {
        (Test-Path -LiteralPath $script:workerFile -PathType Leaf) | Should -BeTrue -Because 'file missing: WinMediaIndexWorker.psm1'
        Invoke-TestWorker -Job (Get-TestJob)
        Should -Invoke -CommandName Invoke-WinMediaDism -ModuleName WinMediaIndexWorker -Times 4 -Exactly
        Should -Invoke -CommandName Add-WindowsPackage -ModuleName WinMediaIndexWorker -Times 3 -Exactly
        Should -Invoke -CommandName Repair-WindowsImage -ModuleName WinMediaIndexWorker -Times 1 -Exactly
        Should -Invoke -CommandName Mount-WinMediaImage -ModuleName WinMediaIndexWorker -Times 1 -Exactly
    }

    It 'Parallel: driverSet 經 Clixml 往返後仍以 ALL、WinPE、OS 的固定順序交給映像函式' {
        (Test-Path -LiteralPath $script:workerFile -PathType Leaf) | Should -BeTrue -Because 'file missing: WinMediaIndexWorker.psm1'
        $job = Get-TestJob
        $job.driverSet = [ordered]@{
            OS    = @{ Path = (Join-Path -Path $TestDrive -ChildPath 'drv-os'); InfCount = 1; Targets = @('Install') }
            WinPE = @{ Path = (Join-Path -Path $TestDrive -ChildPath 'drv-pe'); InfCount = 2; Targets = @('WinPE') }
            ALL   = @{ Path = (Join-Path -Path $TestDrive -ChildPath 'drv-all'); InfCount = 3; Targets = @('Install', 'WinPE') }
        }
        $jobFile = Join-Path -Path $TestDrive -ChildPath 'driver-job.clixml'
        Export-Clixml -InputObject $job -LiteralPath $jobFile -Depth 10
        $roundTripped = Import-Clixml -LiteralPath $jobFile
        Invoke-TestWorker -Job $roundTripped
        ($script:capturedDriverKeys -join ',') | Should -Be 'ALL,WinPE,OS'
    }

    It 'Parallel: result.clixml 只在 dismount 之後寫入，內容含 Index、KernelVersion、BuildInfo' {
        (Test-Path -LiteralPath $script:workerFile -PathType Leaf) | Should -BeTrue -Because 'file missing: WinMediaIndexWorker.psm1'
        Invoke-TestWorker -Job (Get-TestJob)
        ($null -ne $script:resultSeenInAction) | Should -BeTrue -Because 'the Mount mock must record whether the result existed'; $script:resultSeenInAction | Should -BeFalse -Because 'result file must not exist while the image is still mounted'
        (Test-Path -LiteralPath $script:resultPath -PathType Leaf) | Should -BeTrue
        $result = Import-Clixml -LiteralPath $script:resultPath
        $result.Index | Should -Be 3
        $result.KernelVersion | Should -Be '10.0.26100.1'
        $result.BuildInfo.Build | Should -Be '26100.1'
    }

    It 'Parallel: 非第一個目標（IsFirstTarget false）時 KernelVersion 與 BuildInfo 為 null' {
        (Test-Path -LiteralPath $script:workerFile -PathType Leaf) | Should -BeTrue -Because 'file missing: WinMediaIndexWorker.psm1'
        Invoke-TestWorker -Job (Get-TestJob -IsFirstTarget $false)
        $result = Import-Clixml -LiteralPath $script:resultPath
        $result.Index | Should -Be 3
        $result.KernelVersion | Should -BeNullOrEmpty
        $result.BuildInfo | Should -BeNullOrEmpty
    }

    It 'Parallel: Mount-WinMediaImage 失敗時 worker 例外外拋且不產生 result.clixml' {
        (Test-Path -LiteralPath $script:workerFile -PathType Leaf) | Should -BeTrue -Because 'file missing: WinMediaIndexWorker.psm1'
        Mock -ModuleName WinMediaIndexWorker Mount-WinMediaImage { throw 'mount failed' }
        { Invoke-TestWorker -Job (Get-TestJob) } | Should -Throw
        (Test-Path -LiteralPath $script:resultPath) | Should -BeFalse
    }

    It 'Parallel: StrictMode 下 lxpItems 為 null 且 Config 沒有 OptimizationTarget 時不拋 PropertyNotFound／Count 錯誤' {
        (Test-Path -LiteralPath $script:workerFile -PathType Leaf) | Should -BeTrue -Because 'file missing: WinMediaIndexWorker.psm1'
        { Invoke-TestWorker -Job (Get-TestJob -Minimal) } | Should -Not -Throw
        (Test-Path -LiteralPath $script:resultPath -PathType Leaf) | Should -BeTrue
    }
}

Describe 'Parallel index worker：root module 範圍解析' -Tag 'Unit' {
    BeforeAll {
        if ((Test-Path -LiteralPath $script:workerFile -PathType Leaf) -and (Test-Path -LiteralPath $script:rootManifest -PathType Leaf)) {
            Import-Module -Name $script:rootManifest -Force
            Import-Module -Name $script:workerFile -Force
        }
    }

    It 'Parallel: 匯入 worker 後 WinMediaRefresh 範圍仍解析得到 Write-WinMediaLog、Invoke-WinMediaDism、Invoke-WinMediaOperation' {
        (Test-Path -LiteralPath $script:workerFile -PathType Leaf) | Should -BeTrue -Because 'file missing: WinMediaIndexWorker.psm1'
        $found = @(& (Get-Module -Name WinMediaRefresh) { Get-Command Write-WinMediaLog, Invoke-WinMediaDism, Invoke-WinMediaOperation -ErrorAction Stop })
        $found.Count | Should -Be 3
    }
}

Describe 'Parallel index worker：Start-WinMediaIndexWorker（Start-Process 已 mock）' -Tag 'Unit' {
    BeforeAll {
        if (Test-Path -LiteralPath $script:starterFile -PathType Leaf) {
            Mock -ModuleName WinMediaRefresh Start-Process {
                $script:startFile = $PesterBoundParameters['FilePath']
                $script:startArgs = $PesterBoundParameters['ArgumentList']
                [pscustomobject]@{ Id = 1 }
            }
        }
    }

    BeforeEach {
        $script:startFile = $null
        $script:startArgs = $null
    }

    It 'Parallel: 子程序的 ScratchDirectory（scratch\idxN）在啟動前由啟動器建立' {
        (Test-Path -LiteralPath $script:starterFile -PathType Leaf) | Should -BeTrue -Because 'file missing: Start-WinMediaIndexWorker.ps1'
        (& (Get-Module -Name WinMediaRefresh) { "$((Get-Command -Name Start-Process).CommandType)" }) | Should -Be 'Alias' -Because 'Start-Process must be mocked before the starter runs'
        $dir = Join-Path -Path $TestDrive -ChildPath 'index-scratch'
        $scratch = Join-Path -Path $TestDrive -ChildPath 'scratch\idx2'
        $job = @{ ImagePath = 'X:\work\install.wim'; Index = 1; Config = @{ ScratchDirectory = $scratch } }
        & (Get-Module -Name WinMediaRefresh) { param($j, $d) Start-WinMediaIndexWorker -Job $j -IndexDir $d | Out-Null } $job $dir
        (Test-Path -LiteralPath $scratch -PathType Container) | Should -BeTrue -Because 'DISM needs the child scratch directory to exist before the worker mounts'
    }

    It 'Parallel: 啟動器寫出 job.clixml，並以完整 powershell.exe 路徑只呼叫 Start-Process 一次' {
        (Test-Path -LiteralPath $script:starterFile -PathType Leaf) | Should -BeTrue -Because 'file missing: Start-WinMediaIndexWorker.ps1'
        (& (Get-Module -Name WinMediaRefresh) { "$((Get-Command -Name Start-Process).CommandType)" }) | Should -Be 'Alias' -Because 'Start-Process must be mocked before the starter runs'
        $dir = Join-Path -Path $TestDrive -ChildPath 'index-plain'
        $job = @{ ImagePath = 'X:\work\install.wim'; Index = 2 }
        & (Get-Module -Name WinMediaRefresh) { param($j, $d) Start-WinMediaIndexWorker -Job $j -IndexDir $d | Out-Null } $job $dir

        $jobFile = Join-Path -Path $dir -ChildPath 'job.clixml'
        (Test-Path -LiteralPath $jobFile -PathType Leaf) | Should -BeTrue
        (Import-Clixml -LiteralPath $jobFile).ImagePath | Should -Be 'X:\work\install.wim'
        Should -Invoke -CommandName Start-Process -ModuleName WinMediaRefresh -Times 1 -Exactly -ParameterFilter { $PassThru }
        $script:startFile | Should -Be "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $script:startArgs | Should -Contain '-NoProfile'
        $script:startArgs | Should -Contain '-NonInteractive'
        $script:startArgs | Should -Contain '-ExecutionPolicy'
        $script:startArgs | Should -Contain 'Bypass'
        $script:startArgs | Should -Contain '-File'
    }

    It 'Parallel: 路徑含空白時 job 路徑參數以雙引號包住，且參數列沒有 -NoExit' {
        (Test-Path -LiteralPath $script:starterFile -PathType Leaf) | Should -BeTrue -Because 'file missing: Start-WinMediaIndexWorker.ps1'
        (& (Get-Module -Name WinMediaRefresh) { "$((Get-Command -Name Start-Process).CommandType)" }) | Should -Be 'Alias' -Because 'Start-Process must be mocked before the starter runs'
        $dir = Join-Path -Path $TestDrive -ChildPath 'index dir with space'
        $job = @{ ImagePath = 'X:\work\install.wim'; Index = 2 }
        & (Get-Module -Name WinMediaRefresh) { param($j, $d) Start-WinMediaIndexWorker -Job $j -IndexDir $d | Out-Null } $job $dir

        $jobArg = @(@($script:startArgs) | Where-Object { $_ -like '*job.clixml*' })
        $jobArg.Count | Should -Be 1
        $jobArg[0] | Should -Match '^".*job\.clixml"$'
        (@($script:startArgs) -join ' ') | Should -Not -Match '-NoExit'
        $argv = @($script:startArgs)
        $fileIndex = [array]::IndexOf($argv, '-File')
        $fileIndex | Should -BeGreaterThan -1
        $fileIndex | Should -Be ($argv.Count - 3) -Because 'only the entry path and the job path may follow -File'
        (Test-Path -LiteralPath $argv[$fileIndex + 1].Trim('"') -PathType Leaf) | Should -BeTrue -Because 'the -File argument must be the existing entry script'
    }
}
