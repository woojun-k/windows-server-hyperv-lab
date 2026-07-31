Set-StrictMode -Version Latest

# 오케스트레이션 함수가 반환하는 Lab.*Result 계약을 만든다.
# LabVM.psm1이 dot-source하며 모듈 스코프를 공유한다.


function New-LabVmResult {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessage(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = '메모리 내 결과 객체만 생성하며 외부 상태를 변경하지 않는다.'
    )]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidateSet(
            'Created',
            'Skipped',
            'Aborted',
            'Conflict',
            'Failed'
        )]
        [string]$Status,

        [Parameter(Mandatory)]
        [bool]$Succeeded,

        [ValidateSet(
            'AlreadyCompliant',
            'PrerequisiteConflict',
            'PrerequisiteFailed',
            'InvalidPrerequisiteResult',
            'StagePreflightFailed',
            'InvalidSpec',
            'PrerequisiteException',
            'Reconciled',
            'ReconciliationIncomplete',
            'ShouldProcessDeclined',
            'Created',
            'CreationFailedRollbackIncomplete',
            'CreationException',
            'PreviousVmFailed',
            'UnhandledException'
        )]
        [string]$Reason,

        [object[]]$Issues = @(),

        [object[]]$Warnings = @(),

        [string]$ErrorMessage,

        # Created 상태에서만 의미가 있다. 콘솔 출력이
        # 이 값들로 표시를 재구성할 수 있도록 결과 계약에 담아 둔다.
        [Nullable[int]]$CPU,

        [Nullable[int64]]$MemoryMB,

        [string[]]$Switches = @()
    )

    Assert-LabResultContract `
        -Kind 'VM 결과' `
        -Status $Status `
        -Succeeded $Succeeded `
        -SuccessStatus 'Created', 'Skipped'

    [pscustomobject]@{
        PSTypeName = 'Lab.VmCreationResult'
        Name        = $Name
        Status      = $Status
        Succeeded   = $Succeeded
        Reason      = $Reason
        Issues      = @($Issues)
        Warnings    = @($Warnings)
        Error       = $ErrorMessage
        CPU         = $CPU
        MemoryMB    = $MemoryMB
        Switches    = @($Switches)
    }
}

