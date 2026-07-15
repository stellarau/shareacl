#Requires -Version 7.0
#Requires -Modules ActiveDirectory, PSSQLite

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Database,
    [int] $ScanId,
    [int] $MaxNestingDepth = 16,
    [switch] $EmitProgress
)

$ErrorActionPreference = 'Stop'

function Write-ResolverProgress {
    param(
        [Parameter(Mandatory)] [string] $Phase,
        [Parameter(Mandatory)] [int] $Current,
        [Parameter(Mandatory)] [int] $Total,
        [Parameter(Mandatory)] [string] $Activity
    )

    if (-not $EmitProgress) { return }

    # A compact, line-oriented protocol lets the GUI distinguish real resolver
    # progress from ordinary console output. Keep the activity on one line and
    # reserve pipe characters for field separators.
    $safeActivity = ($Activity -replace '[\r\n]+', ' ' -replace '\|', '/')
    $progressLine = 'SHAREACL_RESOLVER_PROGRESS|{0}|{1}|{2}|{3}' -f @(
        $Phase, $Current, $Total, $safeActivity)
    [Console]::Out.WriteLine($progressLine)
    [Console]::Out.Flush()
}

Write-ResolverProgress -Phase 'Starting' -Current 0 -Total 0 `
    -Activity 'Loading unresolved SIDs from the database…'

# Pull SIDs that need classification
$sidFilter = if ($ScanId) {
    "WHERE a.trustee_sid IN (SELECT DISTINCT trustee_sid FROM aces a JOIN folders f ON a.folder_id=f.folder_id WHERE f.scan_id=$ScanId)"
} else { '' }

$sids = @(Invoke-SqliteQuery -DataSource $Database -Query @"
    SELECT DISTINCT a.trustee_sid AS sid
    FROM aces a
    LEFT JOIN principals p ON p.sid = a.trustee_sid
    $sidFilter
    AND p.sid IS NULL
"@ | ForEach-Object { $_.sid } | Where-Object { $_ })

function Get-PrimaryGroupMembers {
    <#
        For domain-local groups whose membership is held in the primaryGroupID
        attribute on users/computers (RIDs 513-517), Get-ADGroupMember can
        silently under-report. This adds an LDAP-filter fallback.
    #>
    param([string]$GroupSid)

    $rid = ($GroupSid -split '-')[-1]
    if ($rid -notin '513','514','515','516','517') { return @() }

    try {
        Get-ADObject -LDAPFilter "(primaryGroupID=$rid)" `
                     -Properties SamAccountName, objectClass, objectSID, Name `
                     -ErrorAction Stop |
            ForEach-Object {
                # Match the shape Get-ADGroupMember returns
                [pscustomobject]@{
                    Name           = $_.Name
                    SamAccountName = $_.SamAccountName
                    objectClass    = $_.objectClass
                    SID            = $_.objectSID
                }
            }
    } catch {
        @()
    }
}

function Resolve-Sid {
    param([string]$Sid)
    $now = [DateTime]::UtcNow.ToString('o')

    # Well-known check
    try {
        $sidObj = [System.Security.Principal.SecurityIdentifier]::new($Sid)
        if ($sidObj.IsWellKnown([System.Security.Principal.WellKnownSidType]::WorldSid) -or
            $Sid -match '^S-1-5-(18|19|20|32-\d+)$' -or $Sid -match '^S-1-1-0$|^S-1-5-11$') {
            $nt = $sidObj.Translate([System.Security.Principal.NTAccount]).Value
            return @{ name=$nt; domain='BUILTIN'; type='WellKnown'; wk=1; now=$now }
        }
    } catch { }

    # Try AD
    try {
        $obj = Get-ADObject -Filter { ObjectSID -eq $Sid } -Properties sAMAccountName, objectClass -ErrorAction Stop
        if ($obj) {
            $type = switch ($obj.objectClass) {
                'user'     { 'User' }
                'group'    { 'Group' }
                'computer' { 'Computer' }
                'foreignSecurityPrincipal' { 'ForeignSecurityPrincipal' }
                default    { 'Unknown' }
            }
            return @{ name=$obj.Name; domain=$env:USERDOMAIN; sam=$obj.sAMAccountName; type=$type; wk=0; now=$now }
        }
    } catch { }

    # Last attempt: LSA translate
    try {
        $nt = ([System.Security.Principal.SecurityIdentifier]::new($Sid)).Translate([System.Security.Principal.NTAccount]).Value
        return @{ name=$nt; type='Unknown'; wk=0; now=$now }
    } catch {
        return @{ name=$null; type='Orphaned'; wk=0; now=$now }
    }
}

# Insert/update principals
$principalIndex = 0
Write-ResolverProgress -Phase 'Principals' -Current 0 -Total $sids.Count `
    -Activity ("Found {0:N0} unresolved SID(s)." -f $sids.Count)
