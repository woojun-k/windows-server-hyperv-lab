Set-StrictMode -Version Latest

# New-LabVM 생성 실행(디스크/하드웨어/네트워크)과 롤백,
# 기존 VM 드리프트 교정을 담당한다.
# LabVM.psm1이 dot-source하며 모듈 스코프를 공유한다.

function Invoke-LabVmCreationRollback {
    [CmdletBinding()]
    [OutputType([array])]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [hashtable]$State,

        [Parameter(Mandatory)]
        [string]$ChildVhdPath,

        [Parameter(Mandatory)]
        [string]$StagedChildVhdPath,

        [Parameter(Mandatory)]
        [string]$VmPath,

        [Parameter(Mandatory)]
        [string]$VhdDirectory
    )

    $rollbackIssues =
        [Collections.Generic.List[string]]::new()

    $vmRegistrationRemoved = -not $State.CreatedVm

    if ($State.CreatedVm) {
        # 조회 실패를 "VM 등록 없음"으로 오판하면 안 된다. 조회 자체가
        # 실패하면(Hyper-V 서비스 문제 등) VM 등록이 남아 있을 수 있으므로
        # VHDX와 디렉터리를 삭제하지 않고 보존해야 한다.
        try {
            $allVms = @(
                Get-VM -ErrorAction Stop
            )
        }
        catch {
            $rollbackIssues.Add(
                'VM 등록 상태를 확인하지 못해 VHDX와 구성 ' +
                "디렉터리를 보존했습니다: $($_.Exception.Message)"
            )

            return ,$rollbackIssues.ToArray()
        }

        $createdVm = if ($State.CreatedVmId) {
            $allVms |
                Where-Object {
                    $_.Id -eq $State.CreatedVmId
                } |
                Select-Object -First 1
        }
        else {
            $allVms |
                Where-Object {
                    $_.Name -eq $Name
                } |
                Select-Object -First 1
        }

        if (-not $createdVm) {
            $vmRegistrationRemoved = $true
        }
        else {
            try {
                Remove-VM `
                    -VM $createdVm `
                    -Force `
                    -ErrorAction Stop

                $vmRegistrationRemoved = $true
            }
            catch {
                $rollbackIssues.Add(
                    "VM 등록 롤백 실패: $($_.Exception.Message)"
                )
            }
        }
    }

    if (Test-Path -LiteralPath $StagedChildVhdPath) {
        try {
            Remove-Item `
                -LiteralPath $StagedChildVhdPath `
                -Force `
                -ErrorAction Stop
        }
        catch {
            $rollbackIssues.Add(
                "임시 VHDX 롤백 실패: $($_.Exception.Message)"
            )
        }
    }

    if (-not $vmRegistrationRemoved) {
        $rollbackIssues.Add(
            'VM 등록이 남아 있으므로 VHDX와 구성 디렉터리를 보존했습니다.'
        )

        return ,$rollbackIssues.ToArray()
    }

    if (
        $State.CreatedChildVhd -and
        (Test-Path -LiteralPath $ChildVhdPath)
    ) {
        try {
            $childVhdState = Get-VHD `
                -Path $ChildVhdPath `
                -ErrorAction SilentlyContinue

            if ($childVhdState -and $childVhdState.Attached) {
                Dismount-VHD `
                    -Path $ChildVhdPath `
                    -ErrorAction Stop
            }

            Remove-Item `
                -LiteralPath $ChildVhdPath `
                -Force `
                -ErrorAction Stop
        }
        catch {
            $rollbackIssues.Add(
                "자식 VHDX 롤백 실패: $($_.Exception.Message)"
            )
        }
    }

    if (
        $State.CreatedVmPath -and
        (Test-Path -LiteralPath $VmPath)
    ) {
        $ownershipMarkerPath = Join-Path `
            $VmPath `
            '.labvm-creation-owner'

        $ownershipConfirmed = $false

        if (Test-Path -LiteralPath $ownershipMarkerPath) {
            try {
                $markerValue = (
                    Get-Content `
                        -LiteralPath $ownershipMarkerPath `
                        -Raw `
                        -ErrorAction Stop
                ).Trim()

                $ownershipConfirmed =
                    ($markerValue -eq $State.OperationId)
            }
            catch {
                $ownershipConfirmed = $false
            }
        }

        if ($ownershipConfirmed) {
            try {
                Remove-Item `
                    -LiteralPath $VmPath `
                    -Recurse `
                    -Force `
                    -ErrorAction Stop
            }
            catch {
                $rollbackIssues.Add(
                    "VM 구성 디렉터리 롤백 실패: $($_.Exception.Message)"
                )
            }
        }
        else {
            $rollbackIssues.Add(
                'VM 구성 디렉터리의 소유권 marker가 없거나 일치하지 ' +
                "않아 삭제하지 않고 보존했습니다: $VmPath"
            )
        }
    }

    if (
        $State.CreatedVhdDirectory -and
        (Test-Path -LiteralPath $VhdDirectory)
    ) {
        $remainingItems = @(
            Get-ChildItem `
                -LiteralPath $VhdDirectory `
                -Force `
                -ErrorAction SilentlyContinue
        )

        if ($remainingItems.Count -eq 0) {
            try {
                Remove-Item `
                    -LiteralPath $VhdDirectory `
                    -Force `
                    -ErrorAction Stop
            }
            catch {
                $rollbackIssues.Add(
                    "VHDX 디렉터리 롤백 실패: $($_.Exception.Message)"
                )
            }
        }
    }

    ,$rollbackIssues.ToArray()
}

