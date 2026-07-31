Set-StrictMode -Version Latest

# 호스트 VM 이름 색인, Stage 사전검사/생성 결과 매핑,
# Get-LabStatus용 VM 상태 보고서 구성을 담당한다.
# LabVM.psm1이 dot-source하며 모듈 스코프를 공유한다.

function Get-LabHostVmNameIndex {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $byName = @{}
    $duplicateNames =
        [Collections.Generic.List[string]]::new()

    foreach (
        $hostVm in
        @(Get-VM -ErrorAction Stop)
    ) {
        $name = [string]$hostVm.Name

        if ($byName.ContainsKey($name)) {
            if ($duplicateNames -notcontains $name) {
                $duplicateNames.Add($name)
            }
        }
        else {
            $byName[$name] = $hostVm
        }
    }

    foreach ($duplicateName in $duplicateNames) {
        $byName.Remove($duplicateName)
    }

    [pscustomobject]@{
        ByName         = $byName
        DuplicateNames = @($duplicateNames)
    }
}

function Resolve-LabVmPrerequisiteResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [pscustomobject]$Check,

        [object[]]$Warnings = @(),

        [object[]]$Issues = @()
    )

    switch ($Check.Disposition) {
        'Skip' {
            return (
                New-LabVmResult `
                    -Name $Name `
                    -Status Skipped `
                    -Succeeded $true `
                    -Reason 'AlreadyCompliant' `
                    -Warnings $Warnings
            )
        }

        'Conflict' {
            Write-LabPrefixedWarning `
                -Prefix ([string]$Name) `
                -Message $Issues

            return (
                New-LabVmResult `
                    -Name $Name `
                    -Status Conflict `
                    -Succeeded $false `
                    -Reason 'PrerequisiteConflict' `
                    -Issues $Issues `
                    -Warnings $Warnings
            )
        }

        'Failed' {
            Write-LabPrefixedWarning `
                -Prefix ([string]$Name) `
                -Message $Issues

            return (
                New-LabVmResult `
                    -Name $Name `
                    -Status Failed `
                    -Succeeded $false `
                    -Reason 'PrerequisiteFailed' `
                    -Issues $Issues `
                    -Warnings $Warnings `
                    -ErrorMessage (
                        $Issues -join '; '
                    )
            )
        }

        'Create' {
            return $null
        }

        default {
            $message = (
                "Test-LabPrerequisite가 알 수 없는 " +
                "Disposition '$($Check.Disposition)'을 반환했습니다."
            )

            return (
                New-LabVmResult `
                    -Name $Name `
                    -Status Failed `
                    -Succeeded $false `
                    -Reason 'InvalidPrerequisiteResult' `
                    -Issues @($message) `
                    -Warnings $Warnings `
                    -ErrorMessage $message
            )
        }
    }
}

function ConvertTo-LabStagePreflightResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Plan,

        [Parameter(Mandatory)]
        [string]$BlockingNames
    )

    Write-LabPrefixedWarning `
        -Prefix ([string]$Plan.Spec.Name) `
        -Message $Plan.Warnings

    switch ($Plan.Disposition) {
        'Conflict' {
            Write-LabPrefixedWarning `
                -Prefix ([string]$Plan.Spec.Name) `
                -Message $Plan.Issues

            New-LabVmResult `
                -Name $Plan.Spec.Name `
                -Status Conflict `
                -Succeeded $false `
                -Reason 'PrerequisiteConflict' `
                -Issues $Plan.Issues `
                -Warnings $Plan.Warnings
        }

        'Failed' {
            Write-LabPrefixedWarning `
                -Prefix ([string]$Plan.Spec.Name) `
                -Message $Plan.Issues

            $errorMessage = if (
                -not [string]::IsNullOrWhiteSpace(
                    [string]$Plan.ErrorMessage
                )
            ) {
                $Plan.ErrorMessage
            }
            elseif ($Plan.Issues.Count -gt 0) {
                $Plan.Issues -join '; '
            }
            else {
                '알 수 없는 사전 검사 실패'
            }

            New-LabVmResult `
                -Name $Plan.Spec.Name `
                -Status Failed `
                -Succeeded $false `
                -Reason 'PrerequisiteFailed' `
                -Issues $Plan.Issues `
                -Warnings $Plan.Warnings `
                -ErrorMessage $errorMessage
        }

        'Skip' {
            New-LabVmResult `
                -Name $Plan.Spec.Name `
                -Status Skipped `
                -Succeeded $true `
                -Reason 'AlreadyCompliant' `
                -Warnings $Plan.Warnings
        }

        'Create' {
            New-LabVmResult `
                -Name $Plan.Spec.Name `
                -Status Aborted `
                -Succeeded $false `
                -Reason 'StagePreflightFailed' `
                -Issues @(
                    "다른 VM의 사전 검사 실패로 " +
                    "Stage 생성을 중단했습니다: " +
                    $BlockingNames
                ) `
                -Warnings $Plan.Warnings
        }
    }
}

function Get-LabVmStatusReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Spec,

        [AllowNull()]
        [object]$Vm,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Config,

        [switch]$Ambiguous
    )

    $labPaths = Get-LabVmPath `
        -Name ([string]$Spec.Name) `
        -Config $Config

    $configuredDiskPath = $labPaths.VhdPath

    $configuredDiskExists = Test-Path `
        -LiteralPath $configuredDiskPath

    $desiredMemoryGB = ConvertTo-LabGB `
        -Megabyte ([int64]$Spec.MemoryMB)

    $desiredSwitches = @(
        $Spec.Switch |
            Select-LabNonEmptyString -Trim
    )

    $memory = $null
    $networkAdapters = @()
    $actualSwitches = @()
    $hardDiskDrives = @()
    $actualDiskPaths = @()
    $queryError = $null

    if ($Vm) {
        try {
            $memory = Get-VMMemory `
                -VM $Vm `
                -ErrorAction Stop

            $networkAdapters = @(
                Get-VMNetworkAdapter `
                    -VM $Vm `
                    -ErrorAction Stop
            )

            $actualSwitches = @(
                $networkAdapters |
                    ForEach-Object {
                        ConvertTo-LabDisplayText `
                            -Value $_.SwitchName `
                            -Placeholder '<미연결>'
                    }
            )

            $hardDiskDrives = @(
                Get-VMHardDiskDrive `
                    -VM $Vm `
                    -ErrorAction Stop
            )

            $actualDiskPaths = @(
                $hardDiskDrives |
                    ForEach-Object {
                        ConvertTo-LabDisplayText `
                            -Value $_.Path `
                            -Placeholder '<경로 없음>'
                    }
            )
        }
        catch {
            $queryError = $_.Exception.Message
        }
    }

    $driftReasons = [Collections.Generic.List[string]]::new()

    if ($Ambiguous) {
        $driftReasons.Add(
            '동일한 이름의 Hyper-V VM이 여러 개 있어 상태를 확인할 수 없습니다.'
        )
    }
    elseif (-not $Vm) {
        $driftReasons.Add('VM 없음')
    }
    elseif ($queryError) {
        $driftReasons.Add(
            "상태 조회 실패: $queryError"
        )
    }
    else {
        try {
            $template = Resolve-LabTemplate `
                -Name ([string]$Spec['Template']) `
                -Config $Config

            $expectedVmPath = $labPaths.VmPath

            $compliance =
                Test-LabExistingVmCompliance `
                    -Spec $Spec `
                    -VM $Vm `
                    -Template $template `
                    -ExpectedVhdPath $configuredDiskPath `
                    -ExpectedVmPath $expectedVmPath `
                    -Memory $memory `
                    -NetworkAdapters $networkAdapters `
                    -HardDiskDrives $hardDiskDrives

            foreach ($reason in @($compliance.Drift)) {
                $driftReasons.Add([string]$reason.Message)
            }
        }
        catch {
            $driftReasons.Add(
                "Compliance 검사 실패: $($_.Exception.Message)"
            )
        }
    }

    $actualMemoryGB = if ($memory) {
        ConvertTo-LabGB `
            -Byte ([int64]$memory.Startup)
    }
    else {
        $null
    }

    $assignedMemoryGB = if ($Vm) {
        ConvertTo-LabGB `
            -Byte ([int64]$Vm.MemoryAssigned)
    }
    else {
        $null
    }

    [pscustomobject]@{
        PSTypeName = 'Lab.StatusReport'
        Stage    = $Spec.Stage
        Name     = $Spec.Name
        Template = $Spec.Template

        State = if ($Vm) {
            $Vm.State
        }
        else {
            '미생성'
        }

        DesiredvCPU = [int]$Spec.CPU

        ActualvCPU = if ($Vm) {
            [int]$Vm.ProcessorCount
        }
        else {
            $null
        }

        DesiredMemoryGB = $desiredMemoryGB
        ActualMemoryGB  = $actualMemoryGB
        AssignedMemoryGB = $assignedMemoryGB

        DynamicMemory = if ($memory) {
            $memory.DynamicMemoryEnabled
        }
        else {
            $null
        }

        DesiredSwitches = if (
            $desiredSwitches.Count -gt 0
        ) {
            $desiredSwitches -join ', '
        }
        else {
            'NIC 없음'
        }

        ActualSwitches = if (-not $Vm) {
            $null
        }
        elseif ($actualSwitches.Count -gt 0) {
            $actualSwitches -join ', '
        }
        else {
            'NIC 없음'
        }

        ConfiguredDiskPath   = $configuredDiskPath
        ConfiguredDiskExists = $configuredDiskExists

        ActualDiskPath = if (-not $Vm) {
            $null
        }
        elseif ($actualDiskPaths.Count -gt 0) {
            $actualDiskPaths -join ', '
        }
        else {
            '연결된 VHDX 없음'
        }

        Drift = if ($driftReasons.Count -gt 0) {
            $driftReasons -join '; '
        }
        else {
            '없음'
        }
    }
}
