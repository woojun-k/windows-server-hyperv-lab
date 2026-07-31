@{
    RootModule        = 'LabVM.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '215bd930-8600-47a2-883b-44631fe1bbe0'
    Author            = 'woojun-k'
    Description       = 'Hyper-V 실습 랩 VM/스위치 프로비저닝과 상태 관리'

    PowerShellVersion = '5.1'
    RequiredModules   = @('Hyper-V')

    FormatsToProcess  = @('LabVM.Format.ps1xml')

    FunctionsToExport = @(
        'Get-LabConfig',
        'Test-LabPrerequisite',
        'New-LabVM',
        'New-LabStage',
        'Remove-LabVM',
        'Reset-LabStage',
        'Start-LabStage',
        'Stop-LabStage',
        'Get-LabStatus'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