function Repair-LabVmDrift {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessage(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = '호출자인 New-LabVM이 ShouldProcess 확인을 이미 거친 뒤에만 호출하는 내부 헬퍼다.'
    )]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Spec,

        # Test-LabExistingVmCompliance가 반환한 구조화된 드리프트 중
        # Fixable=$true인 항목만 전달받는다.
        [AllowEmptyCollection()]
        [object[]]$Drift = @()
    )

    $applied =
        [Collections.Generic.List[string]]::new()

    $remaining =
        [Collections.Generic.List[string]]::new()

    foreach ($item in $Drift) {
        try {
            # Category → Repair 매핑은 $script:LabDriftRuleTable(LabVM.Checks.ps1)
            # 한 곳에서만 정의한다. 여기서 별도 switch로 다시 나열하면 신규
            # Category 추가 시 한쪽만 갱신하고 잊어버릴 수 있다.
            $rule = $script:LabDriftRuleTable[$item.Category]

            if (-not $rule -or -not $rule.Repair) {
                throw (
                    "교정 방법이 정의되지 않은 드리프트 " +
                    "범주입니다: $($item.Category)"
                )
            }

            & $rule.Repair $Spec $item

            $applied.Add([string]$item.Message)
        }
        catch {
            $remaining.Add(
                "$($item.Message) (교정 실패: " +
                "$($_.Exception.Message))"
            )
        }
    }

    [pscustomobject]@{
        Applied   = @($applied)
        Remaining = @($remaining)
    }
}

