# Pester 4 tests for Group-Mirror.ps1
#
# The tool is a GUI script: running it would load config.json and open a form.
# These tests instead parse the script and load only its function definitions,
# then call them with Active Directory and Microsoft Graph mocked.
#
# Run from the repo root:
#   Invoke-Pester -Path .\tests

$scriptPath = Join-Path $PSScriptRoot '..\Group-Mirror.ps1'
$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path $scriptPath).Path, [ref]$tokens, [ref]$parseErrors)

# Load every top-level function. WinForms types do not exist off Windows, so the
# RichTextBox parameter type is loosened to [object] for the test session only.
$functionAsts = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
foreach ($fn in $functionAsts) {
    $code = $fn.Extent.Text -replace '\[System\.Windows\.Forms\.RichTextBox\]', '[object]'
    . ([scriptblock]::Create($code))
}

# Load the status labels table used by the clipboard formatter
if (-not ('System.Drawing.Color' -as [type])) {
    try { Add-Type -AssemblyName System.Drawing } catch { Add-Type -AssemblyName System.Drawing.Primitives }
}
$statusAst = $ast.Find({
        $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $args[0].Left.Extent.Text -eq '$StatusConfig'
    }, $false)
. ([scriptblock]::Create($statusAst.Extent.Text))

# Exclusion lists, as the script defines them at script scope
$script:LicensingExclusionsRef = @('Licensing - Sample Product A')
$script:DoNotMirrorRef         = @('Restricted - Sample Group A', 'Restricted - Sample Group C')

# Stand-ins for the ActiveDirectory module so the commands can be mocked anywhere
# [CmdletBinding()] so they accept -ErrorAction like the real cmdlets.
function Get-ADUser        { [CmdletBinding()] param($Identity, $Server, $Filter, $Properties) }
function Get-ADGroup       { [CmdletBinding()] param($Identity, $Server, $Properties) }
function Add-ADGroupMember { [CmdletBinding()] param($Identity, $Server, $Members) }

$onWindows = [Environment]::OSVersion.Platform -eq 'Win32NT'

Describe 'Script quality' {
    It 'parses with no errors' {
        $parseErrors.Count | Should -Be 0
    }
    It 'contains only ASCII characters (PowerShell 5.1 reads BOM-less UTF-8 as ANSI)' {
        $text = [System.IO.File]::ReadAllText((Resolve-Path $scriptPath).Path)
        ($text.ToCharArray() | Where-Object { [int]$_ -gt 127 }).Count | Should -Be 0
    }
    It 'uses no WinForms timers or BeginInvoke (both fail in PS2EXE builds)' {
        $text = [System.IO.File]::ReadAllText((Resolve-Path $scriptPath).Path)
        $text | Should -Not -Match 'Forms\.Timer|Add_Tick|BeginInvoke\('
    }
}

Describe 'Input helpers' {
    It 'ConvertTo-SamName strips a DOMAIN\ prefix' {
        ConvertTo-SamName -InputValue 'CORP\jdoe' | Should -Be 'jdoe'
    }
    It 'ConvertTo-SamName keeps only the part before @' {
        ConvertTo-SamName -InputValue 'jdoe@contoso' | Should -Be 'jdoe'
    }
    It 'Get-CloudUPN never appends a domain to a bare name' {
        Get-CloudUPN -InputValue 'jdoe' | Should -Be 'jdoe'
    }
    It 'Get-CloudUPN strips a DOMAIN\ prefix and trims' {
        Get-CloudUPN -InputValue ' CORP\jdoe@contoso ' | Should -Be 'jdoe@contoso'
    }
    It 'Get-DomainFromDN builds the DNS name from DC= parts' {
        Get-DomainFromDN -DN 'CN=App Users,OU=Groups,DC=east,DC=corp,DC=contoso,DC=local' |
            Should -Be 'east.corp.contoso.local'
    }
}

Describe 'Test-SkipUnapproved (confirmation window filter)' {
    It 'skips nothing when no confirmation window was used ($null)' {
        Test-SkipUnapproved -GroupName 'App Users' -ApprovedNames $null | Should -Be $false
    }
    It 'skips everything after Deselect All (empty list)' {
        Test-SkipUnapproved -GroupName 'App Users' -ApprovedNames @() | Should -Be $true
    }
    It 'keeps an approved group' {
        Test-SkipUnapproved -GroupName 'App Users' -ApprovedNames @('App Users') | Should -Be $false
    }
    It 'skips a group that was not approved' {
        Test-SkipUnapproved -GroupName 'Other' -ApprovedNames @('App Users') | Should -Be $true
    }
}

