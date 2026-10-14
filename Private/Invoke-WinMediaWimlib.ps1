function Invoke-WinMediaWimlib {
    # wimlib-imagex 專用入口：只接受 wimlib 自己的子命令與參數，不與 DISM 指令混用（§2.4）
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][hashtable]$Config
    )

    $exe = Resolve-WinMediaWimlib -Config $Config
    $result = Invoke-WinMediaExternal -FilePath $exe -ArgumentList $ArgumentList -Config $Config
    if ($result.ExitCode -ne 0) {
        throw "wimlib-imagex $($ArgumentList[0]) 失敗，結束碼 $($result.ExitCode)：$($result.StdErr)"
    }
    return $result
}
