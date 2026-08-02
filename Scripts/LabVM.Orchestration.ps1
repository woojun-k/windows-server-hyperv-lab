Set-StrictMode -Version Latest

# VM/Stage 생성, 제거, 초기화, 시작과 상태 조회를 담당하는
# 최상위 오케스트레이션 함수들. LabVM.psm1이 dot-source하며
# 모듈 스코프를 공유한다.


function New-LabVM {
    [CmdletBinding(
        SupportsShouldProcess,
        DefaultParameterSetName = 'Name'
    )]
    param(
        [Parameter(
            Mandatory,
            ParameterSetName = 'Name'
        )]
        [string]$Name,

        [Parameter(
            Mandatory,
            ParameterSetName = 'Spec'
        )]
        [System.Collections.IDictionary]$Spec,

        [Parameter(Mandatory)]
        [securestring]$AdminPassword,

        # 기존 VM이 Conflict 상태여도 즉시 실패시키지 않고,
        # Set-VM* 한 줄로 안전하게 고칠 수 있는 드리프트
        # (vCPU, 메모리, 체크포인트 정책, 자동 시작/종료, MAC 스푸핑)를
        # 먼저 교정한 뒤 재검사한다. 디스크·네트워크 토폴로지처럼
        # 자동 교정이 위험한 드리프트는 교정 후에도 Conflict로 남는다.
        [switch]$Reconcile,

        # New-LabStage처럼 이미 Get-LabConfig를 부른 호출자가 Stage 안의
        # VM마다 이 함수를 반복 호출할 때 넘겨서 재조회(및 재귀 딥카피)를
        # 피한다. 생략하면 이 함수가 직접 조회한다.
        [System.Collections.IDictionary]$Config
    )

    $cfg = if ($Config) {
        $Config
    }
    else {
        Get-LabConfig
    }

    if ($PSCmdlet.ParameterSetName -eq 'Name') {
        $Spec = Resolve-LabSingleSpec -Name $Name -Config $cfg
    }
    else {
        try {
            $Spec = Resolve-LabVmSpec `
                -Vm $Spec `
                -Config $cfg `
                -ErrorAction Stop
        }
        catch {
            $invalidSpecName = if (
                $Spec.Contains('Name') -and
                -not [string]::IsNullOrWhiteSpace(
                    [string]$Spec['Name']
                )
            ) {
                [string]$Spec['Name']
            }
            else {
                '<invalid-spec>'
            }

            return New-LabVmResult `
                -Name $invalidSpecName `
                -Status Failed `
                -Succeeded $false `
                -Reason 'InvalidSpec' `
                -Issues @($_.Exception.Message) `
                -ErrorMessage $_.Exception.Message
        }
    }

    $isFullCopy = ([string]$Spec['DiskMode'] -eq 'FullCopy')

    try {
        $check = Test-LabPrerequisite `
            -Spec $Spec `
            -Config $cfg `
            -ErrorAction Stop
    }
    catch {
        return New-LabVmResult `
            -Name $Spec.Name `
            -Status Failed `
            -Succeeded $false `
            -Reason 'PrerequisiteException' `
            -Issues @($_.Exception.Message) `
            -ErrorMessage $_.Exception.Message
    }

    if ($null -eq $check) {
        return (
            New-LabVmResult `
                -Name $Spec.Name `
                -Status Failed `
                -Succeeded $false `
                -Reason 'InvalidPrerequisiteResult' `
                -Issues @(
                    'Test-LabPrerequisite가 결과를 반환하지 않았습니다.'
                ) `
                -ErrorMessage (
                    'Test-LabPrerequisite가 결과를 반환하지 않았습니다.'
                )
        )
    }

    $warnings = @($check.Warnings)
    $issues = @($check.Issues)

    Write-LabPrefixedWarning `
        -Prefix ([string]$Spec.Name) `
        -Message $warnings

    if (
        $Reconcile -and
        $check.Disposition -eq 'Conflict' -and
        $check.Compliance
    ) {
        $fixableDrift = @(
            $check.Compliance.Drift |
                Where-Object {
                    $_.Fixable
                }
        )

        if (
            $fixableDrift.Count -gt 0 -and
            $PSCmdlet.ShouldProcess(
                $Spec.Name,
                'VM 구성 교정'
            )
        ) {
            $repair = Repair-LabVmDrift `
                -Spec $Spec `
                -Drift $fixableDrift

            $unfixableMessages = @(
                $check.Compliance.Drift |
                    Where-Object {
                        -not $_.Fixable
                    } |
                    ForEach-Object Message
            )

            $repairWarnings = @(
                $repair.Applied |
                    ForEach-Object {
                        "교정됨: $_"
                    }
            )

            # Repair-LabVmDrift가 예외 없이 끝났다는 것은 각 교정 명령이
            # 실행됐다는 뜻일 뿐, 실제 VM이 준수 상태가 됐다는 보장은
            # 아니다(값이 반영되지 않았거나, 교정 중 다른 프로세스가
            # 설정을 또 바꿨을 수 있다). 반드시 실제 상태를 다시 조회해
            # 재검사한다.
            try {
                $postCheck = Test-LabPrerequisite `
                    -Spec $Spec `
                    -Config $cfg `
                    -ErrorAction Stop
            }
            catch {
                return New-LabVmResult `
                    -Name $Spec.Name `
                    -Status Failed `
                    -Succeeded $false `
                    -Reason 'PrerequisiteException' `
                    -Issues @($_.Exception.Message) `
                    -ErrorMessage $_.Exception.Message
            }

            if (
                $repair.Remaining.Count -eq 0 -and
                $unfixableMessages.Count -eq 0 -and
                $postCheck.Disposition -eq 'Skip'
            ) {
                return (
                    New-LabVmResult `
                        -Name $Spec.Name `
                        -Status Skipped `
                        -Succeeded $true `
                        -Reason 'Reconciled' `
                        -Warnings (
                            @($warnings) +
                            @($postCheck.Warnings) +
                            $repairWarnings
                        )
                )
            }

            $remainingIssues = @(
                $repair.Remaining
                $unfixableMessages
                switch ($postCheck.Disposition) {
                    'Conflict' {
                        $postCheck.Compliance.Drift |
                            ForEach-Object Message
                    }
                    'Skip' {
                    }
                    default {
                        if ($postCheck.Issues) {
                            $postCheck.Issues
                        }
                        else {
                            '재검사 결과가 예상과 다릅니다: ' +
                            $postCheck.Disposition
                        }
                    }
                }
            ) | Select-Object -Unique

            Write-LabPrefixedWarning `
                -Prefix ([string]$Spec.Name) `
                -Message $remainingIssues

            return (
                New-LabVmResult `
                    -Name $Spec.Name `
                    -Status Conflict `
                    -Succeeded $false `
                    -Reason 'ReconciliationIncomplete' `
                    -Issues $remainingIssues `
                    -Warnings $warnings
            )
        }
    }

    $dispositionResult = Resolve-LabVmPrerequisiteResult `
        -Name $Spec.Name `
        -Check $check `
        -Warnings $warnings `
        -Issues $issues

    if ($dispositionResult) {
        return $dispositionResult
    }

    if (
        -not $PSCmdlet.ShouldProcess(
            $Spec.Name,
            'VM 생성'
        )
    ) {
        return (
            New-LabVmResult `
                -Name $Spec.Name `
                -Status Skipped `
                -Succeeded $true `
                -Reason 'ShouldProcessDeclined' `
                -Warnings $warnings
        )
    }

    $child = $check.ChildVhdPath
    $vmPath = $check.VmPath
    $vhdDirectory = Split-Path $child -Parent
    $memory = [int64]$Spec['MemoryMB'] * 1MB
    $switches = @($Spec['Switch'])

    $state = @{
        CreatedVhdDirectory = $false
        CreatedVmPath       = $false
        CreatedChildVhd     = $false
        CreatedVm           = $false
        CreatedVmId         = $null
        # $VmPath 소유권 marker에 적어 두는 값. 롤백이 이 값을 기록한
        # 마커와 대조해, 이 작업이 만든 디렉터리가 맞는지 확인한다.
        OperationId         = [guid]::NewGuid().ToString('N')
    }

    $stagedChildVhd = Join-Path `
        $vhdDirectory `
        ('.{0}.{1}.tmp.vhdx' -f `
            $Spec.Name, `
            [guid]::NewGuid().ToString('N')
        )

    try {
        New-LabVmDiskArtifact `
            -Check $check `
            -IsFullCopy $isFullCopy `
            -VhdDirectory $vhdDirectory `
            -VmPath $vmPath `
            -ChildVhdPath $child `
            -StagedChildVhdPath $stagedChildVhd `
            -State $state

        Set-LabUnattend `
            -VhdPath $child `
            -ComputerName $Spec.Name `
            -AdminPassword $AdminPassword `
            -TemplatePath $check.Template.UnattendPath `
            -AccountMode $check.Template.AccountMode `
            -LocalAdminName $cfg.LocalAdminName `
            -TimeZone $cfg.TimeZone `
            -Location PantherUnattend

        Set-LabVmHardwareProfile `
            -Spec $Spec `
            -Check $check `
            -MemoryBytes $memory `
            -ChildVhdPath $child `
            -VmPath $vmPath `
            -State $state

        Set-LabVmNetworkAdapter `
            -Spec $Spec `
            -Switches $switches

        $postCheck = Test-LabPrerequisite `
            -Spec $Spec `
            -Config $cfg `
            -ErrorAction Stop

        if ($postCheck.Disposition -ne 'Skip') {
            $postIssues = if ($postCheck.Compliance) {
                @(
                    $postCheck.Compliance.Drift |
                        ForEach-Object Message
                )
            }
            else {
                @($postCheck.Issues)
            }

            throw (
                'VM 생성 후 준수 검사에 실패했습니다: ' +
                ($postIssues -join '; ')
            )
        }

        # 생성이 성공했으므로 롤백용 소유권 marker는 더 이상 필요 없다.
        # 지워두지 않으면 Export-VM 결과물 등에 섞여 나간다.
        Remove-Item `
            -LiteralPath (
                Join-Path $vmPath '.labvm-creation-owner'
            ) `
            -Force `
            -ErrorAction SilentlyContinue

        return (
            New-LabVmResult `
                -Name $Spec.Name `
                -Status Created `
                -Succeeded $true `
                -Reason 'Created' `
                -Warnings (
                    @($warnings) + @($postCheck.Warnings)
                ) `
                -CPU ([int]$Spec.CPU) `
                -MemoryMB ([int64]$Spec.MemoryMB) `
                -Switches $switches
        )
    }
    catch {
        $failure = $_

        $rollbackIssues = Invoke-LabVmCreationRollback `
            -Name $Spec.Name `
            -State $state `
            -ChildVhdPath $child `
            -StagedChildVhdPath $stagedChildVhd `
            -VmPath $vmPath `
            -VhdDirectory $vhdDirectory

        $errorMessage = (
            "VM '$($Spec.Name)' 생성 실패: " +
            $failure.Exception.Message
        )

        Write-Warning $errorMessage

        foreach ($rollbackIssue in $rollbackIssues) {
            Write-Warning $rollbackIssue
        }

        $reason = if ($rollbackIssues.Count -gt 0) {
            'CreationFailedRollbackIncomplete'
        }
        else {
            'CreationException'
        }

        return (
            New-LabVmResult `
                -Name $Spec.Name `
                -Status Failed `
                -Succeeded $false `
                -Reason $reason `
                -Issues @(
                    $errorMessage
                    $rollbackIssues
                ) `
                -Warnings $warnings `
                -ErrorMessage $failure.Exception.Message
        )
    }
}

function Remove-LabVM {
    [CmdletBinding(
        SupportsShouldProcess,
        ConfirmImpact = 'High'
    )]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        # 실행 중 VM의 강제 전원 차단과
        # 구성 편차가 있는 VM 등록 제거를 허용한다.
        [switch]$Force,

        # Remove-LabVM을 내부에서 반복 호출하는 New-LabStage 롤백,
        # Reset-LabStage 같은 호출자가 이미 Get-LabConfig를 부른 경우
        # 넘겨서 재조회(및 재귀 딥카피)를 피한다. 생략하면 이 함수가
        # 직접 조회한다.
        [System.Collections.IDictionary]$Config
    )

    $cfg = if ($Config) {
        $Config
    }
    else {
        Get-LabConfig
    }

    $null = Resolve-LabSingleSpec -Name $Name -Config $cfg

    $labPaths = Get-LabVmPath `
        -Name $Name `
        -Config $cfg

    $expectedVhdPath = $labPaths.VhdPath
    $expectedVmPath = $labPaths.VmPath

    $expectedVhdNormalized = ConvertTo-LabNormalizedPath `
        -Path $expectedVhdPath

    $expectedVmNormalized = ConvertTo-LabNormalizedPath `
        -Path $expectedVmPath

    try {
        $vm = Get-LabVmByName `
            -Name $Name `
            -ErrorAction Stop
    }
    catch {
        $message = (
            "VM '$Name' 조회 실패: " +
            $_.Exception.Message
        )

        Write-Warning $message

        return (
            New-LabVmRemovalResult `
                -Name $Name `
                -Status Failed `
                -Succeeded $false `
                -Reason 'VmLookupException' `
                -Issues @($message) `
                -ErrorMessage $_.Exception.Message
        )
    }

    $vhdExists =
        Test-Path -LiteralPath $expectedVhdPath

    $vmPathExists =
        Test-Path -LiteralPath $expectedVmPath

    if (
        -not $vm -and
        -not $vhdExists -and
        -not $vmPathExists
    ) {
        return (
            New-LabVmRemovalResult `
                -Name $Name `
                -Status Skipped `
                -Succeeded $true `
                -Reason 'AlreadyAbsent'
        )
    }

    $preservedPaths =
        [Collections.Generic.List[string]]::new()

    $conflictCheck = Test-LabVmRemovalConflict `
        -Name $Name `
        -Vm $vm `
        -Force:$Force `
        -ExpectedVhdNormalized $expectedVhdNormalized `
        -ExpectedVmNormalized $expectedVmNormalized

    if ($conflictCheck.BlockingResult) {
        return $conflictCheck.BlockingResult
    }

    $actualDiskPaths = $conflictCheck.ActualDiskPaths
    $snapshots = $conflictCheck.Snapshots

    $crossUseResult = Test-LabVmRemovalCrossUse `
        -Name $Name `
        -Vm $vm `
        -Force:$Force `
        -ExpectedVhdPath $expectedVhdPath `
        -ExpectedVhdNormalized $expectedVhdNormalized `
        -ExpectedVmPath $expectedVmPath `
        -ExpectedVmNormalized $expectedVmNormalized `
        -VhdExists $vhdExists `
        -ActualDiskPaths $actualDiskPaths

    if ($crossUseResult) {
        return $crossUseResult
    }

    if (
        -not $PSCmdlet.ShouldProcess(
            $Name,
            (
                'VM 등록, 예상 VHDX 및 ' +
                'VM 구성 디렉터리 제거'
            )
        )
    ) {
        return (
            New-LabVmRemovalResult `
                -Name $Name `
                -Status Skipped `
                -Succeeded $true `
                -Reason 'ShouldProcessDeclined'
        )
    }

    $removedPaths =
        [Collections.Generic.List[string]]::new()

    try {
        return Invoke-LabVmRemovalExecution `
            -Name $Name `
            -Vm $vm `
            -Snapshots $snapshots `
            -ExpectedVhdPath $expectedVhdPath `
            -ExpectedVmPath $expectedVmPath `
            -ExpectedVhdNormalized $expectedVhdNormalized `
            -ActualDiskPaths $actualDiskPaths `
            -RemovedPaths $removedPaths `
            -PreservedPaths $preservedPaths
    }
    catch {
        $message = (
            "VM '$Name' 제거 실패: " +
            $_.Exception.Message
        )

        Write-Warning $message

        return (
            New-LabVmRemovalResult `
                -Name $Name `
                -Status Failed `
                -Succeeded $false `
                -Reason 'RemovalException' `
                -RemovedPaths @(
                    $removedPaths
                ) `
                -PreservedPaths @(
                    $preservedPaths |
                        Select-Object -Unique
                ) `
                -Issues @($message) `
                -ErrorMessage $_.Exception.Message
        )
    }
}

function New-LabStage {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Stage,

        [securestring]$AdminPassword,

        # Conflict인 기존 VM 중 드리프트가 전부 Fixable인 것들을
        # New-LabVM -Reconcile로 교정한다. 자세한 내용은
        # New-LabVM -Reconcile 설명을 참고한다.
        [switch]$Reconcile
    )

    $cfg = Get-LabConfig

    Assert-LabStageName `
        -Stage $Stage `
        -Config $cfg

    # VM Stage 여부와 무관하게, 이 Stage를 돌리는 데 필요한 가상
    # 스위치 목록을 먼저 계산해 모든 New-LabStageResult 반환 지점에
    # 실어 보낸다(Lab.StageCreationResult 계약의 RequiredSwitches).
    $requiredSwitches = @(
        Get-LabStageRequiredSwitch `
            -Stage $Stage `
            -CheckExistence `
            -Config $cfg
    )

    $specs = @(
        Resolve-LabSpec -Stage $Stage -Config $cfg
    )

    # VM이 없는 base 같은 인프라 Stage 처리
    if ($specs.Count -eq 0) {
        if ($requiredSwitches.Count -gt 0) {
            return (
                New-LabStageResult `
                    -Stage $Stage `
                    -Status Skipped `
                    -Succeeded $true `
                    -Reason 'InfrastructureOnlyStage' `
                    -RequiredSwitches $requiredSwitches
            )
        }

        return (
            New-LabStageResult `
                -Stage $Stage `
                -Status Skipped `
                -Succeeded $true `
                -Reason 'NoVmDefinitions' `
                -RequiredSwitches $requiredSwitches
        )
    }

    if (-not $AdminPassword) {
        throw (
            "VM이 포함된 Stage '$Stage'에는 " +
            '-AdminPassword가 필요합니다.'
        )
    }

    # ---------------------------------------------------------
    # 1단계: Stage 전체 사전 검사
    # 이 단계에서는 VM이나 디스크를 생성하지 않는다.
    # ---------------------------------------------------------
    $plans = @(
        foreach ($spec in $specs) {
            try {
                $check = Test-LabPrerequisite `
                    -Spec $spec `
                    -Config $cfg `
                    -ErrorAction Stop

                if ($null -eq $check) {
                    throw (
                        'Test-LabPrerequisite가 ' +
                        '결과를 반환하지 않았습니다.'
                    )
                }

                if (
                    $check.Disposition -notin @(
                        'Create',
                        'Skip',
                        'Conflict',
                        'Failed'
                    )
                ) {
                    throw (
                        "알 수 없는 Disposition: " +
                        "'$($check.Disposition)'"
                    )
                }

                # Conflict인 기존 VM의 드리프트가 전부 Fixable이면
                # -Reconcile 아래에서는 이 계획을 차단하지 않고
                # 2단계의 New-LabVM -Reconcile로 넘긴다.
                $reconcileEligible = (
                    $Reconcile -and
                    $check.Disposition -eq 'Conflict' -and
                    $check.Compliance -and
                    (
                        @(
                            $check.Compliance.Drift |
                                Where-Object {
                                    -not $_.Fixable
                                }
                        ).Count -eq 0
                    )
                )

                [pscustomobject]@{
                    Spec              = $spec
                    Check             = $check
                    Disposition       = $check.Disposition
                    Issues            = @($check.Issues)
                    Warnings          = @($check.Warnings)
                    ErrorMessage      = $null
                    ReconcileEligible = $reconcileEligible
                }
            }
            catch {
                [pscustomobject]@{
                    Spec              = $spec
                    Check             = $null
                    Disposition       = 'Failed'
                    Issues            = @(
                        $_.Exception.Message
                    )
                    Warnings          = @()
                    ErrorMessage      = $_.Exception.Message
                    ReconcileEligible = $false
                }
            }
        }
    )

    # Stage에서 실제로 생성할 Create 계획들의 디스크 요구량을 합산해
    # 전체 생성 가능 여부를 검사한다. 부족하면 해당 계획들을 Failed로
    # 바꾼다($plans 원소는 참조 타입이라 아래 $blockingPlans 재계산에
    # 곧바로 반영된다).
    Update-LabStagePlanDiskBudget `
        -Stage $Stage `
        -Config $cfg `
        -Plans $plans

    $blockingPlans = @(
        Select-LabResultByStatus `
            -Result $plans `
            -Status 'Conflict', 'Failed' `
            -Property 'Disposition' |
            Where-Object {
                -not $_.ReconcileEligible
            }
    )

    if ($blockingPlans.Count -gt 0) {
        $blockingNames = @(
            $blockingPlans |
                ForEach-Object {
                    $_.Spec.Name
                }
        ) -join ', '

        $results = @(
            foreach ($plan in $plans) {
                ConvertTo-LabStagePreflightResult `
                    -Plan $plan `
                    -BlockingNames $blockingNames
            }
        )

        $stageStatus = Resolve-LabAggregateStatus `
            -Result $blockingPlans `
            -Priority 'Failed' `
            -DefaultStatus 'Conflict' `
            -Property 'Disposition'

        return (
            New-LabStageResult `
                -Stage $Stage `
                -Status $stageStatus `
                -Succeeded $false `
                -Reason 'PreflightFailed' `
                -Results $results `
                -RequiredSwitches $requiredSwitches
        )
    }

    $createCount = Get-LabStatusCount `
        -Result $plans `
        -Status 'Create' `
        -Property 'Disposition'

    $reconcileCount = @(
        $plans |
            Where-Object {
                $_.ReconcileEligible
            }
    ).Count

    if ($createCount -eq 0 -and $reconcileCount -eq 0) {
        $alreadyCompliantResults = @(
            foreach ($plan in $plans) {
                New-LabVmResult `
                    -Name $plan.Spec.Name `
                    -Status Skipped `
                    -Succeeded $true `
                    -Reason 'AlreadyCompliant' `
                    -Warnings $plan.Warnings
            }
        )

        return (
            New-LabStageResult `
                -Stage $Stage `
                -Status Skipped `
                -Succeeded $true `
                -Reason 'AlreadyCompliant' `
                -Results $alreadyCompliantResults `
                -RequiredSwitches $requiredSwitches
        )
    }

    $stageActionDescription = if ($reconcileCount -gt 0) {
        "Stage VM ${createCount}대 생성, ${reconcileCount}대 교정"
    }
    else {
        "Stage VM ${createCount}대 생성"
    }

    if (
        -not $PSCmdlet.ShouldProcess(
            $Stage,
            $stageActionDescription
        )
    ) {
        $declinedResults = @(
            foreach ($plan in $plans) {
                if ($plan.Disposition -eq 'Skip') {
                    New-LabVmResult `
                        -Name $plan.Spec.Name `
                        -Status Skipped `
                        -Succeeded $true `
                        -Reason 'AlreadyCompliant' `
                        -Warnings $plan.Warnings
                }
                else {
                    New-LabVmResult `
                        -Name $plan.Spec.Name `
                        -Status Skipped `
                        -Succeeded $true `
                        -Reason 'ShouldProcessDeclined' `
                        -Warnings $plan.Warnings
                }
            }
        )

        return New-LabStageResult `
            -Stage $Stage `
            -Status Skipped `
            -Succeeded $true `
            -Reason 'ShouldProcessDeclined' `
            -Results $declinedResults `
            -RequiredSwitches $requiredSwitches
    }

    # ---------------------------------------------------------
    # 2단계: 모든 사전 검사가 통과한 경우에만 생성 시작
    #
    # New-LabVM에서 사전 검사를 다시 수행한다.
    # 첫 검사 이후 다른 프로세스가 VM이나 경로를 생성한
    # 경쟁 조건을 다시 탐지하기 위한 의도적인 재검사다.
    # ---------------------------------------------------------
    $executionPlans = @(
        @(
            $plans |
                Where-Object {
                    -not $_.ReconcileEligible
                }
        ) +
        @(
            $plans |
                Where-Object {
                    $_.ReconcileEligible
                }
        )
    )

    $resultsByPlan =
        [System.Collections.Generic.Dictionary[object, object]]::new()

    $createdNames = [System.Collections.Generic.List[string]]::new()
    $rollbackResults = [System.Collections.Generic.List[object]]::new()
    $previousFailure = $null

    foreach ($plan in $executionPlans) {
        if ($null -ne $previousFailure) {
            $resultsByPlan[$plan] = (
                New-LabVmResult `
                    -Name $plan.Spec.Name `
                    -Status Aborted `
                    -Succeeded $false `
                    -Reason 'PreviousVmFailed' `
                    -Issues @(
                        "이전 VM '$($previousFailure.Name)'의 " +
                        '생성 실패로 실행하지 않았습니다.'
                    ) `
                    -Warnings $plan.Warnings
            )

            continue
        }

        try {
            $vmOutput = @(
                New-LabVM `
                    -Spec $plan.Spec `
                    -AdminPassword $AdminPassword `
                    -Reconcile:$Reconcile `
                    -Confirm:$false `
                    -Config $cfg
            )

            if ($vmOutput.Count -ne 1) {
                throw (
                    "New-LabVM이 결과 객체를 정확히 하나 " +
                    "반환해야 하지만 $($vmOutput.Count)개를 " +
                    '반환했습니다.'
                )
            }

            $vmResult = $vmOutput[0]
        }
        catch {
            $vmResult = New-LabVmResult `
                -Name $plan.Spec.Name `
                -Status Failed `
                -Succeeded $false `
                -Reason 'UnhandledException' `
                -ErrorMessage $_.Exception.Message `
                -Issues @(
                    "처리되지 않은 예외: " +
                    $_.Exception.Message
                )
        }

        $resultsByPlan[$plan] = $vmResult

        if ($vmResult.Status -eq 'Created') {
            $createdNames.Add([string]$vmResult.Name)
        }

        if (-not $vmResult.Succeeded) {
            $previousFailure = $vmResult

            $rollbackNames = @($createdNames)
            [array]::Reverse($rollbackNames)

            foreach ($createdName in $rollbackNames) {
                try {
                    $rollbackResult = Remove-LabVM `
                        -Name $createdName `
                        -Force `
                        -Confirm:$false `
                        -Config $cfg

                    $rollbackResults.Add($rollbackResult)
                }
                catch {
                    $rollbackResults.Add(
                        [pscustomobject]@{
                            Name      = $createdName
                            Status    = 'Failed'
                            Succeeded = $false
                            Error     = $_.Exception.Message
                        }
                    )
                }
            }
        }
    }

    # 실행은 안전을 위해 Create 우선 순서로 했지만, 보고는 Stage에
    # 정의된 원래 순서를 유지한다.
    $resultArray = @(
        $plans |
            ForEach-Object {
                $resultsByPlan[$_]
            }
    )

    $stageStatus = Resolve-LabAggregateStatus `
        -Result $resultArray `
        -Priority 'Failed', 'Conflict', 'Aborted', 'Created' `
        -DefaultStatus 'Skipped'

    $stageSucceeded = @(
        $resultArray |
            Where-Object {
                -not $_.Succeeded
            }
    ).Count -eq 0

    $reason = switch ($stageStatus) {
        'Created' {
            'Completed'
        }

        'Skipped' {
            'AlreadyCompliant'
        }

        'Aborted' {
            'ExecutionAborted'
        }

        'Conflict' {
            'ConcurrentConflict'
        }

        'Failed' {
            'ExecutionFailed'
        }
    }

    return (
        New-LabStageResult `
            -Stage $Stage `
            -Status $stageStatus `
            -Succeeded $stageSucceeded `
            -Reason $reason `
            -Results $resultArray `
            -RequiredSwitches $requiredSwitches `
            -RollbackResults @($rollbackResults)
    )
}

function Reset-LabStage {
    [CmdletBinding(
        SupportsShouldProcess,
        ConfirmImpact = 'High'
    )]
    param(
        [Parameter(Mandatory)]
        [string]$Stage,

        [switch]$Force
    )

    $cfg = Get-LabConfig

    Assert-LabStageName `
        -Stage $Stage `
        -Config $cfg

    $specs = @(
        Resolve-LabSpec -Stage $Stage -Config $cfg
    )

    if ($specs.Count -eq 0) {
        return (
            New-LabStageResetResult `
                -Stage $Stage `
                -Status Skipped `
                -Succeeded $true `
                -Reason 'NoVmDefinitions'
        )
    }

    if (
        -not $PSCmdlet.ShouldProcess(
            $Stage,
            (
                "Stage VM $($specs.Count)대와 " +
                '관련 LabRoot 리소스 제거'
            )
        )
    ) {
        return (
            New-LabStageResetResult `
                -Stage $Stage `
                -Status Skipped `
                -Succeeded $true `
                -Reason 'ShouldProcessDeclined'
        )
    }

    $orderedSpecs = @($specs)
    [array]::Reverse($orderedSpecs)

    $results = @(
        foreach ($spec in $orderedSpecs) {
            Remove-LabVM `
                -Name ([string]$spec['Name']) `
                -Force:$Force `
                -Confirm:$false `
                -Config $cfg
        }
    )

    $failedCount = Get-LabStatusCount `
        -Result $results `
        -Status 'Failed'

    $removedCount = Get-LabStatusCount `
        -Result $results `
        -Status 'Removed'

    if ($failedCount -gt 0) {
        return (
            New-LabStageResetResult `
                -Stage $Stage `
                -Status Failed `
                -Succeeded $false `
                -Reason 'PartialFailure' `
                -Results $results
        )
    }

    if ($removedCount -gt 0) {
        return (
            New-LabStageResetResult `
                -Stage $Stage `
                -Status Removed `
                -Succeeded $true `
                -Reason 'Removed' `
                -Results $results
        )
    }

    return (
        New-LabStageResetResult `
            -Stage $Stage `
            -Status Skipped `
            -Succeeded $true `
            -Reason 'AlreadyAbsent' `
            -Results $results
    )
}

function Start-LabStage {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Stage,

        [string[]]$Also,

        [switch]$Force
    )

    $cfg = Get-LabConfig

    Assert-LabStageName `
        -Stage $Stage `
        -Config $cfg

    $requiredSwitches = @(
        Get-LabStageRequiredSwitch `
            -Stage $Stage `
            -AdditionalVmName $Also `
            -CheckExistence `
            -Config $cfg
    )

    $invalidSwitches = @(
        $requiredSwitches |
            Where-Object {
                $_.Compliant -ne $true
            }
    )

    if ($invalidSwitches.Count -gt 0) {
        $switchIssues = @(
            foreach ($switchInfo in $invalidSwitches) {
                if (-not $switchInfo.Exists) {
                    "가상 스위치 '$($switchInfo.Name)'가 없습니다. " +
                    "기대 유형=$($switchInfo.DesiredType), " +
                    "선언 Stage=$($switchInfo.DeclaredIn)"
                }
                else {
                    "가상 스위치 '$($switchInfo.Name)' 유형 불일치: " +
                    "기대=$($switchInfo.DesiredType), " +
                    "실제=$($switchInfo.ActualType)"
                }
            }
        )

        Write-LabPrefixedWarning `
            -Prefix ([string]$Stage) `
            -Message $switchIssues

        return New-LabStageStartResult `
            -Stage $Stage `
            -Status Failed `
            -Succeeded $false `
            -Reason 'SwitchPreflightFailed' `
            -RequiredSwitches $requiredSwitches
    }

    $stageNames = @(
        Resolve-LabSpec -Stage $Stage -Config $cfg |
            ForEach-Object {
                [string]$_['Name']
            }
    )

    if ($stageNames.Count -eq 0) {
        if ($requiredSwitches.Count -gt 0) {
            return (
                New-LabStageStartResult `
                    -Stage $Stage `
                    -Status Skipped `
                    -Succeeded $true `
                    -Reason 'InfrastructureOnlyStage' `
                    -RequiredSwitches $requiredSwitches
            )
        }

        return (
            New-LabStageStartResult `
                -Stage $Stage `
                -Status Skipped `
                -Succeeded $true `
                -Reason 'NoVmDefinitions' `
                -RequiredSwitches $requiredSwitches
        )
    }

    $dependencyNames = @(
        Get-LabStageDependencyClosure `
            -Stage $Stage `
            -Config $cfg
    )

    # 의존 VM(예: RRAS01)이 Stage 자체 VM보다 먼저 시작되도록 맨
    # 앞에 둔다. Select-Object -Unique는 첫 등장 순서를 유지하므로
    # 이후 stageNames/Also에 같은 이름이 다시 나와도 순서가 안
    # 흐트러진다.
    $targetNames = @(
        $dependencyNames +
        $stageNames +
        @($Also | Select-LabNonEmptyString) |
            Select-Object -Unique
    )

    $results =
        [Collections.Generic.List[object]]::new()

    $targets =
        [Collections.Generic.List[object]]::new()

    $missingNames =
        [Collections.Generic.List[string]]::new()

    $hostVmIndex = Get-LabHostVmNameIndex
    $hostVmsByName = $hostVmIndex.ByName
    $ambiguousNames =
        [Collections.Generic.List[string]]::new()

    foreach ($targetName in $targetNames) {
        if ($hostVmIndex.DuplicateNames -contains $targetName) {
            $ambiguousNames.Add($targetName)
            continue
        }

        $vm = $hostVmsByName[$targetName]

        if (-not $vm) {
            $missingNames.Add($targetName)
            continue
        }

        $targets.Add($vm)
    }

    if (
        $missingNames.Count -gt 0 -or
        $ambiguousNames.Count -gt 0
    ) {
        $preflightResults = @(
            foreach ($targetName in $targetNames) {
                if ($ambiguousNames -contains $targetName) {
                    New-LabVmStartResult `
                        -Name $targetName `
                        -Status Failed `
                        -Succeeded $false `
                        -Reason 'AmbiguousVmName' `
                        -Issues @(
                            "동일한 이름의 Hyper-V VM이 여러 개 있습니다: $targetName"
                        ) `
                        -ErrorMessage '동일한 이름의 Hyper-V VM이 여러 개 있습니다.'
                }
                elseif ($missingNames -contains $targetName) {
                    New-LabVmStartResult `
                        -Name $targetName `
                        -Status Failed `
                        -Succeeded $false `
                        -Reason 'VmNotFound' `
                        -Issues @(
                            "VM '$targetName'이 생성되어 있지 않습니다."
                        ) `
                        -ErrorMessage 'VM이 생성되어 있지 않습니다.'
                }
                else {
                    New-LabVmStartResult `
                        -Name $targetName `
                        -Status Aborted `
                        -Succeeded $false `
                        -Reason 'StagePreflightFailed' `
                        -Issues @(
                            (
                                '다른 Stage VM에 문제가 있어 시작을 중단했습니다: ' +
                                (
                                    @($missingNames) + @($ambiguousNames) -join ', '
                                )
                            )
                        )
                }
            }
        )

        return New-LabStageStartResult `
            -Stage $Stage `
            -Status Failed `
            -Succeeded $false `
            -Reason 'StagePreflightFailed' `
            -Results $preflightResults `
            -RequiredSwitches $requiredSwitches
    }

    $memoryCheck = Get-LabHostMemoryBudget `
        -Config $cfg `
        -Targets $targets `
        -Force:$Force

    $memoryBudget = $memoryCheck.MemoryBudget
    $memoryBlocked = $memoryCheck.Blocked
    $requestMB = $memoryCheck.RequestMB
    $availableMB = $memoryCheck.AvailableMB

    # ---------------------------------------------------------
    # 시작
    # ---------------------------------------------------------

    foreach ($vm in $targets) {
        if ($vm.State -eq 'Running') {
            $results.Add(
                (
                    New-LabVmStartResult `
                        -Name $vm.Name `
                        -Status Skipped `
                        -Succeeded $true `
                        -Reason 'AlreadyRunning' `
                        -State 'Running' `
                        -MemoryStartupBytes (
                            [int64]$vm.MemoryStartup
                        )
                )
            )

            continue
        }

        if ($memoryBlocked) {
            $results.Add(
                (
                    New-LabVmStartResult `
                        -Name $vm.Name `
                        -Status Aborted `
                        -Succeeded $false `
                        -Reason 'InsufficientHostMemory' `
                        -State ([string]$vm.State) `
                        -MemoryStartupBytes (
                            [int64]$vm.MemoryStartup
                        ) `
                        -Issues @(
                            "호스트 가용 메모리 부족으로 " +
                            "시작하지 않았습니다: " +
                            "요청=${requestMB}MB, " +
                            "가용=${availableMB}MB"
                        )
                )
            )

            continue
        }

        if (
            -not $PSCmdlet.ShouldProcess(
                $vm.Name,
                'VM 시작'
            )
        ) {
            $results.Add(
                (
                    New-LabVmStartResult `
                        -Name $vm.Name `
                        -Status Skipped `
                        -Succeeded $true `
                        -Reason 'ShouldProcessDeclined' `
                        -State ([string]$vm.State) `
                        -MemoryStartupBytes (
                            [int64]$vm.MemoryStartup
                        )
                )
            )

            continue
        }

        try {
            Start-VM `
                -VM $vm `
                -ErrorAction Stop

            # $vm은 Start-VM 시점부터 stale이므로 다시 조회한다.
            $current = Get-VM `
                -Name $vm.Name `
                -ErrorAction SilentlyContinue

            $currentState = if ($current) {
                [string]$current.State
            }
            else {
                'Unknown'
            }

            $results.Add(
                (
                    New-LabVmStartResult `
                        -Name $vm.Name `
                        -Status Started `
                        -Succeeded $true `
                        -Reason 'Started' `
                        -State $currentState `
                        -MemoryStartupBytes (
                            [int64]$vm.MemoryStartup
                        )
                )
            )
        }
        catch {
            $memoryHint = ''

            try {
                $liveMemory = Get-LabHostMemoryBudget `
                    -Config $cfg `
                    -Targets @() `
                    -Force

                $requiredMB = [math]::Ceiling(
                    [int64]$vm.MemoryStartup / 1MB
                )

                if ($liveMemory.AvailableMB -lt $requiredMB) {
                    $memoryHint = (
                        ' (호스트 가용 메모리 부족 가능성: ' +
                        "약 $($liveMemory.AvailableMB)MB 남음, " +
                        "필요 약 ${requiredMB}MB)"
                    )
                }
            }
            catch {
                # 진단용 재조회 실패는 원래 오류를 가리지 않는다.
            }

            $startMessage = (
                "VM '$($vm.Name)' 시작 실패: " +
                $_.Exception.Message +
                $memoryHint
            )

            Write-Warning $startMessage

            $results.Add(
                (
                    New-LabVmStartResult `
                        -Name $vm.Name `
                        -Status Failed `
                        -Succeeded $false `
                        -Reason 'StartException' `
                        -State ([string]$vm.State) `
                        -MemoryStartupBytes (
                            [int64]$vm.MemoryStartup
                        ) `
                        -Issues @($startMessage) `
                        -ErrorMessage $_.Exception.Message
                )
            )
        }
    }

    $resultArray = @($results)

    $stageStatus = Resolve-LabAggregateStatus `
        -Result $resultArray `
        -Priority 'Failed', 'Aborted', 'Started' `
        -DefaultStatus 'Skipped'

    $reason = switch ($stageStatus) {
        'Started' {
            'Completed'
        }

        'Skipped' {
            # 전부 -WhatIf/거부로 건너뛴 경우와
            # 이미 실행 중이라 건너뛴 경우를 구분한다.
            $declined = Get-LabStatusCount `
                -Result $resultArray `
                -Status 'ShouldProcessDeclined' `
                -Property 'Reason'

            if (
                $resultArray.Count -gt 0 -and
                $declined -eq $resultArray.Count
            ) {
                'ShouldProcessDeclined'
            }
            else {
                'AlreadyRunning'
            }
        }

        'Aborted' {
            'InsufficientHostMemory'
        }

        'Failed' {
            'StartFailed'
        }
    }

    return (
        New-LabStageStartResult `
            -Stage $Stage `
            -Status $stageStatus `
            -Succeeded (
                @(
                    $resultArray |
                        Where-Object {
                            -not $_.Succeeded
                        }
                ).Count -eq 0
            ) `
            -Reason $reason `
            -Results $resultArray `
            -RequiredSwitches $requiredSwitches `
            -DependencyNames $dependencyNames `
            -MemoryBudget $memoryBudget
    )
}

function Test-LabVmStillNeeded {
    # $Name을 끄기 전에, $ExcludingStage 이외의 다른 Stage가 지금
    # StageDependencies로 이 VM을 요구하고 있으면서, 그 Stage가
    # 실제로 활성 상태(그 Stage 소유 VM 중 하나라도 Running)인지
    # 확인한다. 해당하면 그 Stage 이름을 돌려주고, 없으면 $null을
    # 돌려준다.
    #
    # $Name의 소유 Stage 자체는 검사 대상에서 자연히 제외된다 -
    # StageDependencies는 자기 자신 소유 VM을 의존성으로 선언할 수
    # 없으므로(Assert-LabConfig가 막는다), $Name의 소유 Stage가
    # 이 검사에 걸릴 일은 없다. 만약 ownNames(그 Stage의 소유 VM)에
    # $Name이 포함됐는지를 따로 검사하면, "지금 끄려는 VM 자신이
    # Running이니 자기 Stage가 활성 상태"라는 동어반복에 빠져 절대
    # 끌 수 없게 되므로 그런 검사는 하지 않는다.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$ExcludingStage,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Config,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$HostVmsByName
    )

    foreach ($otherStage in @($Config['StageOrder'])) {
        $otherStage = [string]$otherStage

        if ($otherStage -eq $ExcludingStage) {
            continue
        }

        $dependsOnName = (
            @(
                Get-LabStageDependencyClosure `
                    -Stage $otherStage `
                    -Config $Config
            ) -contains $Name
        )

        if (-not $dependsOnName) {
            continue
        }

        $ownNames = @(
            Resolve-LabSpec -Stage $otherStage -Config $Config |
                ForEach-Object {
                    [string]$_['Name']
                }
        )

        $isActive = @(
            $ownNames |
                Where-Object {
                    $HostVmsByName.Contains($_) -and
                    $HostVmsByName[$_].State -eq 'Running'
                }
        ).Count -gt 0

        if ($isActive) {
            return $otherStage
        }
    }

    $null
}

function Stop-LabStage {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Stage,

        [string[]]$Also,

        # 통합 서비스를 통한 정상 종료 대신 즉시 전원을 끈다.
        [switch]$TurnOff,

        [switch]$Force
    )

    $cfg = Get-LabConfig

    Assert-LabStageName `
        -Stage $Stage `
        -Config $cfg

    $stageNames = @(
        Resolve-LabSpec -Stage $Stage -Config $cfg |
            ForEach-Object {
                [string]$_['Name']
            }
    )

    if ($stageNames.Count -eq 0) {
        return (
            New-LabStageStopResult `
                -Stage $Stage `
                -Status Skipped `
                -Succeeded $true `
                -Reason 'NoVmDefinitions'
        )
    }

    # Start-LabStage는 Stage 정의 순서대로 VM을 시작한다(예: AD DS
    # Stage에서 DC가 멤버 서버보다 먼저 정의되어 먼저 시작된다).
    # 종료는 그 반대 순서로 진행해, DC처럼 다른 VM이 의존하는 VM을
    # 가장 나중에 끈다. Reset-LabStage의 제거 순서와 같은 원칙이다.
    # -Also로 추가된 VM은 Stage 소속이 아니라 부가적으로 함께 끄는
    # 대상이므로, 반전 이후 목록 맨 뒤에 붙여 Stage 자체 VM보다도
    # 나중에(가장 마지막에) 꺼지게 한다.
    $reversedStageNames = @($stageNames)
    [array]::Reverse($reversedStageNames)

    # StageDependencies로 이 Stage와 함께 자동으로 켜졌을 VM들.
    # Stage 자체 VM을 다 끈 다음, 가까운 의존부터(Get-LabStageDependencyClosure의
    # 발견 순서 그대로) 이어서 끈다. 다른 활성 Stage가 아직 쓰고
    # 있으면 Test-LabVmStillNeeded가 걸러낸다.
    $dependencyNames = @(
        Get-LabStageDependencyClosure `
            -Stage $Stage `
            -Config $cfg
    )

    $additionalNames = @(
        foreach (
            $additionalName in
            @($Also | Select-LabNonEmptyString)
        ) {
            $additionalSpec = Resolve-LabSingleSpec `
                -Name $additionalName `
                -Context '-Also 대상' `
                -Config $cfg

            [string]$additionalSpec['Name']
        }
    )

    $targetNames = @(
        $reversedStageNames +
        $dependencyNames +
        $additionalNames |
            Select-Object -Unique
    )

    $hostVmIndex = Get-LabHostVmNameIndex
    $hostVmsByName = $hostVmIndex.ByName

    $results =
        [Collections.Generic.List[object]]::new()

    foreach ($targetName in $targetNames) {
        if ($hostVmIndex.DuplicateNames -contains $targetName) {
            $results.Add(
                (
                    New-LabVmStopResult `
                        -Name $targetName `
                        -Status Failed `
                        -Succeeded $false `
                        -Reason 'AmbiguousVmName' `
                        -Issues @(
                            "동일한 이름의 Hyper-V VM이 여러 개 있습니다: $targetName"
                        ) `
                        -ErrorMessage '동일한 이름의 Hyper-V VM이 여러 개 있습니다.'
                )
            )

            continue
        }

        $vm = $hostVmsByName[$targetName]

        if (-not $vm) {
            $results.Add(
                (
                    New-LabVmStopResult `
                        -Name $targetName `
                        -Status Skipped `
                        -Succeeded $true `
                        -Reason 'VmNotFound'
                )
            )

            continue
        }

        if ($vm.State -eq 'Off') {
            $results.Add(
                (
                    New-LabVmStopResult `
                        -Name $vm.Name `
                        -Status Skipped `
                        -Succeeded $true `
                        -Reason 'AlreadyOff' `
                        -State 'Off'
                )
            )

            continue
        }

        if (-not $Force) {
            $stillNeededBy = Test-LabVmStillNeeded `
                -Name $vm.Name `
                -ExcludingStage $Stage `
                -Config $cfg `
                -HostVmsByName $hostVmsByName

            if ($stillNeededBy) {
                $results.Add(
                    (
                        New-LabVmStopResult `
                            -Name $vm.Name `
                            -Status Skipped `
                            -Succeeded $true `
                            -Reason 'StillRequiredByStage' `
                            -State ([string]$vm.State) `
                            -Issues @(
                                "Stage '$stillNeededBy'가 아직 사용 중이라 " +
                                "끄지 않았습니다. 정말 끄려면 -Force를 " +
                                '사용하십시오.'
                            )
                    )
                )

                continue
            }
        }

        if (
            -not $PSCmdlet.ShouldProcess(
                $vm.Name,
                'VM 종료'
            )
        ) {
            $results.Add(
                (
                    New-LabVmStopResult `
                        -Name $vm.Name `
                        -Status Skipped `
                        -Succeeded $true `
                        -Reason 'ShouldProcessDeclined' `
                        -State ([string]$vm.State)
                )
            )

            continue
        }

        try {
            Stop-VM `
                -VM $vm `
                -TurnOff:$TurnOff `
                -Force:$Force `
                -ErrorAction Stop

            # $vm은 Stop-VM 시점부터 stale이므로 다시 조회한다.
            $current = Get-VM `
                -Name $vm.Name `
                -ErrorAction SilentlyContinue

            $currentState = if ($current) {
                [string]$current.State
            }
            else {
                'Unknown'
            }

            $results.Add(
                (
                    New-LabVmStopResult `
                        -Name $vm.Name `
                        -Status Stopped `
                        -Succeeded $true `
                        -Reason 'Stopped' `
                        -State $currentState
                )
            )
        }
        catch {
            $stopMessage = (
                "VM '$($vm.Name)' 종료 실패: " +
                $_.Exception.Message
            )

            Write-Warning $stopMessage

            $results.Add(
                (
                    New-LabVmStopResult `
                        -Name $vm.Name `
                        -Status Failed `
                        -Succeeded $false `
                        -Reason 'StopException' `
                        -State ([string]$vm.State) `
                        -Issues @($stopMessage) `
                        -ErrorMessage $_.Exception.Message
                )
            )
        }
    }

    $resultArray = @($results)

    $stageStatus = Resolve-LabAggregateStatus `
        -Result $resultArray `
        -Priority 'Failed', 'Stopped' `
        -DefaultStatus 'Skipped'

    $reason = switch ($stageStatus) {
        'Stopped' {
            'Completed'
        }

        'Skipped' {
            # 전부 -WhatIf/거부로 건너뛴 경우, 다른 Stage가 아직
            # 써서 건너뛴 경우, 이미 꺼져 있어 건너뛴 경우를 구분한다.
            $declined = Get-LabStatusCount `
                -Result $resultArray `
                -Status 'ShouldProcessDeclined' `
                -Property 'Reason'

            $stillRequired = Get-LabStatusCount `
                -Result $resultArray `
                -Status 'StillRequiredByStage' `
                -Property 'Reason'

            if (
                $resultArray.Count -gt 0 -and
                $declined -eq $resultArray.Count
            ) {
                'ShouldProcessDeclined'
            }
            elseif (
                $resultArray.Count -gt 0 -and
                $stillRequired -eq $resultArray.Count
            ) {
                'StillRequiredElsewhere'
            }
            else {
                'AlreadyOff'
            }
        }

        'Failed' {
            'StopFailed'
        }
    }

    return (
        New-LabStageStopResult `
            -Stage $Stage `
            -Status $stageStatus `
            -Succeeded (
                @(
                    $resultArray |
                        Where-Object {
                            -not $_.Succeeded
                        }
                ).Count -eq 0
            ) `
            -Reason $reason `
            -Results $resultArray
    )
}