Describe 'Test-DoNotMirror' {
    It 'matches an exact restricted name' {
        Test-DoNotMirror -GroupName 'Restricted - Sample Group A' | Should -Be $true
    }
    It 'matches a restricted name with a generated suffix' {
        Test-DoNotMirror -GroupName 'Restricted - Sample Group A_0a1b2c3d4e5f' | Should -Be $true
    }
    It 'does not match an unrelated group' {
        Test-DoNotMirror -GroupName 'App Users' | Should -Be $false
    }
}

Describe 'Find-DomainUser' {
    Mock Get-ADUser -ParameterFilter { $Server -eq 'east.corp.contoso.local' } {
        [pscustomobject]@{ SamAccountName = 'jdoe'; DistinguishedName = 'CN=jdoe,DC=east,DC=corp,DC=contoso,DC=local' }
    }
    Mock Get-ADUser -ParameterFilter { $Server -eq 'west.corp.contoso.local' } { }
    Mock Get-ADUser -ParameterFilter { $Server -eq 'down.corp.contoso.local' } { throw 'Unable to contact the server' }

    $r = Find-DomainUser -LookupValue 'jdoe' -Domains @('east.corp.contoso.local', 'west.corp.contoso.local', 'down.corp.contoso.local')

    It 'finds the user in the one domain that has it' {
        @($r.Matches).Count       | Should -Be 1
        $r.Matches[0].Domain      | Should -Be 'east.corp.contoso.local'
    }
    It 'reports the unreachable domain instead of hiding it' {
        @($r.Unreachable) | Should -Be @('down.corp.contoso.local')
    }
}

Describe 'Invoke-OnPremCopy' {
    $dn = @{
        App        = 'CN=App Users,OU=Groups,DC=corp,DC=contoso,DC=local'
        Second     = 'CN=Second App,OU=Groups,DC=corp,DC=contoso,DC=local'
        Restricted = 'CN=Restricted - Sample Group A_0a1b2c3d4e5f,OU=Groups,DC=corp,DC=contoso,DC=local'
        Shared     = 'CN=Already Shared,OU=Groups,DC=corp,DC=contoso,DC=local'
    }

    Mock Add-LogLine { }
    Mock Find-DomainUser {
        if ($LookupValue -eq 'source.user') {
            $u = [pscustomobject]@{ SamAccountName = 'source.user'; DistinguishedName = 'CN=source.user,DC=corp,DC=contoso,DC=local'
                MemberOf = @($dn.App, $dn.Second, $dn.Restricted, $dn.Shared) }
        }
        else {
            $u = [pscustomobject]@{ SamAccountName = 'target.user'; DistinguishedName = 'CN=target.user,DC=corp,DC=contoso,DC=local'
                MemberOf = @($dn.Shared) }
        }
        [pscustomobject]@{ Matches = @([pscustomobject]@{ Domain = 'corp.contoso.local'; User = $u }); Unreachable = @() }
    }
    Mock Get-ADUser { [pscustomobject]@{ SamAccountName = 'target.user' } }
    Mock Get-ADGroup {
        $name = ($Identity -split ',')[0] -replace '^CN=', ''
        [pscustomobject]@{ Name = $name; GroupScope = 'Universal'; GroupCategory = 'Security'; DistinguishedName = $Identity }
    }

    Context 'no confirmation filter' {
        Mock Add-ADGroupMember { }
        $r = Invoke-OnPremCopy -SourceInput 'source.user' -TargetInput 'target.user' -Domains @('corp.contoso.local') -Log $null

        It 'adds the two mirrorable groups' {
            Assert-MockCalled Add-ADGroupMember -Exactly 2 -Scope Context
            @($r | Where-Object Status -eq 'Added').Count | Should -Be 2
        }
        It 'blocks the restricted group and never tries to add it' {
            ($r | Where-Object Status -eq 'Blocked').GroupName | Should -Be 'Restricted - Sample Group A_0a1b2c3d4e5f'
            Assert-MockCalled Add-ADGroupMember -Times 0 -Scope Context -ParameterFilter { $Identity -eq $dn.Restricted }
        }
        It 'reports the group the target already has' {
            ($r | Where-Object Status -eq 'AlreadyMember').GroupName | Should -Be 'Already Shared'
        }
    }

    Context 'Deselect All in the confirmation window' {
        Mock Add-ADGroupMember { }
        $r = Invoke-OnPremCopy -SourceInput 'source.user' -TargetInput 'target.user' -Domains @('corp.contoso.local') -Log $null -ApprovedNames @()

        It 'adds nothing' {
            Assert-MockCalled Add-ADGroupMember -Exactly 0 -Scope Context
        }
        It 'still reports blocked and already-member groups' {
            @($r | Where-Object Status -eq 'Blocked').Count       | Should -Be 1
            @($r | Where-Object Status -eq 'AlreadyMember').Count | Should -Be 1
        }
    }

    Context 'one group approved' {
        Mock Add-ADGroupMember { }
        $null = Invoke-OnPremCopy -SourceInput 'source.user' -TargetInput 'target.user' -Domains @('corp.contoso.local') -Log $null -ApprovedNames @('Second App')

        It 'adds only the approved group' {
            Assert-MockCalled Add-ADGroupMember -Exactly 1 -Scope Context
            Assert-MockCalled Add-ADGroupMember -Exactly 1 -Scope Context -ParameterFilter { $Identity -eq $dn.Second }
        }
    }

    Context 'an add is refused' {
        Mock Add-ADGroupMember { throw 'Insufficient access rights to perform the operation' }
        $r = Invoke-OnPremCopy -SourceInput 'source.user' -TargetInput 'target.user' -Domains @('corp.contoso.local') -Log $null

        It 'reports Failed with the error text' {
            $failed = @($r | Where-Object Status -eq 'Failed')
            $failed.Count | Should -Be 2
            $failed[0].Detail | Should -Match 'Insufficient access rights'
        }
    }
}

