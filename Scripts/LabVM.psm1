#Requires -RunAsAdministrator
Set-StrictMode -Version Latest

# 이 파일은 로더 역할만 한다. 실제 함수는 논리적 경계를 따라
# 아래 파일들로 나뉘어 있으며, 전부 dot-source로 읽어 들여
# 이 모듈 스코프를 그대로 공유한다.
#
#   LabCommon.ps1          - 공통 유틸리티, 반복되던 검사/조회
#   LabVM.Config.ps1        - LabConfig 로드/검증/조회, 스펙/스위치/템플릿 해석
#   LabVM.Checks.ps1        - 기존 VM 준수 여부, 생성 사전 조건 검사
#   LabVM.Image.ps1         - 응답 파일 처리, 템플릿 VHDX generalize 검사
#   LabVM.ResultTypes.ps1   - Lab.*Result 결과 계약
#   LabVM.Provisioning.ps1  - VM 생성 실행(디스크/하드웨어/네트워크)·롤백·드리프트 교정
#   LabVM.Removal.ps1       - VM 제거 사전검사(충돌·교차 사용)·실제 제거 실행
#   LabVM.Capacity.ps1      - Stage 디스크 예산, 호스트 메모리 예산
#   LabVM.Reporting.ps1     - 호스트 VM 색인, Stage 결과 매핑, 상태 보고서
#   LabVM.Orchestration.ps1 - VM/Stage 생성·제거·초기화·시작, 상태 조회
foreach ($module in @(
    'LabCommon.ps1',
    'LabVM.Config.ps1',
    'LabVM.Checks.ps1',
    'LabVM.Image.ps1',
    'LabVM.ResultTypes.ps1',
    'LabVM.Provisioning.ps1',
    'LabVM.Removal.ps1',
    'LabVM.Capacity.ps1',
    'LabVM.Reporting.ps1',
    'LabVM.Orchestration.ps1'
)) {
    . (Join-Path $PSScriptRoot $module)
}

Export-ModuleMember -Function `
    Get-LabConfig, `
    Test-LabPrerequisite, `
    New-LabVM, `
    New-LabStage, `
    Remove-LabVM, `
    Reset-LabStage, `
    Start-LabStage, `
    Stop-LabStage, `
    Get-LabStatus
