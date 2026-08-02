Set-StrictMode -Version Latest

# LabConfig.psd1/.local.psd1 로드, 검증, 조회와
# 스펙/스위치/템플릿 이름 해석을 담당한다.
# LabVM.psm1이 dot-source하며 모듈 스코프를 공유한다.

$script:Config = $null


function Assert-LabVmSpec {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Vm,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Config
    )

    foreach ($required in @(
        'Name',
        'Stage',
        'Template',
        'CPU',
        'MemoryMB',
        'Switch'
    )) {
        if (-not $Vm.Contains($required)) {
            throw (
                "VM 정의 '$($Vm['Name'])'에 " +
                "'$required' 값이 없습니다."
            )
        }
    }

    $vmName       = [string]$Vm['Name']
    $vmStage      = [string]$Vm['Stage']
    $templateName = [string]$Vm['Template']

    Assert-LabComputerName `
        -Name $vmName `
        -Label 'VM 이름'

    $stageNames = @(
        $Config['StageOrder'] |
            ForEach-Object {
                [string]$_
            }
    )

    if ($stageNames -notcontains $vmStage) {
        throw (
            "VM '$vmName'의 Stage '$vmStage'가 " +
            'StageOrder에 없습니다.'
        )
    }

    if (
        @($Config['Templates'].Keys) -notcontains
        $templateName
    ) {
        throw (
            "VM '$vmName'이 정의되지 않은 " +
            "템플릿 '$templateName'을 참조합니다."
        )
    }

    if (
        $Vm['CPU'] -isnot [int] -or
        $Vm['CPU'] -lt 1
    ) {
        throw "VM '$vmName'의 CPU는 1 이상의 정수여야 합니다."
    }

    if ([int]$Vm['MemoryMB'] -lt 512) {
        throw "VM '$vmName'의 MemoryMB는 512 이상이어야 합니다."
    }

    $switchNames = @(
        $Config['Switches'] |
            ForEach-Object {
                [string]$_['Name']
            }
    )

    foreach ($switchName in @($Vm['Switch'])) {
        if (
            $switchNames -notcontains
            [string]$switchName
        ) {
            throw (
                "VM '$vmName'이 정의되지 않은 " +
                "가상 스위치 '$switchName'을 참조합니다."
            )
        }
    }

    foreach (
        $spoofingSwitch in
        @(
            $Vm['MacSpoofingSwitches'] |
                Select-LabNonEmptyString
        )
    ) {
        if (
            @($Vm['Switch']) -notcontains
            [string]$spoofingSwitch
        ) {
            throw (
                "VM '$vmName'의 MacSpoofingSwitches 값 " +
                "'$spoofingSwitch'은 해당 VM의 " +
                'Switch 목록에 없습니다.'
            )
        }
    }

    if (
        $Vm.Contains('NestedVirtualization') -and
        $Vm['NestedVirtualization'] -isnot [bool]
    ) {
        throw (
            "VM '$vmName'의 NestedVirtualization은 " +
            '$true 또는 $false여야 합니다.'
        )
    }

    if (
        $Vm.Contains('DiskMode') -and
        @(
            'Differencing',
            'FullCopy'
        ) -notcontains [string]$Vm['DiskMode']
    ) {
        throw (
            "VM '$vmName'의 DiskMode가 올바르지 않습니다: " +
            "$($Vm['DiskMode'])"
        )
    }

    $vmSwitchNames = @(
        $Vm['Switch'] |
            ForEach-Object {
                [string]$_
            }
    )

    $duplicateVmSwitches = @(
        Get-LabDuplicateValue -Value $vmSwitchNames
    )

    if ($duplicateVmSwitches.Count -gt 0) {
        throw (
            "VM '$vmName'의 Switch 목록에 중복이 있습니다: " +
            ($duplicateVmSwitches -join ', ')
        )
    }
}