function New-LabVmDiskArtifact {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessage(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = '호출자인 New-LabVM이 ShouldProcess 확인을 이미 거친 뒤에만 호출하는 내부 헬퍼다.'
    )]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Check,

        [Parameter(Mandatory)]
        [bool]$IsFullCopy,

        [Parameter(Mandatory)]
        [string]$VhdDirectory,

        [Parameter(Mandatory)]
        [string]$VmPath,

        [Parameter(Mandatory)]
        [string]$ChildVhdPath,

        [Parameter(Mandatory)]
        [string]$StagedChildVhdPath,

        [Parameter(Mandatory)]
        [hashtable]$State
    )

    if (-not (Test-Path -LiteralPath $VhdDirectory)) {
        New-Item `
            -Path $VhdDirectory `
            -ItemType Directory `
            -ErrorAction Stop |
            Out-Null

        $State.CreatedVhdDirectory = $true
    }

    # 사전 검사 이후 경로가 새로 생기는 경쟁 조건도 -Force 없이 차단한다.
    New-Item `
        -Path $VmPath `
        -ItemType Directory `
        -ErrorAction Stop |
        Out-Null

    $State.CreatedVmPath = $true

    # 롤백이 이 디렉터리를 재귀 삭제해도 되는지 판단할 수 있도록
    # 소유권 marker를 남긴다. 롤백 시점에 marker가 없거나 값이 다르면
    # 다른 프로세스가 같은 경로에 손을 댔다는 뜻이므로 삭제하지 않는다.
    Set-Content `
        -LiteralPath (
            Join-Path $VmPath '.labvm-creation-owner'
        ) `
        -Value $State.OperationId `
        -Encoding Ascii `
        -NoNewline `
        -ErrorAction Stop

    if ($IsFullCopy) {
        Copy-Item `
            -LiteralPath $Check.Template.VhdPath `
            -Destination $StagedChildVhdPath `
            -ErrorAction Stop

        (
            Get-Item `
                -LiteralPath $StagedChildVhdPath
        ).IsReadOnly = $false
    }
    else {
        New-VHD `
            -Differencing `
            -ParentPath $Check.Template.VhdPath `
            -Path $StagedChildVhdPath `
            -ErrorAction Stop |
            Out-Null
    }

    $State.CreatedChildVhd = $true

    Move-Item `
        -LiteralPath $StagedChildVhdPath `
        -Destination $ChildVhdPath `
        -ErrorAction Stop
}

function Set-LabVmHardwareProfile {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessage(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = '호출자인 New-LabVM이 ShouldProcess 확인을 이미 거친 뒤에만 호출하는 내부 헬퍼다.'
    )]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Spec,

        [Parameter(Mandatory)]
        [pscustomobject]$Check,

        [Parameter(Mandatory)]
        [int64]$MemoryBytes,

        [Parameter(Mandatory)]
        [string]$ChildVhdPath,

        [Parameter(Mandatory)]
        [string]$VmPath,

        [Parameter(Mandatory)]
        [hashtable]$State
    )

    $createdVm = New-VM `
        -Name $Spec.Name `
        -Generation 2 `
        -MemoryStartupBytes $MemoryBytes `
        -VHDPath $ChildVhdPath `
        -Path (Split-Path -Path $VmPath -Parent) `
        -ErrorAction Stop

    $State.CreatedVm   = $true
    $State.CreatedVmId = $createdVm.Id

    Set-VMProcessor `
        -VMName $Spec.Name `
        -Count $Spec.CPU `
        -ErrorAction Stop

    Set-VMMemory `
        -VMName $Spec.Name `
        -DynamicMemoryEnabled $false `
        -StartupBytes $MemoryBytes `
        -ErrorAction Stop

    if ([bool]$Spec['NestedVirtualization']) {
        Set-VMProcessor `
            -VMName $Spec.Name `
            -ExposeVirtualizationExtensions $true `
            -ErrorAction Stop
    }

    Set-VM `
        -Name $Spec.Name `
        -AutomaticStartAction Nothing `
        -AutomaticStopAction ShutDown `
        -AutomaticCheckpointsEnabled $false `
        -CheckpointType Production `
        -ErrorAction Stop

    if ($Check.Template.SecureBoot) {
        Set-VMFirmware `
            -VMName $Spec.Name `
            -EnableSecureBoot On `
            -SecureBootTemplate MicrosoftWindows `
            -ErrorAction Stop
    }
    else {
        Set-VMFirmware `
            -VMName $Spec.Name `
            -EnableSecureBoot Off `
            -ErrorAction Stop
    }

    if ($Check.Template.EnableTpm) {
        Set-VMKeyProtector `
            -VMName $Spec.Name `
            -NewLocalKeyProtector `
            -ErrorAction Stop

        Enable-VMTPM `
            -VMName $Spec.Name `
            -ErrorAction Stop
    }
}

function Set-LabVmNetworkAdapter {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessage(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = '호출자인 New-LabVM이 ShouldProcess 확인을 이미 거친 뒤에만 호출하는 내부 헬퍼다.'
    )]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Spec,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Switches
    )

    $primaryAdapter = Get-VMNetworkAdapter `
        -VMName $Spec.Name |
        Select-Object -First 1

    if ($Switches.Count -eq 0) {
        if ($primaryAdapter) {
            Remove-VMNetworkAdapter `
                -VMNetworkAdapter $primaryAdapter `
                -ErrorAction Stop
        }
    }
    else {
        if (-not $primaryAdapter) {
            throw "VM '$($Spec.Name)'에 기본 네트워크 어댑터가 없습니다."
        }

        Connect-VMNetworkAdapter `
            -VMNetworkAdapter $primaryAdapter `
            -SwitchName $Switches[0] `
            -ErrorAction Stop

        Rename-VMNetworkAdapter `
            -VMNetworkAdapter $primaryAdapter `
            -NewName $Switches[0] `
            -ErrorAction Stop

        foreach (
            $sw in (
                $Switches |
                    Select-Object -Skip 1
            )
        ) {
            Add-VMNetworkAdapter `
                -VMName $Spec.Name `
                -Name $sw `
                -SwitchName $sw `
                -ErrorAction Stop
        }
    }

    foreach (
        $adapterName in @(
            $Spec['MacSpoofingSwitches'] |
                Select-LabNonEmptyString
        )
    ) {
        $adapter = Get-VMNetworkAdapter `
            -VMName $Spec.Name `
            -Name $adapterName `
            -ErrorAction SilentlyContinue

        if ($adapter) {
            Set-VMNetworkAdapter `
                -VMNetworkAdapter $adapter `
                -MacAddressSpoofing On `
                -ErrorAction Stop
        }
    }
}
