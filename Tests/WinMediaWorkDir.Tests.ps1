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
        foreach ($name in 'Resolve-WinMediaLogFile', 'Assert-WinMediaOutputDir', 'Use-WinMediaWorkDir', 'Remove-WinMediaCleanupDir') { $names | Should -Contain $name }
        $direct = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Remove-Item' -and $n.Extent.Text -match '\$dir\b' }, $true))
        $direct.Count | Should -Be 0
    }

    It 'OutputDir 在 Assert 之前以 PowerShell 位置正規化（相對路徑不依行程目錄解析）' {
        $mainPath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Public\Invoke-WindowsMediaRefresh.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($mainPath, [ref]$null, [ref]$null)
        $norm = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$Config.OutputDir' -and $n.Right.Extent.Text -match 'GetUnresolvedProviderPathFromPSPath' }, $true))
        $assert = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Assert-WinMediaOutputDir' }, $true))
        $norm.Count | Should -BeGreaterThan 0
        $norm[0].Extent.StartOffset | Should -BeLessThan $assert[0].Extent.StartOffset
    }
}

Describe 'Resolve-WinMediaLogLocation（OperationLog／LogDir 缺鍵時由 WorkDir 推導，StrictMode 下不拋錯）' -Tag 'Unit' {
    It '設定只有 WorkDir 時，LogDir 為 WorkDir\logs，OperationLog 為 LogDir\OperationLog.txt' {
        $work = Join-Path -Path $TestDrive -ChildPath 'work-loc'
        $loc = Resolve-WinMediaLogLocation -Config @{ WorkDir = $work }
        $loc.LogDir | Should -BeExactly (Join-Path -Path $work -ChildPath 'logs')
        $loc.OperationLog | Should -BeExactly (Join-Path -Path $work -ChildPath 'logs\OperationLog.txt')
    }

    It 'OperationLog 為空字串時原樣保留（空白代表不寫操作紀錄）' {
        $loc = Resolve-WinMediaLogLocation -Config @{ WorkDir = (Join-Path -Path $TestDrive -ChildPath 'w2'); LogDir = (Join-Path -Path $TestDrive -ChildPath 'l2'); OperationLog = '' }
        $loc.OperationLog | Should -BeExactly ''
    }

    It '明確指定的 LogDir 原樣保留，OperationLog 缺鍵時由它推導' {
        $logDir = Join-Path -Path $TestDrive -ChildPath 'explicit-logs'
        $loc = Resolve-WinMediaLogLocation -Config @{ WorkDir = $TestDrive; LogDir = $logDir }
        $loc.LogDir | Should -BeExactly $logDir
        $loc.OperationLog | Should -BeExactly (Join-Path -Path $logDir -ChildPath 'OperationLog.txt')
    }

    It '主流程在第一個 Invoke-WinMediaOperation 之前呼叫 Resolve-WinMediaLogLocation（AST）' {
        $mainPath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Public\Invoke-WindowsMediaRefresh.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($mainPath, [ref]$null, [ref]$null)
        $loc = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Resolve-WinMediaLogLocation' }, $true))
        $op = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-WinMediaOperation' }, $true))
        $loc.Count | Should -BeGreaterThan 0
        $loc[0].Extent.StartOffset | Should -BeLessThan $op[0].Extent.StartOffset
    }
}

