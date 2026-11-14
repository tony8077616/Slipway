Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\PSModules\Common\WinMediaLog.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\PSModules\Common\WinMediaOperation.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\PSModules\Imaging\WinMediaDism.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\PSModules\Imaging\WinMediaOptimize.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\PSModules\Imaging\WinMediaImage.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\Modules\WinMediaLangFod.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\Modules\WinMediaDriver.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\Modules\WinMediaLxp.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\Modules\WinMediaStoreApps.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\Modules\WinMediaAppx.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\Modules\WinMediaIndexInfo.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\Modules\WinMediaPackage.psm1') -Force

. (Join-Path -Path $PSScriptRoot -ChildPath '..\Public\Invoke-WinMediaInstallIndexImageUpdate.ps1')

function Invoke-WinMediaIndexWorkerJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Job,
        [Parameter(Mandatory)][string]$ResultPath
    )

    $mountSwitches = $Job.mountSwitches
    $Config = $Job.Config
    # 結果經由 holder 取回：Mount 的回傳值還可能夾帶 finally 卸載階段的輸出，不依賴它的形狀
    $holder = @{}

    # 經 Clixml 往返後 [ordered] 在 5.1 會變成 Hashtable，因此以固定順序重建 driverSet，讓安裝順序與父程序一致
    if ($null -ne $Job.driverSet) {
        $rebuiltDriverSet = [ordered]@{}
        foreach ($k in 'ALL', 'WinPE', 'OS') {
            if ($Job.driverSet.Contains($k)) { $rebuiltDriverSet[$k] = $Job.driverSet[$k] }
        }
    } else {
        $rebuiltDriverSet = $null
    }

    Mount-WinMediaImage -ImagePath $Job.ImagePath -Index $Job.Index -MountPath $Job.MountPath @mountSwitches -Config $Config -Action {
        $holder.Result = Invoke-WinMediaInstallIndexImageUpdate -mounted $Job.MountPath -ssu $Job.ssu -lcuStage $Job.lcuStage -langFod $Job.langFod -dotNet $Job.dotNet -enablement $Job.enablement -appxList $Job.appxList -storeSet $Job.storeSet -lxpItems $Job.lxpItems -driverSet $rebuiltDriverSet -forceUnsigned $Job.forceUnsigned -resetBaseOS $Job.resetBaseOS -common $Job.common -IsFirstTarget ([bool]$Job.IsFirstTarget) -winreWim $Job.winreWim -Config $Config
    }

    # result 在卸載之後才寫：它是子程序完成的標記，父程序只有看到檔案存在才視為成功
    Export-Clixml -LiteralPath $ResultPath -Depth 10 -InputObject ([pscustomobject]@{ Index = $Job.Index; KernelVersion = $holder.Result.KernelVersion; BuildInfo = $holder.Result.BuildInfo })
}

Export-ModuleMember -Function Invoke-WinMediaIndexWorkerJob
