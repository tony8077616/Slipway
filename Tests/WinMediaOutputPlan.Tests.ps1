#Requires -Version 5.1

BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    Import-Module -Name (Join-Path -Path $script:root -ChildPath 'Modules\WinMediaPath.psm1') -Force
}

Describe 'Resolve-WinMediaOutputPlan 輸出形式矩陣（Step 10b，藍圖 F7）' -Tag 'Unit' {
    It 'OutputFormat=<Format> OutputForm=[<Form>] 解析為 <Expect>' -ForEach @(
        @{ Format = 'WIM'; Form = ''; Expect = 'Iso'; Oscdimg = $true; Wimlib = $false }
        @{ Format = 'WIM'; Form = 'Iso'; Expect = 'Iso'; Oscdimg = $true; Wimlib = $false }
        @{ Format = 'WIM'; Form = 'Folder'; Expect = 'Folder'; Oscdimg = $false; Wimlib = $false }
        @{ Format = 'WIM'; Form = 'Image'; Expect = 'Image'; Oscdimg = $false; Wimlib = $false }
        @{ Format = 'ESD'; Form = ''; Expect = 'Iso'; Oscdimg = $true; Wimlib = $true }
        @{ Format = 'ESD'; Form = 'Iso'; Expect = 'Iso'; Oscdimg = $true; Wimlib = $true }
        @{ Format = 'ESD'; Form = 'Folder'; Expect = 'Folder'; Oscdimg = $false; Wimlib = $true }
        @{ Format = 'ESD'; Form = 'Image'; Expect = 'Image'; Oscdimg = $false; Wimlib = $true }
    ) {
        $plan = Resolve-WinMediaOutputPlan -OutputFormat $Format -OutputForm $Form
        $plan.OutputForm | Should -Be $Expect
        $plan.NeedsOscdimg | Should -Be $Oscdimg
        $plan.NeedsWimlib | Should -Be $Wimlib
    }

    It '不支援的 OutputFormat 丟出中文訊息' {
        { Resolve-WinMediaOutputPlan -OutputFormat 'DVD' } | Should -Throw '*不支援的 OutputFormat*'
    }
}
