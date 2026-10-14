Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$privateDir = Join-Path -Path $PSScriptRoot -ChildPath 'Private'
$publicDir = Join-Path -Path $PSScriptRoot -ChildPath 'Public'

foreach ($file in @(Get-ChildItem -LiteralPath $privateDir -Filter '*.ps1' -File) + @(Get-ChildItem -LiteralPath $publicDir -Filter '*.ps1' -File)) {
    . $file.FullName
}

Export-ModuleMember -Function @(
    'Invoke-WindowsMediaRefresh',
    'Export-WinMediaEsd',
    'Add-WinMediaVirtualEdition',
    'Get-WinMediaPackageCategory'
)
