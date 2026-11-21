# =============================================================
# Group Mirror Tool
# Copies on-prem AD and/or Entra cloud group memberships
# from a source user to a target user.
#
# Layout:
#   C:\Group-Mirror\
#       Group-Mirror.ps1
#       config.json
#       Logs\GroupMirror_Log.html
#
# To compile to EXE (run once, on your PC):
#   Install-Module ps2exe -Scope CurrentUser
#   Invoke-PS2EXE .\Group-Mirror.ps1 .\Group-Mirror.exe -noConsole
# =============================================================

$ErrorActionPreference = "Continue"


#region --- ASSEMBLIES ---
try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Web
    [System.Windows.Forms.Application]::EnableVisualStyles()
}
catch {
    [System.Windows.Forms.MessageBox]::Show(
        "Failed to load required assemblies.`n`n$($_.Exception.Message)",
        "Startup Error", "OK", "Error"
    )
    exit 1
}
#endregion

#region --- CONFIG ---

# ps2exe-safe path resolution
# $PSScriptRoot is null in compiled EXEs - use the EXE/script location instead
$ScriptRoot = if ($PSScriptRoot) {
    $PSScriptRoot
} elseif ($MyInvocation.MyCommand.Path) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    # Fallback for ps2exe compiled EXE - get the EXE directory
    Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
}
$ConfigPath = Join-Path $ScriptRoot "config.json"


function Import-ToolConfig {
    if (-not (Test-Path $ConfigPath)) {
        [System.Windows.Forms.MessageBox]::Show(
            "config.json not found at:`n$ConfigPath`n`nPlace config.json in the same folder as this script.",
            "Configuration Missing", "OK", "Error"
        )
        exit 1
    }

    try {
        $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "config.json could not be parsed. Check JSON syntax.`n`n$($_.Exception.Message)",
            "Configuration Error", "OK", "Error"
        )
        exit 1
    }

    $required = @("TenantId","ClientId","ClientSecret","SearchDomains","LogPath","LogFile")
    foreach ($field in $required) {
        if (-not $cfg.$field) {
            [System.Windows.Forms.MessageBox]::Show(
                "config.json is missing required field: $field",
                "Configuration Error", "OK", "Error"
            )
            exit 1
        }
    }

    return $cfg
}

$Config = Import-ToolConfig

#endregion

#region --- DPAPI SECRET MANAGEMENT ---


# DPAPI scope note:
#   LocalMachine ties the encrypted secret to THIS SERVER, so any account that
#   can run the tool on this server can decrypt it. That is what we want for a
#   shared management server.
#   CurrentUser (the old behaviour) tied it to one Windows account only, which
#   is why other admins got "secret cannot be decrypted".

function Protect-Secret {
    param([string]$PlainText)
    $bytes     = [System.Text.Encoding]::UTF8.GetBytes($PlainText)
    $encrypted = [System.Security.Cryptography.ProtectedData]::Protect(
        $bytes, $null,
        [System.Security.Cryptography.DataProtectionScope]::LocalMachine
    )
    return [Convert]::ToBase64String($encrypted)
}

function Unprotect-Secret {
    param(
        [string]$CipherText,
        [System.Security.Cryptography.DataProtectionScope]$Scope =
            [System.Security.Cryptography.DataProtectionScope]::LocalMachine
    )
    $bytes     = [Convert]::FromBase64String($CipherText)
    $decrypted = [System.Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, $Scope)
    return [System.Text.Encoding]::UTF8.GetString($decrypted)
}

Add-Type -AssemblyName System.Security

# ---- First run with a plaintext secret: encrypt it ----
if ($Config.SecretEncrypted -eq $false -and
    @("", "PASTE-CLIENT-SECRET-HERE", "YOUR-CLIENT-SECRET-HERE") -contains [string]$Config.ClientSecret) {
    [System.Windows.Forms.MessageBox]::Show(
        "config.json still has a placeholder client secret. Paste the real secret into ClientSecret, then run again.",
        "Configuration Error", "OK", "Error"
    )
    exit 1
}

if ($Config.SecretEncrypted -eq $false) {
    try {
        $Config.ClientSecret    = Protect-Secret -PlainText $Config.ClientSecret
        $Config.SecretEncrypted = $true
        $Config | ConvertTo-Json -Depth 5 | Set-Content $ConfigPath -Encoding UTF8
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Failed to encrypt client secret with DPAPI.`n`n$($_.Exception.Message)",
            "Encryption Error", "OK", "Error"
        )
        exit 1
    }
}

