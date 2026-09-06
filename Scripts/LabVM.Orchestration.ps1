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
        [System.Collections.IDictionary]$Config,

        [switch]$CompleteActivation,

        [int]$ActivationTimeoutSeconds = 300,

        [int]$ActivationGraceSeconds = 60,

        [int]$SeedTimeoutSeconds = 300,

        [int]$SeedGraceSeconds = 0
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

    $isLinuxGuest = Test-LabTemplateIsLinux `
        -Template $check.Template

    $seedVhd = if ($isLinuxGuest) {
        (
            Get-LabVmPath `
                -Name $Spec.Name `
                -Config $cfg
        ).SeedVhdPath
    }
    else {
        $null
    }

    $state = @{
        CreatedVhdDirectory = $false
        CreatedVmPath       = $false
        CreatedChildVhd     = $false
        CreatedSeedVhd      = $false
        CreatedVm           = $false
        CreatedVmId         = $null
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

        if (-not $isLinuxGuest) {
            Set-LabUnattend `
                -VhdPath $child `
                -ComputerName $Spec.Name `
                -AdminPassword $AdminPassword `
                -TemplatePath $check.Template.UnattendPath `
                -AccountMode $check.Template.AccountMode `
                -LocalAdminName $cfg.LocalAdminName `
                -TimeZone $cfg.TimeZone `
                -Location PantherUnattend
        }

        Set-LabVmHardwareProfile `
            -Spec $Spec `
            -Check $check `
            -MemoryBytes $memory `
            -ChildVhdPath $child `
            -VmPath $vmPath `
            -State $state

        if ($isLinuxGuest) {
            Add-LabVmCloudInitSeedDisk `
                -Name $Spec.Name `
                -SeedVhdPath $seedVhd `
                -UserName (
                    ([string]$cfg.LocalAdminName).ToLowerInvariant()
                ) `
                -AdminPassword $AdminPassword `
                -State $state
        }

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

        Remove-Item `
            -LiteralPath (
                Join-Path $vmPath '.labvm-creation-owner'
            ) `
            -Force `
            -ErrorAction SilentlyContinue

        $firstBootWarnings = @()

        if ($CompleteActivation) {
            try {
                Start-VM `
                    -Name $Spec.Name `
                    -ErrorAction Stop

                $activationResult = Complete-LabVmActivationIfNeeded `
                    -Name @($Spec.Name) `
                    -Config $cfg `
                    -AdminPassword $AdminPassword `
                    -TimeoutSeconds $ActivationTimeoutSeconds `
                    -GraceSeconds $ActivationGraceSeconds

                $seedResult = Complete-LabVmCloudInitSeedIfNeeded `
                    -Name @($Spec.Name) `
                    -Config $cfg `
                    -TimeoutSeconds $SeedTimeoutSeconds `
                    -GraceSeconds $SeedGraceSeconds

                if (
                    $activationResult -and
                    $activationResult.TimedOutNames.Count -gt 0
                ) {
                    $firstBootWarnings += (
                        "VM '$($Spec.Name)'이 평가판 활성화 임시 " +
                        '네트워크에서 제한 시간 안에 IP를 받지 ' +
                        "못했습니다. VM 디렉터리의 " +
                        "'.labvm-activation-state' 파일을 지운 뒤 " +
                        'Complete-LabVmActivation으로 다시 시도할 수 ' +
                        '있습니다.'
                    )
                }

                if (
                    $seedResult -and
                    $seedResult.TimedOutNames.Count -gt 0
                ) {
                    $firstBootWarnings += (
                        "VM '$($Spec.Name)'이 제한 시간 안에 " +
                        'cloud-init 적용을 알리지 않아 시드 디스크가 ' +
                        '그대로 남아 있습니다. 게스트 상태를 확인한 ' +
                        '뒤 Remove-LabVmCloudInitSeed로 다시 회수할 ' +
                        '수 있습니다.'
                    )
                }

                $firstBootPending = (
                    (
                        $activationResult -and
                        $activationResult.TimedOutNames.Count -gt 0
                    ) -or
                    (
                        $seedResult -and
                        $seedResult.TimedOutNames.Count -gt 0
                    )
                )

                $firstBootCompleted = (
                    (
                        $activationResult -and
                        $activationResult.Status -eq 'Completed'
                    ) -or
                    (
                        $seedResult -and
                        $seedResult.Status -eq 'Removed'
                    )
                )

                if (
                    -not $firstBootPending -and
                    $firstBootCompleted
                ) {
                    try {
                        Stop-VM `
                            -Name $Spec.Name `
                            -ErrorAction Stop
                    }
                    catch {
                        $firstBootWarnings += (
                            "VM '$($Spec.Name)' 첫 부팅 작업 완료 후 " +
                            "종료 실패: $($_.Exception.Message)"
                        )
                    }
                }
            }
            catch {
                $firstBootWarnings += (
                    "VM '$($Spec.Name)' 첫 부팅 자동 처리 " +
                    "실패: $($_.Exception.Message)"
                )
            }
        }

        return (
            New-LabVmResult `
                -Name $Spec.Name `
                -Status Created `
                -Succeeded $true `
                -Reason 'Created' `
                -Warnings (
                    @($warnings) +
                    @($postCheck.Warnings) +
                    $firstBootWarnings
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
            -VhdDirectory $vhdDirectory `
            -SeedVhdPath $seedVhd

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

        [switch]$Force,

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

    $expectedSeedVhdPath = $labPaths.SeedVhdPath

    $expectedVhdNormalized = ConvertTo-LabNormalizedPath `
        -Path $expectedVhdPath

    $expectedVmNormalized = ConvertTo-LabNormalizedPath `
        -Path $expectedVmPath

    $expectedSeedVhdNormalized = ConvertTo-LabNormalizedPath `
        -Path $expectedSeedVhdPath

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

    $seedVhdExists =
        Test-Path -LiteralPath $expectedSeedVhdPath

    if (
        -not $vm -and
        -not $vhdExists -and
        -not $vmPathExists -and
        -not $seedVhdExists
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
        -ExpectedVmNormalized $expectedVmNormalized `
        -AdditionalExpectedVhdNormalized @(
            $expectedSeedVhdNormalized
        )

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
            -SeedVhdPath $expectedSeedVhdPath `
            -SeedVhdNormalized $expectedSeedVhdNormalized `
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

        [switch]$Reconcile,

        [switch]$CompleteActivation,

        [int]$ActivationTimeoutSeconds = 300,

        [int]$ActivationGraceSeconds = 60,

        [int]$SeedTimeoutSeconds = 300,

        [int]$SeedGraceSeconds = 0
    )

    $cfg = Get-LabConfig

    Assert-LabStageName `
        -Stage $Stage `
        -Config $cfg

    $requiredSwitches = @(
        Get-LabStageRequiredSwitch `
            -Stage $Stage `
            -CheckExistence `
            -Config $cfg
    )

    $specs = @(
        Resolve-LabSpec -Stage $Stage -Config $cfg
    )

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
                    -Config $cfg `
                    -CompleteActivation:$CompleteActivation `
                    -ActivationTimeoutSeconds $ActivationTimeoutSeconds `
                    -ActivationGraceSeconds $ActivationGraceSeconds `
                    -SeedTimeoutSeconds $SeedTimeoutSeconds `
                    -SeedGraceSeconds $SeedGraceSeconds
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

        [switch]$Force,

        [switch]$SkipActivation,

        [switch]$SkipSeedCleanup,

        [securestring]$AdminPassword,

        [ValidateRange(0, 3600)]
        [int]$ActivationTimeoutSeconds = 300,

        [ValidateRange(0, 600)]
        [int]$ActivationGraceSeconds = 60,

        [ValidateRange(0, 3600)]
        [int]$SeedTimeoutSeconds = 300,

        [ValidateRange(0, 600)]
        [int]$SeedGraceSeconds = 0
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

    $freshlyStartedNames = @(
        $resultArray |
            Where-Object {
                $_.Status -eq 'Started' -and
                $_.Reason -eq 'Started'
            } |
            ForEach-Object {
                [string]$_.Name
            }
    )

    $activationResult = $null

    if (
        -not $SkipActivation -and
        $freshlyStartedNames.Count -gt 0
    ) {
        $activationResult = Complete-LabVmActivationIfNeeded `
            -Name $freshlyStartedNames `
            -Config $cfg `
            -AdminPassword $AdminPassword `
            -TimeoutSeconds $ActivationTimeoutSeconds `
            -GraceSeconds $ActivationGraceSeconds
    }

    $cloudInitSeedResult = $null

    if (
        -not $SkipSeedCleanup -and
        $freshlyStartedNames.Count -gt 0
    ) {
        $cloudInitSeedResult = Complete-LabVmCloudInitSeedIfNeeded `
            -Name $freshlyStartedNames `
            -Config $cfg `
            -TimeoutSeconds $SeedTimeoutSeconds `
            -GraceSeconds $SeedGraceSeconds
    }

    $stageStatus = Resolve-LabAggregateStatus `
        -Result $resultArray `
        -Priority 'Failed', 'Aborted', 'Started' `
        -DefaultStatus 'Skipped'

    $reason = switch ($stageStatus) {
        'Started' {
            'Completed'
        }

        'Skipped' {
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
            -MemoryBudget $memoryBudget `
            -ActivationResult $activationResult `
            -CloudInitSeedResult $cloudInitSeedResult
    )
}

function Test-LabVmStillNeeded {
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

    $reversedStageNames = @($stageNames)
    [array]::Reverse($reversedStageNames)

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

function Grant-LabVmActivationNetwork {

    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'ByStage')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'ByStage')]
        [string]$Stage,

        [Parameter(ParameterSetName = 'ByStage')]
        [string[]]$Also,

        [Parameter(Mandatory, ParameterSetName = 'ByName')]
        [ValidateNotNullOrEmpty()]
        [string[]]$Name,

        [System.Collections.IDictionary]$Config
    )

    $cfg = if ($Config) {
        $Config
    }
    else {
        Get-LabConfig
    }

    $externalSwitchName = Get-LabExternalSwitchName `
        -Config $cfg

    $stageLabel = if ($PSCmdlet.ParameterSetName -eq 'ByName') {
        ''
    }
    else {
        $Stage
    }

    $targetNames = @(
        if ($PSCmdlet.ParameterSetName -eq 'ByName') {
            @(
                $Name |
                    Select-LabNonEmptyString |
                    Select-Object -Unique
            )
        }
        else {
            Assert-LabStageName `
                -Stage $Stage `
                -Config $cfg

            $stageNames = @(
                Resolve-LabSpec -Stage $Stage -Config $cfg |
                    ForEach-Object {
                        [string]$_['Name']
                    }
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

            @(
                $stageNames +
                $additionalNames |
                    Select-Object -Unique
            )
        }
    )

    if ($targetNames.Count -eq 0) {
        return (
            New-LabStageActivationGrantResult `
                -Stage $stageLabel `
                -Status Skipped `
                -Succeeded $true `
                -Reason 'NoVmDefinitions'
        )
    }

    $hostVmIndex = Get-LabHostVmNameIndex
    $hostVmsByName = $hostVmIndex.ByName

    $results =
        [Collections.Generic.List[object]]::new()

    foreach ($targetName in $targetNames) {
        if ($hostVmIndex.DuplicateNames -contains $targetName) {
            $results.Add(
                (
                    New-LabVmActivationGrantResult `
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

        $spec = Resolve-LabSingleSpec `
            -Name $targetName `
            -Config $cfg

        if (@($spec['Switch']) -contains $externalSwitchName) {
            $results.Add(
                (
                    New-LabVmActivationGrantResult `
                        -Name $targetName `
                        -Status Skipped `
                        -Succeeded $true `
                        -Reason 'AlreadyExternallyConnected' `
                        -SwitchName $externalSwitchName
                )
            )

            continue
        }

        $vm = $hostVmsByName[$targetName]

        if (-not $vm) {
            $results.Add(
                (
                    New-LabVmActivationGrantResult `
                        -Name $targetName `
                        -Status Skipped `
                        -Succeeded $true `
                        -Reason 'VmNotFound'
                )
            )

            continue
        }

        $existingAdapter = Get-VMNetworkAdapter `
            -VMName $targetName `
            -Name $script:LabActivationAdapterName `
            -ErrorAction SilentlyContinue

        if ($existingAdapter) {
            $results.Add(
                (
                    New-LabVmActivationGrantResult `
                        -Name $targetName `
                        -Status Skipped `
                        -Succeeded $true `
                        -Reason 'AlreadyGranted' `
                        -SwitchName $externalSwitchName
                )
            )

            continue
        }

        if (
            -not $PSCmdlet.ShouldProcess(
                $targetName,
                "평가판 활성화용 '$externalSwitchName' 임시 연결"
            )
        ) {
            $results.Add(
                (
                    New-LabVmActivationGrantResult `
                        -Name $targetName `
                        -Status Skipped `
                        -Succeeded $true `
                        -Reason 'ShouldProcessDeclined'
                )
            )

            continue
        }

        try {
            Add-VMNetworkAdapter `
                -VMName $targetName `
                -Name $script:LabActivationAdapterName `
                -SwitchName $externalSwitchName `
                -ErrorAction Stop |
                Out-Null

            $results.Add(
                (
                    New-LabVmActivationGrantResult `
                        -Name $targetName `
                        -Status Granted `
                        -Succeeded $true `
                        -Reason 'Granted' `
                        -SwitchName $externalSwitchName
                )
            )
        }
        catch {
            $grantMessage = (
                "VM '$targetName'에 임시 어댑터 연결 실패: " +
                $_.Exception.Message
            )

            Write-Warning $grantMessage

            $results.Add(
                (
                    New-LabVmActivationGrantResult `
                        -Name $targetName `
                        -Status Failed `
                        -Succeeded $false `
                        -Reason 'GrantException' `
                        -Issues @($grantMessage) `
                        -ErrorMessage $_.Exception.Message
                )
            )
        }
    }

    $resultArray = @($results)

    $stageStatus = Resolve-LabAggregateStatus `
        -Result $resultArray `
        -Priority 'Failed', 'Granted' `
        -DefaultStatus 'Skipped'

    $reason = switch ($stageStatus) {
        'Granted' {
            'Completed'
        }

        'Skipped' {
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
                'AlreadyCompliant'
            }
        }

        'Failed' {
            'GrantFailed'
        }
    }

    return (
        New-LabStageActivationGrantResult `
            -Stage $stageLabel `
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

function Revoke-LabVmActivationNetwork {
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'ByStage')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'ByStage')]
        [string]$Stage,

        [Parameter(ParameterSetName = 'ByStage')]
        [string[]]$Also,

        [Parameter(Mandatory, ParameterSetName = 'ByName')]
        [ValidateNotNullOrEmpty()]
        [string[]]$Name,

        [System.Collections.IDictionary]$Config
    )

    $cfg = if ($Config) {
        $Config
    }
    else {
        Get-LabConfig
    }

    $stageLabel = if ($PSCmdlet.ParameterSetName -eq 'ByName') {
        ''
    }
    else {
        $Stage
    }

    $targetNames = @(
        if ($PSCmdlet.ParameterSetName -eq 'ByName') {
            @(
                $Name |
                    Select-LabNonEmptyString |
                    Select-Object -Unique
            )
        }
        else {
            Assert-LabStageName `
                -Stage $Stage `
                -Config $cfg

            $stageNames = @(
                Resolve-LabSpec -Stage $Stage -Config $cfg |
                    ForEach-Object {
                        [string]$_['Name']
                    }
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

            @(
                $stageNames +
                $additionalNames |
                    Select-Object -Unique
            )
        }
    )

    if ($targetNames.Count -eq 0) {
        return (
            New-LabStageActivationRevokeResult `
                -Stage $stageLabel `
                -Status Skipped `
                -Succeeded $true `
                -Reason 'NoVmDefinitions'
        )
    }

    $hostVmIndex = Get-LabHostVmNameIndex
    $hostVmsByName = $hostVmIndex.ByName

    $results =
        [Collections.Generic.List[object]]::new()

    foreach ($targetName in $targetNames) {
        if ($hostVmIndex.DuplicateNames -contains $targetName) {
            $results.Add(
                (
                    New-LabVmActivationRevokeResult `
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
                    New-LabVmActivationRevokeResult `
                        -Name $targetName `
                        -Status Skipped `
                        -Succeeded $true `
                        -Reason 'VmNotFound'
                )
            )

            continue
        }

        $adapter = Get-VMNetworkAdapter `
            -VMName $targetName `
            -Name $script:LabActivationAdapterName `
            -ErrorAction SilentlyContinue

        if (-not $adapter) {
            $results.Add(
                (
                    New-LabVmActivationRevokeResult `
                        -Name $targetName `
                        -Status Skipped `
                        -Succeeded $true `
                        -Reason 'AlreadyAbsent'
                )
            )

            continue
        }

        if (
            -not $PSCmdlet.ShouldProcess(
                $targetName,
                '평가판 활성화용 임시 어댑터 제거'
            )
        ) {
            $results.Add(
                (
                    New-LabVmActivationRevokeResult `
                        -Name $targetName `
                        -Status Skipped `
                        -Succeeded $true `
                        -Reason 'ShouldProcessDeclined'
                )
            )

            continue
        }

        try {
            Remove-VMNetworkAdapter `
                -VMNetworkAdapter $adapter `
                -ErrorAction Stop

            $results.Add(
                (
                    New-LabVmActivationRevokeResult `
                        -Name $targetName `
                        -Status Revoked `
                        -Succeeded $true `
                        -Reason 'Revoked'
                )
            )
        }
        catch {
            $revokeMessage = (
                "VM '$targetName'의 임시 어댑터 제거 실패: " +
                $_.Exception.Message
            )

            Write-Warning $revokeMessage

            $results.Add(
                (
                    New-LabVmActivationRevokeResult `
                        -Name $targetName `
                        -Status Failed `
                        -Succeeded $false `
                        -Reason 'RevokeException' `
                        -Issues @($revokeMessage) `
                        -ErrorMessage $_.Exception.Message
                )
            )
        }
    }

    $resultArray = @($results)

    $stageStatus = Resolve-LabAggregateStatus `
        -Result $resultArray `
        -Priority 'Failed', 'Revoked' `
        -DefaultStatus 'Skipped'

    $reason = switch ($stageStatus) {
        'Revoked' {
            'Completed'
        }

        'Skipped' {
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
                'AlreadyAbsent'
            }
        }

        'Failed' {
            'RevokeFailed'
        }
    }

    return (
        New-LabStageActivationRevokeResult `
            -Stage $stageLabel `
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

function Complete-LabVmActivation {

    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'ByStage')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'ByStage')]
        [string]$Stage,

        [Parameter(ParameterSetName = 'ByStage')]
        [string[]]$Also,

        [Parameter(Mandatory, ParameterSetName = 'ByName')]
        [ValidateNotNullOrEmpty()]
        [string[]]$Name,

        [securestring]$AdminPassword,

        [ValidateRange(0, 3600)]
        [int]$TimeoutSeconds = 300,

        [ValidateRange(0, 600)]
        [int]$GraceSeconds = 60,

        [ValidateRange(1, 60)]
        [int]$PollIntervalSeconds = 5,

        [System.Collections.IDictionary]$Config
    )

    $cfg = if ($Config) {
        $Config
    }
    else {
        Get-LabConfig
    }

    $stageLabel = if ($PSCmdlet.ParameterSetName -eq 'ByName') {
        ''
    }
    else {
        $Stage
    }

    $targetSplat = if ($PSCmdlet.ParameterSetName -eq 'ByName') {
        @{ Name = $Name }
    }
    else {
        @{ Stage = $Stage; Also = $Also }
    }

    $targetSplat['Config'] = $cfg

    if (
        -not $PSCmdlet.ShouldProcess(
            $(
                if ($PSCmdlet.ParameterSetName -eq 'ByName') {
                    $Name -join ', '
                }
                else {
                    $Stage
                }
            ),
            '평가판 활성화용 임시 네트워크 연결 -> 대기 -> 해제'
        )
    ) {
        return (
            New-LabVmActivationCompletionResult `
                -Stage $stageLabel `
                -Status Skipped `
                -Succeeded $true `
                -Reason 'ShouldProcessDeclined'
        )
    }

    $grantResult = Grant-LabVmActivationNetwork `
        @targetSplat `
        -Confirm:$false

    $pendingNames =
        [Collections.Generic.List[string]]::new()

    foreach (
        $pendingName in
        @(
            $grantResult.Results |
                Where-Object {
                    $_.Status -eq 'Granted'
                } |
                ForEach-Object {
                    [string]$_.Name
                }
        )
    ) {
        $pendingNames.Add($pendingName)
    }

    if ($pendingNames.Count -gt 0) {
        if ($AdminPassword) {
            $credentialCache = @{}

            $activationCheckScript = {
                $product = Get-CimInstance `
                    -ClassName SoftwareLicensingProduct `
                    -Filter 'PartialProductKey is not null' `
                    -ErrorAction Stop |
                    Where-Object {
                        $_.Name -like 'Windows*'
                    } |
                    Select-Object -First 1

                if ($product -and $product.LicenseStatus -ne 1) {
                    & cscript.exe //nologo `
                        "$env:windir\System32\slmgr.vbs" `
                        /ato |
                        Out-Null

                    Start-Sleep -Seconds 5

                    $product = Get-CimInstance `
                        -ClassName SoftwareLicensingProduct `
                        -Filter 'PartialProductKey is not null' `
                        -ErrorAction Stop |
                        Where-Object {
                            $_.Name -like 'Windows*'
                        } |
                        Select-Object -First 1
                }

                [bool](
                    $product -and
                    $product.LicenseStatus -eq 1
                )
            }

            $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

            while (
                $pendingNames.Count -gt 0 -and
                (Get-Date) -lt $deadline
            ) {
                foreach ($pendingName in @($pendingNames)) {
                    if (-not $credentialCache.Contains($pendingName)) {
                        try {
                            $spec = Resolve-LabSingleSpec `
                                -Name $pendingName `
                                -Config $cfg

                            $template = Resolve-LabTemplate `
                                -Name ([string]$spec['Template']) `
                                -Config $cfg

                            $username = if (
                                $template.AccountMode -eq
                                'BuiltInAdministrator'
                            ) {
                                'Administrator'
                            }
                            else {
                                [string]$cfg['LocalAdminName']
                            }

                            $credentialCache[$pendingName] = [pscredential]::new(
                                $username,
                                $AdminPassword
                            )
                        }
                        catch {
                            continue
                        }
                    }

                    try {
                        $licensed = Invoke-Command `
                            -VMName $pendingName `
                            -Credential $credentialCache[$pendingName] `
                            -ScriptBlock $activationCheckScript `
                            -ErrorAction Stop
                    }
                    catch {
                        $licensed = $false
                    }

                    if ($licensed) {
                        [void]$pendingNames.Remove($pendingName)
                    }
                }

                if ($pendingNames.Count -gt 0) {
                    Start-Sleep -Seconds $PollIntervalSeconds
                }
            }
        }
        else {
            $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

            while (
                $pendingNames.Count -gt 0 -and
                (Get-Date) -lt $deadline
            ) {
                foreach ($pendingName in @($pendingNames)) {
                    $adapter = Get-VMNetworkAdapter `
                        -VMName $pendingName `
                        -Name $script:LabActivationAdapterName `
                        -ErrorAction SilentlyContinue

                    $hasUsableAddress = @(
                        $adapter.IPAddresses |
                            Where-Object {
                                $_ -and
                                $_ -ne '0.0.0.0' -and
                                $_ -notlike '169.254.*' -and
                                $_ -notlike 'fe80:*'
                            }
                    ).Count -gt 0

                    if ($hasUsableAddress) {
                        [void]$pendingNames.Remove($pendingName)
                    }
                }

                if ($pendingNames.Count -gt 0) {
                    Start-Sleep -Seconds $PollIntervalSeconds
                }
            }

            if ($GraceSeconds -gt 0) {
                Start-Sleep -Seconds $GraceSeconds
            }
        }
    }

    $timedOutNames = @($pendingNames)

    $revokeResult = Revoke-LabVmActivationNetwork `
        @targetSplat `
        -Confirm:$false

    $succeeded = (
        $grantResult.Succeeded -and
        $revokeResult.Succeeded
    )

    $status = if (-not $succeeded) {
        'Failed'
    }
    elseif ($timedOutNames.Count -gt 0) {
        'TimedOut'
    }
    elseif ($grantResult.Reason -eq 'NoVmDefinitions') {
        'Skipped'
    }
    else {
        'Completed'
    }

    $reason = switch ($status) {
        'Failed' {
            if (-not $grantResult.Succeeded) {
                'GrantFailed'
            }
            else {
                'RevokeFailed'
            }
        }

        'TimedOut' {
            'ActivationWaitTimedOut'
        }

        'Skipped' {
            'NoVmDefinitions'
        }

        'Completed' {
            'Completed'
        }
    }

    return (
        New-LabVmActivationCompletionResult `
            -Stage $stageLabel `
            -Status $status `
            -Succeeded $succeeded `
            -Reason $reason `
            -GrantResult $grantResult `
            -RevokeResult $revokeResult `
            -TimedOutNames $timedOutNames
    )
}

function Complete-LabVmActivationIfNeeded {

    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory)]
        [string[]]$Name,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Config,

        [securestring]$AdminPassword,

        [int]$TimeoutSeconds = 300,

        [int]$GraceSeconds = 60
    )

    $externalSwitchName = $null

    try {
        $externalSwitchName = Get-LabExternalSwitchName `
            -Config $Config
    }
    catch {
        return $null
    }

    $pendingNames = @(
        foreach ($vmName in $Name) {
            $spec = Resolve-LabSingleSpec `
                -Name $vmName `
                -Config $Config

            if (@($spec['Switch']) -contains $externalSwitchName) {
                continue
            }

            $vmTemplate = $null

            try {
                $vmTemplate = Resolve-LabTemplate `
                    -Name ([string]$spec['Template']) `
                    -Config $Config
            }
            catch {
                $vmTemplate = $null
            }

            if (
                $vmTemplate -and
                (
                    Test-LabTemplateIsLinux `
                        -Template $vmTemplate
                )
            ) {
                continue
            }

            $markerPath = Get-LabVmActivationMarkerPath `
                -Name $vmName `
                -Config $Config

            if (Test-Path -LiteralPath $markerPath) {
                continue
            }

            $vmName
        }
    )

    if ($pendingNames.Count -eq 0) {
        return $null
    }

    $activationResult = Complete-LabVmActivation `
        -Name $pendingNames `
        -AdminPassword $AdminPassword `
        -TimeoutSeconds $TimeoutSeconds `
        -GraceSeconds $GraceSeconds `
        -Config $Config `
        -Confirm:$false

    foreach ($vmName in $pendingNames) {
        $markerStatus = if (
            $activationResult.TimedOutNames -contains $vmName
        ) {
            'TimedOut'
        }
        else {
            'Completed'
        }

        try {
            Set-Content `
                -LiteralPath (
                    Get-LabVmActivationMarkerPath `
                        -Name $vmName `
                        -Config $Config
                ) `
                -Value "$markerStatus $(Get-Date -Format o)" `
                -Encoding Ascii `
                -NoNewline `
                -ErrorAction Stop
        }
        catch {
            Write-Warning (
                "VM '$vmName'의 활성화 상태 마커 기록 " +
                "실패: $($_.Exception.Message)"
            )
        }
    }

    $activationResult
}

function Test-LabVmCloudInitApplied {
    <#
    .SYNOPSIS
        게스트가 시드 적용을 마쳤다고 알렸는지 확인한다.
    .DESCRIPTION
        시드 user-data의 마지막 runcmd가 게스트 쪽 KVP 풀에 VM 이름을
        쓴다. runcmd는 cloud-init의 마지막 단계라, 이 값이 보이면 호스트
        이름과 계정 암호 주입이 모두 끝난 뒤다.

        호스트 이름 KVP를 쓰지 않는 이유는 Get-LabVmGuestKvpValue 설명을
        참고한다.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $appliedValue = Get-LabVmGuestKvpValue `
        -Name $Name `
        -Key $script:LabCloudInitAppliedKvpKey

    if ([string]::IsNullOrWhiteSpace($appliedValue)) {
        return $false
    }

    return ($appliedValue -ieq $Name)
}

function Remove-LabVmCloudInitSeed {
    <#
    .SYNOPSIS
        첫 부팅이 끝난 VM에서 cloud-init 시드 디스크를 회수한다.
    .DESCRIPTION
        시드 user-data에는 실습 계정 암호가 평문으로 들어 있고, 쓰이는
        시점은 첫 부팅 한 번뿐이다. 그래서 cloud-init이 값을 적용한 것을
        확인하는 즉시 디스크를 분리하고 VHDX 파일을 지운다.

        Start-LabStage와 New-LabVM -CompleteActivation이 첫 부팅 직후
        이 작업을 자동으로 부르므로 보통은 직접 부를 일이 없다. 게스트가
        제한 시간 안에 응답하지 않아 시드가 남았을 때 다시 시도하는
        용도로 공개해 둔다.

        적용 여부는 게스트가 cloud-init 마지막 단계에서 KVP로 올리는
        완료 표시로 판정한다. 이 표시는 호스트 이름과 계정 암호 주입이
        모두 끝난 뒤에 올라오므로 따로 기다릴 필요가 없다. 게스트가
        느린 환경을 위해 -GraceSeconds를 남겨 두었지만 기본값은 0이다.

        -Force는 이 확인을 건너뛰고 곧바로 회수한다. 첫 부팅이 확실히
        끝난 VM에만 쓴다. 완료 표시를 넣기 전(구 버전 시드)에 만든 VM도
        이 방법으로 회수한다.
    #>
    [CmdletBinding(
        SupportsShouldProcess,
        DefaultParameterSetName = 'ByStage'
    )]
    param(
        [Parameter(Mandatory, ParameterSetName = 'ByStage')]
        [string]$Stage,

        [Parameter(ParameterSetName = 'ByStage')]
        [string[]]$Also,

        [Parameter(Mandatory, ParameterSetName = 'ByName')]
        [ValidateNotNullOrEmpty()]
        [string[]]$Name,

        # cloud-init 적용 확인을 건너뛰고 곧바로 회수한다.
        [switch]$Force,

        [ValidateRange(0, 3600)]
        [int]$TimeoutSeconds = 300,

        [ValidateRange(0, 600)]
        [int]$GraceSeconds = 0,

        [ValidateRange(1, 60)]
        [int]$PollIntervalSeconds = 5,

        [System.Collections.IDictionary]$Config
    )

    $cfg = if ($Config) {
        $Config
    }
    else {
        Get-LabConfig
    }

    $stageLabel = if ($PSCmdlet.ParameterSetName -eq 'ByName') {
        ''
    }
    else {
        $Stage
    }

    $targetNames = if ($PSCmdlet.ParameterSetName -eq 'ByName') {
        @($Name)
    }
    else {
        Assert-LabStageName `
            -Stage $Stage `
            -Config $cfg

        @(
            @(
                Resolve-LabSpec -Stage $Stage -Config $cfg |
                    ForEach-Object {
                        [string]$_['Name']
                    }
            ) +
            @($Also | Select-LabNonEmptyString) |
                Select-Object -Unique
        )
    }

    $results =
        [Collections.Generic.List[object]]::new()

    $seedPaths = @{}

    $waitingNames =
        [Collections.Generic.List[string]]::new()

    $readyNames =
        [Collections.Generic.List[string]]::new()

    foreach ($targetName in $targetNames) {
        $seedPath = (
            Get-LabVmPath `
                -Name $targetName `
                -Config $cfg
        ).SeedVhdPath

        if (-not (Test-Path -LiteralPath $seedPath)) {
            $results.Add(
                (
                    New-LabVmCloudInitSeedResult `
                        -Name $targetName `
                        -Status Skipped `
                        -Succeeded $true `
                        -Reason 'SeedNotFound' `
                        -SeedVhdPath $seedPath
                )
            )

            continue
        }

        if (
            -not $PSCmdlet.ShouldProcess(
                $targetName,
                'cloud-init 시드 디스크 분리 후 삭제'
            )
        ) {
            $results.Add(
                (
                    New-LabVmCloudInitSeedResult `
                        -Name $targetName `
                        -Status Skipped `
                        -Succeeded $true `
                        -Reason 'ShouldProcessDeclined' `
                        -SeedVhdPath $seedPath
                )
            )

            continue
        }

        $seedPaths[$targetName] = $seedPath

        if ($Force) {
            $readyNames.Add($targetName)

            continue
        }

        $vm = Get-LabVmByName -Name $targetName

        if (
            -not $vm -or
            [string]$vm.State -ne 'Running'
        ) {
            $results.Add(
                (
                    New-LabVmCloudInitSeedResult `
                        -Name $targetName `
                        -Status Skipped `
                        -Succeeded $true `
                        -Reason 'GuestNotRunning' `
                        -SeedVhdPath $seedPath
                )
            )

            continue
        }

        $waitingNames.Add($targetName)
    }

    if ($waitingNames.Count -gt 0) {
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

        while ($true) {
            foreach ($waitingName in @($waitingNames)) {
                if (
                    Test-LabVmCloudInitApplied `
                        -Name $waitingName
                ) {
                    $readyNames.Add($waitingName)

                    $waitingNames.Remove($waitingName) |
                        Out-Null
                }
            }

            if (
                $waitingNames.Count -eq 0 -or
                (Get-Date) -ge $deadline
            ) {
                break
            }

            Start-Sleep -Seconds $PollIntervalSeconds
        }

        if (
            $readyNames.Count -gt 0 -and
            $GraceSeconds -gt 0
        ) {
            Start-Sleep -Seconds $GraceSeconds
        }
    }

    foreach ($readyName in $readyNames) {
        try {
            Remove-LabVmCloudInitSeedDisk `
                -Name $readyName `
                -SeedVhdPath $seedPaths[$readyName]

            $results.Add(
                (
                    New-LabVmCloudInitSeedResult `
                        -Name $readyName `
                        -Status Removed `
                        -Succeeded $true `
                        -Reason 'Removed' `
                        -SeedVhdPath $seedPaths[$readyName]
                )
            )
        }
        catch {
            $removeMessage = (
                "VM '$readyName'의 cloud-init 시드 디스크 회수 " +
                "실패: $($_.Exception.Message)"
            )

            Write-Warning $removeMessage

            $results.Add(
                (
                    New-LabVmCloudInitSeedResult `
                        -Name $readyName `
                        -Status Failed `
                        -Succeeded $false `
                        -Reason 'RemoveFailed' `
                        -SeedVhdPath $seedPaths[$readyName] `
                        -Issues @($removeMessage) `
                        -ErrorMessage $_.Exception.Message
                )
            )
        }
    }

    foreach ($timedOutName in $waitingNames) {
        $observedKeys = @(
            Get-LabVmGuestKvpItem -Name $timedOutName |
                ForEach-Object {
                    '{0}={1}' -f $_.Name, $_.Data
                }
        )

        $observedText = if ($observedKeys.Count -gt 0) {
            $observedKeys -join ', '
        }
        else {
            '(없음)'
        }

        $timeoutMessage = (
            "VM '$timedOutName'이 제한 시간 안에 cloud-init 적용을 " +
            '알리지 않아 시드 디스크를 남겨 두었습니다. 호스트가 읽은 ' +
            "게스트 KVP 항목: $observedText. 게스트에서 " +
            "'cloud-init status --long'과 " +
            "'systemctl status hypervkvpd'를 확인하십시오. 적용이 " +
            '끝난 것이 확실하면(완료 표시가 없는 구 버전 시드 포함) ' +
            'Remove-LabVmCloudInitSeed -Force로 회수할 수 있습니다.'
        )

        Write-Warning $timeoutMessage

        $results.Add(
            (
                New-LabVmCloudInitSeedResult `
                    -Name $timedOutName `
                    -Status TimedOut `
                    -Succeeded $true `
                    -Reason 'SeedWaitTimedOut' `
                    -SeedVhdPath $seedPaths[$timedOutName] `
                    -Issues @($timeoutMessage)
            )
        )
    }

    $resultArray = @($results)

    $status = Resolve-LabAggregateStatus `
        -Result $resultArray `
        -Priority 'Failed', 'TimedOut', 'Removed' `
        -DefaultStatus 'Skipped'

    $reason = switch ($status) {
        'Removed' {
            'Completed'
        }

        'TimedOut' {
            'SeedWaitTimedOut'
        }

        'Failed' {
            'RemoveFailed'
        }

        'Skipped' {
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
                'NoSeedDisk'
            }
        }
    }

    return (
        New-LabCloudInitSeedRemovalResult `
            -Stage $stageLabel `
            -Status $status `
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
            -TimedOutNames @($waitingNames)
    )
}

function Complete-LabVmCloudInitSeedIfNeeded {
    <#
    .SYNOPSIS
        방금 부팅한 VM 중 시드 디스크가 남아 있는 것만 회수한다.
    .DESCRIPTION
        Windows 평가판 활성화의 Complete-LabVmActivationIfNeeded와 같은
        자리에서 돌며, 회수할 시드가 하나도 없으면 $null을 돌려준다.

        회수가 끝나면 VHDX 파일이 사라지므로 활성화처럼 별도 마커
        파일을 둘 필요가 없다. 파일이 남아 있다는 것이 곧 아직
        회수하지 않았다는 뜻이다.
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory)]
        [string[]]$Name,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Config,

        [int]$TimeoutSeconds = 300,

        [int]$GraceSeconds = 0
    )

    $pendingNames = @(
        foreach ($vmName in $Name) {
            $seedPath = (
                Get-LabVmPath `
                    -Name $vmName `
                    -Config $Config
            ).SeedVhdPath

            if (Test-Path -LiteralPath $seedPath) {
                $vmName
            }
        }
    )

    if ($pendingNames.Count -eq 0) {
        return $null
    }

    Remove-LabVmCloudInitSeed `
        -Name $pendingNames `
        -Config $Config `
        -TimeoutSeconds $TimeoutSeconds `
        -GraceSeconds $GraceSeconds `
        -Confirm:$false
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