function ConvertTo-LabNormalizedVmSpec {
    # Vm 해시테이블에 선택적 키의 기본값을 채워 넣기만 한다(검증은
    # 하지 않는다). Resolve-LabVmSpec처럼 전체 Config(Templates,
    # Switches)를 갖춘 경로와 Resolve-LabSpec처럼 이름/Stage로 가볍게
    # 조회만 하는 경로 양쪽에서 같은 기본값 적용 로직을 공유해, 둘 중
    # 한쪽에만 기본값이 채워지는 일이 없도록 한다.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Vm
    )

    $resolved = Copy-LabValue -Value $Vm

    if (-not $resolved.Contains('NestedVirtualization')) {
        $resolved['NestedVirtualization'] = $false
    }

    if (-not $resolved.Contains('MacSpoofingSwitches')) {
        $resolved['MacSpoofingSwitches'] = @()
    }

    if (-not $resolved.Contains('DiskMode')) {
        $resolved['DiskMode'] = 'Differencing'
    }

    $resolved
}

function Resolve-LabVmSpec {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Vm,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Config
    )

    Assert-LabVmSpec -Vm $Vm -Config $Config

    ConvertTo-LabNormalizedVmSpec -Vm $Vm
}


function Assert-LabConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Config
    )

    foreach ($key in @(
        'LabRoot',
        'HostReserveMB',
        'DiskSafetyReserveMB',
        'DifferencingReserveMB',
        'DifferencingPerVmReserveMB',
        'TimeZone',
        'LocalAdminName',
        'StageOrder',
        'StageDependencies',
        'Templates',
        'Switches',
        'VMs'
    )) {
        if (-not $Config.Contains($key)) {
            throw "LabConfig.psd1에 필수 키 '$key'가 없습니다."
        }
    }

    if (
        [string]::IsNullOrWhiteSpace([string]$Config.LabRoot) -or
        -not [IO.Path]::IsPathRooted([string]$Config.LabRoot)
    ) {
        throw "LabRoot는 절대 경로여야 합니다: $($Config.LabRoot)"
    }

    Assert-LabTimeZoneId `
        -TimeZone ([string]$Config['TimeZone'])

    Assert-LabLocalAdminName `
        -Name ([string]$Config['LocalAdminName'])

    $numericValues = @{}

    foreach ($numericKey in @(
        'HostReserveMB',
        'DiskSafetyReserveMB',
        'DifferencingReserveMB',
        'DifferencingPerVmReserveMB'
    )) {
        [int64]$numericValue = 0

        if (
            -not [int64]::TryParse(
                [string]$Config[$numericKey],
                [ref]$numericValue
            )
        ) {
            throw (
                "$numericKey 값은 정수여야 합니다: " +
                "'$($Config[$numericKey])'"
            )
        }

        if ($numericValue -lt 0) {
            throw "$numericKey 값은 0 이상이어야 합니다."
        }

        $numericValues[$numericKey] = $numericValue
    }

    if (
        $numericValues['DifferencingReserveMB'] -lt
        128
    ) {
        throw (
            'DifferencingReserveMB는 ' +
            '최소 128MB 이상이어야 합니다.'
        )
    }

    if (
        $numericValues['DifferencingPerVmReserveMB'] -lt
        16
    ) {
        throw (
            'DifferencingPerVmReserveMB는 ' +
            '최소 16MB 이상이어야 합니다.'
        )
    }

    $stageNames = @(
        $Config['StageOrder'] |
            ForEach-Object {
                [string]$_
            }
    )

    if ($stageNames.Count -eq 0) {
        throw 'StageOrder가 비어 있습니다.'
    }

    foreach ($stageName in $stageNames) {
        if ([string]::IsNullOrWhiteSpace($stageName)) {
            throw 'StageOrder에 공백 값이 있습니다.'
        }
    }

    $duplicateStages = @(
        Get-LabDuplicateValue -Value $stageNames
    )

    if ($duplicateStages.Count -gt 0) {
        throw (
            'StageOrder 중복: ' +
            ($duplicateStages -join ', ')
        )
    }

    # ------------------------------------------------------------
    # 스위치 정의 검증
    # ------------------------------------------------------------

    $switchNames =
        [Collections.Generic.List[string]]::new()

    foreach ($switch in @($Config['Switches'])) {
        if (
            $switch -isnot
            [System.Collections.IDictionary]
        ) {
            throw 'Switches의 각 항목은 Hashtable이어야 합니다.'
        }

        foreach ($required in @(
            'Name',
            'Type',
            'Stage'
        )) {
            if (-not $switch.Contains($required)) {
                throw "가상 스위치 정의에 '$required' 값이 없습니다."
            }
        }

        $switchName  = [string]$switch['Name']
        $switchType  = [string]$switch['Type']
        $switchStage = [string]$switch['Stage']

        if (
            [string]::IsNullOrWhiteSpace(
                $switchName
            )
        ) {
            throw '가상 스위치 Name은 비어 있을 수 없습니다.'
        }

        if (
            @(
                'Internal',
                'External',
                'Private'
            ) -notcontains $switchType
        ) {
            throw (
                "가상 스위치 '$switchName'의 " +
                "Type '$switchType'이 올바르지 않습니다."
            )
        }

        if ($stageNames -notcontains $switchStage) {
            throw (
                "가상 스위치 '$switchName'의 " +
                "Stage '$switchStage'가 StageOrder에 없습니다."
            )
        }

        $switchNames.Add($switchName)
    }

    $duplicateSwitchNames = @(
        Get-LabDuplicateValue -Value $switchNames
    )

    if ($duplicateSwitchNames.Count -gt 0) {
        throw (
            '중복 가상 스위치 이름: ' +
            ($duplicateSwitchNames -join ', ')
        )
    }

    # ------------------------------------------------------------
    # 템플릿 정의 검증
    # ------------------------------------------------------------

    if (
        $Config['Templates'] -isnot
        [System.Collections.IDictionary]
    ) {
        throw 'Templates는 Hashtable이어야 합니다.'
    }

    foreach (
        $templateName in
        @($Config['Templates'].Keys)
    ) {
        $templateEntry =
            $Config['Templates'][$templateName]

        if (
            $templateEntry -isnot
            [System.Collections.IDictionary]
        ) {
            throw (
                "템플릿 '$templateName'은 " +
                'Hashtable이어야 합니다.'
            )
        }

        foreach ($requiredKey in @(
            'Vhd',
            'Unattend',
            'AccountMode',
            'SecureBoot',
            'EnableTpm'
        )) {
            if (-not $templateEntry.Contains($requiredKey)) {
                throw (
                    "템플릿 '$templateName' 정의에 " +
                    "'$requiredKey' 값이 없습니다."
                )
            }
        }

        foreach ($pathKey in @('Vhd', 'Unattend')) {
            if (
                [string]::IsNullOrWhiteSpace(
                    [string]$templateEntry[$pathKey]
                )
            ) {
                throw (
                    "템플릿 '$templateName'의 " +
                    "$pathKey 값이 비어 있습니다."
                )
            }
        }

        foreach ($boolKey in @(
            'SecureBoot',
            'EnableTpm'
        )) {
            if (
                $templateEntry[$boolKey] -isnot [bool]
            ) {
                throw (
                    "템플릿 '$templateName'의 " +
                    "$boolKey 값은 `$true 또는 `$false여야 합니다."
                )
            }
        }

        if (
            @(
                'BuiltInAdministrator',
                'LocalAccount'
            ) -notcontains
            [string]$templateEntry['AccountMode']
        ) {
            throw (
                "템플릿 '$templateName'의 AccountMode가 " +
                "올바르지 않습니다: $($templateEntry['AccountMode'])"
            )
        }
    }

    # ------------------------------------------------------------
    # VM 정의 및 스위치 참조 검증
    # ------------------------------------------------------------

    $vmNames =
        [Collections.Generic.List[string]]::new()

    $vmList = @($Config['VMs'])

    for ($vmIndex = 0; $vmIndex -lt $vmList.Count; $vmIndex++) {
        $vm = $vmList[$vmIndex]

        if (
            $vm -isnot
            [System.Collections.IDictionary]
        ) {
            throw 'VMs의 각 항목은 Hashtable이어야 합니다.'
        }

        $resolvedVm = Resolve-LabVmSpec -Vm $vm -Config $Config

        $Config['VMs'][$vmIndex] = $resolvedVm

        $vmNames.Add([string]$resolvedVm['Name'])
    }

    $duplicateVmNames = @(
        Get-LabDuplicateValue -Value $vmNames
    )

    if ($duplicateVmNames.Count -gt 0) {
        throw (
            '중복 VM 이름: ' +
            ($duplicateVmNames -join ', ')
        )
    }

    # ------------------------------------------------------------
    # StageDependencies 검증
    # ------------------------------------------------------------

    if (
        $Config['StageDependencies'] -isnot
        [System.Collections.IDictionary]
    ) {
        throw 'StageDependencies는 Hashtable이어야 합니다.'
    }

    $vmStageByName = @{}

    foreach ($vm in @($Config['VMs'])) {
        $vmStageByName[[string]$vm['Name']] =
            [string]$vm['Stage']
    }

    # Stage 단위 의존 그래프: key Stage -> 그 key가 요구하는 VM들의
    # 소유 Stage 집합. 순환 참조 탐지에 쓴다.
    $stageDependsOnStages = @{}

    foreach (
        $depKey in
        @($Config['StageDependencies'].Keys)
    ) {
        $depKeyName = [string]$depKey

        if ($stageNames -notcontains $depKeyName) {
            throw (
                "StageDependencies의 Stage '$depKeyName'가 " +
                'StageOrder에 없습니다.'
            )
        }

        $depNames = @(
            $Config['StageDependencies'][$depKey] |
                ForEach-Object {
                    [string]$_
                }
        )

        $ownerStages =
            [Collections.Generic.List[string]]::new()

        foreach ($depName in $depNames) {
            if (-not $vmStageByName.Contains($depName)) {
                throw (
                    "StageDependencies의 Stage '$depKeyName'가 " +
                    "정의되지 않은 VM '$depName'을 참조합니다."
                )
            }

            $ownerStage = $vmStageByName[$depName]

            if ($ownerStage -eq $depKeyName) {
                throw (
                    "StageDependencies의 Stage '$depKeyName'가 " +
                    "자기 자신 소유 VM '$depName'을 의존성으로 " +
                    '선언할 수 없습니다.'
                )
            }

            $ownerStages.Add($ownerStage)
        }

        $stageDependsOnStages[$depKeyName] = @(
            $ownerStages | Select-Object -Unique
        )
    }

    # 색상 기반 DFS로 모든 간선을 따라가며 순환을 찾는다(첫 번째
    # 의존 Stage만 따라가면 다른 가지를 통한 순환을 놓칠 수 있다).
    # 0=미방문, 1=경로상(방문 중), 2=완료.
    $stageColor = @{}

    foreach ($stageName in $stageNames) {
        $stageColor[$stageName] = 0
    }

    function local:Test-LabStageDependencyCycle {
        param(
            [string]$Node,
            [Collections.Generic.List[string]]$Path
        )

        $stageColor[$Node] = 1
        $Path.Add($Node)

        if ($stageDependsOnStages.Contains($Node)) {
            foreach ($next in @($stageDependsOnStages[$Node])) {
                if ($stageColor[$next] -eq 1) {
                    throw (
                        'StageDependencies 순환 참조: ' +
                        (
                            (@($Path) + $next) -join ' -> '
                        )
                    )
                }

                if ($stageColor[$next] -eq 0) {
                    Test-LabStageDependencyCycle `
                        -Node $next `
                        -Path $Path
                }
            }
        }

        [void]$Path.Remove($Node)
        $stageColor[$Node] = 2
    }

    foreach ($stageName in $stageNames) {
        if ($stageColor[$stageName] -eq 0) {
            Test-LabStageDependencyCycle `
                -Node $stageName `
                -Path ([Collections.Generic.List[string]]::new())
        }
    }
}