Describe 'Get-OnPremPreview' {
    Mock Find-DomainUser {
        # Source has two groups; target has none
        $groups = if ($LookupValue -eq 'source.user') {
            @('CN=App Users,OU=Groups,DC=corp,DC=contoso,DC=local', 'CN=Gone Group,OU=Groups,DC=corp,DC=contoso,DC=local')
        } else { @() }
        $u = [pscustomobject]@{ MemberOf = $groups }
        [pscustomobject]@{ Matches = @([pscustomobject]@{ Domain = 'corp.contoso.local'; User = $u }); Unreachable = @() }
    }
    Mock Get-ADGroup -ParameterFilter { $Identity -like 'CN=Gone Group*' } { throw 'Cannot find an object with identity' }
    Mock Get-ADGroup -ParameterFilter { $Identity -like 'CN=App Users*' } { [pscustomobject]@{ Name = 'App Users' } }

    $p = Get-OnPremPreview -SourceInput 'source.user' -TargetInput 'target.user' -Domains @('corp.contoso.local')

    It 'lists the resolvable group as mirrorable' {
        ($p | Where-Object Name -eq 'App Users').Mirrorable | Should -Be $true
    }
    It 'shows an unresolvable group with the reason instead of dropping it' {
        $gone = $p | Where-Object Name -like 'CN=Gone Group*'
        $gone.Mirrorable | Should -Be $false
        $gone.Note       | Should -Match 'Could not resolve group'
    }
}