Describe 'Use-WinMediaWorkDir／Remove-WinMediaWorkDir 拒絕 reparse point（審查第 8 則）' -Tag 'Unit' {
    It '登記過的目錄本身是 junction 時拒絕清空，哨兵檔仍在' {
        $sentinelDir = Join-Path -Path $TestDrive -ChildPath 'sentinel-a'
        New-Item -ItemType Directory -Path $sentinelDir -Force | Out-Null
        $sentinelFile = Join-Path -Path $sentinelDir -ChildPath 'keep.txt'
        Set-Content -LiteralPath $sentinelFile -Value 'keep'
        [System.IO.Path]::GetFullPath($sentinelDir).StartsWith([System.IO.Path]::GetFullPath($TestDrive), [System.StringComparison]::OrdinalIgnoreCase) | Should -BeTrue
        $link = Join-Path -Path $TestDrive -ChildPath 'media-link'
        New-Item -ItemType Junction -Path $link -Target $sentinelDir | Out-Null
        Set-Content -LiteralPath "$link.winmedia-owned" -Value 'WinMediaRefresh'
        try {
            { Use-WinMediaWorkDir -Path $link } | Should -Throw -ExpectedMessage '*reparse point*'
            Test-Path -LiteralPath $sentinelFile | Should -BeTrue
        }
        finally { [System.IO.Directory]::Delete($link) }
    }

    It '登記過的目錄內含 junction 子項目時拒絕清空，哨兵檔與其他子項目都保留' {
        $sentinelDir = Join-Path -Path $TestDrive -ChildPath 'sentinel-b'
        New-Item -ItemType Directory -Path $sentinelDir -Force | Out-Null
        $sentinelFile = Join-Path -Path $sentinelDir -ChildPath 'keep.txt'
        Set-Content -LiteralPath $sentinelFile -Value 'keep'
        [System.IO.Path]::GetFullPath($sentinelDir).StartsWith([System.IO.Path]::GetFullPath($TestDrive), [System.StringComparison]::OrdinalIgnoreCase) | Should -BeTrue
        $dir = Join-Path -Path $TestDrive -ChildPath 'media-child'
        Use-WinMediaWorkDir -Path $dir
        $other = Join-Path -Path $dir -ChildPath 'other.txt'
        Set-Content -LiteralPath $other -Value 'x'
        $link = Join-Path -Path $dir -ChildPath 'evil'
        New-Item -ItemType Junction -Path $link -Target $sentinelDir | Out-Null
        try {
            { Use-WinMediaWorkDir -Path $dir } | Should -Throw -ExpectedMessage '*reparse point*'
            Test-Path -LiteralPath $sentinelFile | Should -BeTrue
            Test-Path -LiteralPath $other | Should -BeTrue
        }
        finally { [System.IO.Directory]::Delete($link) }
    }

    It 'Remove-WinMediaWorkDir 遇到 junction 子項目同樣拒絕，哨兵檔仍在' {
        $sentinelDir = Join-Path -Path $TestDrive -ChildPath 'sentinel-c'
        New-Item -ItemType Directory -Path $sentinelDir -Force | Out-Null
        $sentinelFile = Join-Path -Path $sentinelDir -ChildPath 'keep.txt'
        Set-Content -LiteralPath $sentinelFile -Value 'keep'
        [System.IO.Path]::GetFullPath($sentinelDir).StartsWith([System.IO.Path]::GetFullPath($TestDrive), [System.StringComparison]::OrdinalIgnoreCase) | Should -BeTrue
        $dir = Join-Path -Path $TestDrive -ChildPath 'media-remove'
        Use-WinMediaWorkDir -Path $dir
        $link = Join-Path -Path $dir -ChildPath 'evil'
        New-Item -ItemType Junction -Path $link -Target $sentinelDir | Out-Null
        try {
            { Remove-WinMediaWorkDir -Path $dir -Confirm:$false } | Should -Throw -ExpectedMessage '*reparse point*'
            Test-Path -LiteralPath $sentinelFile | Should -BeTrue
        }
        finally { [System.IO.Directory]::Delete($link) }
    }
}

