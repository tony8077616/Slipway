#Requires -Version 5.1

BeforeAll {
    Import-Module -Name (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'WinMediaRefresh.psd1') -Force
}

Describe 'Mount-WinMediaSourceIso（使用者預先掛載的 ISO 不卸載）' -Tag 'Unit' {
    InModuleScope WinMediaPath {
        It '已掛載時不再掛載，回報 Mounted = $false（之後不得卸載）' {
            Mock Get-DiskImage { New-CimInstance -ClassName MSFT_DiskImage -Namespace root/Microsoft/Windows/Storage -ClientOnly -Property @{ Attached = $true } }
            Mock Mount-DiskImage { throw '已掛載的 ISO 不應再呼叫 Mount-DiskImage' }
            Mock Get-Volume { [pscustomobject]@{ DriveLetter = 'O' } }
            $result = Mount-WinMediaSourceIso -ImagePath 'D:\win.iso' -Confirm:$false
            $result.Mounted | Should -BeFalse
            $result.DriveLetter | Should -Be 'O'
            Should -Invoke Mount-DiskImage -Times 0 -Exactly
        }

        It '未掛載時掛載，回報 Mounted = $true（結束時須卸載）' {
            Mock Get-DiskImage { New-CimInstance -ClassName MSFT_DiskImage -Namespace root/Microsoft/Windows/Storage -ClientOnly -Property @{ Attached = $false } }
            Mock Mount-DiskImage { New-CimInstance -ClassName MSFT_DiskImage -Namespace root/Microsoft/Windows/Storage -ClientOnly -Property @{ Attached = $true } }
            Mock Get-Volume { [pscustomobject]@{ DriveLetter = 'P' } }
            $result = Mount-WinMediaSourceIso -ImagePath 'D:\win.iso' -Confirm:$false
            $result.Mounted | Should -BeTrue
            $result.DriveLetter | Should -Be 'P'
            Should -Invoke Mount-DiskImage -Times 1 -Exactly
        }
    }

    It '主流程改用 Mount-WinMediaSourceIso，且不再直接呼叫 Mount-DiskImage（AST）' {
        $file = Join-Path -Path $PSScriptRoot -ChildPath '..\Public\Invoke-WindowsMediaRefresh.ps1'
        $ast = [Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $file).Path, [ref]$null, [ref]$null)
        $helper = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Mount-WinMediaSourceIso' }, $true))
        $direct = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Mount-DiskImage' }, $true))
        $helper.Count | Should -Be 1
        $direct.Count | Should -Be 0
    }
}
