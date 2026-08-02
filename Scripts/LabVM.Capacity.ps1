Set-StrictMode -Version Latest

# Stage 단위 디스크 예산 합산과 호스트 메모리 예산 계산을 담당한다.
# LabVM.psm1이 dot-source하며 모듈 스코프를 공유한다.

function Update-LabStagePlanDiskBudget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Stage,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Config,

        [AllowEmptyCollection()]
        [object[]]$Plans = @()
    )

    # 개별 Test-LabPrerequisite 검사는 각 VM 하나를 생성할 수 있는지만
    # 검사한다. 이 함수는 Stage에서 실제로 생성할 Create 계획들의 디스크
    # 요구량을 합산해 전체 생성 가능 여부를 검사하고, 부족하면 해당
    # Create 계획들을 Failed로 바꾼다. $Plans의 원소는 pscustomobject라
    # 참조로 전달되므로 이 함수 안에서 바꾼 내용이 호출자에도 반영된다.
    #
    # Skip은 추가 디스크 공간이 필요 없고, Conflict/Failed가 하나라도
    # 있으면 어차피 Stage 전체가 중단되므로 합산 검사를 생략한다.
    # 단, ReconcileEligible로 표시된 Conflict는 New-LabStage -Reconcile
    # 아래에서 Stage를 막지 않고 2단계로 넘어가므로 blocker로 세지 않는다.

    $hasIndividualBlocker = (
        @(
            Select-LabResultByStatus `
                -Result $Plans `
                -Status 'Conflict', 'Failed' `
                -Property 'Disposition' |
                Where-Object {
                    -not $_.ReconcileEligible
                }
        ).Count
    ) -gt 0

    if ($hasIndividualBlocker) {
        return
    }

    $createPlans = @(
        Select-LabResultByStatus `
            -Result $Plans `
            -Status 'Create' `
            -Property 'Disposition'
    )

    if ($createPlans.Count -eq 0) {
        return
    }

    # Stage 안에서도 VM마다 DiskMode(FullCopy/Differencing)가
    # 다를 수 있으므로 모드별로 나눠 합산한다.
    $fullCopyCreatePlans = @(
        $createPlans |
            Where-Object {
                [string]$_.Spec['DiskMode'] -eq 'FullCopy'
            }
    )

    $differencingCreatePlans = @(
        $createPlans |
            Where-Object {
                [string]$_.Spec['DiskMode'] -ne 'FullCopy'
            }
    )

    [int64]$stageCreationBytes = 0

    foreach ($plan in $fullCopyCreatePlans) {
        $stageCreationBytes +=
            [int64]$plan.Check.RequiredDiskBytes
    }

    if ($differencingCreatePlans.Count -gt 0) {
        $stageCreationBytes +=
            [int64]$Config['DifferencingReserveMB'] * 1MB

        $stageCreationBytes += (
            [int64]$Config['DifferencingPerVmReserveMB'] *
            1MB
        ) * $differencingCreatePlans.Count
    }

    $stageDiskModeLabel = if (
        $fullCopyCreatePlans.Count -gt 0 -and
        $differencingCreatePlans.Count -gt 0
    ) {
        "Mixed(FullCopy=$($fullCopyCreatePlans.Count), " +
        "Differencing=$($differencingCreatePlans.Count))"
    }
    elseif ($fullCopyCreatePlans.Count -gt 0) {
        'FullCopy'
    }
    else {
        'Differencing'
    }

    [int64]$stageSafetyReserveBytes = (
        [int64]$Config['DiskSafetyReserveMB'] *
        1MB
    )

    [int64]$stageRequiredDiskBytes = (
        $stageCreationBytes +
        $stageSafetyReserveBytes
    )

    # 모든 Create 계획이 같은 LabRoot 볼륨을 쓰므로 볼륨은 여기서 한 번만 조회한다.
    $labRootDriveRoot = [IO.Path]::GetPathRoot(
        [IO.Path]::GetFullPath([string]$Config['LabRoot'])
    )

    try {
        $labRootDrive = [IO.DriveInfo]::new($labRootDriveRoot)

        if (-not $labRootDrive.IsReady) {
            throw "드라이브가 준비되지 않았습니다: $labRootDriveRoot"
        }

        [int64]$stageAvailableDiskBytes =
            $labRootDrive.AvailableFreeSpace
    }
    catch {
        $stageDiskIssue = (
            "Stage '$Stage' 디스크 여유 공간을 확인하지 " +
            "못했습니다($labRootDriveRoot): $($_.Exception.Message)"
        )

        foreach ($plan in $createPlans) {
            $plan.Disposition = 'Failed'

            $plan.Issues = @(
                @($plan.Issues)
                $stageDiskIssue
            )

            $plan.ErrorMessage = $stageDiskIssue
        }

        return
    }

    if (
        $stageAvailableDiskBytes -lt
        $stageRequiredDiskBytes
    ) {
        $stageDiskIssue = Format-LabDiskShortageMessage `
            -Prefix (
                "Stage '$Stage' 전체 디스크 여유 공간 부족"
            ) `
            -DiskMode $stageDiskModeLabel `
            -TargetCount $createPlans.Count `
            -RequiredBytes $stageRequiredDiskBytes `
            -CreationBytes $stageCreationBytes `
            -SafetyReserveBytes $stageSafetyReserveBytes `
            -AvailableBytes $stageAvailableDiskBytes

        foreach ($plan in $createPlans) {
            $plan.Disposition = 'Failed'

            $plan.Issues = @(
                @($plan.Issues)
                $stageDiskIssue
            )

            $plan.ErrorMessage =
                $stageDiskIssue
        }
    }
}

function Get-LabHostMemoryBudget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Config,

        [AllowEmptyCollection()]
        [object[]]$Targets = @(),

        [switch]$Force
    )

    $computerSystem = Get-CimInstance `
        -ClassName Win32_ComputerSystem `
        -ErrorAction Stop

    $totalBytes = [int64]$computerSystem.TotalPhysicalMemory

    $freeBytes = [int64](
        Get-CimInstance `
            -ClassName Win32_PerfRawData_PerfOS_Memory `
            -ErrorAction Stop
    ).AvailableBytes

    $allVms = @(
        Get-VM -ErrorAction Stop
    )

    # $allVms가 비어 있으면(예: VM이 하나도 없는 새 호스트)
    # Measure-Object가 아무 출력도 내지 않아 $measured 자체가
    # $null이 된다 - Set-StrictMode에서 $null.Sum은 예외이므로
    # .Sum에 접근하기 전에 먼저 확인한다.
    $measured = $allVms |
        Measure-Object `
            -Property MemoryAssigned `
            -Sum

    $assignedSum = if ($measured) {
        $measured.Sum
    }
    else {
        0
    }

    [int64]$requestSum = 0

    foreach ($target in $Targets) {
        if ($target.State -eq 'Running') {
            continue
        }

        $additionalBytes = [math]::Max(
            [int64]0,
            (
                [int64]$target.MemoryStartup -
                [int64]$target.MemoryAssigned
            )
        )

        $requestSum += $additionalBytes
    }

    $totalMB = [math]::Floor(
        $totalBytes / 1MB
    )

    $freeMB = [math]::Floor(
        $freeBytes / 1MB
    )

    $assignedMB = [math]::Round(
        $assignedSum / 1MB
    )

    $requestMB = [math]::Round(
        $requestSum / 1MB
    )

    $reservedMB = [int64]$Config['HostReserveMB']

    $availableMB = [math]::Max(
        [int64]0,
        $freeMB - $reservedMB
    )

    # GB 표시는 Lab.MemoryBudget용 LabVM.Format.ps1xml 뷰가 담당한다.
    $memoryBudget = [pscustomobject]@{
        PSTypeName  = 'Lab.MemoryBudget'
        TotalMB     = $totalMB
        ReservedMB  = $reservedMB
        AssignedMB  = $assignedMB
        RequestedMB = $requestMB
        AvailableMB = $availableMB
    }

    $memoryBlocked = (
        $requestMB -gt $availableMB -and
        -not $Force
    )

    if ($memoryBlocked) {
        Write-Warning (
            '메모리가 부족합니다. 다른 실습 VM을 종료하거나 ' +
            'LabConfig.psd1의 MemoryMB를 낮추십시오. ' +
            '무시하려면 -Force를 사용합니다.'
        )
    }

    [pscustomobject]@{
        MemoryBudget = $memoryBudget
        Blocked      = $memoryBlocked
        RequestMB    = $requestMB
        AvailableMB  = $availableMB
    }
}
