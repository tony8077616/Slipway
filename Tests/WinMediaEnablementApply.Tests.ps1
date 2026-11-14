BeforeAll {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\Modules\WinMediaPackage.psm1') -Force
    $script:pkgDir = Join-Path -Path $TestDrive -ChildPath 'Packages'
    New-Item -ItemType Directory -Path $script:pkgDir -Force | Out-Null
    function script:New-PkgFixture([string[]]$Names) {
        Get-ChildItem -LiteralPath $script:pkgDir -File | Remove-Item -Force
        foreach ($n in $Names) { [IO.File]::WriteAllText((Join-Path -Path $script:pkgDir -ChildPath $n), '') }
    }
    $script:editions = @('Microsoft-Windows-CoreEdition', 'Microsoft-Windows-ProfessionalEdition', 'Microsoft-Windows-EnterpriseSEdition')
}

Describe 'Test-WinMediaEnablementApplicable（convert-UUP :enablement 的 Edition 與 LTSC 條件）' -Tag 'Unit' {
    It 'Pro 映像（有 ProfessionalEdition 套件）：套用' {
        New-PkgFixture @('Microsoft-Windows-ProfessionalEdition~31bf3856ad364e35~amd64~~10.0.26100.1.mum')
        Test-WinMediaEnablementApplicable -Editions $script:editions -PackagesDir $script:pkgDir | Should -BeTrue
    }

    It 'LTSC 映像（有 EnterpriseSEdition 套件）：即使 Edition 命中也不套用' {
        New-PkgFixture @('Microsoft-Windows-EnterpriseSEdition~31bf3856ad364e35~amd64~~10.0.26100.1.mum')
        Test-WinMediaEnablementApplicable -Editions $script:editions -PackagesDir $script:pkgDir | Should -BeFalse
    }

    It 'Server 版映像（Server*Edition 套件）：視為 LTSC，不套用' {
        New-PkgFixture @('Microsoft-Windows-ProfessionalEdition~31bf3856ad364e35~amd64~~10.0.26100.1.mum', 'Microsoft-Windows-ServerStandardEdition~31bf3856ad364e35~amd64~~10.0.26100.1.mum')
        Test-WinMediaEnablementApplicable -Editions $script:editions -PackagesDir $script:pkgDir | Should -BeFalse
    }

    It 'Azure Stack HCI 會覆蓋 LTSC 判定（與 convert-UUP 2958 相同）：Edition 命中即套用' {
        New-PkgFixture @('Microsoft-Windows-ProfessionalEdition~31bf3856ad364e35~amd64~~10.0.26100.1.mum', 'Microsoft-Windows-ServerAzureStackHCIEdition~31bf3856ad364e35~amd64~~10.0.26100.1.mum', 'Microsoft-Windows-ServerStandardEdition~31bf3856ad364e35~amd64~~10.0.26100.1.mum')
        Test-WinMediaEnablementApplicable -Editions $script:editions -PackagesDir $script:pkgDir | Should -BeTrue
    }

    It '沒有任何 Edition 套件命中：不套用' {
        New-PkgFixture @('Microsoft-Windows-HomeEdition~31bf3856ad364e35~amd64~~10.0.26100.1.mum')
        Test-WinMediaEnablementApplicable -Editions $script:editions -PackagesDir $script:pkgDir | Should -BeFalse
    }

    It '套件目錄不存在：不套用' {
        Test-WinMediaEnablementApplicable -Editions $script:editions -PackagesDir (Join-Path -Path $TestDrive -ChildPath 'missing') | Should -BeFalse
    }
}

Describe 'Get-WinMediaEnablementEdition（讀取 eKB update.mum 的 Edition）' -Tag 'Unit' {
    It '只取出 Microsoft-Windows-<X>Edition 形式的 identity 名稱，去除重複' {
        $root = Join-Path -Path $TestDrive -ChildPath 'ekb'
        $cabDir = Join-Path -Path $root -ChildPath 'Windows11.0-KB5121794-x64.cab'
        New-Item -ItemType Directory -Path $cabDir -Force | Out-Null
        $mum = @'
<assembly>
  <assemblyIdentity name="Microsoft-Windows-CoreEdition" version="10.0.26100.1" />
  <assemblyIdentity name="Microsoft-Windows-ProfessionalEdition" version="10.0.26100.1" />
  <assemblyIdentity name="Microsoft-Windows-CoreEdition" version="10.0.26100.1" />
  <assemblyIdentity name="Package_for_KB5121794" version="26100.9544.1.2" />
</assembly>
'@
        [IO.File]::WriteAllText((Join-Path -Path $cabDir -ChildPath 'update.mum'), $mum)
        $result = Get-WinMediaEnablementEdition -Package 'C:\pkg\Windows11.0-KB5121794-x64.cab' -ExpandDir $root
        $result | Should -Be @('Microsoft-Windows-CoreEdition', 'Microsoft-Windows-ProfessionalEdition')
    }
}