Describe 'WorkDir ACL 與擁有者檢查（審查第 8 則）' -Tag 'Unit' {
    It 'Get-WinMediaWorkDirSecurity 是純函式：關閉繼承，只有 SYSTEM 與 Administrators 完全控制' {
        $sec = Get-WinMediaWorkDirSecurity
        $sec | Should -BeOfType ([System.Security.AccessControl.DirectorySecurity])
        $sec.AreAccessRulesProtected | Should -BeTrue
        $rules = @($sec.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]))
        $rules.Count | Should -Be 2
        @($rules | ForEach-Object { $_.IdentityReference.Value } | Sort-Object) | Should -Be @('S-1-5-18', 'S-1-5-32-544')
        foreach ($rule in $rules) {
            $rule.FileSystemRights | Should -Be ([System.Security.AccessControl.FileSystemRights]::FullControl)
            $rule.AccessControlType | Should -Be ([System.Security.AccessControl.AccessControlType]::Allow)
            $rule.InheritanceFlags | Should -Be ([System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit')
        }
    }

    It '不存在時建立目錄，並只透過 Set-WinMediaWorkDirAcl 套用關閉繼承的 ACL' {
        Mock -ModuleName WinMediaPath Set-WinMediaWorkDirAcl { }
        $root = Join-Path -Path $TestDrive -ChildPath 'work-new'
        Initialize-WinMediaWorkRoot -Path $root
        Test-Path -LiteralPath $root -PathType Container | Should -BeTrue
        Should -Invoke -CommandName Set-WinMediaWorkDirAcl -ModuleName WinMediaPath -Times 1 -Exactly -ParameterFilter { $Security.AreAccessRulesProtected }
    }

    It '既有目錄的擁有者不在允許清單時拒絕，訊息說明先刪除該目錄，且不套用 ACL' {
        Mock -ModuleName WinMediaPath Set-WinMediaWorkDirAcl { }
        Mock -ModuleName WinMediaPath Get-WinMediaPathOwnerSid { [System.Security.Principal.SecurityIdentifier]'S-1-5-21-1-2-3-1001' }
        $root = Join-Path -Path $TestDrive -ChildPath 'work-foreign'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        { Initialize-WinMediaWorkRoot -Path $root } | Should -Throw -ExpectedMessage '*擁有者*請先刪除*'
        Should -Invoke -CommandName Set-WinMediaWorkDirAcl -ModuleName WinMediaPath -Times 0 -Exactly
    }

    It '既有目錄的擁有者是 SYSTEM 時允許並套用 ACL' {
        Mock -ModuleName WinMediaPath Set-WinMediaWorkDirAcl { }
        Mock -ModuleName WinMediaPath Get-WinMediaPathOwnerSid { [System.Security.Principal.SecurityIdentifier]'S-1-5-18' }
        $root = Join-Path -Path $TestDrive -ChildPath 'work-system'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        { Initialize-WinMediaWorkRoot -Path $root } | Should -Not -Throw
        Should -Invoke -CommandName Set-WinMediaWorkDirAcl -ModuleName WinMediaPath -Times 1 -Exactly
    }

    It '既有 WorkDir 本身是 junction 時拒絕，不套用 ACL' {
        Mock -ModuleName WinMediaPath Set-WinMediaWorkDirAcl { }
        $target = Join-Path -Path $TestDrive -ChildPath 'work-target'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        [System.IO.Path]::GetFullPath($target).StartsWith([System.IO.Path]::GetFullPath($TestDrive), [System.StringComparison]::OrdinalIgnoreCase) | Should -BeTrue
        $link = Join-Path -Path $TestDrive -ChildPath 'work-link'
        New-Item -ItemType Junction -Path $link -Target $target | Out-Null
        try {
            { Initialize-WinMediaWorkRoot -Path $link } | Should -Throw -ExpectedMessage '*reparse point*'
            Should -Invoke -CommandName Set-WinMediaWorkDirAcl -ModuleName WinMediaPath -Times 0 -Exactly
        }
        finally { [System.IO.Directory]::Delete($link) }
    }

    It '所有模組與主流程中，只有 Set-WinMediaWorkDirAcl 內部直接呼叫 Set-Acl（AST）' {
        $root = Split-Path -Parent $PSScriptRoot
        $files = @(Get-ChildItem -LiteralPath (Join-Path -Path $root -ChildPath 'Modules') -Filter '*.psm1') + @(Get-ChildItem -LiteralPath (Join-Path -Path $root -ChildPath 'Public') -Filter '*.ps1')
        $callers = New-Object -TypeName System.Collections.Generic.List[string]
        foreach ($file in $files) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
            foreach ($call in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Set-Acl' }, $true)) {
                $parent = $call.Parent
                while ($null -ne $parent -and $parent -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $parent = $parent.Parent }
                $callers.Add($(if ($null -eq $parent) { "$($file.Name):<top>" } else { $parent.Name }))
            }
        }
        $callers.Count | Should -Be 1
        $callers[0] | Should -BeExactly 'Set-WinMediaWorkDirAcl'
    }

    It '主流程在第一個 Use-WinMediaWorkDir 之前呼叫 Initialize-WinMediaWorkRoot（AST）' {
        $mainPath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Public\Invoke-WindowsMediaRefresh.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($mainPath, [ref]$null, [ref]$null)
        $init = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Initialize-WinMediaWorkRoot' }, $true))
        $use = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Use-WinMediaWorkDir' }, $true))
        $init.Count | Should -BeGreaterThan 0
        $init[0].Extent.StartOffset | Should -BeLessThan $use[0].Extent.StartOffset
    }
}

Describe 'Resolve-WinMediaDefenderStatePath（審查第 15 則）' -Tag 'Unit' {
    It 'LogDir 不在 WorkDir 底下時，狀態檔放在 LogDir' {
        $p = Resolve-WinMediaDefenderStatePath -LogDir 'D:\Logs' -WorkDir 'D:\Work'
        $p | Should -BeExactly 'D:\Logs\DefenderExclusions.state.json'
    }

    It 'LogDir 在 WorkDir 底下（預設設定）時，不可放進會被清空的 WorkDir，改放在 WorkDir 同層' {
        $p = Resolve-WinMediaDefenderStatePath -LogDir 'D:\Work\logs' -WorkDir 'D:\Work'
        $p | Should -BeExactly 'D:\Work.defender-state.json'
    }
}
