Set-StrictMode -Version Latest

# 응답 파일(unattend) 처리와 템플릿 VHDX generalize 상태 검사 등
# 오프라인 이미지 조작을 담당한다. LabVM.psm1이 dot-source하며
# 모듈 스코프를 공유한다.

$script:TemplateGeneralizationCache = @{}


function ConvertTo-UnattendPassword {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [securestring]$Password,

        [ValidateSet(
            'AdministratorPassword',
            'Password'
        )]
        [string]$Element = 'AdministratorPassword'
    )

    $bstr = [Runtime.InteropServices.Marshal]::
        SecureStringToGlobalAllocUnicode($Password)

    $passwordBytes = $null
    $elementBytes = $null

    try {
        $charCount = $Password.Length
        $elementBytes = [Text.Encoding]::Unicode.GetBytes($Element)
        $passwordBytes = [byte[]]::new(
            ($charCount * 2) + $elementBytes.Length
        )

        [Runtime.InteropServices.Marshal]::Copy(
            $bstr,
            $passwordBytes,
            0,
            $charCount * 2
        )

        [Array]::Copy(
            $elementBytes,
            0,
            $passwordBytes,
            $charCount * 2,
            $elementBytes.Length
        )

        [Convert]::ToBase64String($passwordBytes)
    }
    finally {
        if ($null -ne $passwordBytes) {
            [Array]::Clear(
                $passwordBytes,
                0,
                $passwordBytes.Length
            )
        }

        if ($null -ne $elementBytes) {
            [Array]::Clear(
                $elementBytes,
                0,
                $elementBytes.Length
            )
        }

        [Runtime.InteropServices.Marshal]::
            ZeroFreeGlobalAllocUnicode($bstr)
    }
}

function Get-LabTemplateMountMutexName {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$NormalizedPath
    )

    $sha256 = [Security.Cryptography.SHA256]::Create()

    try {
        $hashBytes = $sha256.ComputeHash(
            [Text.Encoding]::UTF8.GetBytes(
                $NormalizedPath.ToUpperInvariant()
            )
        )
    }
    finally {
        $sha256.Dispose()
    }

    'Global\LabVM.TemplateMount.' + (
        [BitConverter]::ToString($hashBytes) -replace '-'
    )
}

