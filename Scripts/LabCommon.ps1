Set-StrictMode -Version Latest

# ================================================================
# LabVM 공통 헬퍼
#
# LabVM.psm1이 dot-source로 읽어 들이며 모듈 스코프를 공유한다.
# 따라서 이 파일의 함수도 $script: 변수와
# LabVM.psm1의 함수를 그대로 사용할 수 있다.
#
# 이 파일에는 다음 두 종류만 둔다.
#   1. 여러 함수가 함께 쓰는 순수 유틸리티
#   2. 여러 함수에 같은 형태로 반복되던 검사와 조회
# ================================================================

$script:ComputerNamePattern =
    '^(?![0-9]+$)(?!-)[A-Za-z0-9-]{1,15}(?<!-)$'

$script:LocalAdminNamePattern =
    '^(?![. ]+$)(?! )(?!.*\.$)(?!(?i:Administrator|Guest)$)[^"/\\[\]:;|=,+*?<>@]{1,20}$'


# ----------------------------------------------------------------
# 값과 문자열
# ----------------------------------------------------------------

function Copy-LabValue {
    [CmdletBinding()]
    [OutputType([hashtable])]
    [OutputType([System.Object[]])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $Value
    )

    if ($null -eq $Value) {
        return $null
    }

    if (
        $Value -is
        [System.Collections.IDictionary]
    ) {
        $copy = @{}

        foreach ($key in $Value.Keys) {
            $copy[$key] = Copy-LabValue `
                -Value $Value[$key]
        }

        return $copy
    }

    if (
        $Value -is
        [System.Collections.IEnumerable] -and
        $Value -isnot [string]
    ) {
        # 단항 콤마로 감싸지 않으면 빈 배열이 파이프라인에서
        # 0개 객체로 풀려 호출부에서 $null로 대입된다.
        return , @(
            foreach ($item in $Value) {
                Copy-LabValue -Value $item
            }
        )
    }

    $Value
}

function Merge-LabHashtable {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Base,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Override
    )

    foreach ($key in $Override.Keys) {
        if ($Base.Contains($key) -and
            $Base[$key] -is [System.Collections.IDictionary] -and
            $Override[$key] -is [System.Collections.IDictionary]) {

            Merge-LabHashtable `
                -Base $Base[$key] `
                -Override $Override[$key] | Out-Null
        }
        else {
            $Base[$key] = $Override[$key]
        }
    }

    $Base
}

function ConvertTo-LabXmlText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    [Security.SecurityElement]::Escape($Value)
}

function Select-LabNonEmptyString {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(ValueFromPipeline)]
        [AllowNull()]
        [AllowEmptyCollection()]
        $Value,

        [switch]$Trim
    )

    process {
        foreach ($item in @($Value)) {
            $text = [string]$item

            if (
                [string]::IsNullOrWhiteSpace($text)
            ) {
                continue
            }

            if ($Trim) {
                $text.Trim()
            }
            else {
                $text
            }
        }
    }
}

function ConvertTo-LabDisplayText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(ValueFromPipeline)]
        [AllowNull()]
        [AllowEmptyCollection()]
        $Value,

        # 값이 비어 있을 때 대신 표시할 문자열.
        [Parameter(Mandatory)]
        [string]$Placeholder
    )

    process {
        foreach ($item in @($Value)) {
            $text = [string]$item

            if (
                [string]::IsNullOrWhiteSpace($text)
            ) {
                $Placeholder
            }
            else {
                $text
            }
        }
    }
}

function Get-LabDuplicateValue {
    [CmdletBinding()]
    [OutputType([array])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Value
    )

    @(
        $Value |
            Group-Object |
            Where-Object {
                $_.Count -gt 1
            } |
            ForEach-Object Name
    )
}


# ----------------------------------------------------------------
# 경로와 용량
# ----------------------------------------------------------------

function ConvertTo-LabNormalizedPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }

    (
        [IO.Path]::GetFullPath($Path)
    ).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
}

function ConvertTo-LabGB {
    [CmdletBinding(DefaultParameterSetName = 'Byte')]
    param(
        [Parameter(
            Mandatory,
            ParameterSetName = 'Byte'
        )]
        [int64]$Byte,

        [Parameter(
            Mandatory,
            ParameterSetName = 'Megabyte'
        )]
        [int64]$Megabyte,

        [int]$Decimals = 1
    )

    $bytes = if (
        $PSCmdlet.ParameterSetName -eq 'Megabyte'
    ) {
        $Megabyte * 1MB
    }
    else {
        $Byte
    }

    [math]::Round($bytes / 1GB, $Decimals)
}

function Format-LabDiskShortageMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DiskMode,

        [Parameter(Mandatory)]
        [int64]$RequiredBytes,

        [Parameter(Mandatory)]
        [int64]$CreationBytes,

        [Parameter(Mandatory)]
        [int64]$SafetyReserveBytes,

        [Parameter(Mandatory)]
        [int64]$AvailableBytes,

        [string]$Prefix = '디스크 여유 공간 부족',

        [int]$TargetCount = 0,

        [string]$Volume
    )

    $parts =
        [Collections.Generic.List[string]]::new()

    $parts.Add("모드=$DiskMode")

    if ($TargetCount -gt 0) {
        $parts.Add("생성 대상=${TargetCount}대")
    }

    $parts.Add(
        "필요=$(
            ConvertTo-LabGB `
                -Byte $RequiredBytes `
                -Decimals 2
        )GB " +
        "(생성 $(
            ConvertTo-LabGB `
                -Byte $CreationBytes `
                -Decimals 2
        )GB + 안전 여유 $(
            ConvertTo-LabGB `
                -Byte $SafetyReserveBytes `
                -Decimals 2
        )GB)"
    )

    $parts.Add(
        "가용=$(
            ConvertTo-LabGB `
                -Byte $AvailableBytes `
                -Decimals 2
        )GB"
    )

    if (
        -not [string]::IsNullOrWhiteSpace($Volume)
    ) {
        $parts.Add("볼륨=$Volume")
    }

    "${Prefix}: " + ($parts -join ', ')
}


# ----------------------------------------------------------------
# 입력값 검증
# ----------------------------------------------------------------

function Assert-LabTimeZoneId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$TimeZone
    )

    if ([string]::IsNullOrWhiteSpace($TimeZone)) {
        throw 'TimeZone은 비어 있을 수 없습니다.'
    }

    try {
        $null = [TimeZoneInfo]::FindSystemTimeZoneById(
            $TimeZone
        )
    }
    catch {
        throw (
            "TimeZone '$TimeZone'은 이 호스트에서 " +
            '인식할 수 있는 Windows 시간대 ID가 아닙니다.'
        )
    }
}

function Assert-LabComputerName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Name,

        [string]$Label = 'ComputerName'
    )

    if (
        $Name -notmatch
        $script:ComputerNamePattern
    ) {
        throw (
            "$Label '$Name'은 " +
            'Windows 컴퓨터 이름 규칙을 만족하지 않습니다.'
        )
    }
}

function Assert-LabLocalAdminName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Name
    )

    if (
        [string]::IsNullOrWhiteSpace($Name) -or
        $Name -notmatch
        $script:LocalAdminNamePattern
    ) {
        throw (
            "LocalAdminName '$Name'은 " +
            'Windows 로컬 계정 이름 규칙을 만족하지 않습니다.'
        )
    }
}


# ----------------------------------------------------------------
# 결과 객체 공통 처리
# ----------------------------------------------------------------

function Assert-LabResultContract {
    [CmdletBinding()]
    param(
        # 오류 메시지 앞에 붙는 결과 종류. 예: 'VM 결과'
        [Parameter(Mandatory)]
        [string]$Kind,

        [Parameter(Mandatory)]
        [string]$Status,

        [Parameter(Mandatory)]
        [bool]$Succeeded,

        [Parameter(Mandatory)]
        [string[]]$SuccessStatus
    )

    $expectedSucceeded = (
        $Status -in $SuccessStatus
    )

    if ($Succeeded -ne $expectedSucceeded) {
        throw (
            "$Kind 상태 계약 위반: " +
            "Status='$Status', " +
            "Succeeded='$Succeeded'"
        )
    }
}

function Select-LabResultByStatus {
    [CmdletBinding()]
    [OutputType([array])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Result = @(),

        [Parameter(Mandatory)]
        [string[]]$Status,

        # 계획 객체처럼 Status가 아닌 속성으로
        # 판정해야 하는 경우에 사용한다.
        [string]$Property = 'Status'
    )

    @(
        $Result |
            Where-Object {
                $_.$Property -in $Status
            }
    )
}

function Get-LabStatusCount {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Result = @(),

        [Parameter(Mandatory)]
        [string[]]$Status,

        [string]$Property = 'Status'
    )

    @(
        Select-LabResultByStatus `
            -Result $Result `
            -Status $Status `
            -Property $Property
    ).Count
}

function Resolve-LabAggregateStatus {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Result = @(),

        # 우선순위가 높은 상태부터 나열한다.
        [Parameter(Mandatory)]
        [string[]]$Priority,

        [Parameter(Mandatory)]
        [string]$DefaultStatus,

        [string]$Property = 'Status'
    )

    foreach ($status in $Priority) {
        $count = Get-LabStatusCount `
            -Result $Result `
            -Status $status `
            -Property $Property

        if ($count -gt 0) {
            return $status
        }
    }

    $DefaultStatus
}

function Write-LabPrefixedWarning {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Prefix,

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Message = @()
    )

    foreach ($item in @($Message)) {
        Write-Warning "${Prefix}: $item"
    }
}

function Assert-LabNoDeferredError {
    [CmdletBinding()]
    param(
        # 본 작업에서 발생한 예외. 없으면 $null.
        [AllowNull()]
        [Exception]$OperationError,

        # finally 정리 단계에서 발생한 예외 목록.
        [AllowNull()]
        [AllowEmptyCollection()]
        [Exception[]]$CleanupError = @(),

        # 본 작업과 정리가 모두 실패했을 때의 메시지.
        [Parameter(Mandatory)]
        [string]$CombinedMessage,

        # 정리만 실패했을 때의 메시지.
        # 생략하면 정리 예외를 그대로 던진다.
        [string]$CleanupMessage
    )

    $cleanupErrors = @(
        $CleanupError |
            Where-Object {
                $null -ne $_
            }
    )

    if ($OperationError) {
        if ($cleanupErrors.Count -gt 0) {
            throw [AggregateException]::new(
                $CombinedMessage,
                [Exception[]]@(
                    $OperationError
                    $cleanupErrors
                )
            )
        }

        throw $OperationError
    }

    if ($cleanupErrors.Count -eq 0) {
        return
    }

    if (
        [string]::IsNullOrWhiteSpace($CleanupMessage) -and
        $cleanupErrors.Count -eq 1
    ) {
        throw $cleanupErrors[0]
    }

    throw [AggregateException]::new(
        $(
            if (
                [string]::IsNullOrWhiteSpace(
                    $CleanupMessage
                )
            ) {
                $CombinedMessage
            }
            else {
                $CleanupMessage
            }
        ),
        [Exception[]]$cleanupErrors
    )
}


# ----------------------------------------------------------------
# Hyper-V 조회와 디스크 조작
# ----------------------------------------------------------------

function Get-LabVmByName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $matchingVms = @(
        Get-VM -ErrorAction Stop |
            Where-Object {
                $_.Name -eq $Name
            }
    )

    if ($matchingVms.Count -gt 1) {
        throw (
            "동일한 이름의 Hyper-V VM이 여러 개 조회되었습니다: " +
            $Name
        )
    }

    $matchingVms | Select-Object -First 1
}

function Get-LabMissingCommand {
    [CmdletBinding()]
    [OutputType([array])]
    param(
        [Parameter(Mandatory)]
        [string[]]$Name
    )

    @(
        $Name |
            Where-Object {
                -not (
                    Get-Command $_ `
                        -ErrorAction SilentlyContinue
                )
            }
    )
}

