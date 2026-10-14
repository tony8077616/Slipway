function Protect-WinMediaLogValue {
    # 參數遮蔽（§4.1）：密碼、token、代理憑證在所有紀錄等級都以 *** 取代
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][AllowEmptyString()][string]$Value
    )

    if ([string]::IsNullOrEmpty($Value)) { return $Value }

    $masked = [regex]::Replace($Value, '(?i)(?<=\s|^)(--proxy-user|-u)\s+\S+', '$1 ***')
    $masked = [regex]::Replace($masked, '(?i)(?<=\s|^)-p\S+', '-p***')
    $masked = [regex]::Replace($masked, '(?i)((?:password|passwd|token|secret|proxypassword)\s*[=:]\s*)\S+', '$1***')
    return $masked
}