Describe 'Invoke-CloudCopy and Get-CloudPreview (Graph mocked)' {
    function New-TestGroup($id, $name, [switch]$Dynamic, [switch]$Synced) {
        [pscustomobject]@{
            '@odata.type'         = '#microsoft.graph.group'
            id                    = $id
            displayName           = $name
            groupTypes            = $(if ($Dynamic) { @('DynamicMembership') } else { @() })
            onPremisesSyncEnabled = $(if ($Synced) { $true } else { $null })
        }
    }
    $sourceGroups = @(
        (New-TestGroup 'g1' 'App Users'),
        (New-TestGroup 'g2' 'All Staff Dynamic' -Dynamic),
        (New-TestGroup 'g3' 'Synced From AD' -Synced),
        (New-TestGroup 'g4' 'Licensing - Sample Product A'),
        (New-TestGroup 'g5' 'Restricted - Sample Group C'),
        (New-TestGroup 'g6' 'Already Shared'),
        (New-TestGroup 'g7' 'Second App')
    )

    Mock Add-LogLine { }
    Mock Invoke-RestMethod -ParameterFilter { $Uri -like '*/oauth2/v2.0/token' } { [pscustomobject]@{ access_token = 'test-token' } }
    Mock Invoke-RestMethod -ParameterFilter { $Uri -like '*/users/source.user*' -and $Uri -notlike '*memberOf*' } { [pscustomobject]@{ id = 'src'; userPrincipalName = 'source.user@contoso' } }
    Mock Invoke-RestMethod -ParameterFilter { $Uri -like '*/users/target.user*' -and $Uri -notlike '*memberOf*' } { [pscustomobject]@{ id = 'tgt'; userPrincipalName = 'target.user@contoso' } }
    Mock Invoke-RestMethod -ParameterFilter { $Uri -like '*/users/src/memberOf*' } { [pscustomobject]@{ value = $sourceGroups } }
    Mock Invoke-RestMethod -ParameterFilter { $Uri -like '*/users/tgt/memberOf*' } { [pscustomobject]@{ value = @($sourceGroups[5]) } }

    $cloudArgs = @{ SourceUPN = 'source.user@contoso'; TargetUPN = 'target.user@contoso'
        TenantId = '00000000-0000-0000-0000-000000000000'; ClientId = '00000000-0000-0000-0000-000000000000'; ClientSecret = 'not-a-secret' }

    Context 'no confirmation filter' {
        Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'POST' -and $Uri -like '*/members/$ref' } { }
        $r = Invoke-CloudCopy @cloudArgs -Log $null

        It 'tags each group with the right status' {
            ($r | Where-Object GroupName -eq 'App Users').Status                     | Should -Be 'Added'
            ($r | Where-Object GroupName -eq 'Second App').Status                    | Should -Be 'Added'
            ($r | Where-Object GroupName -eq 'All Staff Dynamic').Status             | Should -Be 'Dynamic'
            ($r | Where-Object GroupName -eq 'Synced From AD').Status                | Should -Be 'OnPremSynced'
            ($r | Where-Object GroupName -eq 'Licensing - Sample Product A').Status  | Should -Be 'LicSkipped'
            ($r | Where-Object GroupName -eq 'Restricted - Sample Group C').Status | Should -Be 'Blocked'
            ($r | Where-Object GroupName -eq 'Already Shared').Status                | Should -Be 'AlreadyMember'
        }
        It 'makes exactly two add calls' {
            Assert-MockCalled Invoke-RestMethod -Exactly 2 -Scope Context -ParameterFilter { $Method -eq 'POST' -and $Uri -like '*/members/$ref' }
        }
    }

    Context 'Deselect All in the confirmation window' {
        Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'POST' -and $Uri -like '*/members/$ref' } { }
        $null = Invoke-CloudCopy @cloudArgs -Log $null -ApprovedNames @()

        It 'makes no add calls' {
            Assert-MockCalled Invoke-RestMethod -Exactly 0 -Scope Context -ParameterFilter { $Method -eq 'POST' -and $Uri -like '*/members/$ref' }
        }
    }

    Context 'sign-in fails' {
        Mock Invoke-RestMethod -ParameterFilter { $Uri -like '*/oauth2/v2.0/token' } { throw 'invalid_client' }
        $r = Invoke-CloudCopy @cloudArgs -Log $null

        It 'returns no results and logs the failure' {
            @($r).Count | Should -Be 0
            Assert-MockCalled Add-LogLine -Scope Context -ParameterFilter { $Text -like '*Cloud auth failed*' }
        }
    }

    Context 'preview' {
        $p = Get-CloudPreview @cloudArgs

        It 'marks only App Users and Second App as mirrorable' {
            @($p | Where-Object Mirrorable).Name | Sort-Object | Should -Be @('App Users', 'Second App')
        }
        It 'gives a reason for every excluded group' {
            @($p | Where-Object { -not $_.Mirrorable -and -not $_.Note }).Count | Should -Be 0
        }
    }
}

Describe 'Format-ClipboardText' {
    $results = @(
        [pscustomobject]@{ Section = 'OnPrem'; Status = 'Added';  GroupName = 'App Users';  GroupDomain = 'corp.contoso.local'; Detail = 'Added successfully' },
        [pscustomobject]@{ Section = 'Cloud';  Status = 'Failed'; GroupName = 'Second App'; GroupDomain = 'Entra ID'; Detail = 'Request denied' }
    )
    $text = Format-ClipboardText -Results $results -SourceInput 'source.user' -TargetInput 'target.user' -RunTime '2026-01-01 00:00:00'

    It 'names the source and target' {
        $text | Should -Match 'copying FROM\): source\.user'
        $text | Should -Match 'copying TO\):\s+target\.user'
    }
    It 'shows failure details for the ticket' {
        $text | Should -Match 'Request denied'
    }
    It 'counts blocked and licensing groups in the summary line' {
        $more = $results + [pscustomobject]@{ Section = 'Cloud'; Status = 'Blocked'; GroupName = 'Restricted - Sample Group C'; GroupDomain = 'Entra ID'; Detail = 'Blocked' }
        $t2 = Format-ClipboardText -Results $more -SourceInput 'source.user' -TargetInput 'target.user' -RunTime '2026-01-01 00:00:00'
        $t2 | Should -Match '\[BLOCK\] 1'
        $t2 | Should -Match '\[LIC\] 0'
    }
}

Describe 'DPAPI secret helpers' {
    It 'round-trips a secret with machine scope' -Skip:(-not $onWindows) {
        Add-Type -AssemblyName System.Security
        $blob = Protect-Secret -PlainText 'sample-value'
        $blob | Should -Not -Be 'sample-value'
        Unprotect-Secret -CipherText $blob | Should -Be 'sample-value'
    }
}