function Get-LabConfig {
    [CmdletBinding()]
    param(
        [switch]$Refresh
    )

    if ($script:Config -and -not $Refresh) {
        return Copy-LabValue `
            -Value $script:Config
    }

    if ($Refresh) {
        $script:TemplateGeneralizationCache.Clear()
    }

    $basePath = Join-Path $PSScriptRoot 'LabConfig.psd1'

    if (-not (Test-Path -LiteralPath $basePath)) {
        throw "기본 설정 파일이 없습니다: $basePath"
    }

    $localPath = Join-Path $PSScriptRoot 'LabConfig.local.psd1'

    if (-not (Test-Path -LiteralPath $localPath)) {
        throw (
            'LabConfig.local.psd1이 없습니다. ' +
            'LabConfig.local.psd1.example을 복사한 뒤 LabRoot를 수정하십시오.'
        )
    }

    $base = Import-PowerShellDataFile -Path $basePath
    $local = Import-PowerShellDataFile -Path $localPath

    $allowedLocalKeys = @(
        'LabRoot',
        'HostReserveMB',
        'DiskSafetyReserveMB',
        'DifferencingReserveMB',
        'DifferencingPerVmReserveMB',
        'TimeZone',
        'LocalAdminName'
    )

    $unknownLocalKeys = @(
        $local.Keys |
            Where-Object {
                $_ -notin $allowedLocalKeys
            }
    )

    if ($unknownLocalKeys.Count -gt 0) {
        throw (
            'LabConfig.local.psd1에 알 수 없는 키가 있습니다: ' +
            ($unknownLocalKeys -join ', ')
        )
    }

    $merged = Merge-LabHashtable `
        -Base $base `
        -Override $local

    Assert-LabConfig -Config $merged

    $script:Config = Copy-LabValue `
        -Value $merged

    Copy-LabValue `
        -Value $script:Config
}

function Resolve-LabSpec {
    [CmdletBinding()]
    [OutputType([System.Object[]])]
    [OutputType([array])]
    param(
        [string]$Name,
        [string]$Stage,

        [System.Collections.IDictionary]$Config
    )

    if (-not $Config) {
        $Config = Get-LabConfig
    }

    $cfg = $Config

    if ($Name) {
        return @(
            $cfg.VMs |
                Where-Object {
                    [string]$_['Name'] -eq $Name
                } |
                ForEach-Object {
                    ConvertTo-LabNormalizedVmSpec -Vm $_
                }
        )
    }

    if ($Stage) {
        return @(
            $cfg.VMs |
                Where-Object {
                    [string]$_['Stage'] -eq $Stage
                } |
                ForEach-Object {
                    ConvertTo-LabNormalizedVmSpec -Vm $_
                }
        )
    }

    @()
}

function Assert-LabStageName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Stage,

        [System.Collections.IDictionary]$Config
    )

    if (-not $Config) {
        $Config = Get-LabConfig
    }

    if (
        @($Config['StageOrder']) -notcontains
        $Stage
    ) {
        throw (
            "Stage '$Stage'가 " +
            'StageOrder에 정의되어 있지 않습니다.'
        )
    }
}

function Resolve-LabSingleSpec {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        # 오류 메시지에 붙는 호출 맥락. 예: '-Also 대상'
        [string]$Context,

        [System.Collections.IDictionary]$Config
    )

    $found = @(
        Resolve-LabSpec -Name $Name -Config $Config
    )

    $label = if (
        [string]::IsNullOrWhiteSpace($Context)
    ) {
        "VM '$Name'"
    }
    else {
        "$Context VM '$Name'"
    }

    if ($found.Count -eq 0) {
        throw "$label 정의가 LabConfig.psd1에 없습니다."
    }

    if ($found.Count -gt 1) {
        throw "$label 정의가 LabConfig.psd1에 중복되어 있습니다."
    }

    $found[0]
}

function Get-LabSwitchSpec {
    [CmdletBinding()]
    [OutputType([array])]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [System.Collections.IDictionary]$Config
    )

    if (-not $Config) {
        $Config = Get-LabConfig
    }

    @(
        $Config['Switches'] |
            Where-Object {
                [string]$_['Name'] -eq $Name
            }
    )
}

function Get-LabVmPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [System.Collections.IDictionary]$Config
    )

    if (-not $Config) {
        $Config = Get-LabConfig
    }

    [pscustomobject]@{
        VhdPath = Join-Path `
            $Config['LabRoot'] `
            "VHDs\$Name.vhdx"

        VmPath  = Join-Path `
            $Config['LabRoot'] `
            "VMs\$Name"
    }
}

function Get-LabStageSwitch {
    [CmdletBinding()]
    [OutputType([array])]
    param(
        [Parameter(Mandatory)]
        [string]$Stage,

        [System.Collections.IDictionary]$Config
    )

    if (-not $Config) {
        $Config = Get-LabConfig
    }

    $cfg = $Config

    @(
        $cfg['Switches'] |
            Where-Object {
                [string]$_['Stage'] -eq $Stage
            }
    )
}

function Get-LabStageDependencyClosure {
    # $Stage를 시작하려면 자동으로 함께 켜야 하는 VM 이름을,
    # StageDependencies에 선언된 직접 의존부터 시작해 재귀적으로
    # 전부 펼쳐서 돌려준다(전이 의존: dhcp가 addc의 DC01을 요구하고
    # addc가 rras의 RRAS01을 요구하면, dhcp의 closure에는 DC01과
    # RRAS01이 모두 들어간다). 반환 순서는 발견 순서(직접 의존이
    # 먼저)이며, 이 순서가 그대로 시작 순서로 쓰인다.
    [CmdletBinding()]
    [OutputType([array])]
    param(
        [Parameter(Mandatory)]
        [string]$Stage,

        [System.Collections.IDictionary]$Config
    )

    if (-not $Config) {
        $Config = Get-LabConfig
    }

    $cfg = $Config

    # StageDependencies 자체가 없거나(레거시/테스트 Config) 특정
    # Stage 키가 없을 수 있다 - 그런 경우는 의존성 없음으로 취급한다.
    # Set-StrictMode -Version Latest에서는 $null을 인덱싱하면 예외가
    # 나므로 .Contains()로 먼저 키 존재를 확인한다.
    $stageDependencies = $cfg['StageDependencies']

    $result = [Collections.Generic.List[string]]::new()
    $visited = [Collections.Generic.HashSet[string]]::new()
    $queue = [Collections.Generic.Queue[string]]::new()

    foreach (
        $directName in
        @(
            if (
                $stageDependencies -and
                $stageDependencies.Contains($Stage)
            ) {
                $stageDependencies[$Stage] |
                    Select-LabNonEmptyString
            }
        )
    ) {
        if ($visited.Add($directName)) {
            $queue.Enqueue($directName)
        }
    }

    while ($queue.Count -gt 0) {
        $name = $queue.Dequeue()
        $result.Add($name)

        $ownerStage = [string](
            Resolve-LabSingleSpec `
                -Name $name `
                -Config $cfg
        )['Stage']

        foreach (
            $nextName in
            @(
                if (
                    $stageDependencies -and
                    $stageDependencies.Contains($ownerStage)
                ) {
                    $stageDependencies[$ownerStage] |
                        Select-LabNonEmptyString
                }
            )
        ) {
            if ($visited.Add($nextName)) {
                $queue.Enqueue($nextName)
            }
        }
    }

    @($result)
}

function Get-LabStageRequiredSwitch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Stage,

        [string[]]$AdditionalVmName,

        [switch]$CheckExistence,

        [System.Collections.IDictionary]$Config
    )

    if (-not $Config) {
        $Config = Get-LabConfig
    }

    $cfg = $Config

    $names =
        [Collections.Generic.List[string]]::new()

    # Stage에 직접 선언된 스위치
    foreach (
        $switchSpec in
        @(Get-LabStageSwitch -Stage $Stage -Config $cfg)
    ) {
        $names.Add([string]$switchSpec['Name'])
    }

    # Stage의 VM이 참조하는 스위치.
    # 다른 Stage에 선언되어 있어도 이 Stage를 돌리려면 필요하다.
    foreach (
        $spec in
        @(Resolve-LabSpec -Stage $Stage -Config $cfg)
    ) {
        foreach ($switchName in @($spec['Switch'])) {
            $names.Add([string]$switchName)
        }
    }

    # StageDependencies로 자동 시작되는 VM이 참조하는 스위치.
    foreach (
        $depName in
        @(Get-LabStageDependencyClosure -Stage $Stage -Config $cfg)
    ) {
        $depSpec = Resolve-LabSingleSpec `
            -Name $depName `
            -Config $cfg

        foreach ($switchName in @($depSpec['Switch'])) {
            $names.Add([string]$switchName)
        }
    }

    foreach (
        $additionalName in
        @($AdditionalVmName | Select-LabNonEmptyString)
    ) {
        $additionalSpec = Resolve-LabSingleSpec `
            -Name $additionalName `
            -Context '-Also 대상' `
            -Config $cfg

        foreach ($switchName in @($additionalSpec['Switch'])) {
            $names.Add([string]$switchName)
        }
    }

    $hostSwitchesByName = $null

    if ($CheckExistence) {
        $hostSwitchesByName = @{}

        foreach (
            $hostSwitch in
            @(Get-VMSwitch -ErrorAction Stop)
        ) {
            if (-not $hostSwitchesByName.Contains($hostSwitch.Name)) {
                $hostSwitchesByName[$hostSwitch.Name] =
                    [Collections.Generic.List[object]]::new()
            }

            $hostSwitchesByName[$hostSwitch.Name].Add($hostSwitch)
        }
    }

    foreach ($name in @(
        $names |
            Select-Object -Unique |
            Sort-Object
    )) {
        $switchSpec = Get-LabSwitchSpec `
            -Name $name `
            -Config $cfg |
            Select-Object -First 1

        $actualSwitch = $null
        $exists = $null
        $actualType = $null
        $compliant = $null

        if ($CheckExistence) {
            $actualMatches = @(
                if ($hostSwitchesByName.Contains($name)) {
                    $hostSwitchesByName[$name]
                }
            )

            if ($actualMatches.Count -gt 1) {
                throw (
                    "동일한 이름의 Hyper-V 스위치가 " +
                    "여러 개 조회되었습니다: $name"
                )
            }

            $actualSwitch =
                $actualMatches |
                Select-Object -First 1

            $exists = $null -ne $actualSwitch

            if ($actualSwitch) {
                $actualType =
                    $actualSwitch.SwitchType.ToString()
            }

            $compliant = (
                $exists -and
                $actualType -eq
                [string]$switchSpec['Type']
            )
        }

        [pscustomobject]@{
            PSTypeName  = 'Lab.SwitchRequirement'
            Name        = $name
            DesiredType = [string]$switchSpec['Type']
            ActualType  = $actualType
            DeclaredIn  = [string]$switchSpec['Stage']
            Exists      = $exists
            Compliant   = $compliant
        }
    }
}

function Resolve-LabTemplate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [System.Collections.IDictionary]$Config
    )

    if (-not $Config) {
        $Config = Get-LabConfig
    }

    $cfg = $Config
    $entry = $cfg.Templates[$Name]

    if (-not $entry) {
        throw "템플릿 '$Name'이 LabConfig.psd1에 정의되어 있지 않습니다."
    }


    [pscustomobject]@{
        Name         = $Name
        VhdPath      = Join-Path $cfg.LabRoot $entry.Vhd
        UnattendPath = Join-Path $PSScriptRoot $entry.Unattend
        AccountMode  = [string]$entry.AccountMode
        SecureBoot   = [bool]$entry.SecureBoot
        EnableTpm    = [bool]$entry.EnableTpm
    }
}

