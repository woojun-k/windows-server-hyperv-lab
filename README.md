# Windows Server 2025 Hyper-V Lab Scripts

Windows Server 2025 실습용 Hyper-V VM을 일관된 구성으로 생성하고 관리하기 위한 PowerShell 모듈입니다.

이 모듈은 반복되는 VM 프로비저닝을 줄여 AD DS, DNS, DHCP, RRAS, WSUS, AD CS, IIS 등 **게스트 OS 내부의 서버 역할 실습에 집중**할 수 있도록 돕습니다.

실습 강의는 [윈도우 서버 2025 구성하기](https://velog.io/@polarishb/series/%EC%9C%88%EB%8F%84%EC%9A%B0-%EC%84%9C%EB%B2%84-2025-%EA%B5%AC%EC%84%B1%ED%95%98%EA%B8%B0) 시리즈에서 진행됩니다.

> 이 프로젝트는 Windows Server 역할을 자동 설치하는 원클릭 배포 도구가 아닙니다.  
> 템플릿 복제, VM 하드웨어·네트워크 구성, 응답 파일 주입과 VM 생명주기만 관리합니다.

## 주요 기능

- 일반화된 Windows Server·Windows 11 템플릿에서 VM 생성
- 기본 차등 디스크, 선택적 전체 복사 지원
- VM 한 대 또는 Stage 단위 일괄 생성
- 템플릿, 스위치, 디스크 공간, 기존 VM 충돌 사전 검사
- Stage 전체 사전 검사 후 생성 시작
- 생성 도중 실패 시 이번 실행에서 만든 VM 롤백
- 설정값과 실제 Hyper-V 구성의 드리프트 확인
- 안전한 일부 드리프트 자동 교정
- Stage 단위 시작·종료·초기화
- 중첩 Hyper-V와 MAC 주소 스푸핑 지원
- `-WhatIf` 및 확인 프롬프트 지원

---

## 요구사항

- Windows 11 Pro/Enterprise 또는 Windows Server Hyper-V 호스트
- 관리자 권한의 Windows PowerShell 5.1
- Hyper-V 기능과 Hyper-V PowerShell 모듈
- Sysprep으로 일반화한 템플릿 VHDX
  - `WS25-BASE-GUI.vhdx`
  - `WS25-BASE-CORE.vhdx`
  - `WIN11-BASE.vhdx`

기본 `LabRoot`가 `D:\HyperV-Lab`이라면 템플릿은 다음 경로에 둡니다.

```text
D:\HyperV-Lab\Templates\WS25-BASE-GUI.vhdx
D:\HyperV-Lab\Templates\WS25-BASE-CORE.vhdx
D:\HyperV-Lab\Templates\WIN11-BASE.vhdx
```

템플릿은 Hyper-V VM에 연결되지 않은 종료 상태여야 하며, Sysprep `/generalize`가 완료되고 파일이 읽기 전용으로 설정되어 있어야 합니다.

기본 차등 디스크 모드에서는 부모 템플릿 보호를 위해 읽기 전용 속성이 필요합니다.

```powershell
Get-ChildItem 'D:\HyperV-Lab\Templates\*.vhdx' |
    ForEach-Object { $_.IsReadOnly = $true }
```

---

## 저장소 구조

```text
.
├─ Scripts
│  ├─ LabVM.psd1
│  ├─ LabVM.psm1
│  ├─ LabConfig.psd1
│  ├─ LabConfig.local.psd1.example
│  ├─ LabVM.*.ps1
│  └─ unattend-oobe.*.xml
└─ Tests
   └─ *.Tests.ps1
```

---

## 빠른 시작

### 1. 로컬 설정 생성

관리자 Windows PowerShell에서 저장소 경로로 이동합니다.

```powershell
Set-Location C:\Path\To\Repository
```

호스트별 설정 파일을 생성합니다.

```powershell
Copy-Item `
    .\Scripts\LabConfig.local.psd1.example `
    .\Scripts\LabConfig.local.psd1

notepad .\Scripts\LabConfig.local.psd1
```

예시:

```powershell
@{
    LabRoot       = 'D:\HyperV-Lab'
    HostReserveMB = 8192
}
```

`LabConfig.local.psd1`에서는 다음 값만 덮어쓸 수 있습니다.

- `LabRoot`
- `HostReserveMB`
- `DiskSafetyReserveMB`
- `DifferencingReserveMB`
- `DifferencingPerVmReserveMB`
- `TimeZone`
- `LocalAdminName`

VM, Stage, 템플릿과 스위치 정의는 `LabConfig.psd1`에 있습니다.

### 2. 모듈 가져오기

```powershell
Import-Module .\Scripts\LabVM.psd1 -Force
```

내보낸 명령 확인:

```powershell
Get-Command -Module LabVM
```

### 3. 설정 검증

```powershell
$config = Get-LabConfig

[pscustomobject]$config |
    Select-Object `
        LabRoot,
        HostReserveMB,
        TimeZone,
        LocalAdminName
```

설정 파일을 수정한 뒤에는 캐시를 갱신합니다.

```powershell
Get-LabConfig -Refresh
```

---

## 가상 스위치 준비

이 모듈은 가상 스위치를 자동 생성하지 않습니다. 강의 단계에서 직접 생성한 스위치의 이름과 유형을 검사합니다.

### 내부망

```powershell
New-VMSwitch `
    -Name 'LAB-Internal' `
    -SwitchType Internal
```

### DMZ

```powershell
New-VMSwitch `
    -Name 'LAB-DMZ' `
    -SwitchType Internal
```

### 중첩 Hyper-V 전용망

```powershell
New-VMSwitch `
    -Name 'LAB-Nested' `
    -SwitchType Private
```

### 외부망

먼저 실제 물리 NIC 이름을 확인합니다.

```powershell
Get-NetAdapter |
    Where-Object Status -eq 'Up' |
    Select-Object Name, InterfaceDescription, LinkSpeed
```

예시:

```powershell
New-VMSwitch `
    -Name 'LAB-External' `
    -NetAdapterName '이더넷' `
    -AllowManagementOS $true
```

> External 스위치를 만들면 물리 NIC 바인딩이 변경되어 호스트 네트워크가 잠시 끊길 수 있습니다.

`base`는 VM이 없는 인프라 전용 Stage입니다. 다음 명령으로 `LAB-Internal` 상태를 확인할 수 있습니다.

```powershell
$base = New-LabStage -Stage base
$base.RequiredSwitches
```

---

## 관리자 암호 준비

```powershell
$AdminPassword = Read-Host `
    '실습 VM 관리자 암호' `
    -AsSecureString
```

- Windows Server: 기본 제공 Administrator 계정 암호
- Windows 11: `LocalAdminName`으로 지정한 로컬 계정 암호

암호를 일반 문자열로 스크립트에 직접 작성하지 않는 것을 권장합니다.

---

## 기본 사용 흐름

```powershell
Import-Module .\Scripts\LabVM.psd1 -Force

$AdminPassword = Read-Host `
    '실습 VM 관리자 암호' `
    -AsSecureString

Get-LabStatus -Stage addc

New-LabStage `
    -Stage addc `
    -AdminPassword $AdminPassword `
    -WhatIf

New-LabStage `
    -Stage addc `
    -AdminPassword $AdminPassword

Start-LabStage -Stage addc
```

실습 종료:

```powershell
Stop-LabStage -Stage addc
```

처음부터 다시 구성:

```powershell
Reset-LabStage -Stage addc
```

---

## 상태 확인

전체 VM:

```powershell
Get-LabStatus
```

특정 Stage:

```powershell
Get-LabStatus -Stage addc
```

상세 속성:

```powershell
Get-LabStatus -Stage addc |
    Format-List *
```

`Get-LabStatus`는 다음 희망 상태와 실제 상태를 비교합니다.

- vCPU
- 시작 메모리
- 가상 스위치 연결
- VHDX 경로
- 체크포인트와 자동 시작·종료 정책
- 중첩 가상화와 MAC 주소 스푸핑

---

## 생성 전 사전 검사

```powershell
$config = Get-LabConfig

$spec = $config.VMs |
    Where-Object Name -eq 'DC01'

$check = Test-LabPrerequisite -Spec $spec
$check
```

| Disposition | 의미 |
|---|---|
| `Create` | 생성 가능 |
| `Skip` | 이미 설정과 일치하는 VM이 존재함 |
| `Conflict` | 기존 VM 또는 리소스와 충돌함 |
| `Failed` | 템플릿, 경로, 디스크 공간 등의 검사 실패 |

상세 원인:

```powershell
$check | Format-List *
```

---

## VM 한 대 생성

실행 계획 확인:

```powershell
New-LabVM `
    -Name 'DC01' `
    -AdminPassword $AdminPassword `
    -WhatIf
```

실제 생성:

```powershell
$result = New-LabVM `
    -Name 'DC01' `
    -AdminPassword $AdminPassword

$result
```

상세 결과:

```powershell
$result | Format-List *
```

생성된 VM은 자동으로 시작되지 않습니다.

---

## Stage 단위 생성

`addc` Stage는 `DC01`, `DC02`, `MGMT01`, `CLIENT01`을 생성합니다.

```powershell
$result = New-LabStage `
    -Stage addc `
    -AdminPassword $AdminPassword

$result
```

VM별 결과:

```powershell
$result.Results |
    Format-Table Name, Status, Reason
```

실패 항목만 확인:

```powershell
$result.Results |
    Where-Object Succeeded -eq $false |
    Format-List *
```

Stage 생성은 다음 순서로 동작합니다.

1. Stage의 모든 VM 사전 검사
2. 스위치, 템플릿, 디스크 예산과 기존 리소스 충돌 확인
3. 하나라도 차단 조건이 있으면 생성하지 않음
4. 모든 검사가 통과하면 생성 시작
5. 생성 도중 실패하면 이번 실행에서 생성한 VM 롤백

이미 모든 VM이 설정과 일치하면 `Skipped / AlreadyCompliant`를 반환합니다.

---

## Stage 시작과 종료

시작:

```powershell
Start-LabStage -Stage addc
```

다른 Stage의 VM을 함께 시작:

```powershell
Start-LabStage `
    -Stage iis `
    -Also RRAS01, DC01
```

`Start-LabStage`는 필요한 스위치와 VM 존재 여부, 호스트 메모리 예산을 검사합니다. 메모리 예산 차단을 의도적으로 무시할 때만 `-Force`를 사용합니다.

```powershell
Start-LabStage `
    -Stage wsus `
    -Force
```

정상 종료:

```powershell
Stop-LabStage -Stage addc
```

즉시 전원 차단:

```powershell
Stop-LabStage `
    -Stage addc `
    -TurnOff `
    -Force
```

`-TurnOff`는 정상 종료 절차를 건너뛰므로 응답하지 않는 VM에만 사용하십시오.

---

## 구성 드리프트 교정

예를 들어 `DC01`의 vCPU를 수동으로 변경합니다.

```powershell
Set-VMProcessor `
    -VMName 'DC01' `
    -Count 1

Get-LabStatus -Stage addc
```

안전하게 교정할 수 있는 항목은 `-Reconcile`로 복구할 수 있습니다.

```powershell
New-LabVM `
    -Name 'DC01' `
    -AdminPassword $AdminPassword `
    -Reconcile
```

Stage 전체 교정:

```powershell
New-LabStage `
    -Stage addc `
    -AdminPassword $AdminPassword `
    -Reconcile
```

자동 교정 대상에는 vCPU, 메모리, 체크포인트 정책, 자동 시작·종료 정책, MAC 주소 스푸핑 등이 포함됩니다.

디스크 경로, 부모 VHDX와 NIC 토폴로지는 자동 교정하지 않으며 `Conflict`로 남습니다.

---

## VM 제거와 Stage 초기화

VM 한 대 제거 계획:

```powershell
Remove-LabVM `
    -Name 'DC01' `
    -WhatIf
```

실제 제거:

```powershell
Remove-LabVM -Name 'DC01'
```

Stage 전체 초기화 계획:

```powershell
Reset-LabStage `
    -Stage addc `
    -WhatIf
```

실제 초기화:

```powershell
Reset-LabStage -Stage addc
```

실행 중이거나 일부 구성 편차가 있는 VM을 의도적으로 제거할 때만 `-Force`를 사용합니다.

```powershell
Reset-LabStage `
    -Stage addc `
    -Force
```

Stage 초기화는 템플릿 VHDX와 가상 스위치를 제거하지 않습니다.

---

## 전체 복사 방식으로 한 번만 생성

기본 디스크 모드는 `Differencing`입니다. 특정 VM만 일회성으로 전체 복사하려면 설정 복사본에 `DiskMode`를 추가합니다.

```powershell
$config = Get-LabConfig

$spec = $config.VMs |
    Where-Object Name -eq 'DC01'

$spec['DiskMode'] = 'FullCopy'

New-LabVM `
    -Spec $spec `
    -AdminPassword $AdminPassword
```

- `Differencing`: 템플릿을 부모로 사용하는 차등 디스크
- `FullCopy`: 템플릿 VHDX 전체 복사

차등 디스크 생성 후에는 부모 템플릿을 이동·수정·삭제하면 안 됩니다.

---

## Stage 목록

| Stage | VM | 필요 스위치 |
|---|---|---|
| `base` | `없음` | LAB-Internal |
| `rras` | `RRAS01` | External, Internal, DMZ, Egress |
| `rras-core` | `RRAS-C01` | External, Internal, DMZ, Egress |
| `addc` | `DC01`, `DC02`, `MGMT01`, `CLIENT01` | Internal |
| `addc-core` | `DC-C01`, `DC-C02` | Internal |
| `dhcp` | `DHCP01`, `DHCP02` | Internal |
| `dhcp-core` | `DHCP-C01`, `DHCP-C02` | Internal |
| `wsus` | `WSUS01` | Internal |
| `wsus-core` | `WSUS-C01` | Internal |
| `pki` | `ROOTCA`, `CA01` | CA01: Internal |
| `pki-core` | `ROOTCA-C01`, `CA-C01` | CA-C01: Internal |
| `iis` | `WEB01`, `WEBPUB01` | Internal, DMZ |
| `iis-core` | `WEB-C01`, `WEBPUB-C01` | Internal, DMZ |
| `adfs` | `ADFS01`, `WAP01` | Internal, DMZ |
| `adfs-core` | `ADFS-C01`, `WAP-C01` | Internal, DMZ |
| `sql` | `SQL01` | Internal |
| `sql-core` | `SQL-C01` | Internal |
| `fs` | `FS01` | Internal |
| `fs-core` | `FS-C01` | Internal |
| `nested` | `HV01`, `HV02` | Internal, Nested |
| `nested-core` | `HV-C01`, `HV-C02` | Internal, Nested |

---

## 결과 상태

| Status | 의미 |
|---|---|
| `Created` | 생성 완료 |
| `Skipped` | 이미 일치하거나 `-WhatIf` 등으로 실행하지 않음 |
| `Conflict` | 기존 VM·디스크·네트워크 구성과 충돌 |
| `Aborted` | 앞선 VM 실패로 이후 작업 중단 |
| `Failed` | 검사 또는 실행 실패 |

상세 원인은 `Issues`, `Warnings`, `Error`에서 확인합니다.

```powershell
$result | Format-List *
$result.Results | Format-List *
```

---

## 실습 예제

### RRAS와 AD DS

```powershell
New-LabStage `
    -Stage rras `
    -AdminPassword $AdminPassword

New-LabStage `
    -Stage addc `
    -AdminPassword $AdminPassword

Start-LabStage -Stage rras
Start-LabStage -Stage addc
```

### Server Core

```powershell
New-LabStage `
    -Stage addc-core `
    -AdminPassword $AdminPassword

Start-LabStage -Stage addc-core
```

---

## 테스트

```powershell
Invoke-Pester .\Tests
```

정적 분석 테스트에는 PSScriptAnalyzer가 필요합니다.

```powershell
Install-Module PSScriptAnalyzer -Scope CurrentUser
Invoke-Pester .\Tests\ScriptAnalyzer.Tests.ps1
```

---

## 주의사항

- 관리자 Windows PowerShell에서 실행하십시오.
- 운영 Hyper-V 호스트가 아닌 실습 환경에서 사용하십시오.
- 처음 실행하는 변경 명령은 `-WhatIf`로 확인하십시오.
- 템플릿 VHDX를 실행 중인 VM에 직접 연결하지 마십시오.
- 차등 디스크 생성 후 부모 템플릿을 변경하지 마십시오.
- `LAB-External` 생성 전 실제 물리 NIC를 확인하십시오.
- `-Force`, `-TurnOff`, `Reset-LabStage`는 영향을 이해한 뒤 사용하십시오.