function New-LabStageResult {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessage(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = '메모리 내 결과 객체만 생성하며 외부 상태를 변경하지 않는다.'
    )]
    param(
        [Parameter(Mandatory)]
        [string]$Stage,

        [Parameter(Mandatory)]
        [ValidateSet(
            'Created',
            'Skipped',
            'Aborted',
            'Conflict',
            'Failed'
        )]
        [string]$Status,

        [Parameter(Mandatory)]
        [bool]$Succeeded,

        [ValidateSet(
            'InfrastructureOnlyStage',
            'NoVmDefinitions',
            'AlreadyCompliant',
            'PreflightFailed',
            'ShouldProcessDeclined',
            'Completed',
            'ExecutionAborted',
            'ConcurrentConflict',
            'ExecutionFailed'
        )]
        [string]$Reason,

        [object[]]$Results = @(),

        [object[]]$RequiredSwitches = @(),

        [object[]]$RollbackResults = @()
    )

    Assert-LabResultContract `
        -Kind 'Stage 결과' `
        -Status $Status `
        -Succeeded $Succeeded `
        -SuccessStatus 'Created', 'Skipped'

    [pscustomobject]@{
        PSTypeName      = 'Lab.StageCreationResult'
        Stage           = $Stage
        Status          = $Status
        Succeeded       = $Succeeded
        Reason          = $Reason

        CreatedCount    = Get-LabStatusCount `
            -Result $Results `
            -Status 'Created'

        SkippedCount    = Get-LabStatusCount `
            -Result $Results `
            -Status 'Skipped'

        ReconciledCount = Get-LabStatusCount `
            -Result $Results `
            -Status 'Reconciled' `
            -Property 'Reason'

        AbortedCount    = Get-LabStatusCount `
            -Result $Results `
            -Status 'Aborted'

        ConflictCount   = Get-LabStatusCount `
            -Result $Results `
            -Status 'Conflict'

        FailedCount     = Get-LabStatusCount `
            -Result $Results `
            -Status 'Failed'

        Results         = @($Results)
        RequiredSwitches = @($RequiredSwitches)

        RollbackResults = @($RollbackResults)

        RollbackFailedCount = Get-LabStatusCount `
            -Result $RollbackResults `
            -Status 'Failed'

        RollbackRemovedCount = Get-LabStatusCount `
            -Result $RollbackResults `
            -Status 'Removed'

        RetainedCreatedCount = [math]::Max(
            0,
            (
                Get-LabStatusCount `
                    -Result $Results `
                    -Status 'Created'
            ) -
            (
                Get-LabStatusCount `
                    -Result $RollbackResults `
                    -Status 'Removed'
            )
        )
    }
}

function New-LabVmRemovalResult {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessage(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = '메모리 내 결과 객체만 생성하며 외부 상태를 변경하지 않는다.'
    )]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidateSet(
            'Removed',
            'Skipped',
            'Failed'
        )]
        [string]$Status,

        [Parameter(Mandatory)]
        [bool]$Succeeded,

        [ValidateSet(
            'HasCheckpoints',
            'ExternalVmConfigurationPath',
            'ExternalDiskInsideVmPath',
            'ExternalResourcesDetected',
            'VmRunning',
            'VhdUsedByOtherVm',
            'VmPathUsedByOtherVm',
            'VhdAttachedExternally',
            'RemovalPreflightException',
            'Removed',
            'VmLookupException',
            'AlreadyAbsent',
            'ShouldProcessDeclined',
            'RemovalException'
        )]
        [string]$Reason,

        [object[]]$RemovedPaths = @(),

        [object[]]$PreservedPaths = @(),

        [object[]]$Issues = @(),

        [string]$ErrorMessage
    )

    Assert-LabResultContract `
        -Kind 'VM 제거 결과' `
        -Status $Status `
        -Succeeded $Succeeded `
        -SuccessStatus 'Removed', 'Skipped'

    [pscustomobject]@{
        PSTypeName     = 'Lab.VmRemovalResult'
        Name           = $Name
        Status         = $Status
        Succeeded      = $Succeeded
        Reason         = $Reason
        RemovedPaths   = @($RemovedPaths)
        PreservedPaths = @($PreservedPaths)
        Issues         = @($Issues)
        Error          = $ErrorMessage
    }
}

function New-LabStageResetResult {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessage(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = '메모리 내 결과 객체만 생성하며 외부 상태를 변경하지 않는다.'
    )]
    param(
        [Parameter(Mandatory)]
        [string]$Stage,

        [Parameter(Mandatory)]
        [ValidateSet(
            'Removed',
            'Skipped',
            'Failed'
        )]
        [string]$Status,

        [Parameter(Mandatory)]
        [bool]$Succeeded,

        [ValidateSet(
            'NoVmDefinitions',
            'ShouldProcessDeclined',
            'PartialFailure',
            'Removed',
            'AlreadyAbsent'
        )]
        [string]$Reason,

        [object[]]$Results = @()
    )

    Assert-LabResultContract `
        -Kind 'Stage 초기화 결과' `
        -Status $Status `
        -Succeeded $Succeeded `
        -SuccessStatus 'Removed', 'Skipped'

    [pscustomobject]@{
        PSTypeName   = 'Lab.StageResetResult'
        Stage        = $Stage
        Status       = $Status
        Succeeded    = $Succeeded
        Reason       = $Reason

        RemovedCount = Get-LabStatusCount `
            -Result $Results `
            -Status 'Removed'

        SkippedCount = Get-LabStatusCount `
            -Result $Results `
            -Status 'Skipped'

        FailedCount  = Get-LabStatusCount `
            -Result $Results `
            -Status 'Failed'

        Results = @($Results)
    }
}

function New-LabVmStartResult {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessage(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = '메모리 내 결과 객체만 생성하며 외부 상태를 변경하지 않는다.'
    )]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidateSet(
            'Started',
            'Skipped',
            'Aborted',
            'Failed'
        )]
        [string]$Status,

        [Parameter(Mandatory)]
        [bool]$Succeeded,

        [ValidateSet(
            'VmNotFound',
            'AmbiguousVmName',
            'StagePreflightFailed',
            'AlreadyRunning',
            'InsufficientHostMemory',
            'ShouldProcessDeclined',
            'Started',
            'StartException'
        )]
        [string]$Reason,

        [string]$State,

        [int64]$MemoryStartupBytes = 0,

        [object[]]$Issues = @(),

        [string]$ErrorMessage
    )

    Assert-LabResultContract `
        -Kind 'VM 시작 결과' `
        -Status $Status `
        -Succeeded $Succeeded `
        -SuccessStatus 'Started', 'Skipped'

    [pscustomobject]@{
        PSTypeName         = 'Lab.VmStartResult'
        Name               = $Name
        Status             = $Status
        Succeeded          = $Succeeded
        Reason             = $Reason
        State              = $State
        MemoryStartupBytes = $MemoryStartupBytes
        Issues             = @($Issues)
        Error              = $ErrorMessage
    }
}

function New-LabStageStartResult {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessage(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = '메모리 내 결과 객체만 생성하며 외부 상태를 변경하지 않는다.'
    )]
    param(
        [Parameter(Mandatory)]
        [string]$Stage,

        [Parameter(Mandatory)]
        [ValidateSet(
            'Started',
            'Skipped',
            'Aborted',
            'Failed'
        )]
        [string]$Status,

        [Parameter(Mandatory)]
        [bool]$Succeeded,

        [ValidateSet(
            'SwitchPreflightFailed',
            'InfrastructureOnlyStage',
            'NoVmDefinitions',
            'StagePreflightFailed',
            'Completed',
            'ShouldProcessDeclined',
            'AlreadyRunning',
            'InsufficientHostMemory',
            'StartFailed'
        )]
        [string]$Reason,

        [object[]]$Results = @(),

        [object[]]$RequiredSwitches = @(),

        [psobject]$MemoryBudget
    )

    Assert-LabResultContract `
        -Kind 'Stage 시작 결과' `
        -Status $Status `
        -Succeeded $Succeeded `
        -SuccessStatus 'Started', 'Skipped'

    [pscustomobject]@{
        PSTypeName   = 'Lab.StageStartResult'
        Stage        = $Stage
        Status       = $Status
        Succeeded    = $Succeeded
        Reason       = $Reason

        StartedCount = Get-LabStatusCount `
            -Result $Results `
            -Status 'Started'

        SkippedCount = Get-LabStatusCount `
            -Result $Results `
            -Status 'Skipped'

        AbortedCount = Get-LabStatusCount `
            -Result $Results `
            -Status 'Aborted'

        FailedCount  = Get-LabStatusCount `
            -Result $Results `
            -Status 'Failed'

        Results          = @($Results)
        RequiredSwitches = @($RequiredSwitches)
        MemoryBudget     = $MemoryBudget
    }
}

function New-LabVmStopResult {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessage(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = '메모리 내 결과 객체만 생성하며 외부 상태를 변경하지 않는다.'
    )]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidateSet(
            'Stopped',
            'Skipped',
            'Failed'
        )]
        [string]$Status,

        [Parameter(Mandatory)]
        [bool]$Succeeded,

        [ValidateSet(
            'VmNotFound',
            'AmbiguousVmName',
            'AlreadyOff',
            'ShouldProcessDeclined',
            'Stopped',
            'StopException'
        )]
        [string]$Reason,

        [string]$State,

        [object[]]$Issues = @(),

        [string]$ErrorMessage
    )

    Assert-LabResultContract `
        -Kind 'VM 종료 결과' `
        -Status $Status `
        -Succeeded $Succeeded `
        -SuccessStatus 'Stopped', 'Skipped'

    [pscustomobject]@{
        PSTypeName = 'Lab.VmStopResult'
        Name       = $Name
        Status     = $Status
        Succeeded  = $Succeeded
        Reason     = $Reason
        State      = $State
        Issues     = @($Issues)
        Error      = $ErrorMessage
    }
}

function New-LabStageStopResult {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessage(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = '메모리 내 결과 객체만 생성하며 외부 상태를 변경하지 않는다.'
    )]
    param(
        [Parameter(Mandatory)]
        [string]$Stage,

        [Parameter(Mandatory)]
        [ValidateSet(
            'Stopped',
            'Skipped',
            'Failed'
        )]
        [string]$Status,

        [Parameter(Mandatory)]
        [bool]$Succeeded,

        [ValidateSet(
            'NoVmDefinitions',
            'Completed',
            'ShouldProcessDeclined',
            'AlreadyOff',
            'StopFailed'
        )]
        [string]$Reason,

        [object[]]$Results = @()
    )

    Assert-LabResultContract `
        -Kind 'Stage 종료 결과' `
        -Status $Status `
        -Succeeded $Succeeded `
        -SuccessStatus 'Stopped', 'Skipped'

    [pscustomobject]@{
        PSTypeName   = 'Lab.StageStopResult'
        Stage        = $Stage
        Status       = $Status
        Succeeded    = $Succeeded
        Reason       = $Reason

        StoppedCount = Get-LabStatusCount `
            -Result $Results `
            -Status 'Stopped'

        SkippedCount = Get-LabStatusCount `
            -Result $Results `
            -Status 'Skipped'

        FailedCount  = Get-LabStatusCount `
            -Result $Results `
            -Status 'Failed'

        Results = @($Results)
    }
}

