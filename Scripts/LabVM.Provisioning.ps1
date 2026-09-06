Set-StrictMode -Version Latest

# New-LabVM 생성 실행(디스크/하드웨어/네트워크)과 롤백,
# 기존 VM 드리프트 교정을 담당한다.
# LabVM.psm1이 dot-source하며 모듈 스코프를 공유한다.

$script:LabCloudInitAppliedKvpKey = 'LabSeedApplied'
$script:LabCloudInitKvpPoolPath = '/var/lib/hyperv/.kvp_pool_1'

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
        [string]$VhdDirectory,

        [AllowEmptyString()]
        [AllowNull()]
        [string]$SeedVhdPath
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
        $State['CreatedSeedVhd'] -and
        -not [string]::IsNullOrWhiteSpace($SeedVhdPath) -and
        (Test-Path -LiteralPath $SeedVhdPath)
    ) {
        try {
            $seedVhdState = Get-VHD `
                -Path $SeedVhdPath `
                -ErrorAction SilentlyContinue

            if ($seedVhdState -and $seedVhdState.Attached) {
                Dismount-VHD `
                    -Path $SeedVhdPath `
                    -ErrorAction Stop
            }

            Remove-Item `
                -LiteralPath $SeedVhdPath `
                -Force `
                -ErrorAction Stop
        }
        catch {
            $rollbackIssues.Add(
                "cloud-init 시드 VHDX 롤백 실패: $($_.Exception.Message)"
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

function ConvertFrom-LabSecureString {
    <#
    .SYNOPSIS
        SecureString를 평문으로 되돌린다.
    .DESCRIPTION
        cloud-init user-data에 넣을 때만 사용한다. 호출자는 결과 문자열을
        오래 들고 있지 않는다.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [securestring]$SecureString
    )

    $bstr = [Runtime.InteropServices.Marshal]::
        SecureStringToBSTR($SecureString)

    try {
        [Runtime.InteropServices.Marshal]::
            PtrToStringBSTR($bstr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::
            ZeroFreeBSTR($bstr)
    }
}

function Get-LabCloudInitSeedContent {
    <#
    .SYNOPSIS
        cloud-init NoCloud 시드에 넣을 meta-data와 user-data를 만든다.
    .DESCRIPTION
        호스트 이름과, -AdminPassword를 주면 실습 계정 암호까지 주입한다.
        IP와 DNS는 각 실습 문서의 절차대로 게스트 안에서 직접 설정한다.

        마지막 runcmd는 적용이 끝났음을 Hyper-V KVP로 호스트에 알린다.
        호스트는 이 표시를 보고 시드 디스크를 회수한다.

        instance-id가 바뀌면 cloud-init이 새 인스턴스로 보고 per-instance
        모듈을 다시 실행하므로, VM을 다시 만들 때마다 새 값을 쓴다.

        암호는 user-data에 평문으로 들어간다. Windows 응답 파일이 암호를
        Base64로만 감싸 자식 VHDX에 넣는 것과 노출 수준이 같고, 시드
        VHDX는 호스트의 VHDs 폴더에만 있다가 첫 부팅이 끝나는 즉시
        Remove-LabVmCloudInitSeed로 회수된다.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [string]$UserName,

        [securestring]$AdminPassword,

        [string]$InstanceId
    )

    if ([string]::IsNullOrWhiteSpace($InstanceId)) {
        $InstanceId = '{0}-{1}' -f `
            $Name, `
            [guid]::NewGuid().ToString('N')
    }

    $metaData = (
        @(
            "instance-id: $InstanceId",
            "local-hostname: $Name"
        ) -join "`n"
    ) + "`n"

    $userDataLines = [Collections.Generic.List[string]]::new()

    $userDataLines.Add('#cloud-config')
    $userDataLines.Add('preserve_hostname: false')

    if (
        $AdminPassword -and
        -not [string]::IsNullOrWhiteSpace($UserName)
    ) {
        $plainPassword = ConvertFrom-LabSecureString `
            -SecureString $AdminPassword

        $escapedPassword = $plainPassword -replace "'", "''"

        $userDataLines.Add('chpasswd:')
        $userDataLines.Add('  expire: false')
        $userDataLines.Add('  users:')
        $userDataLines.Add("    - name: $UserName")
        $userDataLines.Add("      password: '$escapedPassword'")
        $userDataLines.Add('      type: text')
    }

    $kvpWriteScript = (
        'open("{0}","wb").write(' -f $script:LabCloudInitKvpPoolPath
    ) + (
        'b"{0}".ljust(512,bytes(1))' -f $script:LabCloudInitAppliedKvpKey
    ) + (
        ' + b"{0}".ljust(2048,bytes(1)))' -f $Name
    )

    $userDataLines.Add('runcmd:')
    $userDataLines.Add("  - [ python3, -c, '$kvpWriteScript' ]")
    $userDataLines.Add('  - [ systemctl, restart, hypervkvpd.service ]')

    $userData = ($userDataLines -join "`n") + "`n"

    [pscustomobject]@{
        InstanceId = $InstanceId
        MetaData   = $metaData
        UserData   = $userData
    }
}

function Add-LabVmCloudInitSeedDisk {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessage(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = '호출자인 New-LabVM이 ShouldProcess 확인을 이미 거친 뒤에만 호출하는 내부 헬퍼다.'
    )]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$SeedVhdPath,

        [string]$UserName,

        [securestring]$AdminPassword,

        [Parameter(Mandatory)]
        [hashtable]$State
    )

    if (Test-Path -LiteralPath $SeedVhdPath) {
        throw (
            'cloud-init 시드 VHDX가 이미 있습니다. 이전 VM의 잔여 ' +
            "파일이면 삭제한 뒤 다시 시도하십시오: $SeedVhdPath"
        )
    }

    $seedDirectory = Split-Path -Path $SeedVhdPath -Parent

    if (-not (Test-Path -LiteralPath $seedDirectory)) {
        New-Item `
            -Path $seedDirectory `
            -ItemType Directory `
            -ErrorAction Stop |
            Out-Null
    }

    $seedContent = Get-LabCloudInitSeedContent `
        -Name $Name `
        -UserName $UserName `
        -AdminPassword $AdminPassword

    New-VHD `
        -Path $SeedVhdPath `
        -SizeBytes 64MB `
        -Fixed `
        -ErrorAction Stop |
        Out-Null

    $State.CreatedSeedVhd = $true

    $mounted = $false

    try {
        $mountedVhd = Mount-VHD `
            -Path $SeedVhdPath `
            -Passthru `
            -ErrorAction Stop

        $mounted = $true

        $diskNumber = [int]$mountedVhd.DiskNumber

        Initialize-Disk `
            -Number $diskNumber `
            -PartitionStyle MBR `
            -Confirm:$false `
            -ErrorAction Stop |
            Out-Null

        $partition = New-Partition `
            -DiskNumber $diskNumber `
            -UseMaximumSize `
            -AssignDriveLetter `
            -ErrorAction Stop

        Format-Volume `
            -Partition $partition `
            -FileSystem FAT `
            -NewFileSystemLabel 'CIDATA' `
            -Force `
            -Confirm:$false `
            -ErrorAction Stop |
            Out-Null

        $seedVolume = Get-Partition `
            -DiskNumber $diskNumber `
            -PartitionNumber $partition.PartitionNumber `
            -ErrorAction Stop

        $seedDriveLetter = [string]$seedVolume.DriveLetter

        if (
            [string]::IsNullOrWhiteSpace($seedDriveLetter) -or
            $seedDriveLetter -eq "`0"
        ) {
            throw (
                'cloud-init 시드 볼륨에 드라이브 문자를 할당하지 ' +
                "못했습니다: $SeedVhdPath"
            )
        }

        $seedRoot = '{0}:\' -f $seedDriveLetter

        $seedEncoding = [Text.UTF8Encoding]::new($false)

        [IO.File]::WriteAllText(
            (Join-Path $seedRoot 'meta-data'),
            $seedContent.MetaData,
            $seedEncoding
        )

        [IO.File]::WriteAllText(
            (Join-Path $seedRoot 'user-data'),
            $seedContent.UserData,
            $seedEncoding
        )
    }
    finally {
        if ($mounted) {
            Dismount-VHD `
                -Path $SeedVhdPath `
                -ErrorAction SilentlyContinue
        }
    }

    Add-VMHardDiskDrive `
        -VMName $Name `
        -Path $SeedVhdPath `
        -ErrorAction Stop
}

function Get-LabVmGuestKvpItem {
    <#
    .SYNOPSIS
        게스트가 Hyper-V KVP 풀에 올린 항목을 모두 읽는다.
    .DESCRIPTION
        게스트가 쓰고 호스트가 읽는 항목(GuestExchangeItems)만 본다.
        게스트 쪽 통합 서비스(Linux는 hypervkvpd)가 값을 올린 뒤에만
        읽을 수 있고, 아직 없으면 빈 배열을 돌려준다.

        호스트 이름 같은 내장 항목(GuestIntrinsicExchangeItems)은 쓰지
        않는다. Linux의 FullyQualifiedDomainName은 hypervkvpd가
        getaddrinfo로 만들어 내는 값이라, cloud-init이 호스트 이름을
        바꾼 뒤에도 부팅 초기의 값이 그대로 남아 있을 수 있다.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $items = [Collections.Generic.List[object]]::new()

    try {
        $vmObject = Get-CimInstance `
            -Namespace 'root\virtualization\v2' `
            -ClassName 'Msvm_ComputerSystem' `
            -Filter (
                "ElementName='{0}'" -f ($Name -replace "'", "''")
            ) `
            -ErrorAction Stop |
            Select-Object -First 1

        if (-not $vmObject) {
            return @()
        }

        $kvpComponent = Get-CimAssociatedInstance `
            -InputObject $vmObject `
            -ResultClassName 'Msvm_KvpExchangeComponent' `
            -ErrorAction Stop |
            Select-Object -First 1

        if (
            -not $kvpComponent -or
            -not $kvpComponent.PSObject.Properties[
                'GuestExchangeItems'
            ]
        ) {
            return @()
        }

        foreach (
            $item in
            @($kvpComponent.GuestExchangeItems)
        ) {
            if ([string]::IsNullOrWhiteSpace($item)) {
                continue
            }

            $itemXml = [xml]$item

            $itemName = $itemXml.SelectSingleNode(
                "/INSTANCE/PROPERTY[@NAME='Name']/VALUE"
            )

            if (-not $itemName) {
                continue
            }

            $itemData = $itemXml.SelectSingleNode(
                "/INSTANCE/PROPERTY[@NAME='Data']/VALUE"
            )

            $items.Add(
                [pscustomobject]@{
                    Name = [string]$itemName.InnerText

                    Data = if ($itemData) {
                        [string]$itemData.InnerText
                    }
                    else {
                        ''
                    }
                }
            )
        }
    }
    catch {
        return @()
    }

    return @($items)
}

