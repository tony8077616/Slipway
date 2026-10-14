function Get-WinMediaWimlibSpec {
    # wimlib 1.14.5 Windows 發行包與 SHA-256（來源：wimlib 論壇 1.14.5 公告，viewtopic.php?t=1133）
    [CmdletBinding()]
    param(
        [string]$Architecture = $env:PROCESSOR_ARCHITECTURE
    )

    $releases = @{
        'x86_64'  = @{ FileName = 'wimlib-1.14.5-windows-x86_64-bin.zip'; Sha256 = '2f446d6fa3866582175f1a22a7be198eeee0aec7aba5b4e04ad25c99eae2d265' }
        'aarch64' = @{ FileName = 'wimlib-1.14.5-windows-aarch64-bin.zip'; Sha256 = '2c2e3e50cf21bfdd4ffd693b5052b231aa04a10c85f218ae61eb5a031dfcdd8f' }
        'i686'    = @{ FileName = 'wimlib-1.14.5-windows-i686-bin.zip';    Sha256 = '3739eb2291b9a86d2fcc2914c4b2b53317c045de214782e46588ed8350371905' }
    }

    $machine = @{ AMD64 = 'x86_64'; ARM64 = 'aarch64'; x86 = 'i686' }[$Architecture]
    if (-not $machine) {
        throw "不支援的處理器架構：$Architecture"
    }

    [pscustomobject]@{
        Version      = '1.14.5'
        Architecture = $machine
        FileName     = $releases[$machine].FileName
        Url          = 'https://wimlib.net/downloads/' + $releases[$machine].FileName
        Sha256       = $releases[$machine].Sha256
    }
}
