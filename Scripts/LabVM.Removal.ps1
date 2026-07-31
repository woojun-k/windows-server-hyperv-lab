Set-StrictMode -Version Latest

# Remove-LabVM의 제거 사전검사(충돌·교차 사용)와 실제 제거 실행을 담당한다.
# LabVM.psm1이 dot-source하며 모듈 스코프를 공유한다.

function Test-LabVmRemovalConflict {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [AllowNull()]
        [object]$Vm,

        [switch]$Force,

        [Parameter(Mandatory)]
        [string]$ExpectedVhdNormalized,

        [Parameter(Mandatory)]
        [string]$ExpectedVmNormalized
    )

    $result = [pscustomobject]@{
        BlockingResult  = $null
        ActualDiskPaths = @()
        Snapshots       = @()
    }

    if (-not $Vm) {
        return $result
    }

    $issues =
        [Collections.Generic.List[string]]::new()

    $preservedPaths =
        [Collections.Generic.List[string]]::new()

    try {
        $snapshots = @(
            Get-VMSnapshot `
                -VM $Vm `
                -ErrorAction Stop
        )
    }
    catch {
        $result.BlockingResult = New-LabVmRemovalResult `
            -Name $Name `
            -Status Failed `
            -Succeeded $false `
            -Reason 'RemovalPreflightException' `
            -Issues @($_.Exception.Message) `
            -ErrorMessage (
                "VM '$Name'의 체크포인트를 조회하지 " +
                "못했습니다: $($_.Exception.Message)"
            )

        return $result
    }

    $result.Snapshots = $snapshots

    if ($snapshots.Count -gt 0 -and -not $Force) {
        $result.BlockingResult = New-LabVmRemovalResult `
            -Name $Name `
            -Status Failed `
            -Succeeded $false `
            -Reason 'HasCheckpoints' `
            -Issues @(
                (
                    "VM '$Name'에 체크포인트가 " +
                    "$($snapshots.Count)개 있습니다: " +
                    (
                        (
                            $snapshots |
                                ForEach-Object Name
                        ) -join ', '
                    )
                )
            ) `
            -ErrorMessage (
                '체크포인트가 있는 VM은 자동으로 제거하지 ' +
                '않습니다. 체크포인트를 정리한 뒤 다시 ' +
                '시도하거나, -Force로 병합 후 제거를 ' +
                '진행하십시오.'
            )

        return $result
    }

    try {
        $actualDiskPaths = @(
            Get-VMHardDiskDrive `
                -VM $Vm `
                -ErrorAction Stop |
                ForEach-Object Path |
                Select-LabNonEmptyString |
                ForEach-Object {
                    ConvertTo-LabNormalizedPath -Path $_
                }
        )
    }
    catch {
        $result.BlockingResult = New-LabVmRemovalResult `
            -Name $Name `
            -Status Failed `
            -Succeeded $false `
            -Reason 'RemovalPreflightException' `
            -Issues @($_.Exception.Message) `
            -ErrorMessage (
                "VM '$Name'의 연결된 디스크를 조회하지 " +
                "못했습니다: $($_.Exception.Message)"
            )

        return $result
    }

    $result.ActualDiskPaths = $actualDiskPaths

    $externalDiskPaths = @(
        $actualDiskPaths |
            Where-Object {
                $_ -ine $ExpectedVhdNormalized
            }
    )

    $actualVmPath = ConvertTo-LabNormalizedPath `
        -Path $Vm.Path

    $externalVmPath = (
        -not [string]::IsNullOrWhiteSpace(
            $actualVmPath
        ) -and
        $actualVmPath -ine $ExpectedVmNormalized
    )

    if ($externalVmPath) {
        $issues.Add(
            'VM 구성 경로가 LabConfig의 예상 경로와 ' +
            "다릅니다: 실제=$actualVmPath"
        )

        $preservedPaths.Add($actualVmPath)

        $result.BlockingResult = New-LabVmRemovalResult `
            -Name $Name `
            -Status Failed `
            -Succeeded $false `
            -Reason 'ExternalVmConfigurationPath' `
            -PreservedPaths @($preservedPaths) `
            -Issues @($issues) `
            -ErrorMessage (
                'Remove-VM은 실제 VM 구성 파일을 삭제합니다. ' +
                'LabConfig 관리 범위 밖의 구성 경로를 가진 ' +
                'VM은 -Force로도 이 명령으로 제거하지 ' +
                '않습니다.'
            )

        return $result
    }

    # 외부 VHDX가 제거 대상 VM 구성 디렉터리 안에 있으면, VM 등록 제거
    # 후 $ExpectedVmPath를 재귀 삭제할 때 그 파일도 함께 지워진다.
    # 이 경우는 -Force로도 자동 제거를 허용하지 않는다.
    $expectedVmPrefix = (
        $ExpectedVmNormalized +
        [IO.Path]::DirectorySeparatorChar
    )

    $externalDisksInsideVmPath = @(
        $externalDiskPaths |
            Where-Object {
                $_.StartsWith(
                    $expectedVmPrefix,
                    [StringComparison]::OrdinalIgnoreCase
                )
            }
    )

    if ($externalDisksInsideVmPath.Count -gt 0) {
        foreach ($insidePath in $externalDisksInsideVmPath) {
            $issues.Add(
                '보존 대상 외부 VHDX가 제거 대상 VM 구성 ' +
                "디렉터리 안에 있습니다: $insidePath"
            )

            $preservedPaths.Add($insidePath)
        }

        $result.BlockingResult = New-LabVmRemovalResult `
            -Name $Name `
            -Status Failed `
            -Succeeded $false `
            -Reason 'ExternalDiskInsideVmPath' `
            -PreservedPaths @($preservedPaths) `
            -Issues @($issues) `
            -ErrorMessage (
                'VM 구성 디렉터리를 재귀 삭제하면 외부 VHDX도 ' +
                '삭제되므로 -Force로도 자동 제거하지 않습니다.'
            )

        return $result
    }

    if (
        $externalDiskPaths.Count -gt 0 -and
        -not $Force
    ) {
        foreach ($externalPath in $externalDiskPaths) {
            $issues.Add(
                'VM에 LabConfig 관리 범위 밖의 VHDX가 ' +
                "연결되어 있습니다: $externalPath"
            )

            $preservedPaths.Add($externalPath)
        }

        $result.BlockingResult = New-LabVmRemovalResult `
            -Name $Name `
            -Status Failed `
            -Succeeded $false `
            -Reason 'ExternalResourcesDetected' `
            -PreservedPaths @($preservedPaths) `
            -Issues @($issues) `
            -ErrorMessage (
                '구성 편차가 있는 VM을 제거하려면 ' +
                '-Force가 필요합니다. 외부 경로 VHDX는 ' +
                'Force를 사용해도 삭제하지 않습니다.'
            )
    }

    return $result
}

