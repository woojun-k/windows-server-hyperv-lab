Set-StrictMode -Version Latest

# 기존 VM 구성이 LabConfig와 일치하는지, VM 생성 사전 조건이
# 충족되는지 검사한다. LabVM.psm1이 dot-source하며 모듈
# 스코프를 공유한다.

# 교정 가능한 드리프트 Category의 단일 정의. RequiresOff/Repair를 여기
# 한 곳에만 두어, Test-LabExistingVmCompliance(생산자)와
# Repair-LabVmDrift(소비자)가 서로 다른 Category 집합을 갖는 문제를 막는다.
# Category가 이 표에 없으면 애초에 교정 대상이 아니다(Fixable=$false).
$script:LabDriftRuleTable = [ordered]@{
    CPU = @{
        # RequiresOff=$true인 Category는 VM이 꺼져 있어야만 안전하게 교정할 수 있다.
        RequiresOff = $true
        Expected    = { param($Spec, $VM, $Memory) [int]$Spec['CPU'] }
        Actual      = { param($Spec, $VM, $Memory) [int]$VM.ProcessorCount }
        Format      = { param($e, $a) "vCPU 불일치: 설정=$e, 실제=$a" }
        Repair      = {
            param($Spec, $Item)
            Set-VMProcessor `
                -VMName ([string]$Spec['Name']) `
                -Count ([int]$Spec['CPU']) `
                -ErrorAction Stop
        }
    }

    Memory = @{
        RequiresOff = $true
        Expected    = { param($Spec, $VM, $Memory) [int64]$Spec['MemoryMB'] * 1MB }
        Actual      = { param($Spec, $VM, $Memory) [int64]$Memory.Startup }
        Format      = {
            param($e, $a)
            "메모리 불일치: 설정=$([math]::Round($e / 1GB, 1))GB, " +
            "실제=$([math]::Round($a / 1GB, 1))GB"
        }
        Repair      = {
            param($Spec, $Item)
            Set-VMMemory `
                -VMName ([string]$Spec['Name']) `
                -StartupBytes ([int64]$Spec['MemoryMB'] * 1MB) `
                -ErrorAction Stop
        }
    }

    DynamicMemory = @{
        RequiresOff = $true
        Expected    = { param($Spec, $VM, $Memory) $false }
        Actual      = { param($Spec, $VM, $Memory) [bool]$Memory.DynamicMemoryEnabled }
        Format      = { param($e, $a) '동적 메모리가 활성화되어 있습니다.' }
        Repair      = {
            param($Spec, $Item)
            Set-VMMemory `
                -VMName ([string]$Spec['Name']) `
                -DynamicMemoryEnabled $false `
                -ErrorAction Stop
        }
    }

    AutoStart = @{
        RequiresOff = $false
        Expected    = { param($Spec, $VM, $Memory) 'Nothing' }
        Actual      = { param($Spec, $VM, $Memory) $VM.AutomaticStartAction.ToString() }
        Format      = { param($e, $a) "자동 시작 동작 불일치: 설정=$e, 실제=$a" }
        Repair      = {
            param($Spec, $Item)
            Set-VM `
                -Name ([string]$Spec['Name']) `
                -AutomaticStartAction Nothing `
                -ErrorAction Stop
        }
    }

    AutoStop = @{
        RequiresOff = $false
        Expected    = { param($Spec, $VM, $Memory) 'ShutDown' }
        Actual      = { param($Spec, $VM, $Memory) $VM.AutomaticStopAction.ToString() }
        Format      = { param($e, $a) "자동 종료 동작 불일치: 설정=$e, 실제=$a" }
        Repair      = {
            param($Spec, $Item)
            Set-VM `
                -Name ([string]$Spec['Name']) `
                -AutomaticStopAction ShutDown `
                -ErrorAction Stop
        }
    }

    AutoCheckpoints = @{
        RequiresOff = $false
        Expected    = { param($Spec, $VM, $Memory) $false }
        Actual      = { param($Spec, $VM, $Memory) [bool]$VM.AutomaticCheckpointsEnabled }
        Format      = { param($e, $a) '자동 체크포인트가 활성화되어 있습니다.' }
        Repair      = {
            param($Spec, $Item)
            Set-VM `
                -Name ([string]$Spec['Name']) `
                -AutomaticCheckpointsEnabled $false `
                -ErrorAction Stop
        }
    }

    CheckpointType = @{
        RequiresOff = $true
        Expected    = { param($Spec, $VM, $Memory) 'Production' }
        Actual      = { param($Spec, $VM, $Memory) $VM.CheckpointType.ToString() }
        Format      = { param($e, $a) "체크포인트 유형 불일치: 설정=$e, 실제=$a" }
        Repair      = {
            param($Spec, $Item)
            Set-VM `
                -Name ([string]$Spec['Name']) `
                -CheckpointType Production `
                -ErrorAction Stop
        }
    }

    # Expected/Actual/Format이 없다: 어댑터별로 반복 검사해야 해서
    # 스칼라 비교로 표현할 수 없다. 네트워크 어댑터 루프에서 직접
    # Add-LabDrift를 호출하고, 교정만 이 표의 Repair를 공유한다.
    MacSpoofing = @{
        RequiresOff = $false
        Repair      = {
            param($Spec, $Item)

            $adapter = Get-VMNetworkAdapter `
                -VMName ([string]$Spec['Name']) `
                -Name $Item.AdapterName `
                -ErrorAction Stop

            $macSpoofingState = if ($Item.ExpectedMacSpoofing) {
                'On'
            }
            else {
                'Off'
            }

            Set-VMNetworkAdapter `
                -VMNetworkAdapter $adapter `
                -MacAddressSpoofing $macSpoofingState `
                -ErrorAction Stop
        }
    }
}


function Test-LabExistingVmCompliance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Spec,

        [Parameter(Mandatory)]
        [object]$VM,

        [Parameter(Mandatory)]
        [object]$Template,

        [Parameter(Mandatory)]
        [string]$ExpectedVhdPath,

        [Parameter(Mandatory)]
        [string]$ExpectedVmPath,

        # 호출자가 이미 조회해 둔 값이 있으면 재사용해 동일 VM에 대한
        # 중복 Hyper-V 조회를 줄인다. 넘기지 않으면 이 함수가 직접 조회한다.
        [AllowNull()]
        [object]$Memory,

        [AllowNull()]
        [object[]]$NetworkAdapters,

        [AllowNull()]
        [object[]]$HardDiskDrives
    )

    $drift =
        [Collections.Generic.List[object]]::new()

    $isFullCopy = ([string]$Spec['DiskMode'] -eq 'FullCopy')

    function Add-LabDrift {
        param(
            [Parameter(Mandatory)]
            [string]$Category,

            [Parameter(Mandatory)]
            [string]$Message,

            [bool]$Fixable = $false,

            [string]$AdapterName,

            [Nullable[bool]]$ExpectedMacSpoofing
        )

        $rule = $script:LabDriftRuleTable[$Category]

        $requiresOff = [bool]($rule -and $rule.RequiresOff)

        $blockedByRunningVm = (
            $Fixable -and
            $requiresOff -and
            $VM.State.ToString() -ne 'Off'
        )

        $effectiveFixable = (
            $Fixable -and
            ($null -ne $rule) -and
            (
                -not $requiresOff -or
                $VM.State.ToString() -eq 'Off'
            )
        )

        $effectiveMessage = if ($blockedByRunningVm) {
            "$Message (VM이 실행 중이라 자동 교정할 수 없습니다. VM을 끈 뒤 다시 시도하세요.)"
        }
        else {
            $Message
        }

        $drift.Add(
            [pscustomobject]@{
                Category            = $Category
                Message             = $effectiveMessage
                Fixable             = $effectiveFixable
                RequiresOff         = $requiresOff
                AdapterName         = $AdapterName
                ExpectedMacSpoofing = $ExpectedMacSpoofing
            }
        )
    }

    # $script:LabDriftRuleTable에 Expected/Actual/Format이 모두 있는
    # 스칼라 비교 Category용 헬퍼. CPU/Memory처럼 "설정값과 실제값을
    # 비교해 다르면 드리프트"로 표현되는 검사의 반복을 줄인다.
    function Test-LabRuleDrift {
        param(
            [Parameter(Mandatory)]
            [string]$Category
        )

        $rule = $script:LabDriftRuleTable[$Category]

        $expectedValue = & $rule.Expected $Spec $VM $memory
        $actualValue   = & $rule.Actual $Spec $VM $memory

        if ($expectedValue -ne $actualValue) {
            Add-LabDrift `
                -Category $Category `
                -Fixable $true `
                -Message (& $rule.Format $expectedValue $actualValue)
        }
    }

    # 이후 모든 검사에서 재사용하므로 여기서 한 번만 조회한다.
    $memory = if ($Memory) {
        $Memory
    }
    else {
        Get-VMMemory `
            -VM $VM `
            -ErrorAction Stop
    }

    # ------------------------------------------------------------
    # VM 기본 설정
    # ------------------------------------------------------------

    if ([int]$VM.Generation -ne 2) {
        Add-LabDrift `
            -Category 'Generation' `
            -Message (
                "Generation 불일치: 설정=2, 실제=$($VM.Generation)"
            )
    }

    Test-LabRuleDrift -Category 'CPU'

    $actualVmPath = ConvertTo-LabNormalizedPath `
        -Path $VM.Path

    $expectedVmPathNormalized = ConvertTo-LabNormalizedPath `
        -Path $ExpectedVmPath

    if (
        $actualVmPath -ine
        $expectedVmPathNormalized
    ) {
        Add-LabDrift `
            -Category 'VmPath' `
            -Message (
                "VM 구성 경로 불일치: " +
                "설정=$expectedVmPathNormalized, " +
                "실제=$actualVmPath"
            )
    }

    if (-not (Test-Path -LiteralPath $ExpectedVmPath)) {
        Add-LabDrift `
            -Category 'VmPathMissing' `
            -Message (
                "VM 구성 디렉터리가 없습니다: $ExpectedVmPath"
            )
    }

    Test-LabRuleDrift -Category 'AutoStart'
    Test-LabRuleDrift -Category 'AutoStop'
    Test-LabRuleDrift -Category 'AutoCheckpoints'
    Test-LabRuleDrift -Category 'CheckpointType'

    # ------------------------------------------------------------
    # 프로세서와 메모리
    # ------------------------------------------------------------

    $processor = Get-VMProcessor `
        -VM $VM `
        -ErrorAction Stop

    $expectedNested =
        [bool]$Spec['NestedVirtualization']

    if (
        [bool]$processor.ExposeVirtualizationExtensions -ne
        $expectedNested
    ) {
        Add-LabDrift `
            -Category 'NestedVirtualization' `
            -Message (
                "중첩 가상화 설정 불일치: " +
                "설정=$expectedNested, " +
                "실제=$(
                    [bool]$processor.ExposeVirtualizationExtensions
                )"
            )
    }

    Test-LabRuleDrift -Category 'DynamicMemory'
    Test-LabRuleDrift -Category 'Memory'

    # ------------------------------------------------------------
    # Secure Boot와 vTPM
    # ------------------------------------------------------------

    $firmware = Get-VMFirmware `
        -VM $VM `
        -ErrorAction Stop

    $actualSecureBoot =
        $firmware.SecureBoot.ToString() -eq 'On'

    $expectedSecureBoot =
        [bool]$Template.SecureBoot

    if (
        $actualSecureBoot -ne
        $expectedSecureBoot
    ) {
        Add-LabDrift `
            -Category 'SecureBoot' `
            -Message (
                "Secure Boot 불일치: " +
                "설정=$expectedSecureBoot, " +
                "실제=$actualSecureBoot"
            )
    }

    $security = Get-VMSecurity `
        -VM $VM `
        -ErrorAction Stop

    $actualTpm = [bool]$security.TpmEnabled
    $expectedTpm = [bool]$Template.EnableTpm

    if ($actualTpm -ne $expectedTpm) {
        Add-LabDrift `
            -Category 'Tpm' `
            -Message (
                "vTPM 불일치: " +
                "설정=$expectedTpm, " +
                "실제=$actualTpm"
            )
    }

    # ------------------------------------------------------------
    # VHDX 연결과 디스크 모드
    # ------------------------------------------------------------

    $hardDisks = @(
        if ($HardDiskDrives) {
            $HardDiskDrives
        }
        else {
            Get-VMHardDiskDrive `
                -VM $VM `
                -ErrorAction Stop
        }
    )

    # 역할에 따라 데이터 디스크가 추가로 연결될 수 있으므로, 연결된
    # VHDX 총 개수가 아니라 예상 OS VHDX가 정확히 하나 연결됐는지만
    # 검사한다. 관리 범위 밖의 추가 디스크는 드리프트로 취급하지 않는다.
    $expectedVhdPathNormalized = ConvertTo-LabNormalizedPath `
        -Path $ExpectedVhdPath

    $expectedDiskMatches = @(
        $hardDisks |
            Where-Object {
                (
                    ConvertTo-LabNormalizedPath `
                        -Path $_.Path
                ) -ieq $expectedVhdPathNormalized
            }
    )

    if ($expectedDiskMatches.Count -eq 0) {
        Add-LabDrift `
            -Category 'VhdPath' `
            -Message (
                '예상 OS VHDX가 연결되어 있지 않습니다: ' +
                $expectedVhdPathNormalized
            )
    }
    elseif ($expectedDiskMatches.Count -gt 1) {
        Add-LabDrift `
            -Category 'VhdCount' `
            -Message (
                '예상 OS VHDX가 중복 연결되어 있습니다: ' +
                $expectedVhdPathNormalized
            )
    }
    else {
        if (
            -not (
                Test-Path `
                    -LiteralPath $ExpectedVhdPath
            )
        ) {
            Add-LabDrift `
                -Category 'VhdMissing' `
                -Message (
                    "연결된 VHDX 파일이 없습니다: " +
                    $ExpectedVhdPath
                )
        }
        else {
            $actualVhd = Get-VHD `
                -Path $ExpectedVhdPath `
                -ErrorAction Stop

            $actualVhdItem = Get-Item `
                -LiteralPath $ExpectedVhdPath `
                -ErrorAction Stop

            if ($actualVhdItem.IsReadOnly) {
                Add-LabDrift `
                    -Category 'VhdReadOnly' `
                    -Message (
                        'VM 자식 VHDX가 읽기 전용입니다: ' +
                        $ExpectedVhdPath
                    )
            }

            if ($isFullCopy) {
                if (
                    $actualVhd.VhdType.ToString() -eq
                    'Differencing'
                ) {
                    Add-LabDrift `
                        -Category 'DiskMode' `
                        -Message (
                            '전체 복사 모드이지만 실제 디스크가 ' +
                            '차등 디스크입니다.'
                        )
                }
            }
            else {
                if (
                    $actualVhd.VhdType.ToString() -ne
                    'Differencing'
                ) {
                    Add-LabDrift `
                        -Category 'DiskMode' `
                        -Message (
                            "차등 디스크 모드이지만 실제 유형이 " +
                            "$($actualVhd.VhdType)입니다."
                        )
                }
                else {
                    $actualParent = ConvertTo-LabNormalizedPath `
                        -Path $actualVhd.ParentPath

                    $expectedParent = ConvertTo-LabNormalizedPath `
                        -Path $Template.VhdPath

                    if ($actualParent -ine $expectedParent) {
                        Add-LabDrift `
                            -Category 'DiskParent' `
                            -Message (
                                "차등 디스크 부모 불일치: " +
                                "설정=$expectedParent, " +
                                "실제=$actualParent"
                            )
                    }
                }
            }
        }
    }

    # ------------------------------------------------------------
    # 네트워크 어댑터
    # ------------------------------------------------------------

    $desiredSwitches = @($Spec['Switch'])
    $actualAdapters = @(
        if ($NetworkAdapters) {
            $NetworkAdapters
        }
        else {
            Get-VMNetworkAdapter `
                -VM $VM `
                -ErrorAction Stop
        }
    )

    if (
        $actualAdapters.Count -ne
        $desiredSwitches.Count
    ) {
        Add-LabDrift `
            -Category 'AdapterCount' `
            -Message (
                "네트워크 어댑터 수 불일치: " +
                "설정=$($desiredSwitches.Count), " +
                "실제=$($actualAdapters.Count)"
            )
    }

    $macSpoofingSwitches =
        @($Spec['MacSpoofingSwitches'])

    foreach ($switchName in $desiredSwitches) {
        $matchingAdapters = @(
            $actualAdapters |
                Where-Object {
                    $_.Name -eq $switchName
                }
        )

        if ($matchingAdapters.Count -eq 0) {
            Add-LabDrift `
                -Category 'AdapterMissing' `
                -Message (
                    "네트워크 어댑터가 없습니다: " +
                    "이름=$switchName"
                )

            continue
        }

        if ($matchingAdapters.Count -gt 1) {
            Add-LabDrift `
                -Category 'AdapterDuplicate' `
                -Message (
                    "동일한 이름의 네트워크 어댑터가 " +
                    "중복되어 있습니다: 이름=$switchName"
                )

            continue
        }

        $adapter = $matchingAdapters[0]

        if ($adapter.SwitchName -ne $switchName) {
            Add-LabDrift `
                -Category 'AdapterConnection' `
                -Message (
                    "네트워크 연결 불일치: " +
                    "설정 스위치=$switchName, " +
                    "실제 스위치=$($adapter.SwitchName)"
                )
        }

        $expectedMacSpoofing =
            $macSpoofingSwitches -contains
            $switchName

        $actualMacSpoofing =
            $adapter.MacAddressSpoofing.ToString() -eq
            'On'

        if (
            $actualMacSpoofing -ne
            $expectedMacSpoofing
        ) {
            Add-LabDrift `
                -Category 'MacSpoofing' `
                -Fixable $true `
                -AdapterName $switchName `
                -ExpectedMacSpoofing $expectedMacSpoofing `
                -Message (
                    "MAC 스푸핑 불일치: " +
                    "어댑터=$switchName, " +
                    "설정=$expectedMacSpoofing, " +
                    "실제=$actualMacSpoofing"
                )
        }
    }

    [pscustomobject]@{
        IsCompliant = ($drift.Count -eq 0)
        Drift       = @($drift)
    }
}