function Get-LabWindowsPartition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Disk
    )

    $partitions = @(
        $Disk |
            Get-Partition |
            Sort-Object Size -Descending
    )

    foreach ($partition in $partitions) {
        $current = $partition

        if (
            -not $current.DriveLetter -and
            $current.Type -eq 'Basic'
        ) {
            try {
                $current |
                    Add-PartitionAccessPath `
                        -AssignDriveLetter `
                        -ErrorAction Stop |
                    Out-Null

                $current = Get-Partition `
                    -DiskNumber $Disk.Number `
                    -PartitionNumber $partition.PartitionNumber
            }
            catch {
                continue
            }
        }

        if (
            $current.DriveLetter -and
            (
                Test-Path (
                    "$($current.DriveLetter):" +
                    '\Windows\System32\ntoskrnl.exe'
                )
            )
        ) {
            return $current
        }
    }

    $null
}

function Dismount-LabVhd {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        # 분리 후에도 연결 상태로 남았을 때의 메시지.
        [string]$FailureMessage
    )

    Dismount-VHD `
        -Path $Path `
        -ErrorAction Stop

    $vhdState = Get-VHD `
        -Path $Path `
        -ErrorAction Stop

    if (-not $vhdState.Attached) {
        return
    }

    if (
        [string]::IsNullOrWhiteSpace($FailureMessage)
    ) {
        throw "VHDX 분리에 실패했습니다: $Path"
    }

    throw $FailureMessage
}
