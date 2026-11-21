# PSScriptAnalyzer settings
# Target: Windows Server 2016, Windows PowerShell 5.1.14393, .NET Framework 4.x
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # WinForms GUI tool: writes status to the host on purpose
        'PSAvoidUsingWriteHost',
        # Flags every WinForms/System.Drawing type, because those assemblies load
        # with Add-Type at runtime. Noise for a GUI tool.
        'PSUseCompatibleTypes'
    )
    Rules = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1')
        }
        PSUseCompatibleCommands = @{
            Enable         = $true
            TargetProfiles = @('win-8_x64_10.0.14393.0_5.1.14393.2791_x64_4.0.30319.42000_framework')
        }
    }
}