function Get-LabStatus {
    [CmdletBinding()]
    param(
        [ValidateNotNullOrEmpty()]
        [string]$Stage
    )

    $cfg = Get-LabConfig

    $validStages = @($cfg.StageOrder)

    if ($PSBoundParameters.ContainsKey('Stage')) {
        $resolvedStage = @(
            $validStages |
                Where-Object {
                    $_ -eq $Stage
                }
        ) |
            Select-Object -First 1

        if (-not $resolvedStage) {
            throw (
                "존재하지 않는 Stage입니다: '$Stage'. " +
                "사용 가능한 Stage: " +
                ($validStages -join ', ')
            )
        }

        $Stage = $resolvedStage

        $specs = @(
            Resolve-LabSpec -Stage $Stage -Config $cfg
        )
    }
    else {
        $specs = @($cfg.VMs)
    }

    $stageIndex = @{}

    for (
        $i = 0;
        $i -lt $cfg.StageOrder.Count;
        $i++
    ) {
        $stageIndex[$cfg.StageOrder[$i]] = $i
    }

    $specs = @(
        $specs |
            Sort-Object `
                @{
                    Expression = {
                        $stageIndex[$_.Stage]
                    }
                },
                @{
                    Expression = {
                        $_.Name
                    }
                }
    )

    $hostVmIndex = Get-LabHostVmNameIndex
    $hostVmsByName = $hostVmIndex.ByName

    foreach ($spec in $specs) {
        $specName = [string]$spec.Name
        $isAmbiguous = $hostVmIndex.DuplicateNames -contains $specName
        $vm = if ($isAmbiguous) { $null } else { $hostVmsByName[$specName] }

        Get-LabVmStatusReport `
            -Spec $spec `
            -Vm $vm `
            -Config $cfg `
            -Ambiguous:$isAmbiguous
    }
}
