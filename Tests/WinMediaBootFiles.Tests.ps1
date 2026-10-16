#Requires -Version 5.1

BeforeAll {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\Modules\WinMediaBootFiles.psm1') -Force
    $script:config = @{ DebugTrace = 0; OperationLog = '' }
}

Describe 'Copy-WinMediaUpdatedBootFiles（選項 B：_EX 開機檔）' -Tag 'Unit' {
    BeforeEach {
        $script:mount = Join-Path -Path $TestDrive -ChildPath ('mount-{0}' -f [guid]::NewGuid().ToString('N'))
        $script:media = Join-Path -Path $TestDrive -ChildPath ('media-{0}' -f [guid]::NewGuid().ToString('N'))
        $script:boot = Join-Path -Path $script:mount -ChildPath 'Windows\Boot'
        New-Item -ItemType Directory -Path (Join-Path $script:boot 'EFI'), (Join-Path $script:boot 'EFI_EX'), (Join-Path $script:boot 'DVD\EFI\en-US'), (Join-Path $script:boot 'DVD_EX\EFI\en-US'), (Join-Path $script:boot 'FONTS_EX') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:media 'efi\boot'), (Join-Path $script:media 'efi\microsoft\boot') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:media 'efi\boot\bootx64.efi') -Value 'OLD'
    }

    It '有 *_EX.efi 時，bootx64 與 efisys 取自 EX 版本，回傳 $true' {
        Set-Content -LiteralPath (Join-Path $script:boot 'EFI_EX\bootmgfw_EX.efi') -Value 'EX1'
        Set-Content -LiteralPath (Join-Path $script:boot 'EFI\bootmgr.efi') -Value 'MGR'
        Set-Content -LiteralPath (Join-Path $script:boot 'DVD\EFI\en-US\efisys.bin') -Value 'NONEX'
        Set-Content -LiteralPath (Join-Path $script:boot 'DVD_EX\EFI\en-US\efisys_EX.bin') -Value 'EFIEX'
        Set-Content -LiteralPath (Join-Path $script:boot 'FONTS_EX\chs_boot_EX.ttf') -Value 'FONT'

        $applied = Copy-WinMediaUpdatedBootFiles -MountPath $script:mount -MediaDir $script:media -Config $script:config

        $applied | Should -BeTrue
        Get-Content -LiteralPath (Join-Path $script:media 'efi\boot\bootx64.efi') | Should -Be 'EX1'
        Get-Content -LiteralPath (Join-Path $script:media 'efi\microsoft\boot\efisys.bin') | Should -Be 'EFIEX'
        Get-Content -LiteralPath (Join-Path $script:media 'bootmgr.efi') | Should -Be 'MGR'
        Test-Path -LiteralPath (Join-Path $script:media 'efi\microsoft\boot\fonts\chs_boot.ttf') | Should -BeTrue
    }

    It 'ARM64 媒體（只有 bootaa64.efi）只覆蓋既有檔案，不建立 bootx64.efi' {
        Remove-Item -LiteralPath (Join-Path $script:media 'efi\boot\bootx64.efi') -Force
        Set-Content -LiteralPath (Join-Path $script:media 'efi\boot\bootaa64.efi') -Value 'OLD64'
        Set-Content -LiteralPath (Join-Path $script:boot 'EFI_EX\bootmgfw_EX.efi') -Value 'EXA64'

        $applied = Copy-WinMediaUpdatedBootFiles -MountPath $script:mount -MediaDir $script:media -Config $script:config

        $applied | Should -BeTrue
        Get-Content -LiteralPath (Join-Path $script:media 'efi\boot\bootaa64.efi') | Should -Be 'EXA64'
        Test-Path -LiteralPath (Join-Path $script:media 'efi\boot\bootx64.efi') | Should -BeFalse
    }

    It '沒有 *_EX.efi 時回傳 $false，且不覆蓋 bootx64' {
        Set-Content -LiteralPath (Join-Path $script:boot 'EFI\bootmgfw.efi') -Value 'NONEX'

        $applied = Copy-WinMediaUpdatedBootFiles -MountPath $script:mount -MediaDir $script:media -Config $script:config

        $applied | Should -BeFalse
        Get-Content -LiteralPath (Join-Path $script:media 'efi\boot\bootx64.efi') | Should -Be 'OLD'
    }
}

Describe '選項 UpdateBootFiles 的讀取保護（StrictMode 下缺鍵會拋錯）' -Tag 'Unit' {
    It '主檔中每一處 $Config.UpdateBootFiles 都以 ContainsKey 保護' {
        $text = Get-Content -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..\Public\Invoke-WindowsMediaRefresh.ps1') -Raw -Encoding UTF8
        $all = ([regex]::Matches($text, '\$Config\.UpdateBootFiles')).Count
        $guarded = ([regex]::Matches($text, "-not \`$Config\.ContainsKey\('UpdateBootFiles'\) -or \`$Config\.UpdateBootFiles")).Count
        $all | Should -BeGreaterThan 0
        $guarded | Should -Be $all
    }
}

Describe 'Get-WinMediaWimHeader（boot.wim 標頭解析）' -Tag 'Unit' {
    It '由 Flags 文字判斷 LZX，並讀取 Boot Index 與 Image Count' {
        $text = @'
Flags                       = 0x40082
    WIM_HDR_FLAG_COMPRESSION is set
    WIM_HDR_FLAG_COMPRESS_LZX is set
Image Count                 = 2
Boot Index                  = 2
'@
        Mock -ModuleName WinMediaBootFiles Invoke-WinMediaWimlib { [pscustomobject]@{ ExitCode = 0; StdOut = $text; StdErr = '' } }

        InModuleScope WinMediaBootFiles -Parameters @{ C = $script:config } {
            $h = Get-WinMediaWimHeader -WimPath 'X.wim' -Config $C
            $h.Compression | Should -Be 'LZX'
            $h.BootIndex | Should -Be 2
            $h.ImageCount | Should -Be 2
        }
    }
}
