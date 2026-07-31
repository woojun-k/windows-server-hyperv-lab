@{
    # 호스트마다 달라질 수 있는 값은 LabConfig.local.psd1에서 덮어쓴다.
    LabRoot       = 'D:\HyperV-Lab'
    HostReserveMB = 8192

    TimeZone       = 'Korea Standard Time'
    LocalAdminName = 'LabAdmin'

    DiskSafetyReserveMB        = 4096
    DifferencingReserveMB      = 16384
    DifferencingPerVmReserveMB = 512

    StageOrder = @(
        'base',
        'rras',
        'rras-core',
        'addc',
        'addc-core',
        'dhcp',
        'dhcp-core',
        'wsus',
        'wsus-core',
        'pki',
        'pki-core',
        'iis',
        'iis-core',
        'adfs',
        'adfs-core',
        'sql',
        'sql-core',
        'fs',
        'fs-core',
        'nested',
        'nested-core'
    )

    Templates = @{
        GUI = @{
            Vhd         = 'Templates\WS25-BASE-GUI.vhdx'
            Unattend    = 'unattend-oobe.template.xml'
            AccountMode = 'BuiltInAdministrator'
            SecureBoot  = $true
            EnableTpm   = $false
        }

        CORE = @{
            Vhd         = 'Templates\WS25-BASE-CORE.vhdx'
            Unattend    = 'unattend-oobe.template.xml'
            AccountMode = 'BuiltInAdministrator'
            SecureBoot  = $true
            EnableTpm   = $false
        }

        WIN11 = @{
            Vhd         = 'Templates\WIN11-BASE.vhdx'
            Unattend    = 'unattend-oobe.win11.template.xml'
            AccountMode = 'LocalAccount'
            SecureBoot  = $true
            EnableTpm   = $true
        }
    }

    # Stage 키는 실습 범위 목록의 주제어와 일치시킨다.
    Switches = @(
        @{ Name = 'LAB-Internal'; Type = 'Internal'; Stage = 'base'   }
        @{ Name = 'LAB-External'; Type = 'External'; Stage = 'rras'   }
        @{ Name = 'LAB-DMZ';      Type = 'Private'; Stage = 'rras'   }
        @{ Name = 'LAB-Egress';   Type = 'Private';  Stage = 'rras' }
        @{ Name = 'LAB-Nested';   Type = 'Private';  Stage = 'nested' }
    )

    VMs = @(
        # ============================================================
        # RRAS — GUI
        # ============================================================

        @{
            Name     = 'RRAS01'
            Stage    = 'rras'
            Template = 'GUI'
            CPU      = 2
            MemoryMB = 4096
            Switch   = @(
                'LAB-External',
                'LAB-Internal',
                'LAB-DMZ',
                'LAB-Egress'
            )
        }

        # ============================================================
        # RRAS — Server Core
        # ============================================================

        @{
            Name     = 'RRAS-C01'
            Stage    = 'rras-core'
            Template = 'CORE'
            CPU      = 2
            MemoryMB = 2048
            Switch   = @(
                'LAB-External',
                'LAB-Internal',
                'LAB-DMZ',
                'LAB-Egress'
            )
        }

        # ============================================================
        # AD DS / DNS — GUI
        # ============================================================

        @{
            Name     = 'DC01'
            Stage    = 'addc'
            Template = 'GUI'
            CPU      = 2
            MemoryMB = 4096
            Switch   = @('LAB-Internal')
        }

        @{
            Name     = 'DC02'
            Stage    = 'addc'
            Template = 'GUI'
            CPU      = 2
            MemoryMB = 4096
            Switch   = @('LAB-Internal')
        }

        @{
            Name     = 'MGMT01'
            Stage    = 'addc'
            Template = 'GUI'
            CPU      = 2
            MemoryMB = 4096
            Switch   = @('LAB-Internal')
        }

        @{
            Name     = 'CLIENT01'
            Stage    = 'addc'
            Template = 'WIN11'
            CPU      = 2
            MemoryMB = 4096
            Switch   = @('LAB-Internal')
        }

        # ============================================================
        # AD DS / DNS — Server Core
        # ============================================================

        @{
            Name     = 'DC-C01'
            Stage    = 'addc-core'
            Template = 'CORE'
            CPU      = 2
            MemoryMB = 2048
            Switch   = @('LAB-Internal')
        }

        @{
            Name     = 'DC-C02'
            Stage    = 'addc-core'
            Template = 'CORE'
            CPU      = 2
            MemoryMB = 2048
            Switch   = @('LAB-Internal')
        }

        # ============================================================
        # DHCP — GUI
        # ============================================================

        @{
            Name     = 'DHCP01'
            Stage    = 'dhcp'
            Template = 'GUI'
            CPU      = 2
            MemoryMB = 4096
            Switch   = @('LAB-Internal')
        }

        @{
            Name     = 'DHCP02'
            Stage    = 'dhcp'
            Template = 'GUI'
            CPU      = 2
            MemoryMB = 4096
            Switch   = @('LAB-Internal')
        }

        # ============================================================
        # DHCP — Server Core
        # ============================================================

        @{
            Name     = 'DHCP-C01'
            Stage    = 'dhcp-core'
            Template = 'CORE'
            CPU      = 2
            MemoryMB = 2048
            Switch   = @('LAB-Internal')
        }

        @{
            Name     = 'DHCP-C02'
            Stage    = 'dhcp-core'
            Template = 'CORE'
            CPU      = 2
            MemoryMB = 2048
            Switch   = @('LAB-Internal')
        }

        # ============================================================
        # WSUS — GUI
        # ============================================================

        @{
            Name     = 'WSUS01'
            Stage    = 'wsus'
            Template = 'GUI'
            CPU      = 4
            MemoryMB = 8192
            Switch   = @('LAB-Internal')
        }

        # ============================================================
        # WSUS — Server Core
        # ============================================================

        @{
            Name     = 'WSUS-C01'
            Stage    = 'wsus-core'
            Template = 'CORE'
            CPU      = 4
            MemoryMB = 8192
            Switch   = @('LAB-Internal')
        }

        # ============================================================
        # AD CS / PKI — GUI
        # ============================================================

        @{
            Name     = 'ROOTCA'
            Stage    = 'pki'
            Template = 'GUI'
            CPU      = 2
            MemoryMB = 2048
            Switch   = @()
        }

        @{
            Name     = 'CA01'
            Stage    = 'pki'
            Template = 'GUI'
            CPU      = 2
            MemoryMB = 4096
            Switch   = @('LAB-Internal')
        }

        # ============================================================
        # AD CS / PKI — Server Core
        # ============================================================

        @{
            Name     = 'ROOTCA-C01'
            Stage    = 'pki-core'
            Template = 'CORE'
            CPU      = 2
            MemoryMB = 2048
            Switch   = @()
        }

        @{
            Name     = 'CA-C01'
            Stage    = 'pki-core'
            Template = 'CORE'
            CPU      = 2
            MemoryMB = 2048
            Switch   = @('LAB-Internal')
        }

        # ============================================================
        # IIS — GUI
        # ============================================================

        @{
            Name     = 'WEB01'
            Stage    = 'iis'
            Template = 'GUI'
            CPU      = 2
            MemoryMB = 4096
            Switch   = @('LAB-Internal')
        }

        @{
            Name     = 'WEBPUB01'
            Stage    = 'iis'
            Template = 'GUI'
            CPU      = 2
            MemoryMB = 4096
            Switch   = @('LAB-DMZ')
        }

        # ============================================================
        # IIS — Server Core
        # ============================================================

        @{
            Name     = 'WEB-C01'
            Stage    = 'iis-core'
            Template = 'CORE'
            CPU      = 2
            MemoryMB = 2048
            Switch   = @('LAB-Internal')
        }

        @{
            Name     = 'WEBPUB-C01'
            Stage    = 'iis-core'
            Template = 'CORE'
            CPU      = 2
            MemoryMB = 2048
            Switch   = @('LAB-DMZ')
        }

        # ============================================================
        # AD FS / WAP — GUI
        # ============================================================

        @{
            Name     = 'ADFS01'
            Stage    = 'adfs'
            Template = 'GUI'
            CPU      = 2
            MemoryMB = 4096
            Switch   = @('LAB-Internal')
        }

        @{
            Name     = 'WAP01'
            Stage    = 'adfs'
            Template = 'GUI'
            CPU      = 2
            MemoryMB = 4096
            Switch   = @('LAB-DMZ')
        }

        # ============================================================
        # AD FS / WAP — Server Core
        # ============================================================

        @{
            Name     = 'ADFS-C01'
            Stage    = 'adfs-core'
            Template = 'CORE'
            CPU      = 2
            MemoryMB = 4096
            Switch   = @('LAB-Internal')
        }

        @{
            Name     = 'WAP-C01'
            Stage    = 'adfs-core'
            Template = 'CORE'
            CPU      = 2
            MemoryMB = 4096
            Switch   = @('LAB-DMZ')
        }

        # ============================================================
        # SQL Server — GUI
        # ============================================================

        @{
            Name     = 'SQL01'
            Stage    = 'sql'
            Template = 'GUI'
            CPU      = 4
            MemoryMB = 8192
            Switch   = @('LAB-Internal')
        }

        # ============================================================
        # SQL Server — Server Core
        # ============================================================

        @{
            Name     = 'SQL-C01'
            Stage    = 'sql-core'
            Template = 'CORE'
            CPU      = 4
            MemoryMB = 8192
            Switch   = @('LAB-Internal')
        }

        # ============================================================
        # File Server — GUI
        # ============================================================

        @{
            Name     = 'FS01'
            Stage    = 'fs'
            Template = 'GUI'
            CPU      = 2
            MemoryMB = 8192
            Switch   = @(
                'LAB-Internal'
            )
        }

        # ============================================================
        # File Server — Server Core
        # ============================================================

        @{
            Name     = 'FS-C01'
            Stage    = 'fs-core'
            Template = 'CORE'
            CPU      = 2
            MemoryMB = 4096
            Switch   = @(
                'LAB-Internal'
            )
        }

        # ============================================================
        # Nested Hyper-V — GUI
        # ============================================================

        @{
            Name                 = 'HV01'
            Stage                = 'nested'
            Template             = 'GUI'
            CPU                  = 4
            MemoryMB             = 8192
            Switch               = @(
                'LAB-Internal',
                'LAB-Nested'
            )
            NestedVirtualization = $true
            MacSpoofingSwitches  = @('LAB-Nested')
        }

        @{
            Name                 = 'HV02'
            Stage                = 'nested'
            Template             = 'GUI'
            CPU                  = 4
            MemoryMB             = 8192
            Switch               = @(
                'LAB-Internal',
                'LAB-Nested'
            )
            NestedVirtualization = $true
            MacSpoofingSwitches  = @('LAB-Nested')
        }

        # ============================================================
        # Nested Hyper-V — Server Core
        # ============================================================

        @{
            Name                 = 'HV-C01'
            Stage                = 'nested-core'
            Template             = 'CORE'
            CPU                  = 4
            MemoryMB             = 8192
            Switch               = @(
                'LAB-Internal',
                'LAB-Nested'
            )
            NestedVirtualization = $true
            MacSpoofingSwitches  = @('LAB-Nested')
        }

        @{
            Name                 = 'HV-C02'
            Stage                = 'nested-core'
            Template             = 'CORE'
            CPU                  = 4
            MemoryMB             = 8192
            Switch               = @(
                'LAB-Internal',
                'LAB-Nested'
            )
            NestedVirtualization = $true
            MacSpoofingSwitches  = @('LAB-Nested')
        }
    )
}