function Test-LabTemplateGeneralization {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$VhdPath
    )

    if (-not (Test-Path -LiteralPath $VhdPath)) {
        throw "템플릿 VHDX가 없습니다: $VhdPath"
    }

    $item = Get-Item `
        -LiteralPath $VhdPath `
        -ErrorAction Stop

    $normalizedPath = [IO.Path]::GetFullPath(
        $item.FullName
    )

    # 파일이 교체되면 자동으로 새 캐시 키가 만들어진다.
    $cacheKey = (
        '{0}|{1}|{2}' -f
        $normalizedPath.ToUpperInvariant(),
        $item.Length,
        $item.LastWriteTimeUtc.Ticks
    )

    if (
        $script:TemplateGeneralizationCache.ContainsKey(
            $cacheKey
        )
    ) {
        return (
            $script:TemplateGeneralizationCache[$cacheKey]
        )
    }

    # 같은 템플릿에 대한 Mount-VHD/Dismount-VHD가 다른 프로세스와
    # 겹치지 않도록 전역 뮤텍스로 직렬화한다.
    $templateMutexName = Get-LabTemplateMountMutexName `
        -NormalizedPath $normalizedPath

    $templateMutex = [Threading.Mutex]::new(
        $false,
        $templateMutexName
    )

    $templateMutexAcquired = $false

    try {
        try {
            $templateMutexAcquired = $templateMutex.WaitOne(
                [TimeSpan]::FromMinutes(10)
            )
        }
        catch [Threading.AbandonedMutexException] {
            $templateMutexAcquired = $true
        }

        if (-not $templateMutexAcquired) {
            throw (
                '템플릿 마운트 뮤텍스 획득 시간 초과: ' +
                $normalizedPath
            )
        }

        if (
            $script:TemplateGeneralizationCache.ContainsKey(
                $cacheKey
            )
        ) {
            return (
                $script:TemplateGeneralizationCache[$cacheKey]
            )
        }

        $result = Get-LabTemplateGeneralizationState `
            -VhdPath $VhdPath `
            -NormalizedPath $normalizedPath

        $script:TemplateGeneralizationCache[$cacheKey] = $result

        $result
    }
    finally {
        if ($templateMutexAcquired) {
            $templateMutex.ReleaseMutex()
        }

        $templateMutex.Dispose()
    }
}

function Get-LabTemplateGeneralizationState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$VhdPath,

        [Parameter(Mandatory)]
        [string]$NormalizedPath
    )

    $mounted = $null
    $softwareHiveLoaded = $false
    $softwareHiveName = (
        'LABVM_SOFTWARE_' +
        [guid]::NewGuid().ToString('N')
    )

    $registryBase = $null
    $setupStateKey = $null
    $stagedHivePath = $null

    $operationError = $null
    $cleanupErrors =
        [Collections.Generic.List[Exception]]::new()

    $imageState = $null
    $stateIniImageState = $null

    try {
        $vhd = Get-VHD `
            -Path $VhdPath `
            -ErrorAction Stop

        if ($vhd.Attached) {
            throw (
                'generalize 상태 검사를 위해서는 템플릿이 ' +
                "분리되어 있어야 합니다: $VhdPath"
            )
        }

        # 템플릿을 변경하지 않도록 읽기 전용 마운트
        $mounted = Mount-VHD `
            -Path $VhdPath `
            -ReadOnly `
            -Passthru `
            -ErrorAction Stop

        $disk = $mounted |
            Get-Disk `
                -ErrorAction Stop

        $partition = Get-LabWindowsPartition `
            -Disk $disk

        if (-not $partition) {
            throw (
                'Windows 파티션을 찾지 못했습니다: ' +
                $VhdPath
            )
        }

        $windowsRoot = (
            "$($partition.DriveLetter):\Windows"
        )

        $softwareHivePath = Join-Path `
            $windowsRoot `
            'System32\Config\SOFTWARE'

        if (
            -not (
                Test-Path `
                    -LiteralPath $softwareHivePath
            )
        ) {
            throw (
                '오프라인 SOFTWARE 하이브가 없습니다: ' +
                $softwareHivePath
            )
        }

        $stagedHivePath = Join-Path `
            ([IO.Path]::GetTempPath()) `
            "$softwareHiveName.hiv"

        Copy-Item `
            -LiteralPath $softwareHivePath `
            -Destination $stagedHivePath `
            -ErrorAction Stop

        $regOutput = @(
            & reg.exe load `
                "HKLM\$softwareHiveName" `
                $stagedHivePath `
                2>&1
        )

        if ($LASTEXITCODE -ne 0) {
            throw (
                '오프라인 SOFTWARE 하이브 로드 실패: ' +
                ($regOutput -join ' ')
            )
        }

        $softwareHiveLoaded = $true

        $registryBase =
            [Microsoft.Win32.RegistryKey]::OpenBaseKey(
                [Microsoft.Win32.RegistryHive]::LocalMachine,
                [Microsoft.Win32.RegistryView]::Registry64
            )

        $setupStateKey = $registryBase.OpenSubKey(
            (
                "$softwareHiveName\" +
                'Microsoft\Windows\CurrentVersion\' +
                'Setup\State'
            )
        )

        if (-not $setupStateKey) {
            throw (
                'Windows Setup State 레지스트리 키를 ' +
                '찾지 못했습니다.'
            )
        }

        $imageState = [string](
            $setupStateKey.GetValue(
                'ImageState',
                $null
            )
        )

        $stateIniPath = Join-Path `
            $windowsRoot `
            'Setup\State\State.ini'

        if (
            Test-Path `
                -LiteralPath $stateIniPath
        ) {
            $stateIniText = Get-Content `
                -LiteralPath $stateIniPath `
                -Raw `
                -ErrorAction Stop

            $stateMatch = [regex]::Match(
                $stateIniText,
                (
                    '(?im)^\s*ImageState\s*=\s*' +
                    '"?([^"\r\n]+)"?\s*$'
                )
            )

            if ($stateMatch.Success) {
                $stateIniImageState = (
                    $stateMatch.Groups[1].Value.Trim()
                )
            }
        }
    }
    catch {
        $operationError = $_.Exception
    }
    finally {
        if ($setupStateKey) {
            $setupStateKey.Dispose()
        }

        if ($registryBase) {
            $registryBase.Dispose()
        }

        if ($softwareHiveLoaded) {
            try {
                [gc]::Collect()
                [gc]::WaitForPendingFinalizers()

                $regOutput = @(
                    & reg.exe unload `
                        "HKLM\$softwareHiveName" `
                        2>&1
                )

                if ($LASTEXITCODE -ne 0) {
                    throw (
                        '오프라인 SOFTWARE 하이브 ' +
                        '언로드 실패: ' +
                        ($regOutput -join ' ')
                    )
                }
            }
            catch {
                $cleanupErrors.Add($_.Exception)
            }
        }

        if ($mounted) {
            try {
                Dismount-LabVhd `
                    -Path $VhdPath `
                    -FailureMessage (
                        '템플릿 VHDX 분리에 실패했습니다: ' +
                        $VhdPath
                    )
            }
            catch {
                $cleanupErrors.Add($_.Exception)
            }
        }

        if (
            $stagedHivePath -and
            (Test-Path -LiteralPath $stagedHivePath)
        ) {
            try {
                Remove-Item `
                    -LiteralPath $stagedHivePath `
                    -Force `
                    -ErrorAction Stop
            }
            catch {
                $cleanupErrors.Add($_.Exception)
            }
        }
    }

    Assert-LabNoDeferredError `
        -OperationError $operationError `
        -CleanupError $cleanupErrors `
        -CombinedMessage (
            '템플릿 generalize 검사와 정리 작업이 ' +
            "모두 실패했습니다: $VhdPath"
        ) `
        -CleanupMessage (
            '템플릿 generalize 검사 후 정리 작업에 ' +
            "실패했습니다: $VhdPath"
        )

    $expectedState =
        'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE'

    $issues =
        [Collections.Generic.List[string]]::new()

    $warnings =
        [Collections.Generic.List[string]]::new()

    if (
        [string]::IsNullOrWhiteSpace(
            $imageState
        )
    ) {
        $issues.Add(
            '템플릿에서 Windows ImageState를 ' +
            '읽지 못했습니다.'
        )
    }
    elseif ($imageState -ne $expectedState) {
        $issues.Add(
            '템플릿이 OOBE 배포 가능한 generalize ' +
            "상태가 아닙니다: 기대=$expectedState, " +
            "실제=$imageState"
        )
    }

    if (
        [string]::IsNullOrWhiteSpace(
            $stateIniImageState
        )
    ) {
        $warnings.Add(
            'State.ini에서 ImageState를 읽지 못했습니다. ' +
            '레지스트리 상태만 사용합니다.'
        )
    }
    elseif (
        $stateIniImageState -ne
        $imageState
    ) {
        $issues.Add(
            'Windows 이미지 상태 정보가 서로 다릅니다: ' +
            "레지스트리=$imageState, " +
            "State.ini=$stateIniImageState"
        )
    }

    [pscustomobject]@{
        PSTypeName        = 'Lab.TemplateGeneralizationResult'
        VhdPath           = $NormalizedPath
        IsGeneralized     = ($issues.Count -eq 0)
        ExpectedImageState = $expectedState
        RegistryImageState = $imageState
        StateIniImageState = $stateIniImageState
        Issues            = @($issues)
        Warnings          = @($warnings)
    }
}

function Set-LabUnattend {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessage(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = '호출자인 New-LabVM이 ShouldProcess 확인을 이미 거친 뒤에만 호출하는 내부 헬퍼다.'
    )]
    param(
        [Parameter(Mandatory)]
        [string]$VhdPath,

        [Parameter(Mandatory)]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [securestring]$AdminPassword,

        [Parameter(Mandatory)]
        [string]$TemplatePath,

        [ValidateSet(
            'BuiltInAdministrator',
            'LocalAccount'
        )]
        [string]$AccountMode = 'BuiltInAdministrator',

        [string]$LocalAdminName = 'LabAdmin',

        [ValidateSet(
            'Sysprep',
            'PantherUnattend'
        )]
        [string]$Location = 'PantherUnattend',

        [string]$TimeZone = 'Korea Standard Time'
    )

    Assert-LabComputerName -Name $ComputerName

    Assert-LabLocalAdminName -Name $LocalAdminName

    Assert-LabTimeZoneId -TimeZone $TimeZone

    if ($AdminPassword.Length -eq 0) {
        throw '관리자 비밀번호는 비어 있을 수 없습니다.'
    }

    if (-not (Test-Path -LiteralPath $VhdPath)) {
        throw "VHDX가 없습니다: $VhdPath"
    }

    if (-not (Test-Path -LiteralPath $TemplatePath)) {
        throw "응답 파일 템플릿이 없습니다: $TemplatePath"
    }

    $vhd = Get-VHD `
        -Path $VhdPath `
        -ErrorAction Stop

    if ($vhd.Attached) {
        throw "VHDX가 이미 연결된 상태입니다: $VhdPath"
    }

    $adminPasswordValue = ConvertTo-UnattendPassword `
        -Password $AdminPassword `
        -Element AdministratorPassword

    $localPasswordValue = ConvertTo-UnattendPassword `
        -Password $AdminPassword `
        -Element Password

    $xml = Get-Content `
        -LiteralPath $TemplatePath `
        -Raw `
        -Encoding UTF8

    $expectedTokenCounts = if (
        $AccountMode -eq 'BuiltInAdministrator'
    ) {
        @{
            '{{COMPUTERNAME}}'  = 1
            '{{TIMEZONE}}'      = 1
            '{{ADMINPASSWORD}}' = 1
            '{{LOCALUSERNAME}}' = 0
            '{{LOCALPASSWORD}}' = 0
        }
    }
    else {
        @{
            '{{COMPUTERNAME}}'  = 1
            '{{TIMEZONE}}'      = 1
            '{{ADMINPASSWORD}}' = 0
            '{{LOCALUSERNAME}}' = 2
            '{{LOCALPASSWORD}}' = 1
        }
    }

    foreach ($token in $expectedTokenCounts.Keys) {
        $actualCount = (
            [regex]::Matches(
                $xml,
                [regex]::Escape($token)
            )
        ).Count

        $expectedCount =
            [int]$expectedTokenCounts[$token]

        if ($actualCount -ne $expectedCount) {
            throw (
                "응답 파일 토큰 개수 불일치: " +
                "토큰=$token, " +
                "기대=$expectedCount, " +
                "실제=$actualCount, " +
                "AccountMode=$AccountMode"
            )
        }
    }

    $escapedComputerName = ConvertTo-LabXmlText `
        -Value $ComputerName

    $escapedTimeZone = ConvertTo-LabXmlText `
        -Value $TimeZone

    $escapedAdminPasswordValue = ConvertTo-LabXmlText `
        -Value $adminPasswordValue

    $escapedLocalAdminName = ConvertTo-LabXmlText `
        -Value $LocalAdminName

    $escapedLocalPasswordValue = ConvertTo-LabXmlText `
        -Value $localPasswordValue

    $xml = $xml.Replace(
        '{{COMPUTERNAME}}',
        $escapedComputerName
    )

    $xml = $xml.Replace(
        '{{TIMEZONE}}',
        $escapedTimeZone
    )

    $xml = $xml.Replace(
        '{{ADMINPASSWORD}}',
        $escapedAdminPasswordValue
    )

    $xml = $xml.Replace(
        '{{LOCALUSERNAME}}',
        $escapedLocalAdminName
    )

    $xml = $xml.Replace(
        '{{LOCALPASSWORD}}',
        $escapedLocalPasswordValue
    )

    $unresolved = @(
        [regex]::Matches(
            $xml,
            '\{\{[A-Z0-9_]+\}\}'
        ) |
            ForEach-Object Value |
            Select-Object -Unique
    )

    if ($unresolved.Count -gt 0) {
        throw (
            '응답 파일에 치환되지 않은 토큰이 있습니다: ' +
            "$($unresolved -join ', ')"
        )
    }

    # XML 문법 검증. 컴포넌트 스키마 검증은 Windows SIM에서 수행한다.
    $null = [xml]$xml

    if (
        $AccountMode -eq 'BuiltInAdministrator' -and
        $xml -notmatch '<AdministratorPassword>'
    ) {
        throw (
            '서버용 응답 파일에 ' +
            'AdministratorPassword 요소가 없습니다.'
        )
    }

    if (
        $AccountMode -eq 'LocalAccount' -and
        $xml -notmatch '<LocalAccount\b'
    ) {
        throw (
            '클라이언트용 응답 파일에 ' +
            'LocalAccount 요소가 없습니다.'
        )
    }

    $cleanupMarker = 'rem --- LabVM unattend cleanup ---'

    $cleanupBlock = @"
@echo off
$cleanupMarker

rem Remove answer files from all known local cache and staging paths.
del /f /q "%SystemDrive%\unattend.xml" >nul 2>&1
del /f /q "%SystemDrive%\autounattend.xml" >nul 2>&1

del /f /q "%WINDIR%\Panther\unattend.xml" >nul 2>&1
del /f /q "%WINDIR%\Panther\Unattend\Unattend.xml" >nul 2>&1

del /f /q "%WINDIR%\System32\Sysprep\Unattend.xml" >nul 2>&1
del /f /q "%WINDIR%\System32\Sysprep\Panther\unattend.xml" >nul 2>&1

rem UnattendGC contains OOBE setup logs and may contain processed data.
if exist "%WINDIR%\Panther\UnattendGC" (
    del /f /s /q "%WINDIR%\Panther\UnattendGC\*" >nul 2>&1
    rd /s /q "%WINDIR%\Panther\UnattendGC" >nul 2>&1
)

rem --- end LabVM unattend cleanup ---
"@

    $mounted = Mount-VHD `
        -Path $VhdPath `
        -Passthru `
        -ErrorAction Stop

    $operationError = $null
    $dismountError = $null

    try {
        $disk = $mounted | Get-Disk
        $part = Get-LabWindowsPartition -Disk $disk

        if (-not $part) {
            throw "Windows 파티션을 찾지 못했습니다: $VhdPath"
        }

        $root = "$($part.DriveLetter):"

        $target = switch ($Location) {
            'Sysprep' {
                "$root\Windows\System32\Sysprep\Unattend.xml"
            }

            'PantherUnattend' {
                "$root\Windows\Panther\Unattend\Unattend.xml"
            }
        }

        New-Item `
            -Path (Split-Path $target -Parent) `
            -ItemType Directory `
            -Force |
            Out-Null

        [IO.File]::WriteAllText(
            $target,
            $xml,
            [Text.UTF8Encoding]::new($false)
        )

        $scriptDir = "$root\Windows\Setup\Scripts"
        $setupPath = Join-Path $scriptDir 'SetupComplete.cmd'
        
        $setupEncoding = [Text.Encoding]::ASCII

        if (Test-Path -LiteralPath $setupPath) {
            $reader = [IO.StreamReader]::new(
                $setupPath,
                $setupEncoding,
                $true
            )

            try {
                $existingSetup = $reader.ReadToEnd()
                $setupEncoding = $reader.CurrentEncoding
            }
            finally {
                $reader.Dispose()
            }
        }
        else {
            $existingSetup = ''
        }

        New-Item `
            -Path $scriptDir `
            -ItemType Directory `
            -Force |
            Out-Null

        if (
            $existingSetup -notmatch
            [regex]::Escape($cleanupMarker)
        ) {
            $combinedSetup =
                $cleanupBlock.TrimEnd() +
                "`r`n" +
                $existingSetup.TrimStart()

            [IO.File]::WriteAllText(
                $setupPath,
                $combinedSetup,
                $setupEncoding
            )
        }

        Write-Verbose "$ComputerName -> $target"
    }
    catch {
        $operationError = $_.Exception
    }
    finally {
        try {
            Dismount-LabVhd -Path $VhdPath
        }
        catch {
            $dismountError = $_.Exception
        }
    }

    Assert-LabNoDeferredError `
        -OperationError $operationError `
        -CleanupError $dismountError `
        -CombinedMessage (
            '응답 파일 처리와 VHDX 분리가 모두 실패했습니다: ' +
            $VhdPath
        )

    $xml = $null
}