function Test-LabVmRemovalCrossUse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [AllowNull()]
        [object]$Vm,

        [switch]$Force,

        [Parameter(Mandatory)]
        [string]$ExpectedVhdPath,

        [Parameter(Mandatory)]
        [string]$ExpectedVhdNormalized,

        [Parameter(Mandatory)]
        [string]$ExpectedVmPath,

        [Parameter(Mandatory)]
        [string]$ExpectedVmNormalized,

        [Parameter(Mandatory)]
        [bool]$VhdExists,

        [object[]]$ActualDiskPaths = @()
    )

    # 이 지점에서는 VM, VHDX, 디렉터리를 절대 변경하지 않는다.
    # 모든 차단 조건을 확인한 뒤에만 $null을 반환해 실제 제거로 넘어간다.

    $preservedPaths =
        [Collections.Generic.List[string]]::new()

    try {
        # 실행 중 VM은 실제 제거 전에 차단한다.
        if (
            $Vm -and
            $Vm.State -ne 'Off' -and
            -not $Force
        ) {
            return (
                New-LabVmRemovalResult `
                    -Name $Name `
                    -Status Failed `
                    -Succeeded $false `
                    -Reason 'VmRunning' `
                    -PreservedPaths @(
                        $preservedPaths |
                            Select-Object -Unique
                    ) `
                    -Issues @(
                        "VM '$Name' 상태가 '$($Vm.State)'입니다."
                    ) `
                    -ErrorMessage (
                        '실행 중 VM을 제거하려면 ' +
                        '-Force가 필요합니다.'
                    )
            )
        }

        # 이후 검사에서 SilentlyContinue를 쓰지 않는다.
        # 조회 실패를 "사용 중인 VM 없음"으로 오판하면 안 된다.
        $allVms = @(
            Get-VM -ErrorAction Stop
        )

        # --------------------------------------------------------
        # 예상 VHDX를 다른 VM이 사용 중인지 확인
        # --------------------------------------------------------

        $otherVhdUsers =
            [Collections.Generic.List[string]]::new()

        foreach ($otherVm in $allVms) {
            # 제거 대상 VM 자신은 제외
            if (
                $Vm -and
                $otherVm.Id -eq $Vm.Id
            ) {
                continue
            }

            $otherDrivePaths = @(
                Get-VMHardDiskDrive `
                    -VM $otherVm `
                    -ErrorAction Stop |
                    ForEach-Object Path |
                    Select-LabNonEmptyString
            )

            foreach ($otherDrivePath in $otherDrivePaths) {
                if (
                    (
                        ConvertTo-LabNormalizedPath `
                            -Path $otherDrivePath
                    ) -ieq
                    $ExpectedVhdNormalized
                ) {
                    $otherVhdUsers.Add(
                        [string]$otherVm.Name
                    )
                }
            }
        }

        if ($otherVhdUsers.Count -gt 0) {
            $preservedPaths.Add($ExpectedVhdPath)

            return (
                New-LabVmRemovalResult `
                    -Name $Name `
                    -Status Failed `
                    -Succeeded $false `
                    -Reason 'VhdUsedByOtherVm' `
                    -PreservedPaths @(
                        $preservedPaths |
                            Select-Object -Unique
                    ) `
                    -Issues @(
                        (
                            '예상 VHDX가 다른 VM에서도 ' +
                            '사용 중입니다: ' +
                            (
                                $otherVhdUsers |
                                    Select-Object -Unique
                            ) -join ', '
                        ),
                        "VHDX: $ExpectedVhdPath"
                    ) `
                    -ErrorMessage (
                        '다른 VM이 사용하는 VHDX는 ' +
                        '자동 삭제할 수 없습니다.'
                    )
            )
        }

        # --------------------------------------------------------
        # 예상 VM 구성 디렉터리를 다른 VM이 사용하는지 확인
        # --------------------------------------------------------

        $expectedVmPrefix = (
            $ExpectedVmNormalized +
            [IO.Path]::DirectorySeparatorChar
        )

        $otherVmPathUsers =
            [Collections.Generic.List[string]]::new()

        foreach ($otherVm in $allVms) {
            if (
                $Vm -and
                $otherVm.Id -eq $Vm.Id
            ) {
                continue
            }

            $otherVmPath = ConvertTo-LabNormalizedPath `
                -Path $otherVm.Path

            if (
                [string]::IsNullOrWhiteSpace(
                    $otherVmPath
                )
            ) {
                continue
            }

            $usesExpectedVmPath = (
                $otherVmPath -ieq
                $ExpectedVmNormalized
            )

            $usesChildPath = (
                $otherVmPath.StartsWith(
                    $expectedVmPrefix,
                    [StringComparison]::OrdinalIgnoreCase
                )
            )

            if (
                $usesExpectedVmPath -or
                $usesChildPath
            ) {
                $otherVmPathUsers.Add(
                    [string]$otherVm.Name
                )
            }
        }

        if ($otherVmPathUsers.Count -gt 0) {
            $preservedPaths.Add($ExpectedVmPath)

            return (
                New-LabVmRemovalResult `
                    -Name $Name `
                    -Status Failed `
                    -Succeeded $false `
                    -Reason 'VmPathUsedByOtherVm' `
                    -PreservedPaths @(
                        $preservedPaths |
                            Select-Object -Unique
                    ) `
                    -Issues @(
                        (
                            '예상 VM 구성 디렉터리를 ' +
                            '다른 VM도 사용 중입니다: ' +
                            (
                                $otherVmPathUsers |
                                    Select-Object -Unique
                            ) -join ', '
                        ),
                        "VM 경로: $ExpectedVmPath"
                    ) `
                    -ErrorMessage (
                        '다른 VM이 사용하는 구성 디렉터리는 ' +
                        '자동 삭제할 수 없습니다.'
                    )
            )
        }

        # --------------------------------------------------------
        # 예상 VHDX가 대상 VM 이외의 방식으로 마운트됐는지 확인
        # --------------------------------------------------------

        if ($VhdExists) {
            $targetUsesExpectedVhd = (
                $Vm -and
                $ActualDiskPaths -contains
                $ExpectedVhdNormalized
            )

            $expectedVhd = Get-VHD `
                -Path $ExpectedVhdPath `
                -ErrorAction Stop

            # 대상 VM이 사용하는 정상 연결은 허용한다.
            # 대상 VM 제거 후 자동으로 분리되기 때문이다.
            #
            # 대상 VM이 사용하지 않는데 Attached이면
            # 호스트 Mount-VHD 또는 다른 외부 연결로 판단한다.
            if (
                $expectedVhd.Attached -and
                -not $targetUsesExpectedVhd
            ) {
                $preservedPaths.Add(
                    $ExpectedVhdPath
                )

                return (
                    New-LabVmRemovalResult `
                        -Name $Name `
                        -Status Failed `
                        -Succeeded $false `
                        -Reason 'VhdAttachedExternally' `
                        -PreservedPaths @(
                            $preservedPaths |
                                Select-Object -Unique
                        ) `
                        -Issues @(
                            (
                                '예상 VHDX가 제거 대상 VM이 아닌 ' +
                                '다른 방식으로 연결되어 있습니다: ' +
                                $ExpectedVhdPath
                            )
                        ) `
                        -ErrorMessage (
                            '외부에서 연결된 VHDX는 ' +
                            '자동 삭제할 수 없습니다.'
                        )
                )
            }
        }
    }
    catch {
        $message = (
            "VM '$Name' 제거 사전 검사 실패: " +
            $_.Exception.Message
        )

        Write-Warning $message

        return (
            New-LabVmRemovalResult `
                -Name $Name `
                -Status Failed `
                -Succeeded $false `
                -Reason 'RemovalPreflightException' `
                -PreservedPaths @(
                    $preservedPaths |
                        Select-Object -Unique
                ) `
                -Issues @($message) `
                -ErrorMessage $_.Exception.Message
        )
    }

    return $null
}

function Invoke-LabVmRemovalExecution {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [AllowNull()]
        [object]$Vm,

        [object[]]$Snapshots = @(),

        [Parameter(Mandatory)]
        [string]$ExpectedVhdPath,

        [Parameter(Mandatory)]
        [string]$ExpectedVmPath,

        [Parameter(Mandatory)]
        [string]$ExpectedVhdNormalized,

        [object[]]$ActualDiskPaths = @(),

        [Collections.Generic.List[string]]$RemovedPaths,

        [Collections.Generic.List[string]]$PreservedPaths
    )

    $actualDiskPaths = @($ActualDiskPaths)

    if ($Vm) {
        if ($Snapshots.Count -gt 0) {
            # 사전 검사에서 -Force가 확인된 경우에만 도달한다.
            # 병합 없이 Remove-VM부터 하면 체크포인트 .avhdx가
            # 고아로 남으므로, 등록 제거 전에 먼저 병합한다.
            $rootSnapshots = @(
                $Snapshots |
                    Where-Object {
                        -not $_.ParentSnapshotId
                    }
            )

            foreach ($rootSnapshot in $rootSnapshots) {
                Remove-VMSnapshot `
                    -VMSnapshot $rootSnapshot `
                    -IncludeAllChildSnapshots `
                    -Confirm:$false `
                    -ErrorAction Stop
            }

            $mergeDeadline =
                [datetime]::UtcNow.AddMinutes(10)

            while ($true) {
                $stillMerging = @(
                    Get-VMHardDiskDrive `
                        -VMName $Name `
                        -ErrorAction SilentlyContinue |
                        Where-Object {
                            $_.Path -like '*.avhdx'
                        }
                ).Count -gt 0

                $remainingSnapshots = @(
                    Get-VMSnapshot `
                        -VMName $Name `
                        -ErrorAction SilentlyContinue
                )

                if (
                    -not $stillMerging -and
                    $remainingSnapshots.Count -eq 0
                ) {
                    break
                }

                if (
                    [datetime]::UtcNow -gt $mergeDeadline
                ) {
                    throw (
                        '체크포인트 병합이 10분 내에 ' +
                        "끝나지 않았습니다: $Name"
                    )
                }

                Start-Sleep -Seconds 2
            }

            # 병합 후 연결된 디스크가 바뀌므로 보존 경로 보고를
            # 위해 다시 조회한다.
            $actualDiskPaths = @(
                Get-VMHardDiskDrive `
                    -VM $Vm `
                    -ErrorAction SilentlyContinue |
                    ForEach-Object Path |
                    Select-LabNonEmptyString |
                    ForEach-Object {
                        ConvertTo-LabNormalizedPath -Path $_
                    }
            )
        }

        if ($Vm.State -ne 'Off') {
            # 여기까지 왔다는 것은 사전 검사에서
            # -Force가 확인됐다는 뜻이다.
            Stop-VM `
                -VM $Vm `
                -TurnOff `
                -Force `
                -ErrorAction Stop
        }

        Remove-VM `
            -VM $Vm `
            -Force `
            -ErrorAction Stop

        $RemovedPaths.Add(
            "Hyper-V VM:$Name"
        )
    }

    if (
        Test-Path `
            -LiteralPath $ExpectedVhdPath
    ) {
        # Remove-VM 이후 대상 VM의 디스크 연결이
        # 실제로 해제됐는지 마지막으로 검사한다.
        $vhd = Get-VHD `
            -Path $ExpectedVhdPath `
            -ErrorAction Stop

        if ($vhd.Attached) {
            throw (
                'VM 등록 제거 후에도 예상 VHDX가 ' +
                '연결된 상태입니다: ' +
                $ExpectedVhdPath
            )
        }

        Remove-Item `
            -LiteralPath $ExpectedVhdPath `
            -Force `
            -ErrorAction Stop

        $RemovedPaths.Add(
            $ExpectedVhdPath
        )
    }

    if (
        Test-Path `
            -LiteralPath $ExpectedVmPath
    ) {
        # 사전 검사 이후 다른 프로세스가 파일을 새로 만든 경쟁
        # 조건에 대비해, 디렉터리 안에 남은 파일이 없을 때만
        # 재귀 삭제한다. 남은 파일이 있으면 통째로 보존한다.
        $remainingVmPathFiles = @(
            Get-ChildItem `
                -LiteralPath $ExpectedVmPath `
                -Force `
                -Recurse `
                -File `
                -ErrorAction Stop
        )

        if ($remainingVmPathFiles.Count -eq 0) {
            Remove-Item `
                -LiteralPath $ExpectedVmPath `
                -Recurse `
                -Force `
                -ErrorAction Stop

            $RemovedPaths.Add(
                $ExpectedVmPath
            )
        }
        else {
            $PreservedPaths.Add($ExpectedVmPath)
        }
    }

    # 실제 VM에 예상 경로 외 디스크가 연결돼 있었더라도
    # 해당 VHDX 파일은 직접 삭제하지 않는다.
    foreach ($actualDiskPath in $actualDiskPaths) {
        if (
            $actualDiskPath -ine
            $ExpectedVhdNormalized
        ) {
            $PreservedPaths.Add(
                $actualDiskPath
            )
        }
    }

    New-LabVmRemovalResult `
        -Name $Name `
        -Status Removed `
        -Succeeded $true `
        -Reason 'Removed' `
        -RemovedPaths @(
            $RemovedPaths
        ) `
        -PreservedPaths @(
            $PreservedPaths |
                Select-Object -Unique
        )
}