function Get-LabVmGuestKvpValue {
    <#
    .SYNOPSIS
        게스트가 Hyper-V KVP 풀에 올린 값 하나를 읽는다.
    .DESCRIPTION
        Get-LabVmGuestKvpItem이 읽어 온 항목에서 $Key와 이름이 같은
        것을 찾는다. 없으면 $null을 돌려준다.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Key
    )

    $item = @(
        Get-LabVmGuestKvpItem -Name $Name |
            Where-Object {
                $_.Name -eq $Key
            }
    ) |
        Select-Object -First 1

    if (-not $item) {
        return $null
    }

    return [string]$item.Data
}

function Remove-LabVmCloudInitSeedDisk {
    <#
    .SYNOPSIS
        cloud-init 시드 디스크를 VM에서 분리하고 VHDX를 지운다.
    .DESCRIPTION
        시드는 첫 부팅에서 한 번만 쓰이고, 안에는 실습 계정 암호가
        평문으로 들어 있다. 그래서 적용이 끝나면 곧바로 회수한다.

        Gen 2 VM에서는 SCSI 컨트롤러에 붙으므로 게스트가 켜져 있어도
        분리할 수 있다.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessage(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = '호출자인 Remove-LabVmCloudInitSeed가 ShouldProcess 확인을 이미 거친 뒤에만 호출하는 내부 헬퍼다.'
    )]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$SeedVhdPath
    )

    $seedNormalized = ConvertTo-LabNormalizedPath `
        -Path $SeedVhdPath

    $attachedSeedDrives = @(
        Get-VMHardDiskDrive `
            -VMName $Name `
            -ErrorAction SilentlyContinue |
            Where-Object {
                (
                    ConvertTo-LabNormalizedPath `
                        -Path $_.Path
                ) -ieq $seedNormalized
            }
    )

    foreach ($seedDrive in $attachedSeedDrives) {
        Remove-VMHardDiskDrive `
            -VMHardDiskDrive $seedDrive `
            -ErrorAction Stop
    }

    if (-not (Test-Path -LiteralPath $SeedVhdPath)) {
        return
    }

    $lastRemoveError = $null

    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            Remove-Item `
                -LiteralPath $SeedVhdPath `
                -Force `
                -ErrorAction Stop

            return
        }
        catch {
            $lastRemoveError = $_

            Start-Sleep -Seconds 1
        }
    }

    throw (
        'cloud-init 시드 VHDX를 지우지 못했습니다: ' +
        "$SeedVhdPath. " +
        $lastRemoveError.Exception.Message
    )
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
            -SecureBootTemplate (
                Get-LabSecureBootTemplateName `
                    -Template $Check.Template
            ) `
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
