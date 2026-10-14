function Test-WinMediaVirtualEdition {
    # 虛擬版本來源條件（§2.7.1、§2.7.7、§2.7.8）：純邏輯，不掛載映像，方便 Pester 測試
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][int]$Build,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$SourceEditionIds,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$RequestedEditions,
        [bool]$IoTEnterpriseSSppPresent = $true
    )

    if ($RequestedEditions.Count -eq 0) { return @() }

    if ($Build -lt 17063) {
        throw "ISO build $Build do not support virtual editions（需要 17063 以上）"
    }

    $sourceHasLtsc = $SourceEditionIds | Where-Object { $_ -ieq 'EnterpriseS' }
    if (-not $sourceHasLtsc) {
        throw '來源映像不含 EnterpriseS，無法建立虛擬版本（§2.7.1）'
    }

    # EditionID 即清單 token（§2.7.8）；最低 build 依 create_virtual_editions.cmd 的門檻
    $rules = @{
        'IoTEnterprise'      = 18277
        'IoTEnterpriseS'     = 19041
        'IoTEnterpriseK'     = 25982
        'IoTEnterpriseSK'    = 25193
        'CloudEdition'       = 21364
        'CloudEditionN'      = 21364
        'Enterprise'         = 0
        'Education'          = 0
        'ProfessionalEducation' = 0
        'ProfessionalWorkstation' = 0
        'EnterpriseN'        = 0
        'EducationN'         = 0
        'ProfessionalEducationN' = 0
        'ProfessionalWorkstationN' = 0
        'CoreSingleLanguage' = 0
        'ServerRdsh'         = 0
    }

    $validated = @()
    foreach ($token in $RequestedEditions) {
        $key = $rules.Keys | Where-Object { $_ -ieq $token } | Select-Object -First 1
        if (-not $key) {
            throw "未知的虛擬版本 token：'$token'（§2.7.8）"
        }
        if ($Build -lt $rules[$key]) {
            throw "版本 $key 需要 build $($rules[$key]) 以上，目前為 $Build（§2.7.1）"
        }
        if ($key -ieq 'IoTEnterpriseS' -and -not $IoTEnterpriseSSppPresent) {
            throw 'IoTEnterpriseS 缺少 spp\tokens\skus\IoTEnterpriseS\IoTEnterpriseS-OEM*.xrm-ms，已中止（§2.7.7，不靜默略過）'
        }
        $validated += $key
    }
    return $validated
}
