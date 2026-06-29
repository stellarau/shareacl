#Requires -Version 7.0
#Requires -Modules ActiveDirectory, PSSQLite

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Database,
    [int] $ScanId,
    [int] $MaxNestingDepth = 16
)

$ErrorActionPreference = 'Stop'

# Pull SIDs that need classification
$sidFilter = if ($ScanId) {
    "WHERE a.trustee_sid IN (SELECT DISTINCT trustee_sid FROM aces a JOIN folders f ON a.folder_id=f.folder_id WHERE f.scan_id=$ScanId)"
} else { '' }

$sids = (Invoke-SqliteQuery -DataSource $Database -Query @"
    SELECT DISTINCT a.trustee_sid AS sid
    FROM aces a
    LEFT JOIN principals p ON p.sid = a.trustee_sid
    $sidFilter
    AND p.sid IS NULL
"@).sid

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
foreach ($sid in $sids) {
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

# Transitive group expansion with cycle detection
$groups = (Invoke-SqliteQuery -DataSource $Database -Query "SELECT sid FROM principals WHERE principal_type='Group'").sid

foreach ($g in $groups) {
    $visited = [System.Collections.Generic.HashSet[string]]::new()
    $queue   = [System.Collections.Generic.Queue[object]]::new()
    $queue.Enqueue(@{ sid=$g; depth=0 })

    while ($queue.Count -gt 0) {
        $cur = $queue.Dequeue()
        if (-not $visited.Add($cur.sid)) { continue }   # cycle guard
        if ($cur.depth -ge $MaxNestingDepth) { continue }

        try {
            $members = Get-ADGroupMember -Identity $cur.sid -ErrorAction Stop
        } catch { continue }

        foreach ($m in $members) {
            $memberSid = $m.SID.Value
            $depth = $cur.depth + 1
            Invoke-SqliteQuery -DataSource $Database -Query @"
                INSERT OR IGNORE INTO group_members(group_sid,member_sid,depth)
                VALUES (@g,@m,@d)
"@ -SqlParameters @{ g=$g; m=$memberSid; d=$depth } | Out-Null

            if ($m.objectClass -eq 'group') {
                $queue.Enqueue(@{ sid=$memberSid; depth=$depth })
            }
        }
    }
}

Write-Host "Resolution complete." -ForegroundColor Green