# ---- Decrypt for runtime use ----
$RuntimeSecret = $null
try {
    # Normal path: machine-scoped blob
    $RuntimeSecret = Unprotect-Secret -CipherText $Config.ClientSecret
}
catch {
    # Migration path: the blob may still be user-scoped from an older version.
    # If the account that originally encrypted it is running now, decrypt with
    # CurrentUser and immediately re-encrypt to LocalMachine so every admin on
    # this server can use it from here on.
    try {
        $RuntimeSecret = Unprotect-Secret -CipherText $Config.ClientSecret `
                            -Scope ([System.Security.Cryptography.DataProtectionScope]::CurrentUser)

        $Config.ClientSecret = Protect-Secret -PlainText $RuntimeSecret
        $Config | ConvertTo-Json -Depth 5 | Set-Content $ConfigPath -Encoding UTF8

        [System.Windows.Forms.MessageBox]::Show(
            "The stored secret was tied to a single Windows account. It has been re-encrypted to this server, so any admin who can run this tool on $env:COMPUTERNAME can now use it.",
            "Secret Re-encrypted", "OK", "Information"
        )
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Could not decrypt the client secret on this machine.`n`nThis usually means the secret was encrypted on a different server, or under a different Windows account before machine-wide encryption was enabled.`n`nTo fix: open config.json, paste the plaintext client secret into ClientSecret, set SecretEncrypted to false, then run this tool once. It will re-encrypt for the whole server.",
            "Decryption Error", "OK", "Error"
        )
        exit 1
    }
}

#endregion

#region --- SHARED EXCLUSION LISTS ---
# These mirror the lists inside Invoke-CloudCopy so the preview window
# can show the same skip reasons before anything is written.
$Script:LicensingExclusionsRef = @(
    # Groups that assign licenses. Replace with your own licensing group names.
    "Licensing - Sample Product A",
    "Licensing - Sample Product B",
    "Licensing - Sample Product C"
)
$Script:DoNotMirrorRef = @(
    # Restricted groups that are never mirrored, on-prem or cloud.
    # Matched by exact name or by prefix (see Test-DoNotMirror).
    "Restricted - Sample Group A",
    "Restricted - Sample Group B",
    "Restricted - Sample Group C"
)
#endregion

#region --- HELPERS ---

function ConvertTo-SamName {
    param([string]$InputValue)
    $cleaned = ($InputValue -replace "^[^\\]+\\", "").Trim()
    if ($cleaned -match "@") { $cleaned = $cleaned.Split("@")[0] }
    return $cleaned
}

function Get-CloudUPN {
    param([string]$InputValue)
    # Strip any DOMAIN\ prefix, otherwise return the input exactly as typed.
    # Never guess a domain: the operator must supply the full UPN with @domain.
    return ($InputValue -replace "^[^\\]+\\", "").Trim()
}

function Get-DomainFromDN {
    param([string]$DN)
    $parts = ($DN -split ",") | Where-Object { $_ -like "DC=*" } | ForEach-Object { $_ -replace "^DC=", "" }
    return ($parts -join ".")
}

function Test-SkipUnapproved {
    param(
        [string]   $GroupName,
        [string[]] $ApprovedNames
    )
    # $null = no confirmation window was used, so nothing is filtered.
    # @()   = the operator approved nothing in this column, so EVERYTHING is skipped.
    # $null must be on the LEFT. "$array -ne $null" filters the array instead of
    # testing it, so an empty approved list used to read as "no filter".
    return ($null -ne $ApprovedNames -and $ApprovedNames -notcontains $GroupName)
}

function Test-DoNotMirror {
    param([string]$GroupName)
    # Some AD/Entra groups carry a generated hash suffix (e.g.
    # "Restricted - Sample Group A_0a1b2c3d4e5f"). Match on exact name OR
    # on the configured name as a prefix so suffixed variants are caught.
    foreach ($blocked in $Script:DoNotMirrorRef) {
        if ($GroupName -eq $blocked) { return $true }
        if ($GroupName -like "$blocked*") { return $true }
    }
    return $false
}

function Find-DomainUser {
    param([string]$LookupValue, [string[]]$Domains)

    $clean       = ConvertTo-SamName -InputValue $LookupValue
    $upn         = if ($LookupValue -match "@") { $LookupValue } else { $clean }
    $escapedSAM  = $clean -replace "'", "''"
    $escapedUPN  = $upn   -replace "'", "''"
    $userMatches = @()
    $unreachable = @()

    foreach ($domain in $Domains) {
        try {
            $found = Get-ADUser `
                -Server $domain `
                -Filter "SamAccountName -eq '$escapedSAM' -or UserPrincipalName -eq '$escapedUPN'" `
                -Properties MemberOf, SamAccountName, UserPrincipalName, DistinguishedName `
                -ErrorAction Stop

            foreach ($u in @($found)) {
                $userMatches += [PSCustomObject]@{ Domain = $domain; User = $u }
            }
        }
        catch { $unreachable += $domain }
    }

    return [PSCustomObject]@{
        Matches     = $userMatches
        Unreachable = $unreachable
    }
}

#endregion

#region --- ON-PREM COPY LOGIC ---

function Invoke-OnPremCopy {
    param(
        [string]   $SourceInput,
        [string]   $TargetInput,
        [string[]] $Domains,
        [System.Windows.Forms.RichTextBox] $Log,
        [string[]] $ApprovedNames = $null
    )

    $results     = @()

    $srcResult = Find-DomainUser -LookupValue $SourceInput -Domains $Domains
    if ($srcResult.Unreachable.Count -gt 0) {
        Add-LogLine $Log "[WARN]  Unreachable domains: $($srcResult.Unreachable -join ', ')" "warn"
    }
    if ($srcResult.Matches.Count -eq 0) {
        Add-LogLine $Log "[FAIL]  Source user not found in any domain: $SourceInput" "fail"
        return $results
    }
    if ($srcResult.Matches.Count -gt 1) {
        Add-LogLine $Log "[FAIL]  Multiple accounts found for source: $SourceInput - use full UPN." "fail"
        return $results
    }

    $sourceUser   = $srcResult.Matches[0].User
    $sourceDomain = $srcResult.Matches[0].Domain

    $tgtResult = Find-DomainUser -LookupValue $TargetInput -Domains $Domains
    if ($tgtResult.Unreachable.Count -gt 0) {
        Add-LogLine $Log "[WARN]  Unreachable domains (target lookup): $($tgtResult.Unreachable -join ', ')" "warn"
    }
    if ($tgtResult.Matches.Count -eq 0) {
        Add-LogLine $Log "[FAIL]  Target user not found in any domain: $TargetInput" "fail"
        return $results
    }
    if ($tgtResult.Matches.Count -gt 1) {
        Add-LogLine $Log "[FAIL]  Multiple accounts found for target: $TargetInput - use full UPN." "fail"
        return $results
    }

    $targetUser       = $tgtResult.Matches[0].User
    $targetUserDomain = $tgtResult.Matches[0].Domain

    Add-LogLine $Log "   Source: $($sourceUser.SamAccountName) [$sourceDomain]" "info"
    Add-LogLine $Log "   Target: $($targetUser.SamAccountName) [$targetUserDomain]" "info"

    $targetGroupDNs = @($targetUser.MemberOf)

    # Re-fetch target user as full ADUser object from their own domain
    # This gives us a live object Add-ADGroupMember can resolve cross-domain
    $targetUserObj = Get-ADUser -Identity $targetUser.DistinguishedName `
                        -Server $targetUserDomain -ErrorAction Stop

    foreach ($groupDN in @($sourceUser.MemberOf)) {
        $group       = $null
        $groupDomain = "Unknown"

        try {
            $groupDomain = Get-DomainFromDN -DN $groupDN

            $group = Get-ADGroup `
                -Server $groupDomain `
                -Identity $groupDN `
                -Properties Name, GroupScope, GroupCategory, DistinguishedName `
                -ErrorAction Stop

            if (Test-DoNotMirror -GroupName $group.Name) {
                $results += [PSCustomObject]@{
                    Section    = "OnPrem"
                    Status     = "Blocked"
                    GroupName  = $group.Name
                    GroupDomain= $groupDomain
                    Detail     = "Blocked from mirroring - restricted access group. Add manually only if explicitly required."
                }
                continue
            }

            if ($targetGroupDNs -contains $groupDN) {
                $results += [PSCustomObject]@{
                    Section    = "OnPrem"
                    Status     = "AlreadyMember"
                    GroupName  = $group.Name
                    GroupDomain= $groupDomain
                    Detail     = "Target already a member"
                }
                continue
            }

            # This group is genuinely mirrorable. Skip only if the operator
            # unchecked it in the confirmation window.
            if (Test-SkipUnapproved -GroupName $group.Name -ApprovedNames $ApprovedNames) {
                continue
            }

            # For cross-domain group membership, pass the full ADUser object
            # rather than just the DN string. The group domain DC resolves the
            # foreign principal via the forest trust using the live object.
            Add-ADGroupMember `
                -Server $groupDomain `
                -Identity $groupDN `
                -Members $targetUserObj `
                -ErrorAction Stop

            $results += [PSCustomObject]@{
                Section    = "OnPrem"
                Status     = "Added"
                GroupName  = $group.Name
                GroupDomain= $groupDomain
                Detail     = "Added successfully"
            }
        }
        catch {
            $err = $_.Exception.Message
            if ($err -match "ADIdentityNotFoundException|does not exist") {
                $results += [PSCustomObject]@{
                    Section    = "OnPrem"
                    Status     = "NotFound"
                    GroupName  = if ($group) { $group.Name } else { "(not resolvable)" }
                    GroupDomain= $groupDomain
                    Detail     = "Group DN in membership but object not found in directory"
                }
            }
            elseif ($err -match "Cannot find an object with identity") {
                $results += [PSCustomObject]@{
                    Section    = "OnPrem"
                    Status     = "Failed"
                    GroupName  = if ($group) { $group.Name } else { "(lookup failed)" }
                    GroupDomain= $groupDomain
                    Detail     = "Cross-domain add failed - target user not resolvable from $groupDomain. Check forest trust."
                }
            }
            else {
                $results += [PSCustomObject]@{
                    Section    = "OnPrem"
                    Status     = "Failed"
                    GroupName  = if ($group) { $group.Name } else { "(lookup failed)" }
                    GroupDomain= $groupDomain
                    Detail     = $err
                }
            }
        }
    }

    return $results
}

#endregion

#region --- CLOUD COPY LOGIC ---

function Invoke-CloudCopy {
    param(
        [string] $SourceUPN,
        [string] $TargetUPN,
        [string] $TenantId,
        [string] $ClientId,
        [string] $ClientSecret,
        [System.Windows.Forms.RichTextBox] $Log,
        [string[]] $ApprovedNames = $null
    )

    $results = @()

    # Exclusion lists live once, at script scope (SHARED EXCLUSION LISTS region).
    $LicensingExclusions = $Script:LicensingExclusionsRef

    # Force TLS 1.2 - PS 5.1 on Server 2016 defaults to TLS 1.0
    # which Microsoft auth endpoints no longer accept
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    try {
        $tokenBody = @{
            grant_type    = "client_credentials"
            scope         = "https://graph.microsoft.com/.default"
            client_id     = $ClientId
            client_secret = $ClientSecret
        }
        $tokenResp   = Invoke-RestMethod -Method POST `
            -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
            -Body $tokenBody -ErrorAction Stop
        $accessToken = $tokenResp.access_token
        $headers     = @{ Authorization = "Bearer $accessToken"; "Content-Type" = "application/json" }
        Add-LogLine $Log "   Graph auth OK" "ok"
    }
    catch {
        Add-LogLine $Log "[FAIL]  Cloud auth failed: $($_.Exception.Message)" "fail"
        return $results
    }

    try {
        $srcUser = Invoke-RestMethod -Headers $headers `
            -Uri "https://graph.microsoft.com/v1.0/users/$([Uri]::EscapeDataString($SourceUPN))" `
            -ErrorAction Stop
    }
    catch {
        Add-LogLine $Log "[FAIL]  Cloud source user not found: $SourceUPN" "fail"
        return $results
    }

    try {
        $tgtUser = Invoke-RestMethod -Headers $headers `
            -Uri "https://graph.microsoft.com/v1.0/users/$([Uri]::EscapeDataString($TargetUPN))" `
            -ErrorAction Stop
    }
    catch {
        Add-LogLine $Log "[FAIL]  Cloud target user not found: $TargetUPN" "fail"
        return $results
    }

    Add-LogLine $Log "   Source: $($srcUser.userPrincipalName)" "info"
    Add-LogLine $Log "   Target: $($tgtUser.userPrincipalName)" "info"

    $srcGroups = @()
    $uri = "https://graph.microsoft.com/v1.0/users/$($srcUser.id)/memberOf?`$top=999"
    do {
        $resp      = Invoke-RestMethod -Headers $headers -Uri $uri -ErrorAction Stop
        $srcGroups += $resp.value | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.group' }
        $uri        = $resp.'@odata.nextLink'
    } while ($uri)

    $tgtGroupIds = @()
    $uri = "https://graph.microsoft.com/v1.0/users/$($tgtUser.id)/memberOf?`$top=999"
    do {
        $resp        = Invoke-RestMethod -Headers $headers -Uri $uri -ErrorAction Stop
        $tgtGroupIds += ($resp.value | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.group' } | Select-Object -ExpandProperty id)
        $uri          = $resp.'@odata.nextLink'
    } while ($uri)

    # Collect unknown licensing groups for single popup
    $unknownLicGroups = @()
    foreach ($group in $srcGroups) {
        $wouldBeAdded = ($LicensingExclusions -notcontains $group.displayName) -and
                        -not (Test-DoNotMirror -GroupName $group.displayName) -and
                        ($group.groupTypes -notcontains "DynamicMembership") -and
                        ($group.onPremisesSyncEnabled -ne $true) -and
                        ($tgtGroupIds -notcontains $group.id)
        if ($wouldBeAdded) {
            if ($group.displayName -match "licens") {
                $unknownLicGroups += $group.displayName
            }
        }
    }

    # Fire one popup for all unknown licensing groups
    $SkipUnknownLicGroups = @()
    if ($unknownLicGroups.Count -gt 0) {
        $groupList  = ($unknownLicGroups | ForEach-Object { "  * $_" }) -join "`n"
        $msg        = "The following groups appear to be licensing groups`nnot in the exclusion list:`n`n$groupList`n`nSkip all and handle manually, or add them anyway?"
        $popupForm  = New-Object System.Windows.Forms.Form
        $popupForm.Text          = "Licensing Groups Detected"
        $popupForm.Size          = New-Object System.Drawing.Size(520, 300)
        $popupForm.StartPosition = "CenterScreen"
        $popupForm.BackColor     = [System.Drawing.Color]::FromArgb(32, 36, 44)
        $popupForm.ForeColor     = [System.Drawing.Color]::FromArgb(220, 222, 228)
        $popupForm.Font          = New-Object System.Drawing.Font("Segoe UI", 9)
        $popupForm.TopMost       = $true

        $lbl          = New-Object System.Windows.Forms.Label
        $lbl.Text     = $msg
        $lbl.Location = New-Object System.Drawing.Point(16, 14)
        $lbl.Size     = New-Object System.Drawing.Size(480, 180)
        $lbl.ForeColor= [System.Drawing.Color]::FromArgb(220, 222, 228)
        $popupForm.Controls.Add($lbl)

        $Script:LicPopupResult = "SkipAll"

        $btnSkipAll = New-Object System.Windows.Forms.Button
        $btnSkipAll.Text     = "Skip All"
        $btnSkipAll.Location = New-Object System.Drawing.Point(16, 210)
        $btnSkipAll.Size     = New-Object System.Drawing.Size(100, 32)
        $btnSkipAll.BackColor= [System.Drawing.Color]::FromArgb(30, 50, 80)
        $btnSkipAll.ForeColor= [System.Drawing.Color]::White
        $btnSkipAll.FlatStyle= "Flat"
        $btnSkipAll.Add_Click({ $Script:LicPopupResult = "SkipAll"; $popupForm.Close() })
        $popupForm.Controls.Add($btnSkipAll)

        $btnAddAll = New-Object System.Windows.Forms.Button
        $btnAddAll.Text     = "Add All Anyway"
        $btnAddAll.Location = New-Object System.Drawing.Point(126, 210)
        $btnAddAll.Size     = New-Object System.Drawing.Size(130, 32)
        $btnAddAll.BackColor= [System.Drawing.Color]::FromArgb(80, 40, 40)
        $btnAddAll.ForeColor= [System.Drawing.Color]::White
        $btnAddAll.FlatStyle= "Flat"
        $btnAddAll.Add_Click({ $Script:LicPopupResult = "AddAll"; $popupForm.Close() })
        $popupForm.Controls.Add($btnAddAll)

        $btnDecide = New-Object System.Windows.Forms.Button
        $btnDecide.Text     = "Decide Each One"
        $btnDecide.Location = New-Object System.Drawing.Point(266, 210)
        $btnDecide.Size     = New-Object System.Drawing.Size(130, 32)
        $btnDecide.BackColor= [System.Drawing.Color]::FromArgb(40, 60, 80)
        $btnDecide.ForeColor= [System.Drawing.Color]::White
        $btnDecide.FlatStyle= "Flat"
        $btnDecide.Add_Click({ $Script:LicPopupResult = "DecideEach"; $popupForm.Close() })
        $popupForm.Controls.Add($btnDecide)

        [void]$popupForm.ShowDialog()

        if ($Script:LicPopupResult -eq "SkipAll") {
            $SkipUnknownLicGroups = $unknownLicGroups
        }
        elseif ($Script:LicPopupResult -eq "DecideEach") {
            foreach ($gName in $unknownLicGroups) {
                $choice = [System.Windows.Forms.MessageBox]::Show(
                    "Skip this licensing group?`n`n$gName",
                    "Licensing Group",
                    [System.Windows.Forms.MessageBoxButtons]::YesNo,
                    [System.Windows.Forms.MessageBoxIcon]::Warning
                )
                if ($choice -eq "Yes") { $SkipUnknownLicGroups += $gName }
            }
        }
        # AddAll = $SkipUnknownLicGroups stays empty, groups proceed normally
    }

    foreach ($group in $srcGroups) {

        # Do-not-mirror security exclusion check
        if (Test-DoNotMirror -GroupName $group.displayName) {
            $results += [PSCustomObject]@{
                Section    = "Cloud"
                Status     = "Blocked"
                GroupName  = $group.displayName
                GroupDomain= "Entra ID"
                Detail     = "Blocked from mirroring - restricted access group. Add manually only if explicitly required."
            }
            continue
        }

        # Hardcoded exclusion check
        if ($LicensingExclusions -contains $group.displayName) {
            $results += [PSCustomObject]@{
                Section    = "Cloud"
                Status     = "LicSkipped"
                GroupName  = $group.displayName
                GroupDomain= "Entra ID"
                Detail     = "Licensing group - excluded from copy. Assign manually based on role."
            }
            continue
        }

        # Unknown licensing group - user chose to skip
        if ($SkipUnknownLicGroups -contains $group.displayName) {
            $results += [PSCustomObject]@{
                Section    = "Cloud"
                Status     = "LicSkipped"
                GroupName  = $group.displayName
                GroupDomain= "Entra ID"
                Detail     = "Unrecognised licensing group - skipped by operator. Assign manually."
            }
            continue
        }

        if ($group.groupTypes -contains "DynamicMembership") {
            $results += [PSCustomObject]@{
                Section    = "Cloud"
                Status     = "Dynamic"
                GroupName  = $group.displayName
                GroupDomain= "Entra ID"
                Detail     = "Dynamic group - membership auto-assigned when account meets rule criteria. Verify in Entra after provisioning completes."
            }
            continue
        }

        if ($group.onPremisesSyncEnabled -eq $true) {
            $results += [PSCustomObject]@{
                Section    = "Cloud"
                Status     = "OnPremSynced"
                GroupName  = $group.displayName
                GroupDomain= "Entra ID (synced)"
                Detail     = "Group is mastered in on-prem AD and synced to Entra. Already handled by on-prem copy - no cloud action needed."
            }
            continue
        }

        if ($tgtGroupIds -contains $group.id) {
            $results += [PSCustomObject]@{
                Section    = "Cloud"
                Status     = "AlreadyMember"
                GroupName  = $group.displayName
                GroupDomain= "Entra ID"
                Detail     = "Target already a member"
            }
            continue
        }

        # This group is genuinely mirrorable. Skip only if the operator
        # unchecked it in the confirmation window.
        if (Test-SkipUnapproved -GroupName $group.displayName -ApprovedNames $ApprovedNames) {
            continue
        }

        try {
            $body = @{ "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($tgtUser.id)" } | ConvertTo-Json
            Invoke-RestMethod -Headers $headers -Method POST `
                -Uri "https://graph.microsoft.com/v1.0/groups/$($group.id)/members/`$ref" `
                -Body $body -ErrorAction Stop

            $results += [PSCustomObject]@{
                Section    = "Cloud"
                Status     = "Added"
                GroupName  = $group.displayName
                GroupDomain= "Entra ID"
                Detail     = "Added successfully"
            }
        }
        catch {
            $err = $_.Exception.Message
            if ($err -match "Request_ResourceNotFound|404") {
                $results += [PSCustomObject]@{
                    Section    = "Cloud"
                    Status     = "NotFound"
                    GroupName  = $group.displayName
                    GroupDomain= "Entra ID"
                    Detail     = "Group exists in source membership but was not found in directory"
                }
            }
            else {
                $results += [PSCustomObject]@{
                    Section    = "Cloud"
                    Status     = "Failed"
                    GroupName  = $group.displayName
                    GroupDomain= "Entra ID"
                    Detail     = $err
                }
            }
        }
    }

    return $results
}

#endregion

#region --- RESULTS RENDERING ---

$StatusConfig = @{
    Added        = @{ Emoji = "[OK]  "; Label = "Added Successfully";        Color = [System.Drawing.Color]::FromArgb(20, 110, 53)  }
    Dynamic      = @{ Emoji = "[DYN] "; Label = "Dynamic (Auto-Assign)";     Color = [System.Drawing.Color]::FromArgb(100, 70, 0)   }
    OnPremSynced = @{ Emoji = "[SYNC]"; Label = "Already Synced On-Prem";    Color = [System.Drawing.Color]::FromArgb(30, 80, 140)  }
    AlreadyMember= @{ Emoji = "[MBR] "; Label = "Already a Member";           Color = [System.Drawing.Color]::FromArgb(60, 60, 130)  }
    LicSkipped   = @{ Emoji = "[LIC] "; Label = "Licensing Group - Skipped"; Color = [System.Drawing.Color]::FromArgb(140, 60, 140) }
    Blocked      = @{ Emoji = "[BLOCK]"; Label = "Blocked - Restricted Group";  Color = [System.Drawing.Color]::FromArgb(160, 40, 40)  }
    Failed       = @{ Emoji = "[FAIL]"; Label = "Failed";                    Color = [System.Drawing.Color]::FromArgb(139, 26, 26)  }
    NotFound     = @{ Emoji = "[???] "; Label = "Group Not Found";            Color = [System.Drawing.Color]::FromArgb(120, 60, 0)   }
}

function Add-LogLine {
    param(
        [System.Windows.Forms.RichTextBox] $RTB,
        [string] $Text,
        [string] $Type = "info"
    )
    $color = switch ($Type) {
        "fail" { [System.Drawing.Color]::FromArgb(200, 50, 50)   }
        "warn" { [System.Drawing.Color]::FromArgb(180, 120, 0)   }
        "ok"   { [System.Drawing.Color]::FromArgb(20, 140, 60)   }
        default{ [System.Drawing.Color]::FromArgb(220, 220, 220) }
    }
    $RTB.SelectionStart  = $RTB.TextLength
    $RTB.SelectionLength = 0
    $RTB.SelectionColor  = $color
    $RTB.AppendText("$Text`n")
    $RTB.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

function Show-Result {
    param(
        [array]  $Results,
        [System.Windows.Forms.RichTextBox] $RTB
    )

    $RTB.AppendText("`n")
    $order = @("Added","Dynamic","OnPremSynced","AlreadyMember","LicSkipped","Blocked","Failed","NotFound")

    foreach ($section in @("OnPrem","Cloud")) {
        $sectionResults = $Results | Where-Object { $_.Section -eq $section }
        if (-not $sectionResults) { continue }

        $RTB.SelectionStart  = $RTB.TextLength
        $RTB.SelectionColor  = [System.Drawing.Color]::FromArgb(110, 160, 220)
        $RTB.SelectionFont   = New-Object System.Drawing.Font("Consolas", 10, [System.Drawing.FontStyle]::Bold)
        $RTB.AppendText("-- $section Groups " + ("-" * 35) + "`n")

        foreach ($status in $order) {
            $group = @($sectionResults | Where-Object { $_.Status -eq $status })
            if ($group.Count -eq 0) { continue }

            $cfg = $StatusConfig[$status]
            $RTB.SelectionStart  = $RTB.TextLength
            $RTB.SelectionColor  = $cfg.Color
            $RTB.SelectionFont   = New-Object System.Drawing.Font("Consolas", 9, [System.Drawing.FontStyle]::Bold)
            $RTB.AppendText("`n  $($cfg.Emoji)  $($cfg.Label) ($($group.Count))`n")
            $RTB.SelectionFont   = New-Object System.Drawing.Font("Consolas", 9, [System.Drawing.FontStyle]::Regular)

            foreach ($item in $group) {
                $RTB.SelectionColor = [System.Drawing.Color]::FromArgb(200, 200, 200)
                $RTB.AppendText("     $($item.GroupName)")
                if ($item.GroupDomain -and $item.GroupDomain -notmatch "^Entra") {
                    $RTB.SelectionColor = [System.Drawing.Color]::FromArgb(120, 120, 120)
                    $RTB.AppendText("  [$($item.GroupDomain)]")
                }
                $RTB.AppendText("`n")
                if ($status -in @("Dynamic","Failed","NotFound","OnPremSynced")) {
                    $RTB.SelectionColor = [System.Drawing.Color]::FromArgb(150, 150, 150)
                    $RTB.AppendText("       --> $($item.Detail)`n")
                }
            }
        }

        $added    = @($sectionResults | Where-Object { $_.Status -eq "Added" }).Count
        $dynamic  = @($sectionResults | Where-Object { $_.Status -eq "Dynamic" }).Count
        $synced   = @($sectionResults | Where-Object { $_.Status -eq "OnPremSynced" }).Count
        $already  = @($sectionResults | Where-Object { $_.Status -eq "AlreadyMember" }).Count
        $licskip  = @($sectionResults | Where-Object { $_.Status -eq "LicSkipped" }).Count
        $blocked  = @($sectionResults | Where-Object { $_.Status -eq "Blocked" }).Count
        $failed   = @($sectionResults | Where-Object { $_.Status -eq "Failed" }).Count
        $notfound = @($sectionResults | Where-Object { $_.Status -eq "NotFound" }).Count

        $RTB.SelectionStart  = $RTB.TextLength
        $RTB.SelectionColor  = [System.Drawing.Color]::FromArgb(140, 140, 140)
        $RTB.SelectionFont   = New-Object System.Drawing.Font("Consolas", 9, [System.Drawing.FontStyle]::Regular)
        $RTB.AppendText("`n  Summary: [OK] $added  [DYN] $dynamic  [SYNC] $synced  [MBR] $already  [LIC] $licskip  [BLOCK] $blocked  [FAIL] $failed  [???] $notfound`n`n")
    }
}

#endregion

#region --- CLIPBOARD FORMATTER ---

function Format-ClipboardText {
    param(
        [array]  $Results,
        [string] $SourceInput,
        [string] $TargetInput,
        [string] $RunTime
    )

    $lines  = @()
    $lines += "Group Mirror - $RunTime"
    $lines += "Source (copying FROM): $SourceInput"
    $lines += "Target (copying TO):   $TargetInput"
    $lines += ""

    $order = @("Added","Dynamic","OnPremSynced","AlreadyMember","LicSkipped","Blocked","Failed","NotFound")

    foreach ($section in @("OnPrem","Cloud")) {
        $sectionResults = $Results | Where-Object { $_.Section -eq $section }
        if (-not $sectionResults) { continue }

        $lines += "-- $section --------------------------"

        foreach ($status in $order) {
            $group = @($sectionResults | Where-Object { $_.Status -eq $status })
            if ($group.Count -eq 0) { continue }
            $cfg    = $StatusConfig[$status]
            $lines += ""
            $lines += "$($cfg.Emoji) $($cfg.Label) ($($group.Count))"
            foreach ($item in $group) {
                $entry  = "   * $($item.GroupName)"
                if ($item.GroupDomain -and $item.GroupDomain -notmatch "^Entra") { $entry += " [$($item.GroupDomain)]" }
                $lines += $entry
                if ($status -in @("Dynamic","Failed","NotFound","OnPremSynced")) {
                    $lines += "     --> $($item.Detail)"
                }
            }
        }

        $added    = @($sectionResults | Where-Object { $_.Status -eq "Added" }).Count
        $dynamic  = @($sectionResults | Where-Object { $_.Status -eq "Dynamic" }).Count
        $synced   = @($sectionResults | Where-Object { $_.Status -eq "OnPremSynced" }).Count
        $already  = @($sectionResults | Where-Object { $_.Status -eq "AlreadyMember" }).Count
        $licskip  = @($sectionResults | Where-Object { $_.Status -eq "LicSkipped" }).Count
        $blocked  = @($sectionResults | Where-Object { $_.Status -eq "Blocked" }).Count
        $failed   = @($sectionResults | Where-Object { $_.Status -eq "Failed" }).Count
        $notfound = @($sectionResults | Where-Object { $_.Status -eq "NotFound" }).Count

        $lines += ""
        $lines += "Summary: [OK]   $added  [DYN]  $dynamic  [SYNC] $synced  [MBR]  $already  [LIC] $licskip  [BLOCK] $blocked  [FAIL] $failed  [???]  $notfound"
        $lines += ""
    }

    return $lines -join "`r`n"
}

#endregion

#region --- HTML LOG ---

function Update-HtmlLog {

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'GUI helper. The confirmation window is this tool''s ShouldProcess.')]

    param(
        [array]  $Results,
        [string] $SourceInput,
        [string] $TargetInput,
        [string] $RunTime,
        [string] $RunBy
    )

    $logDir  = $Config.LogPath
    $logFile = Join-Path $logDir $Config.LogFile

    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

    $entryHtml  = "<div class='run'>"
    $entryHtml += "<div class='run-header'>"
    $entryHtml += "<span class='run-time'>$([System.Web.HttpUtility]::HtmlEncode($RunTime))</span>"
    $entryHtml += "<span class='run-by'>Run by: $([System.Web.HttpUtility]::HtmlEncode($RunBy))</span>"
    $entryHtml += "</div>"
    $entryHtml += "<div class='run-users'>"
    $entryHtml += "<span class='user-label'>Copying FROM</span>"
    $entryHtml += "<span class='user-name'>$([System.Web.HttpUtility]::HtmlEncode($SourceInput))</span>"
    $entryHtml += "<span class='user-arrow'>&rarr;</span>"
    $entryHtml += "<span class='user-label'>Copying TO</span>"
    $entryHtml += "<span class='user-name'>$([System.Web.HttpUtility]::HtmlEncode($TargetInput))</span>"
    $entryHtml += "</div>"

    $order  = @("Added","Dynamic","OnPremSynced","AlreadyMember","LicSkipped","Blocked","Failed","NotFound")
    $labels = @{
        Added        = @{ emoji="[OK]  "; label="Added Successfully";       cls="added"    }
        Dynamic      = @{ emoji="[DYN] "; label="Dynamic (Auto-Assign)";    cls="dynamic"  }
        OnPremSynced = @{ emoji="[SYNC]"; label="Already Synced On-Prem";   cls="synced"   }
        AlreadyMember= @{ emoji="[MBR] "; label="Already a Member";          cls="already"  }
        LicSkipped   = @{ emoji="[LIC] "; label="Licensing - Skipped";      cls="licskip"  }
        Blocked      = @{ emoji="[BLOCK]"; label="Blocked - Restricted";      cls="blocked"  }
        Failed       = @{ emoji="[FAIL]"; label="Failed";                   cls="failed"   }
        NotFound     = @{ emoji="[???] "; label="Not Found";                cls="notfound" }
    }

    foreach ($section in @("OnPrem","Cloud")) {
        $sectionResults = $Results | Where-Object { $_.Section -eq $section }
        if (-not $sectionResults) { continue }

        $entryHtml += "<div class='section-title'>$section</div>"
        $entryHtml += "<div class='section-body'>"

        foreach ($status in $order) {
            $group = @($sectionResults | Where-Object { $_.Status -eq $status })
            if ($group.Count -eq 0) { continue }

            $lbl        = $labels[$status]
            $entryHtml += "<div class='status-group $($lbl.cls)'>"
            $entryHtml += "<div class='status-header'>$($lbl.emoji) $($lbl.label) <span class='badge'>$($group.Count)</span></div>"
            $entryHtml += "<ul>"
            foreach ($item in $group) {
                $name       = [System.Web.HttpUtility]::HtmlEncode($item.GroupName)
                $domain     = [System.Web.HttpUtility]::HtmlEncode($item.GroupDomain)
                $detail     = [System.Web.HttpUtility]::HtmlEncode($item.Detail)
                $entryHtml += "<li><span class='gname'>$name</span>"
                if ($domain -and $domain -notmatch "^Entra") { $entryHtml += " <span class='gdomain'>[$domain]</span>" }
                if ($status -in @("Dynamic","Failed","NotFound","OnPremSynced")) {
                    $entryHtml += "<div class='gdetail'>&rarr; $detail</div>"
                }
                $entryHtml += "</li>"
            }
            $entryHtml += "</ul></div>"
        }

        $a  = @($sectionResults | Where-Object { $_.Status -eq "Added" }).Count
        $dy = @($sectionResults | Where-Object { $_.Status -eq "Dynamic" }).Count
        $sy = @($sectionResults | Where-Object { $_.Status -eq "OnPremSynced" }).Count
        $al = @($sectionResults | Where-Object { $_.Status -eq "AlreadyMember" }).Count
        $ls = @($sectionResults | Where-Object { $_.Status -eq "LicSkipped" }).Count
        $bl = @($sectionResults | Where-Object { $_.Status -eq "Blocked" }).Count
        $fa = @($sectionResults | Where-Object { $_.Status -eq "Failed" }).Count
        $nf = @($sectionResults | Where-Object { $_.Status -eq "NotFound" }).Count
        $entryHtml += "<div class='summary'>[OK]   $a Added &nbsp; [DYN]  $dy Dynamic &nbsp; [SYNC] $sy On-Prem Synced &nbsp; [MBR]  $al Already Member &nbsp; [LIC] $ls Licensing &nbsp; [BLOCK] $bl Blocked &nbsp; [FAIL] $fa Failed &nbsp; [???]  $nf Not Found</div>"
        $entryHtml += "</div>"
    }

    $entryHtml += "</div>"

    if (Test-Path $logFile) {
        $existing = Get-Content $logFile -Raw
        $existing = $existing -replace "(<div id='runs'>)", "`$1`n$entryHtml"
        $existing | Set-Content $logFile -Encoding UTF8
    }
    else {
        $page = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Group Mirror Log</title>
<style>
:root{--header:#1e2a3a;--subheader:#3c5578;--accent:#6496d2;--canvas:#f4f5f8;--card:#fff;--text:#1e2430;--muted:#6b7280;--radius:6px;}
*{box-sizing:border-box;margin:0;padding:0;}
body{font-family:'Segoe UI',Arial,sans-serif;background:var(--canvas);color:var(--text);}
header{background:var(--header);color:#fff;padding:20px 32px;border-bottom:4px solid var(--accent);}
header h1{font-size:1.3rem;font-weight:600;}
header p{font-size:.8rem;opacity:.7;margin-top:4px;}
#runs{padding:24px 32px;display:flex;flex-direction:column;gap:20px;}
.run{background:var(--card);border-radius:var(--radius);box-shadow:0 1px 4px rgba(0,0,0,.08);overflow:hidden;}
.run-header{background:var(--header);color:#fff;padding:10px 18px;display:flex;gap:24px;flex-wrap:wrap;font-size:.85rem;}
.run-time{font-weight:700;}
.run-by{opacity:.8;}
.run-users{background:var(--subheader);color:#fff;padding:10px 18px;display:flex;align-items:center;gap:12px;font-size:.9rem;border-bottom:2px solid var(--accent);}
.user-label{font-size:.72rem;text-transform:uppercase;opacity:.75;letter-spacing:.05em;}
.user-name{font-weight:700;font-size:.95rem;}
.user-arrow{font-size:1.2rem;opacity:.6;margin:0 4px;}
.section-title{background:var(--subheader);color:#fff;padding:7px 18px;font-weight:600;font-size:.88rem;}
.section-body{padding:12px 18px;display:flex;flex-direction:column;gap:10px;}
.status-group{padding:8px 12px;border-radius:4px;border-left:4px solid #ccc;}
.status-group.added   {border-color:#1a6e35;background:#f0faf3;}
.status-group.dynamic {border-color:#7a5000;background:#fdf8ee;}
.status-group.synced  {border-color:#1a4a7a;background:#eef4fc;}
.status-group.already {border-color:#444488;background:#f4f4fc;}
.status-group.failed  {border-color:#8b1a1a;background:#fdf0f0;}
.status-group.notfound{border-color:#885500;background:#fdf5ec;}
.status-group.licskip {border-color:#804080;background:#faf0fa;}
.status-group.blocked {border-color:#a02828;background:#fcefef;}
.status-header{font-weight:600;font-size:.85rem;margin-bottom:6px;}
.badge{background:rgba(0,0,0,.1);border-radius:10px;padding:1px 8px;font-size:.75rem;margin-left:6px;}
ul{list-style:none;padding-left:12px;}
li{padding:3px 0;font-size:.84rem;}
.gname{font-weight:500;}
.gdomain{color:var(--muted);font-size:.78rem;}
.gdetail{color:var(--muted);font-size:.78rem;padding-left:12px;margin-top:2px;}
.summary{font-size:.8rem;color:var(--muted);padding:8px 12px;border-top:1px solid #e6e8ee;margin-top:8px;}
footer{text-align:center;padding:16px;font-size:.75rem;color:var(--muted);}
</style>
</head>
<body>
<header>
  <h1>&#128203; Group Mirror Log</h1>
  <p>Persistent run history &mdash; newest entries at top</p>
</header>
<div id='runs'>
$entryHtml
</div>
<footer>Group Mirror Tool</footer>
</body>
</html>
"@
        $page | Set-Content $logFile -Encoding UTF8
    }
}

#endregion

#region --- PREVIEW / GATHER FOR CONFIRMATION ---

function Get-OnPremPreview {
    param([string]$SourceInput, [string]$TargetInput, [string[]]$Domains)

    $preview = @()
    $srcResult = Find-DomainUser -LookupValue $SourceInput -Domains $Domains
    if ($srcResult.Matches.Count -ne 1) { return $preview }
    $tgtResult = Find-DomainUser -LookupValue $TargetInput -Domains $Domains
    if ($tgtResult.Matches.Count -ne 1) { return $preview }

    $sourceUser     = $srcResult.Matches[0].User
    $targetGroupDNs = @($tgtResult.Matches[0].User.MemberOf)

    foreach ($groupDN in @($sourceUser.MemberOf)) {
        $groupDomain = "Unknown"
        try {
            $groupDomain = Get-DomainFromDN -DN $groupDN
            $group = Get-ADGroup -Server $groupDomain -Identity $groupDN -Properties Name -ErrorAction Stop
            $alreadyMember = $targetGroupDNs -contains $groupDN

            $note       = ""
            $mirrorable = $true
            if (Test-DoNotMirror -GroupName $group.Name) {
                $note = "Blocked - restricted group"; $mirrorable = $false
            }
            elseif ($alreadyMember) {
                $note = "Already a member"; $mirrorable = $false
            }

            $preview += [PSCustomObject]@{
                Section       = "OnPrem"
                Name          = $group.Name
                Domain        = $groupDomain
                AlreadyMember = $alreadyMember
                Note          = $note
                Mirrorable    = $mirrorable
            }
        }
        catch {
            # Never drop a group silently: show it in the Excluded column with the reason
            $preview += [PSCustomObject]@{
                Section       = "OnPrem"
                Name          = $groupDN
                Domain        = $groupDomain
                AlreadyMember = $false
                Note          = "Could not resolve group: $($_.Exception.Message)"
                Mirrorable    = $false
            }
        }
    }
    return $preview
}

function Get-CloudPreview {
    param(
        [string]$SourceUPN, [string]$TargetUPN, [string]$TenantId,
        [string]$ClientId, [string]$ClientSecret,
        [System.Windows.Forms.RichTextBox]$Log = $null
    )

    $preview = @()

    $LicensingExclusions = $Script:LicensingExclusionsRef

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try {
        $tokenBody = @{
            grant_type    = "client_credentials"
            scope         = "https://graph.microsoft.com/.default"
            client_id     = $ClientId
            client_secret = $ClientSecret
        }
        $tokenResp   = Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body $tokenBody -ErrorAction Stop
        $headers     = @{ Authorization = "Bearer $($tokenResp.access_token)"; "Content-Type" = "application/json" }
    }
    catch {
        if ($Log) { Add-LogLine $Log "[WARN]  Cloud preview - auth failed: $($_.Exception.Message)" "warn" }
        return $preview
    }

    try {
        $srcUser = Invoke-RestMethod -Headers $headers -Uri "https://graph.microsoft.com/v1.0/users/$([Uri]::EscapeDataString($SourceUPN))" -ErrorAction Stop
    }
    catch {
        if ($Log) { Add-LogLine $Log "[WARN]  Cloud preview - source user not found in Entra: $SourceUPN" "warn" }
        return $preview
    }
    try {
        $tgtUser = Invoke-RestMethod -Headers $headers -Uri "https://graph.microsoft.com/v1.0/users/$([Uri]::EscapeDataString($TargetUPN))" -ErrorAction Stop
    }
    catch {
        if ($Log) { Add-LogLine $Log "[WARN]  Cloud preview - target user not found in Entra: $TargetUPN" "warn" }
        return $preview
    }

    $srcGroups = @()
    $uri = "https://graph.microsoft.com/v1.0/users/$($srcUser.id)/memberOf?`$top=999"
    do {
        $resp      = Invoke-RestMethod -Headers $headers -Uri $uri -ErrorAction Stop
        $srcGroups += $resp.value | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.group' }
        $uri        = $resp.'@odata.nextLink'
    } while ($uri)

    $tgtGroupIds = @()
    $uri = "https://graph.microsoft.com/v1.0/users/$($tgtUser.id)/memberOf?`$top=999"
    do {
        $resp        = Invoke-RestMethod -Headers $headers -Uri $uri -ErrorAction Stop
        $tgtGroupIds += ($resp.value | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.group' } | Select-Object -ExpandProperty id)
        $uri          = $resp.'@odata.nextLink'
    } while ($uri)

    foreach ($group in $srcGroups) {
        $note       = ""
        $mirrorable = $true

        if (Test-DoNotMirror -GroupName $group.displayName) {
            $note = "Blocked - restricted group"; $mirrorable = $false
        }
        elseif ($LicensingExclusions -contains $group.displayName) {
            $note = "Licensing group - excluded"; $mirrorable = $false
        }
        elseif ($group.groupTypes -contains "DynamicMembership") {
            $note = "Dynamic - auto-assigned"; $mirrorable = $false
        }
        elseif ($group.onPremisesSyncEnabled -eq $true) {
            $note = "On-prem synced - handled on-prem"; $mirrorable = $false
        }
        elseif ($tgtGroupIds -contains $group.id) {
            $note = "Already a member"; $mirrorable = $false
        }

        $preview += [PSCustomObject]@{
            Section       = "Cloud"
            Name          = $group.displayName
            Domain        = "Entra ID"
            AlreadyMember = ($tgtGroupIds -contains $group.id)
            Note          = $note
            Mirrorable    = $mirrorable
        }
    }
    return $preview
}

function Show-ConfirmationWindow {
    param([array]$Preview)

    $cBg    = [System.Drawing.Color]::FromArgb(24, 26, 30)
    $cPanel = [System.Drawing.Color]::FromArgb(32, 36, 44)
    $cText  = [System.Drawing.Color]::FromArgb(220, 222, 228)
    $cHighlight = [System.Drawing.Color]::FromArgb(100, 150, 210)
    $cHeader  = [System.Drawing.Color]::FromArgb(60, 85, 120)
    $cMuted = [System.Drawing.Color]::FromArgb(130, 140, 155)

    $confForm              = New-Object System.Windows.Forms.Form
    $confForm.Text         = "Confirm Groups to Mirror"
    $confForm.Size         = New-Object System.Drawing.Size(1120, 720)
    $confForm.MinimumSize  = New-Object System.Drawing.Size(900, 520)
    $confForm.StartPosition= "CenterScreen"
    $confForm.BackColor    = $cBg
    $confForm.ForeColor    = $cText
    $confForm.Font         = New-Object System.Drawing.Font("Segoe UI", 9)

    $lblHdr          = New-Object System.Windows.Forms.Label
    $lblHdr.Text     = "Checked items in On-Prem and Cloud will be mirrored. The Excluded column is read-only and shows what is being skipped and why."
    $lblHdr.Location = New-Object System.Drawing.Point(14, 12)
    $lblHdr.Size     = New-Object System.Drawing.Size(1080, 36)
    $lblHdr.ForeColor= $cHighlight
    $lblHdr.Anchor   = "Top,Left,Right"
    $confForm.Controls.Add($lblHdr)

    # ---- top buttons ----
    $btnAll          = New-Object System.Windows.Forms.Button
    $btnAll.Text     = "Select All"
    $btnAll.Location = New-Object System.Drawing.Point(14, 50)
    $btnAll.Size     = New-Object System.Drawing.Size(95, 28)
    $btnAll.BackColor= [System.Drawing.Color]::FromArgb(40, 46, 56)
    $btnAll.ForeColor= $cText
    $btnAll.FlatStyle= "Flat"
    $confForm.Controls.Add($btnAll)

    $btnNone          = New-Object System.Windows.Forms.Button
    $btnNone.Text     = "Deselect All"
    $btnNone.Location = New-Object System.Drawing.Point(115, 50)
    $btnNone.Size     = New-Object System.Drawing.Size(95, 28)
    $btnNone.BackColor= [System.Drawing.Color]::FromArgb(40, 46, 56)
    $btnNone.ForeColor= $cText
    $btnNone.FlatStyle= "Flat"
    $confForm.Controls.Add($btnNone)

    $btnReset          = New-Object System.Windows.Forms.Button
    $btnReset.Text     = "Reset"
    $btnReset.Location = New-Object System.Drawing.Point(216, 50)
    $btnReset.Size     = New-Object System.Drawing.Size(95, 28)
    $btnReset.BackColor= [System.Drawing.Color]::FromArgb(40, 46, 56)
    $btnReset.ForeColor= $cText
    $btnReset.FlatStyle= "Flat"
    $confForm.Controls.Add($btnReset)

    # ---- column geometry ----
    $colTop    = 110
    $colHeight = 500
    $colWidth  = 350
    $gap       = 12
    $x1 = 14
    $x2 = $x1 + $colWidth + $gap
    $x3 = $x2 + $colWidth + $gap

    # Column header labels
    function New-ColHeader {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'GUI helper. The confirmation window is this tool''s ShouldProcess.')]
        param($text, $x, $color)
        $l = New-Object System.Windows.Forms.Label
        $l.Text      = $text
        $l.Location  = New-Object System.Drawing.Point($x, ($colTop - 24))
        $l.Size      = New-Object System.Drawing.Size($colWidth, 20)
        $l.ForeColor = [System.Drawing.Color]::White
        $l.BackColor = $color
        $l.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
        $l.Font      = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
        return $l
    }

    # Split preview into the three buckets
    $onPremMirror = @($Preview | Where-Object { $_.Section -eq "OnPrem" -and $_.Mirrorable })
    $cloudMirror  = @($Preview | Where-Object { $_.Section -eq "Cloud"  -and $_.Mirrorable })
    $excluded     = @($Preview | Where-Object { -not $_.Mirrorable })

    $hdrOnPrem = New-ColHeader "ON-PREM  ($($onPremMirror.Count))" $x1 $cHeader
    $hdrCloud  = New-ColHeader "CLOUD  ($($cloudMirror.Count))"   $x2 $cHeader
    $hdrExcl   = New-ColHeader "EXCLUDED  ($($excluded.Count))"   $x3 ([System.Drawing.Color]::FromArgb(90, 70, 70))
    $confForm.Controls.Add($hdrOnPrem)
    $confForm.Controls.Add($hdrCloud)
    $confForm.Controls.Add($hdrExcl)

    # ---- On-Prem checked list ----
    $clbOnPrem              = New-Object System.Windows.Forms.CheckedListBox
    $clbOnPrem.Location     = New-Object System.Drawing.Point($x1, $colTop)
    $clbOnPrem.Size         = New-Object System.Drawing.Size($colWidth, $colHeight)
    $clbOnPrem.BackColor    = $cPanel
    $clbOnPrem.ForeColor    = $cText
    $clbOnPrem.BorderStyle  = "FixedSingle"
    $clbOnPrem.CheckOnClick = $true
    $clbOnPrem.Font         = New-Object System.Drawing.Font("Consolas", 9)
    $clbOnPrem.Anchor       = "Top,Bottom,Left"
    foreach ($row in $onPremMirror) { [void]$clbOnPrem.Items.Add($row.Name, $true) }
    $confForm.Controls.Add($clbOnPrem)

    # ---- Cloud checked list ----
    $clbCloud              = New-Object System.Windows.Forms.CheckedListBox
    $clbCloud.Location     = New-Object System.Drawing.Point($x2, $colTop)
    $clbCloud.Size         = New-Object System.Drawing.Size($colWidth, $colHeight)
    $clbCloud.BackColor    = $cPanel
    $clbCloud.ForeColor    = $cText
    $clbCloud.BorderStyle  = "FixedSingle"
    $clbCloud.CheckOnClick = $true
    $clbCloud.Font         = New-Object System.Drawing.Font("Consolas", 9)
    $clbCloud.Anchor       = "Top,Bottom,Left"
    foreach ($row in $cloudMirror) { [void]$clbCloud.Items.Add($row.Name, $true) }
    $confForm.Controls.Add($clbCloud)

    # ---- Excluded read-only list ----
    $lstExcl              = New-Object System.Windows.Forms.ListBox
    $lstExcl.Location     = New-Object System.Drawing.Point($x3, $colTop)
    $lstExcl.Size         = New-Object System.Drawing.Size($colWidth, $colHeight)
    $lstExcl.BackColor    = [System.Drawing.Color]::FromArgb(40, 34, 34)
    $lstExcl.ForeColor    = $cMuted
    $lstExcl.BorderStyle  = "FixedSingle"
    $lstExcl.Font         = New-Object System.Drawing.Font("Consolas", 8.5)
    $lstExcl.Anchor       = "Top,Bottom,Left"
    $lstExcl.DrawMode     = [System.Windows.Forms.DrawMode]::OwnerDrawFixed
    $lstExcl.ItemHeight   = 32
    foreach ($row in $excluded) {
        [void]$lstExcl.Items.Add("$($row.Name)|$($row.Section)|$($row.Note)")
    }
    # Owner-draw the excluded items as two lines: name + reason
    $lstExcl.Add_DrawItem({
        $e = $_   # DrawItemEventArgs; the sender is not needed
        if ($e.Index -lt 0) { return }
        $e.DrawBackground()
        $parts   = $lstExcl.Items[$e.Index].ToString().Split("|")
        $name    = $parts[0]
        $section = $parts[1]
        $note    = $parts[2]

        $nameColor = if ($note -match "Blocked") {
            [System.Drawing.Color]::FromArgb(210, 110, 110)
        } else {
            [System.Drawing.Color]::FromArgb(180, 182, 188)
        }
        $nb = New-Object System.Drawing.SolidBrush $nameColor
        $f1 = New-Object System.Drawing.Font("Consolas", 8.5, [System.Drawing.FontStyle]::Bold)
        $e.Graphics.DrawString("$name  [$section]", $f1, $nb, $e.Bounds.Left + 3, $e.Bounds.Top + 2)
        $nb.Dispose(); $f1.Dispose()

        $rb = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(140, 145, 155))
        $f2 = New-Object System.Drawing.Font("Consolas", 8)
        $e.Graphics.DrawString($note, $f2, $rb, $e.Bounds.Left + 8, $e.Bounds.Top + 16)
        $rb.Dispose(); $f2.Dispose()
    })
    $confForm.Controls.Add($lstExcl)

    $Script:ConfResult = "Cancel"

    # ---- bottom buttons ----
    $btnConfirm          = New-Object System.Windows.Forms.Button
    $btnConfirm.Location = New-Object System.Drawing.Point(14, 630)
    $btnConfirm.Size     = New-Object System.Drawing.Size(260, 40)
    $btnConfirm.BackColor= [System.Drawing.Color]::FromArgb(30, 50, 80)
    $btnConfirm.ForeColor= [System.Drawing.Color]::White
    $btnConfirm.FlatStyle= "Flat"
    $btnConfirm.Anchor   = "Bottom,Left"
    $confForm.Controls.Add($btnConfirm)

    $btnCancel          = New-Object System.Windows.Forms.Button
    $btnCancel.Text     = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(284, 630)
    $btnCancel.Size     = New-Object System.Drawing.Size(120, 40)
    $btnCancel.BackColor= [System.Drawing.Color]::FromArgb(60, 60, 60)
    $btnCancel.ForeColor= [System.Drawing.Color]::White
    $btnCancel.FlatStyle= "Flat"
    $btnCancel.Anchor   = "Bottom,Left"
    $confForm.Controls.Add($btnCancel)

    # ---- live count (no BeginInvoke - direct call) ----
    $updateCount = {
        $n = 0
        for ($i = 0; $i -lt $clbOnPrem.Items.Count; $i++) { if ($clbOnPrem.GetItemChecked($i)) { $n++ } }
        for ($i = 0; $i -lt $clbCloud.Items.Count;  $i++) { if ($clbCloud.GetItemChecked($i))  { $n++ } }
        $btnConfirm.Text = "Confirm and Mirror ($n selected)"
    }

    $btnAll.Add_Click({
        for ($i = 0; $i -lt $clbOnPrem.Items.Count; $i++) { $clbOnPrem.SetItemChecked($i, $true) }
        for ($i = 0; $i -lt $clbCloud.Items.Count;  $i++) { $clbCloud.SetItemChecked($i, $true) }
        & $updateCount
    })
    $btnNone.Add_Click({
        for ($i = 0; $i -lt $clbOnPrem.Items.Count; $i++) { $clbOnPrem.SetItemChecked($i, $false) }
        for ($i = 0; $i -lt $clbCloud.Items.Count;  $i++) { $clbCloud.SetItemChecked($i, $false) }
        & $updateCount
    })
    $btnReset.Add_Click({
        for ($i = 0; $i -lt $clbOnPrem.Items.Count; $i++) { $clbOnPrem.SetItemChecked($i, $true) }
        for ($i = 0; $i -lt $clbCloud.Items.Count;  $i++) { $clbCloud.SetItemChecked($i, $true) }
        & $updateCount
    })

    # ItemCheck fires before the value changes, so recount after the click instead
    $clbOnPrem.Add_SelectedIndexChanged({ & $updateCount })
    $clbCloud.Add_SelectedIndexChanged({  & $updateCount })
    $clbOnPrem.Add_MouseUp({ & $updateCount })
    $clbCloud.Add_MouseUp({  & $updateCount })

    $btnConfirm.Add_Click({ $Script:ConfResult = "Confirm"; $confForm.Close() })
    $btnCancel.Add_Click({  $Script:ConfResult = "Cancel";  $confForm.Close() })

    & $updateCount
    [void]$confForm.ShowDialog()

    if ($Script:ConfResult -ne "Confirm") {
        return $null
    }

    $approvedOnPrem = @()
    $approvedCloud  = @()
    for ($i = 0; $i -lt $clbOnPrem.Items.Count; $i++) {
        if ($clbOnPrem.GetItemChecked($i)) { $approvedOnPrem += $clbOnPrem.Items[$i].ToString() }
    }
    for ($i = 0; $i -lt $clbCloud.Items.Count; $i++) {
        if ($clbCloud.GetItemChecked($i)) { $approvedCloud += $clbCloud.Items[$i].ToString() }
    }

    return [PSCustomObject]@{
        OnPrem = $approvedOnPrem
        Cloud  = $approvedCloud
    }
}

#endregion

#region --- GUI ---


$clrBg     = [System.Drawing.Color]::FromArgb(24, 26, 30)
$clrPanel  = [System.Drawing.Color]::FromArgb(32, 36, 44)
$clrAccent = [System.Drawing.Color]::FromArgb(30, 50, 80)
$clrHighlight  = [System.Drawing.Color]::FromArgb(100, 150, 210)
$clrText   = [System.Drawing.Color]::FromArgb(220, 222, 228)
$clrMuted  = [System.Drawing.Color]::FromArgb(130, 140, 155)
$clrInput  = [System.Drawing.Color]::FromArgb(40, 46, 56)
$clrBorder = [System.Drawing.Color]::FromArgb(60, 75, 100)
$fontMain  = New-Object System.Drawing.Font("Segoe UI", 9)
$fontBold  = New-Object System.Drawing.Font("Segoe UI", 9,  [System.Drawing.FontStyle]::Bold)
$fontMono  = New-Object System.Drawing.Font("Consolas", 9)
$fontTitle = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)

$form                 = New-Object System.Windows.Forms.Form
$form.Text            = "Group Mirror"
$form.Size            = New-Object System.Drawing.Size(720, 720)
$form.MinimumSize     = New-Object System.Drawing.Size(720, 640)
$form.BackColor       = $clrBg
$form.ForeColor       = $clrText
$form.Font            = $fontMain
$form.StartPosition   = "CenterScreen"

$lblTitle             = New-Object System.Windows.Forms.Label
$lblTitle.Text        = "  Group Mirror"
$lblTitle.Font        = $fontTitle
$lblTitle.ForeColor   = $clrHighlight
$lblTitle.Location    = New-Object System.Drawing.Point(16, 14)
$lblTitle.Size        = New-Object System.Drawing.Size(400, 30)
$form.Controls.Add($lblTitle)

$lblSub               = New-Object System.Windows.Forms.Label
$lblSub.Text          = "  Copy group memberships between users"
$lblSub.Font          = $fontMain
$lblSub.ForeColor     = $clrMuted
$lblSub.Location      = New-Object System.Drawing.Point(18, 44)
$lblSub.Size          = New-Object System.Drawing.Size(500, 18)
$form.Controls.Add($lblSub)

$panelInput           = New-Object System.Windows.Forms.Panel
$panelInput.Location  = New-Object System.Drawing.Point(12, 70)
$panelInput.Size      = New-Object System.Drawing.Size(688, 120)
$panelInput.BackColor = $clrPanel
$form.Controls.Add($panelInput)

function New-Label {

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'GUI helper. The confirmation window is this tool''s ShouldProcess.')]

    param($text,$x,$y,$w=300,$h=18,$bold=$false)
    $l            = New-Object System.Windows.Forms.Label
    $l.Text       = $text
    $l.Location   = New-Object System.Drawing.Point($x,$y)
    $l.Size       = New-Object System.Drawing.Size($w,$h)
    $l.ForeColor  = $clrText
    $l.Font       = if ($bold) { $fontBold } else { $fontMain }
    return $l
}

function New-TextBox {

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'GUI helper. The confirmation window is this tool''s ShouldProcess.')]

    param($x,$y,$w=300)
    $t              = New-Object System.Windows.Forms.TextBox
    $t.Location     = New-Object System.Drawing.Point($x,$y)
    $t.Size         = New-Object System.Drawing.Size($w,24)
    $t.BackColor    = $clrInput
    $t.ForeColor    = $clrText
    $t.BorderStyle  = "FixedSingle"
    $t.Font         = $fontMono
    return $t
}

$lblSrc = New-Label "Source User  (user you're copying FROM)" 14 12 450 18 $true
$panelInput.Controls.Add($lblSrc)

$txtSource                    = New-TextBox 14 34 420

$panelInput.Controls.Add($txtSource)

$lblTgt = New-Label "Target User  (user you're copying TO)" 14 66 450 18 $true
$panelInput.Controls.Add($lblTgt)

$txtTarget                    = New-TextBox 14 88 420

$panelInput.Controls.Add($txtTarget)

# Cloud toggle - placed on the FORM (not the input panel) so it never clips.
# Sits below the input panel, left-aligned with the fields.
$chkCloud                     = New-Object System.Windows.Forms.CheckBox
$chkCloud.Text                = "Also copy Cloud (Entra ID) groups"
$chkCloud.Location            = New-Object System.Drawing.Point(16, 196)
$chkCloud.AutoSize            = $true
$chkCloud.ForeColor           = $clrText
$chkCloud.BackColor           = $clrBg
$chkCloud.Font                = $fontMain
$chkCloud.Checked             = $true
$form.Controls.Add($chkCloud)

# Hint: cloud needs full UPN
$lblCloudHint                 = New-Object System.Windows.Forms.Label
$lblCloudHint.Text            = "For cloud, enter the full UPN for both users (name@domain)"
$lblCloudHint.Location        = New-Object System.Drawing.Point(34, 218)
$lblCloudHint.AutoSize        = $true
$lblCloudHint.ForeColor       = $clrMuted
$lblCloudHint.BackColor       = $clrBg
$lblCloudHint.Font            = New-Object System.Drawing.Font("Segoe UI", 8)
$form.Controls.Add($lblCloudHint)

$btnRun                       = New-Object System.Windows.Forms.Button
$btnRun.Text                  = ">  Run Mirror"
$btnRun.Location              = New-Object System.Drawing.Point(12, 250)
$btnRun.Size                  = New-Object System.Drawing.Size(150, 36)
$btnRun.BackColor             = $clrAccent
$btnRun.ForeColor             = [System.Drawing.Color]::White
$btnRun.FlatStyle             = "Flat"
$btnRun.Font                  = $fontBold
$btnRun.FlatAppearance.BorderColor = $clrHighlight
$form.Controls.Add($btnRun)

$btnCopy                      = New-Object System.Windows.Forms.Button
$btnCopy.Text                 = "[COPY]  Copy to Clipboard"
$btnCopy.Location             = New-Object System.Drawing.Point(172, 250)
$btnCopy.Size                 = New-Object System.Drawing.Size(170, 36)
$btnCopy.BackColor            = $clrPanel
$btnCopy.ForeColor            = $clrHighlight
$btnCopy.FlatStyle            = "Flat"
$btnCopy.Font                 = $fontBold
$btnCopy.Visible              = $false
$btnCopy.FlatAppearance.BorderColor = $clrBorder
$form.Controls.Add($btnCopy)

$btnLog                       = New-Object System.Windows.Forms.Button
$btnLog.Text                  = "[LOG]  Open Log"
$btnLog.Location              = New-Object System.Drawing.Point(352, 250)
$btnLog.Size                  = New-Object System.Drawing.Size(130, 36)
$btnLog.BackColor             = $clrPanel
$btnLog.ForeColor             = $clrMuted
$btnLog.FlatStyle             = "Flat"
$btnLog.Font                  = $fontMain
$btnLog.FlatAppearance.BorderColor = $clrBorder
$form.Controls.Add($btnLog)

$progress                     = New-Object System.Windows.Forms.ProgressBar
$progress.Location            = New-Object System.Drawing.Point(12, 296)
$progress.Size                = New-Object System.Drawing.Size(688, 10)
$progress.Style               = "Continuous"
$progress.ForeColor           = $clrHighlight
$progress.Visible             = $false
$form.Controls.Add($progress)

$rtb                          = New-Object System.Windows.Forms.RichTextBox
$rtb.Location                 = New-Object System.Drawing.Point(12, 314)
$rtb.Size                     = New-Object System.Drawing.Size(688, 340)
$rtb.BackColor                = $clrPanel
$rtb.ForeColor                = $clrText
$rtb.Font                     = $fontMono
$rtb.ReadOnly                 = $true
$rtb.BorderStyle              = "None"
$rtb.ScrollBars               = "Vertical"
$form.Controls.Add($rtb)

$form.Add_Resize({
    $w            = $form.ClientSize.Width - 24
    $panelInput.Width = $w
    $progress.Width   = $w
    $rtb.Width        = $w
    $rtb.Height       = $form.ClientSize.Height - $rtb.Top - 8
})

$Script:LastResults = @()
$Script:LastSource  = ""
$Script:LastTarget  = ""
$Script:LastRunTime = ""

$btnRun.Add_Click({

    $sourceIn = $txtSource.Text.Trim()
    $targetIn = $txtTarget.Text.Trim()

    if (-not $sourceIn -or -not $targetIn) {
        [System.Windows.Forms.MessageBox]::Show("Both Source and Target fields are required.", "Validation", "OK", "Warning")
        return
    }
    if ($sourceIn -eq $targetIn) {
        [System.Windows.Forms.MessageBox]::Show("Source and Target cannot be the same account.", "Validation", "OK", "Warning")
        return
    }
    if ($chkCloud.Checked) {
        $unset = @("", "YOUR-TENANT-ID-HERE", "YOUR-CLIENT-ID-HERE", "00000000-0000-0000-0000-000000000000")
        if ($unset -contains [string]$Config.TenantId -or $unset -contains [string]$Config.ClientId) {
            [System.Windows.Forms.MessageBox]::Show(
                "Cloud copy is enabled but TenantId or ClientId is not configured in config.json.",
                "Config Error", "OK", "Error")
            return
        }
        # Cloud lookups require a full UPN with @domain - do not guess it
        if ($sourceIn -notmatch "@" -or $targetIn -notmatch "@") {
            [System.Windows.Forms.MessageBox]::Show(
                "Cloud copy is enabled.`n`nFor cloud groups, enter the full email / UPN including @domain for BOTH users (name@domain).`n`nEither uncheck 'Also copy Cloud' to run on-prem only, or add the @domain and try again.",
                "Full UPN Required for Cloud", "OK", "Warning")
            return
        }
    }

    $rtb.Clear()
    $btnCopy.Visible  = $false
    $btnCopy.Text     = "[COPY]  Copy to Clipboard"
    $btnCopy.ForeColor= $clrHighlight
    $progress.Visible = $true
    $progress.Value   = 0
    $btnRun.Enabled   = $false
    $Script:LastResults = @()

    $RunTime            = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $Script:LastSource  = $sourceIn
    $Script:LastTarget  = $targetIn
    $Script:LastRunTime = $RunTime

    Add-LogLine $rtb "Gathering groups for review..." "info"
    [System.Windows.Forms.Application]::DoEvents()

    # Cloud lookups use the UPN exactly as typed (validated above to contain @)
    $sourceCloudUPN = Get-CloudUPN -InputValue $sourceIn
    $targetCloudUPN = Get-CloudUPN -InputValue $targetIn

    # ---- PHASE 1: GATHER PREVIEW (no writes) ----
    $preview = @()
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        $preview += Get-OnPremPreview -SourceInput $sourceIn -TargetInput $targetIn -Domains $Config.SearchDomains
    }
    catch {
        Add-LogLine $rtb "[WARN]  On-prem preview failed: $($_.Exception.Message)" "warn"
    }

    if ($chkCloud.Checked) {
        try {
            $preview += Get-CloudPreview -SourceUPN $sourceCloudUPN -TargetUPN $targetCloudUPN `
                            -TenantId $Config.TenantId -ClientId $Config.ClientId -ClientSecret $RuntimeSecret -Log $rtb
        }
        catch {
            Add-LogLine $rtb "[WARN]  Cloud preview failed: $($_.Exception.Message)" "warn"
        }
    }

    if ($preview.Count -eq 0) {
        Add-LogLine $rtb "[FAIL]  No groups found to mirror. Check the source/target users." "fail"
        $progress.Visible = $false
        $btnRun.Enabled   = $true
        return
    }

    # ---- PHASE 2: CONFIRMATION WINDOW ----
    $approved = Show-ConfirmationWindow -Preview $preview
    if ($null -eq $approved) {
        Add-LogLine $rtb "Mirror cancelled by operator." "warn"
        $progress.Visible = $false
        $btnRun.Enabled   = $true
        return
    }

    Add-LogLine $rtb "Group Mirror started - $RunTime" "info"
    Add-LogLine $rtb "Source (copying FROM): $sourceIn" "info"
    Add-LogLine $rtb "Target (copying TO):   $targetIn" "info"

    $allResults = @()

    # ---- PHASE 3: EXECUTE (only approved groups) ----
    Add-LogLine $rtb "`n-- On-Prem Copy ---------------------------" "info"
    $progress.Value = 10
    try {
        $onPremResults  = Invoke-OnPremCopy -SourceInput $sourceIn -TargetInput $targetIn `
                            -Domains $Config.SearchDomains -Log $rtb -ApprovedNames $approved.OnPrem
        $allResults    += $onPremResults
        $progress.Value = 50
    }
    catch {
        Add-LogLine $rtb "[FAIL]  On-prem copy error: $($_.Exception.Message)" "fail"
        $progress.Value = 50
    }

    if ($chkCloud.Checked) {
        Add-LogLine $rtb "`n-- Cloud Copy (Entra ID) -------------------" "info"
        $progress.Value = 55
        try {
            $cloudResults   = Invoke-CloudCopy -SourceUPN $sourceCloudUPN -TargetUPN $targetCloudUPN `
                                -TenantId $Config.TenantId -ClientId $Config.ClientId `
                                -ClientSecret $RuntimeSecret -Log $rtb -ApprovedNames $approved.Cloud
            $allResults    += $cloudResults
            $progress.Value = 90
        }
        catch {
            Add-LogLine $rtb "[FAIL]  Cloud copy error: $($_.Exception.Message)" "fail"
            $progress.Value = 90
        }
    }

    Show-Result -Results $allResults -RTB $rtb

    try {
        Update-HtmlLog -Results $allResults -SourceInput $sourceIn -TargetInput $targetIn `
            -RunTime $RunTime -RunBy $env:USERNAME
    }
    catch {
        Add-LogLine $rtb "[WARN]  HTML log update failed: $($_.Exception.Message)" "warn"
    }

    $progress.Value     = 100
    $Script:LastResults = $allResults
    $btnCopy.Visible    = $true
    $btnRun.Enabled     = $true

    [System.Windows.Forms.Application]::DoEvents()
})

$btnCopy.Add_Click({
  try {
    # Reset the label from any previous "Copied!" state
    $btnCopy.Text      = "[COPY]  Copy to Clipboard"
    $btnCopy.ForeColor = $clrHighlight

    $text = Format-ClipboardText -Results $Script:LastResults `
                -SourceInput $Script:LastSource `
                -TargetInput $Script:LastTarget `
                -RunTime     $Script:LastRunTime
    try {
        if ([string]::IsNullOrEmpty($text)) {
            [System.Windows.Forms.MessageBox]::Show("Nothing to copy yet.", "Copy", "OK", "Information")
            return
        }
        # Clipboard can be locked by RDP/other apps - retry a few times then
        # give up quietly instead of throwing a cascade of error dialogs
        $copied = $false
        for ($i = 0; $i -lt 3 -and -not $copied; $i++) {
            try {
                [System.Windows.Forms.Clipboard]::SetText($text)
                $copied = $true
            }
            catch {
                Start-Sleep -Milliseconds 150
            }
        }
        if (-not $copied) {
            [System.Windows.Forms.MessageBox]::Show(
                "Could not access the clipboard (it may be locked by another program). Try again, or copy from the results panel manually.",
                "Clipboard Busy", "OK", "Warning")
            return
        }
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Copy failed: $($_.Exception.Message)", "Copy", "OK", "Warning")
        return
    }

    # No timer here on purpose. A WinForms timer's Tick scriptblock cannot
    # reliably resolve these variables in a PS2EXE-compiled binary, and a
    # throwing Tick that never reaches Stop() repeats forever, producing a
    # cascade of error dialogs. The label resets on the next click or run.
    $btnCopy.Text      = "[OK]    Copied!"
    $btnCopy.ForeColor = [System.Drawing.Color]::FromArgb(20, 160, 80)
  }
  catch {
    # Never let an unhandled error escape a click handler in a compiled EXE
    [System.Windows.Forms.MessageBox]::Show(
        "Copy failed: $($_.Exception.Message)", "Copy", "OK", "Warning")
  }
})

$btnLog.Add_Click({
    $logFile = Join-Path $Config.LogPath $Config.LogFile
    if (Test-Path $logFile) {
        Start-Process $logFile
    }
    else {
        [System.Windows.Forms.MessageBox]::Show(
            "No log file found yet. Run a mirror first.",
            "Log", "OK", "Information")
    }
})

[void]$form.ShowDialog()

#endregion