foreach ($sid in $sids) {
    $principalIndex++
    Write-ResolverProgress -Phase 'Principals' -Current $principalIndex -Total $sids.Count `
        -Activity ("Resolving principal {0:N0} of {1:N0}: {2}" -f $principalIndex, $sids.Count, $sid)

    $r = Resolve-Sid -Sid $sid
    Invoke-SqliteQuery -DataSource $Database -Query @"
        INSERT INTO principals(sid,name,domain,sam_account_name,principal_type,is_well_known,last_resolved_utc)
        VALUES (@sid,@n,@d,@sam,@t,@wk,@now)
        ON CONFLICT(sid) DO UPDATE SET
            name=excluded.name, domain=excluded.domain, sam_account_name=excluded.sam_account_name,
            principal_type=excluded.principal_type, is_well_known=excluded.is_well_known,
            last_resolved_utc=excluded.last_resolved_utc
"@ -SqlParameters @{
        sid=$sid; n=$r.name; d=$r.domain; sam=$r.sam; t=$r.type; wk=$r.wk; now=$r.now
    } | Out-Null
}

Write-ResolverProgress -Phase 'Groups' -Current 0 -Total 0 `
    -Activity 'Loading groups for membership expansion…'

# Transitive group expansion with cycle detection
$groups = @(Invoke-SqliteQuery -DataSource $Database `
    -Query "SELECT sid FROM principals WHERE principal_type='Group'" |
    ForEach-Object { $_.sid } | Where-Object { $_ })

$groupIndex = 0
Write-ResolverProgress -Phase 'Groups' -Current 0 -Total $groups.Count `
    -Activity ("Found {0:N0} group(s) to expand." -f $groups.Count)
foreach ($g in $groups) {
    $groupIndex++
    $visited = [System.Collections.Generic.HashSet[string]]::new()
    $queue   = [System.Collections.Generic.Queue[object]]::new()
    $queue.Enqueue(@{ sid=$g; depth=0 })

    Write-ResolverProgress -Phase 'Groups' -Current $groupIndex -Total $groups.Count `
        -Activity ("Expanding group {0:N0} of {1:N0}: {2}" -f $groupIndex, $groups.Count, $g)

    while ($queue.Count -gt 0) {
        $cur = $queue.Dequeue()
        if (-not $visited.Add($cur.sid)) { continue }   # cycle guard
        if ($cur.depth -ge $MaxNestingDepth) { continue }

        Write-ResolverProgress -Phase 'Groups' -Current $groupIndex -Total $groups.Count `
            -Activity ("Querying AD for {0} at nesting depth {1:N0}…" -f $cur.sid, $cur.depth)
        
        $members = @()
            try {
                $members += Get-ADGroupMember -Identity $cur.sid -ErrorAction Stop
            } catch { }
            $members += Get-PrimaryGroupMembers -GroupSid $cur.sid

            # De-duplicate by SID in case both calls return the same account
            $members = $members | Group-Object { $_.SID.Value } | ForEach-Object { $_.Group[0] }

        $memberIndex = 0
        Write-ResolverProgress -Phase 'Groups' -Current $groupIndex -Total $groups.Count `
            -Activity ("Recording {0:N0} member(s) returned for {1}." -f @($members).Count, $cur.sid)
        foreach ($m in $members) {
            $memberIndex++
            $memberSid = $m.SID.Value
            $depth     = $cur.depth + 1

            $memberType = switch ($m.objectClass) {
                'user'                    { 'User' }
                'group'                   { 'Group' }
                'computer'                { 'Computer' }
                'foreignSecurityPrincipal'{ 'ForeignSecurityPrincipal' }
                default                   { 'Unknown' }
            }

            # Make sure this member is searchable in the principal picker.
            # ON CONFLICT DO NOTHING preserves whatever the earlier classification pass found.
            Invoke-SqliteQuery -DataSource $Database -Query @"
                INSERT INTO principals(sid, name, domain, sam_account_name,
                                    principal_type, is_well_known, last_resolved_utc)
                VALUES (@sid, @name, @domain, @sam, @type, 0, @now)
                ON CONFLICT(sid) DO NOTHING
"@ -SqlParameters @{
                sid    = $memberSid
                name   = $m.Name
                domain = $env:USERDOMAIN
                sam    = $m.SamAccountName
                type   = $memberType
                now    = [System.DateTime]::UtcNow.ToString('o')
            } | Out-Null

            Invoke-SqliteQuery -DataSource $Database -Query @"
                INSERT OR IGNORE INTO group_members(group_sid, member_sid, depth)
                VALUES (@g, @m, @d)
"@ -SqlParameters @{ g = $g; m = $memberSid; d = $depth } | Out-Null

            if ($m.objectClass -eq 'group') {
                $queue.Enqueue(@{ sid = $memberSid; depth = $depth })
            }

            if (($memberIndex % 25) -eq 0) {
                Write-ResolverProgress -Phase 'Groups' -Current $groupIndex -Total $groups.Count `
                    -Activity ("Recorded {0:N0} of {1:N0} member(s) for {2}." -f $memberIndex, @($members).Count, $cur.sid)
            }
        }
    }

    Write-ResolverProgress -Phase 'Groups' -Current $groupIndex -Total $groups.Count `
        -Activity ("Expanded group {0:N0} of {1:N0}." -f $groupIndex, $groups.Count)
}

Write-ResolverProgress -Phase 'Complete' -Current 1 -Total 1 -Activity 'Resolution complete.'
Write-Host "Resolution complete." -ForegroundColor Green
exit 0