function Test-LabPrerequisite {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Spec,

        # New-LabVM/New-LabStage처럼 이미 Get-LabConfig를 부른 호출자는
        # 이걸 넘겨 재조회(및 재귀 딥카피)를 피한다. 생략하면 이 함수가
        # 직접 조회한다.
        [System.Collections.IDictionary]$Config
    )

    $cfg = if ($Config) {
        $Config
    }
    else {
        Get-LabConfig
    }

    $issues =
        [Collections.Generic.List[string]]::new()

    $warnings =
        [Collections.Generic.List[string]]::new()

    $template = $null
    $templateVhd = $null
    $compliance = $null

    $requiredDiskBytes = [int64]0
    $availableDiskBytes = [int64]0

    # 검증 전에는 Name이 비어 있거나 잘못됐을 수 있으므로,
    # 경로를 계산하지 않고 Failed 결과 표시용 이름만 확보한다.
    $vmName = if (
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

    $childPath = $null
    $vmPath = $null

    $diskMode = if (
        $Spec.Contains('DiskMode') -and
        -not [string]::IsNullOrWhiteSpace(
            [string]$Spec['DiskMode']
        )
    ) {
        [string]$Spec['DiskMode']
    }
    else {
        'Differencing'
    }

    $isFullCopy = ($diskMode -eq 'FullCopy')

    function New-PrerequisiteResult {
        [Diagnostics.CodeAnalysis.SuppressMessage(
            'PSUseShouldProcessForStateChangingFunctions',
            '',
            Justification = '메모리 내 결과 객체만 생성하며 외부 상태를 변경하지 않는다.'
        )]
        param(
            [Parameter(Mandatory)]
            [ValidateSet(
                'Create',
                'Skip',
                'Conflict',
                'Failed'
            )]
            [string]$Disposition
        )

        [pscustomobject]@{
            PSTypeName         = 'Lab.PrerequisiteResult'
            Name               = $vmName
            Disposition        = $Disposition
            Issues             = @($issues)
            Warnings           = @($warnings)
            ChildVhdPath       = $childPath
            VmPath             = $vmPath
            Template           = $template
            DiskMode           = $diskMode
            RequiredDiskBytes  = $requiredDiskBytes
            AvailableDiskBytes = $availableDiskBytes
            # 기존 VM과 비교한 구조화된 드리프트. Conflict일 때만 채워지며,
            # New-LabVM -Reconcile이 Fixable 항목만 골라 교정하는 데 쓴다.
            Compliance         = $compliance
        }
    }

    # ------------------------------------------------------------
    # 0. 입력 계약 검증
    #
    # Test-LabPrerequisite는 모듈에서 export되므로 New-LabVM을 거치지
    # 않고 직접 호출될 수 있다. 잘못된 Spec을 넘기면 아래 경로 처리나
    # 키 접근 도중 예외가 나는 대신, 정돈된 Failed 결과로 변환한다.
    # ------------------------------------------------------------

    try {
        $Spec = Resolve-LabVmSpec `
            -Vm $Spec `
            -Config $cfg `
            -ErrorAction Stop
    }
    catch {
        $issues.Add($_.Exception.Message)

        return New-PrerequisiteResult `
            -Disposition Failed
    }

    # Resolve-LabVmSpec이 $Spec을 정규화된 사본으로 재바인딩했으므로,
    # 그 이전(원시 $Spec 기준)에 계산해 둔 $diskMode/$isFullCopy는 낡은
    # 값이다. 여기서 다시 계산해야 DiskMode 기본값 규칙이
    # Resolve-LabVmSpec 한 곳에만 있게 된다.
    $vmName = [string]$Spec['Name']
    $diskMode = [string]$Spec['DiskMode']
    $isFullCopy = ($diskMode -eq 'FullCopy')

    $labPaths = Get-LabVmPath `
        -Name $vmName `
        -Config $cfg

    $childPath = $labPaths.VhdPath
    $vmPath = $labPaths.VmPath

    if (
        @('Differencing', 'FullCopy') -notcontains $diskMode
    ) {
        $issues.Add(
            "Spec의 DiskMode 값이 올바르지 않습니다: $diskMode"
        )
    }

    # ------------------------------------------------------------
    # 1. 검사와 생성에 필요한 Hyper-V 명령 확인
    # ------------------------------------------------------------

    foreach ($command in (Get-LabMissingCommand -Name @(
        'Get-VM',
        'New-VM',
        'Remove-VM',
        'Set-VM',
        'Get-VMSwitch',
        'Get-VHD',
        'New-VHD',
        'Mount-VHD',
        'Dismount-VHD',
        'Get-VMProcessor',
        'Set-VMProcessor',
        'Get-VMMemory',
        'Set-VMMemory',
        'Get-VMFirmware',
        'Set-VMFirmware',
        'Get-VMHardDiskDrive',
        'Get-VMNetworkAdapter',
        'Rename-VMNetworkAdapter',
        'Connect-VMNetworkAdapter',
        'Add-VMNetworkAdapter',
        'Remove-VMNetworkAdapter',
        'Set-VMNetworkAdapter',
        'Get-VMSecurity',
        'Get-Disk',
        'Get-Partition',
        'Add-PartitionAccessPath'
    ))) {
        $issues.Add(
            "Hyper-V 명령을 찾을 수 없습니다: $command"
        )
    }

    if (
        @(
            Get-LabMissingCommand -Name 'reg.exe'
        ).Count -gt 0
    ) {
        $issues.Add(
            '오프라인 레지스트리 검사용 reg.exe를 ' +
            '찾을 수 없습니다.'
        )
    }

    if ($issues.Count -gt 0) {
        return New-PrerequisiteResult `
            -Disposition Failed
    }

    # ------------------------------------------------------------
    # 2. 템플릿 설정 해석
    # ------------------------------------------------------------

    try {
        $template = Resolve-LabTemplate `
            -Name ([string]$Spec['Template']) `
            -Config $cfg
    }
    catch {
        $issues.Add($_.Exception.Message)

        return New-PrerequisiteResult `
            -Disposition Failed
    }

    if ($template.EnableTpm) {
        foreach (
            $command in
            (Get-LabMissingCommand -Name @(
                'Set-VMKeyProtector',
                'Enable-VMTPM'
            ))
        ) {
            $issues.Add(
                "vTPM 명령을 찾을 수 없습니다: $command"
            )
        }
    }

    if ($issues.Count -gt 0) {
        return New-PrerequisiteResult `
            -Disposition Failed
    }

    # ------------------------------------------------------------
    # 3. 스위치 설정과 실제 스위치 확인
    # ------------------------------------------------------------

    foreach ($switchName in @($Spec['Switch'])) {
        $switchSpecs = @(
            Get-LabSwitchSpec `
                -Name ([string]$switchName) `
                -Config $cfg
        )

        if ($switchSpecs.Count -eq 0) {
            $issues.Add(
                "설정 무결성 오류: VM '$vmName'이 " +
                "정의되지 않은 가상 스위치 " +
                "'$switchName'을 참조합니다."
            )

            continue
        }

        if ($switchSpecs.Count -gt 1) {
            $issues.Add(
                "설정 무결성 오류: 가상 스위치 " +
                "'$switchName' 정의가 중복되어 있습니다."
            )

            continue
        }

        $switchSpec = $switchSpecs[0]

        # Get-VMSwitch -Name은 와일드카드를 해석하고, 동일한 이름의
        # 스위치가 여러 개 있으면 배열을 반환한다. 정확히 하나만
        # 매칭되는지 이름을 다시 대조해 확인한다.
        try {
            $matchingSwitches = @(
                Get-VMSwitch -ErrorAction Stop |
                    Where-Object {
                        $_.Name -eq $switchName
                    }
            )
        }
        catch {
            $issues.Add(
                "가상 스위치 '$switchName' 조회 실패: " +
                $_.Exception.Message
            )

            continue
        }

        if ($matchingSwitches.Count -gt 1) {
            $issues.Add(
                "가상 스위치 '$switchName'가 Hyper-V 호스트에 " +
                '중복으로 존재합니다.'
            )

            continue
        }

        $existingSwitch = $matchingSwitches |
            Select-Object -First 1

        if (-not $existingSwitch) {
            $issues.Add(
                "가상 스위치 '$switchName'가 " +
                'Hyper-V 호스트에 없습니다. ' +
                "설정 유형=$($switchSpec['Type']), " +
                "준비 Stage=$($switchSpec['Stage'])"
            )

            continue
        }

        if (
            $existingSwitch.SwitchType.ToString() -ne
            [string]$switchSpec['Type']
        ) {
            $issues.Add(
                "가상 스위치 '$switchName' 유형 불일치: " +
                "설정=$($switchSpec['Type']), " +
                "실제=$($existingSwitch.SwitchType)"
            )
        }
    }

    if ($issues.Count -gt 0) {
        return New-PrerequisiteResult `
            -Disposition Failed
    }

    # ------------------------------------------------------------
    # 4. 기존 리소스 상태 판정
    # ------------------------------------------------------------

    try {
        $existingVm = Get-LabVmByName `
            -Name $vmName `
            -ErrorAction Stop
    }
    catch {
        $issues.Add(
            "기존 VM 조회 실패: $($_.Exception.Message)"
        )

        return New-PrerequisiteResult `
            -Disposition Failed
    }

    $childExists =
        Test-Path -LiteralPath $childPath

    $vmPathExists =
        Test-Path -LiteralPath $vmPath

    # VM은 없지만 파일이나 디렉터리만 남아 있으면 충돌
    if (-not $existingVm) {
        if ($childExists) {
            $issues.Add(
                "VM은 없지만 디스크가 이미 존재합니다: " +
                $childPath
            )
        }

        if ($vmPathExists) {
            $issues.Add(
                "VM은 없지만 구성 디렉터리가 " +
                "이미 존재합니다: $vmPath"
            )
        }

        if ($issues.Count -gt 0) {
            return New-PrerequisiteResult `
                -Disposition Conflict
        }
    }

    # 기존 VM이 있으면 원하는 상태와 비교
    if ($existingVm) {
        try {
            $compliance =
                Test-LabExistingVmCompliance `
                    -Spec $Spec `
                    -VM $existingVm `
                    -Template $template `
                    -ExpectedVhdPath $childPath `
                    -ExpectedVmPath $vmPath
        }
        catch {
            $issues.Add(
                "기존 VM 상태 검사 실패: " +
                $_.Exception.Message
            )

            return New-PrerequisiteResult `
                -Disposition Failed
        }

        if ($compliance.IsCompliant) {
            $warnings.Add(
                "VM '$vmName'이 이미 원하는 " +
                '구성으로 존재합니다.'
            )

            return New-PrerequisiteResult `
                -Disposition Skip
        }

        foreach ($item in $compliance.Drift) {
            $issues.Add($item.Message)
        }

        return New-PrerequisiteResult `
            -Disposition Conflict
    }

    # ------------------------------------------------------------
    # 5. 신규 생성에 필요한 템플릿 검사
    # ------------------------------------------------------------

    if (
        -not (
            Test-Path `
                -LiteralPath $template.VhdPath
        )
    ) {
        $issues.Add(
            "템플릿 VHDX가 없습니다: " +
            $template.VhdPath
        )
    }
    else {
        try {
            $templateVhd = Get-VHD `
                -Path $template.VhdPath `
                -ErrorAction Stop

            if ($templateVhd.Attached) {
                $issues.Add(
                    "템플릿 VHDX가 연결된 상태입니다: " +
                    $template.VhdPath
                )
            }

            if (-not $templateVhd.Attached) {
                if (
                    -not $PSCmdlet.ShouldProcess(
                        $template.VhdPath,
                        '템플릿 generalize 상태 확인을 위한 임시 마운트'
                    )
                ) {
                    $warnings.Add(
                        '템플릿 generalize 검사를 건너뛰었습니다 ' +
                        '(-WhatIf: 호스트 마운트/레지스트리 변경 방지).'
                    )
                }
                else {
                    try {
                        $generalization =
                            Test-LabTemplateGeneralization `
                                -VhdPath $template.VhdPath

                        foreach (
                            $generalizationIssue in
                            @($generalization.Issues)
                        ) {
                            $issues.Add(
                                "템플릿 generalize 검사: " +
                                $generalizationIssue
                            )
                        }

                        foreach (
                            $generalizationWarning in
                            @($generalization.Warnings)
                        ) {
                            $warnings.Add(
                                "템플릿 generalize 검사: " +
                                $generalizationWarning
                            )
                        }
                    }
                    catch {
                        $issues.Add(
                            '템플릿 generalize 상태 검사 실패: ' +
                            $_.Exception.Message
                        )
                    }
                }
            }

            if (-not $isFullCopy) {
                $templateItem = Get-Item `
                    -LiteralPath $template.VhdPath `
                    -ErrorAction Stop

                if (-not $templateItem.IsReadOnly) {
                    $issues.Add(
                        '차등 디스크 부모 템플릿은 ' +
                        '읽기 전용이어야 합니다: ' +
                        $template.VhdPath
                    )
                }
            }

            $requiredDiskBytes = if ($isFullCopy) {
                [int64]$templateVhd.FileSize
            }
            else {
                [int64]$cfg[
                    'DifferencingReserveMB'
                ] * 1MB
            }

            [int64]$safetyReserveBytes = (
                [int64]$cfg['DiskSafetyReserveMB'] *
                1MB
            )

            $requiredWithSafety =
                $requiredDiskBytes +
                $safetyReserveBytes

            $driveRoot =
                [IO.Path]::GetPathRoot(
                    [IO.Path]::GetFullPath(
                        [string]$cfg['LabRoot']
                    )
                )

            $driveInfo =
                [IO.DriveInfo]::new($driveRoot)

            if (-not $driveInfo.IsReady) {
                $issues.Add(
                    "LabRoot 볼륨을 사용할 수 없습니다: " +
                    $driveRoot
                )
            }
            else {
                $availableDiskBytes =
                    [int64]$driveInfo.AvailableFreeSpace

                if (
                    $availableDiskBytes -lt
                    $requiredWithSafety
                ) {
                    $issues.Add(
                        (
                            Format-LabDiskShortageMessage `
                                -DiskMode $diskMode `
                                -RequiredBytes $requiredWithSafety `
                                -CreationBytes $requiredDiskBytes `
                                -SafetyReserveBytes $safetyReserveBytes `
                                -AvailableBytes $availableDiskBytes `
                                -Volume $driveRoot
                        )
                    )
                }
            }
        }
        catch {
            $issues.Add(
                '템플릿 또는 LabRoot 볼륨 검사 실패: ' +
                $_.Exception.Message
            )
        }
    }

    if (
        -not (
            Test-Path `
                -LiteralPath $template.UnattendPath
        )
    ) {
        $issues.Add(
            '응답 파일 템플릿이 없습니다: ' +
            $template.UnattendPath
        )
    }

    if ($issues.Count -gt 0) {
        return New-PrerequisiteResult `
            -Disposition Failed
    }

    # 기존 리소스 없음 + 모든 생성 조건 충족
    return New-PrerequisiteResult `
        -Disposition Create
}

