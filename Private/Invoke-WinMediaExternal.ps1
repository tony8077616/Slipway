function Invoke-WinMediaExternal {
    # 第三方程式執行（§4.1）：同步讀取 stdout 與 stderr，避免緩衝區死鎖；參數先遮蔽再紀錄
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [Parameter(Mandatory)][hashtable]$Config
    )

    $quoted = foreach ($argument in $ArgumentList) {
        if ($argument -match '\s') { '"{0}"' -f $argument } else { $argument }
    }
    $target = '{0} {1}' -f $FilePath, ($quoted -join ' ')

    $run = {
        $startInfo = New-Object -TypeName System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $FilePath
        $startInfo.Arguments = $quoted -join ' '
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.CreateNoWindow = $true

        $process = New-Object -TypeName System.Diagnostics.Process
        $process.StartInfo = $startInfo
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $stdout = $stdoutTask.Result

        [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut   = $stdout
            StdErr   = $stderr
        }
    }

    $outcome = Invoke-WinMediaOperation -Category External -Operation ([System.IO.Path]::GetFileName($FilePath)) -Target $target -ScriptBlock $run -Config $Config

    if ([int]$Config.DebugTrace -ge 3) {
        Write-WinMediaLog -Config $Config -Level Debug -Message ('stdout: ' + (Protect-WinMediaLogValue -Value $outcome.StdOut))
        Write-WinMediaLog -Config $Config -Level Debug -Message ('stderr: ' + (Protect-WinMediaLogValue -Value $outcome.StdErr))
    }

    return $outcome
}
