#Requires -Version 5.1
<#
    每次修改後必須執行的驗證：Pester 6.2.0 + PSScriptAnalyzer（Error、Warning 皆須為 0）。
    任何一項失敗即以非 0 結束碼中止，供人工或 CI 判定。
#>
[CmdletBinding()]
param()

$root = Split-Path -Parent $PSScriptRoot

Import-Module -Name Pester -RequiredVersion 6.2.0 -ErrorAction Stop
$pester = Invoke-Pester -Path (Join-Path -Path $root -ChildPath 'Tests') -PassThru
if ($pester.FailedCount -gt 0) {
    throw "Pester 失敗 $($pester.FailedCount) 項。"
}

Import-Module -Name PSScriptAnalyzer -ErrorAction Stop
$issues = @(Invoke-ScriptAnalyzer -Path $root -Recurse -Severity Error, Warning)
if ($issues.Count -gt 0) {
    $issues | Format-Table -AutoSize Severity, RuleName, ScriptName, Line | Out-String | Write-Output
    throw "PSScriptAnalyzer 發現 $($issues.Count) 項 Error／Warning。"
}

Write-Output ('驗證通過：Pester {0} 項、PSScriptAnalyzer 0 項問題。' -f $pester.PassedCount)
