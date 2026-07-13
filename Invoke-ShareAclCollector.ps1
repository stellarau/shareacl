#Requires -Version 7.0
#Requires -Modules NTFSSecurity, PSSQLite

<#
.SYNOPSIS
    ShareACL streaming collector. Walks one or more roots, writes folders + ACEs
    to a SQLite database. Resumable, memory-bounded, group-resolution-deferred.

.PARAMETER RootPath
    One or more UNC or local paths to scan.

.PARAMETER Database
    Path to the SQLite database file. Created if missing.

.PARAMETER BatchSize
    Number of folders per transaction. 500 is a sensible default.

.PARAMETER MaxDepth
    Limit recursion depth. Default: unlimited.

.PARAMETER Resume
    Continue the most recent 'running' scan in the DB instead of starting a new one.

.EXAMPLE
    .\Invoke-ShareAclCollector.ps1 -RootPath '\\fs01\Finance','\\fs01\HR' -Database .\shareacl.db
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string[]] $RootPath,
    [Parameter(Mandatory)] [string]   $Database,
    [int]    $BatchSize = 500,
    [int]    $MaxDepth  = [int]::MaxValue,
    [switch] $Resume
)

$ErrorActionPreference = 'Stop'
# Right after $ErrorActionPreference = 'Stop'
trap {
    try { [System.Data.SQLite.SQLiteConnection]::ClearAllPools() } catch {}
    [GC]::Collect(); [GC]::WaitForPendingFinalizers(); [GC]::Collect()
    # let the error continue propagating
    continue
}
$script:SchemaPath = Join-Path $PSScriptRoot 'schema.sql'

# -----------------------------------------------------------------------------
# DB helpers
# -----------------------------------------------------------------------------
function Initialize-Database {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType File -Path $Path | Out-Null
    }
    $schema = Get-Content -Raw -Path $script:SchemaPath
    Invoke-SqliteQuery -DataSource $Path -Query $schema | Out-Null
}

function New-ScanRecord {
    param([string]$Path, [string[]]$Roots)
    $rootsJson = ($Roots | ConvertTo-Json -Compress)
    $now = [DateTime]::UtcNow.ToString('o')
    Invoke-SqliteQuery -DataSource $Path -Query @"
        INSERT INTO scans (started_utc, root_paths_json, host, operator, status)
        VALUES (@started, @roots, @host, @op, 'running');
        SELECT last_insert_rowid() AS scan_id;
"@ -SqlParameters @{
        started = $now
        roots   = $rootsJson
        host    = $env:COMPUTERNAME
        op      = "$env:USERDOMAIN\$env:USERNAME"
    } | Select-Object -ExpandProperty scan_id
}

function Get-ResumableScanId {
    param([string]$Path)
    (Invoke-SqliteQuery -DataSource $Path -Query @"
        SELECT scan_id FROM scans WHERE status = 'running' ORDER BY scan_id DESC LIMIT 1
"@).scan_id
}

function Complete-ScanRecord {
    param([string]$Path, [int]$ScanId, [string]$Status, [int]$Folders, [int]$Aces, [int]$Errors)
    $now = [DateTime]::UtcNow.ToString('o')
    Invoke-SqliteQuery -DataSource $Path -Query @"
        UPDATE scans SET completed_utc=@done, status=@status,
                         folder_count=@fc, ace_count=@ac, error_count=@ec
        WHERE scan_id=@id
"@ -SqlParameters @{ done=$now; status=$Status; fc=$Folders; ac=$Aces; ec=$Errors; id=$ScanId } | Out-Null
}

function Set-ScanStatus {
    param([string]$Path, [int]$ScanId, [string]$Status)
    Invoke-SqliteQuery -DataSource $Path -Query @"
        UPDATE scans SET status = @s, last_updated_utc = @now WHERE scan_id = @id
"@ -SqlParameters @{
        s   = $Status
        now = [System.DateTime]::UtcNow.ToString('o')
        id  = $ScanId
    } | Out-Null
}

function Set-ScanTotal {
    param([string]$Path, [int]$ScanId, [int64]$Total)
    Invoke-SqliteQuery -DataSource $Path -Query @"
        UPDATE scans SET total_folders = @t, last_updated_utc = @now WHERE scan_id = @id
"@ -SqlParameters @{
        t   = $Total
        now = [System.DateTime]::UtcNow.ToString('o')
        id  = $ScanId
    } | Out-Null
}

function Update-ScanProgress {
    param(
        [System.Data.SQLite.SQLiteConnection]$Conn,
        [int]     $ScanId,
        [int64]   $Processed,
        [double]  $Rate,
        [datetime]$EtaUtc
    )
    $cmd = $null
    try {
        $cmd = $Conn.CreateCommand()
        $cmd.CommandText = @"
        UPDATE scans SET
            processed_folders        = @p,
            folders_per_second       = @r,
            estimated_completion_utc = @eta,
            last_updated_utc         = @now
         WHERE scan_id = @id
"@
        [void]$cmd.Parameters.AddWithValue('@p',   $Processed)
        [void]$cmd.Parameters.AddWithValue('@r',   $Rate)
        [void]$cmd.Parameters.AddWithValue('@eta', $EtaUtc.ToString('o'))
        [void]$cmd.Parameters.AddWithValue('@now', [System.DateTime]::UtcNow.ToString('o'))
        [void]$cmd.Parameters.AddWithValue('@id',  $ScanId)
        [void]$cmd.ExecuteNonQuery()
    } finally {
        if ($null -ne $cmd) { $cmd.Dispose() }
    }
}

function Write-ScanError {
    param([System.Data.SQLite.SQLiteConnection]$Conn, [int]$ScanId, [string]$ItemPath, [string]$Phase, [string]$Message)
    $cmd = $null
    try {
        $cmd = $Conn.CreateCommand()
        $cmd.CommandText = "INSERT INTO scan_errors(scan_id,path,phase,message,logged_utc) VALUES (@s,@p,@ph,@m,@t)"
        [void]$cmd.Parameters.AddWithValue('@s',  $ScanId)
        [void]$cmd.Parameters.AddWithValue('@p',  $ItemPath)
        [void]$cmd.Parameters.AddWithValue('@ph', $Phase)
        [void]$cmd.Parameters.AddWithValue('@m',  $Message)
        [void]$cmd.Parameters.AddWithValue('@t',  [DateTime]::UtcNow.ToString('o'))
        [void]$cmd.ExecuteNonQuery()
    } finally {
        if ($null -ne $cmd) { $cmd.Dispose() }
    }
}

# -----------------------------------------------------------------------------
# Folder & ACE extraction
# -----------------------------------------------------------------------------
function Get-FolderFacts {
    <#
        Returns a hashtable describing the folder, or $null on hard failure.
        Uses NTFSSecurity for speed and correct long-path handling.
    #>
    param([string]$Path)

    $inheritance   = $null
    $owner         = $null
    $aces          = @()
    $isReparse     = $false

    try {
        $item = Get-Item2 -Path $Path -ErrorAction Stop
        $isReparse = [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
    } catch {
        return @{ Error = "stat: $($_.Exception.Message)" }
    }

    try {
        $inh = Get-NTFSInheritance -Path $Path -ErrorAction Stop
        $inheritance = [int]$inh.AccessInheritanceEnabled
    } catch {
        $inheritance = 1   # assume default if we can't read
    }

    try {
        $owner = (Get-NTFSOwner -Path $Path -ErrorAction Stop).Owner.Sid.Value
    } catch { }

    try {
        $aces = Get-NTFSAccess -Path $Path -ExcludeInherited:$false -ErrorAction Stop
    } catch {
        return @{ Error = "acl: $($_.Exception.Message)"; Inheritance = $inheritance; Owner = $owner; IsReparse = $isReparse }
    }

    @{
        Inheritance = $inheritance
        Owner       = $owner
        IsReparse   = [int]$isReparse
        Aces        = $aces
    }
}

function Get-FolderCount {
    <#
        Fast BFS folder count using System.IO.Directory.EnumerateDirectories per level,
        so an inaccessible folder doesn't halt the whole enumeration. Honours MaxDepth
        the same way the main collector does.
    #>
    param(
        [string[]] $Roots,
        [int]      $MaxDepth
    )

    $total = 0
    $announceEvery = 5000
    $queue = [System.Collections.Generic.Queue[object]]::new()
    foreach ($r in $Roots) {
        $queue.Enqueue(@{ Path = $r; Depth = 0 })
    }

    while ($queue.Count -gt 0) {
        $cur = $queue.Dequeue()
        $total++

        if (($total % $announceEvery) -eq 0) {
            Write-Host ("  counting… {0:N0} folders discovered so far" -f $total)
        }

        if ($MaxDepth -gt 0 -and $cur.Depth -ge $MaxDepth) { continue }

        try {
            foreach ($sub in [System.IO.Directory]::EnumerateDirectories($cur.Path)) {
                $queue.Enqueue(@{ Path = $sub; Depth = $cur.Depth + 1 })
            }
        } catch {
            # Inaccessible / long-path / permission — collector will log per-folder when it hits this
        }
    }
    $total
}

function Get-AceTrusteeSid {
    <#
        Returns the trustee SID string for an ACE from Get-NTFSAccess,
        falling back through every place NTFSSecurity might surface it.
        Returns $null only if there is genuinely nothing usable.
    #>
    param($Ace)

    # 1. The normal path
    if ($Ace.Account -and $Ace.Account.Sid -and $Ace.Account.Sid.Value) {
        return [string]$Ace.Account.Sid.Value
    }

    # 2. AccountName sometimes IS the raw SID string for orphaned principals
    $name = $null
    if ($Ace.Account) { $name = [string]$Ace.Account.AccountName }
    if (-not $name -and $Ace.AccessControlType) { $name = [string]$Ace.IdentityReference }

    if ($name -match '^S-1-\d+(-\d+)+$') {
        return $name
    }

    # 3. Try to translate the textual identity to a SID
    if ($name) {
        try {
            $nt  = [System.Security.Principal.NTAccount]::new($name)
            $sid = $nt.Translate([System.Security.Principal.SecurityIdentifier])
            return [string]$sid.Value
        } catch { }
    }

    return $null
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
Initialize-Database -Path $Database

if ($Resume) {
    $scanId = Get-ResumableScanId -Path $Database
    if (-not $scanId) { throw "No resumable scan found in $Database." }
    Write-Host "Resuming scan_id=$scanId" -ForegroundColor Cyan
} else {
    $scanId = New-ScanRecord -Path $Database -Roots $RootPath
    Write-Host "Started scan_id=$scanId" -ForegroundColor Cyan

    # Seed the pending queue with the roots
    foreach ($r in $RootPath) {
        Invoke-SqliteQuery -DataSource $Database -Query @"
            INSERT OR IGNORE INTO folders_pending(scan_id,path,parent_id,depth)
            VALUES (@s,@p,NULL,0)
"@ -SqlParameters @{ s=$scanId; p=$r } | Out-Null
    }
}

$totalCount   = $null
$runStartTime = $null

if (-not $Resume) {
    # Transition to counting phase
    Set-ScanStatus -Path $Database -ScanId $scanId -Status 'counting'
    Write-Host "Counting folders under: $($RootPath -join ', ')" -ForegroundColor Cyan

    $countStart = [System.DateTime]::UtcNow
    try {
        $totalCount = Get-FolderCount -Roots $RootPath -MaxDepth $MaxDepth
        $countElapsed = ([System.DateTime]::UtcNow - $countStart).TotalSeconds
        Write-Host ("Count complete: {0:N0} folders in {1:N1}s" -f $totalCount, $countElapsed) -ForegroundColor Cyan
        Set-ScanTotal -Path $Database -ScanId $scanId -Total $totalCount
    } catch {
        Write-Host "Counting phase failed: $($_.Exception.Message). Proceeding without total." -ForegroundColor Yellow
        $totalCount = $null
    }

    Set-ScanStatus -Path $Database -ScanId $scanId -Status 'running'

    # Seed the pending queue with the roots (moved here from the existing spot, unchanged)
    foreach ($r in $RootPath) {
        Invoke-SqliteQuery -DataSource $Database -Query @"
            INSERT OR IGNORE INTO folders_pending(scan_id,path,parent_id,depth)
            VALUES (@s,@p,NULL,0)
"@ -SqlParameters @{ s=$scanId; p=$r } | Out-Null
    }
} else {
    # For resumed scans, pull the previously-recorded total (may be NULL)
    $prevRow = Invoke-SqliteQuery -DataSource $Database -Query @"
        SELECT total_folders FROM scans WHERE scan_id = @id
"@ -SqlParameters @{ id = $scanId }
    if ($prevRow -and $prevRow.total_folders) { $totalCount = [int64]$prevRow.total_folders }
    Set-ScanStatus -Path $Database -ScanId $scanId -Status 'running'
}

# Record the moment the actual scan begins — used for rate calc, excludes the counting phase
$runStartTime = [System.DateTime]::UtcNow

# Open one long-lived connection for the bulk write loop
$conn = New-SQLiteConnection -DataSource $Database
if ($conn.State -ne [System.Data.ConnectionState]::Open) {
    $conn.Open() | Out-Null
}

# Prepared statements (re-used per row, huge perf win over Invoke-SqliteQuery in a loop)
$insFolder = $conn.CreateCommand()
$insFolder.CommandText = @"
INSERT INTO folders(scan_id,path,parent_id,depth,owner_sid,inheritance_enabled,
                    is_reparse_point,explicit_ace_count,scan_error,visited_utc)
VALUES (@s,@p,@par,@d,@o,@i,@r,@ec,@err,@t);
SELECT last_insert_rowid();
"@
'@s','@p','@par','@d','@o','@i','@r','@ec','@err','@t' | ForEach-Object {
    [void]$insFolder.Parameters.Add($_, [System.Data.DbType]::Object)
}

$insAce = $conn.CreateCommand()
$insAce.CommandText = @"
INSERT INTO aces(folder_id,trustee_sid,access_control_type,rights_text,rights_mask,
                 inheritance_flags,propagation_flags,is_inherited,inherited_from)
VALUES (@f,@sid,@act,@rt,@rm,@if,@pf,@ii,@from)
"@
'@f','@sid','@act','@rt','@rm','@if','@pf','@ii','@from' | ForEach-Object {
    [void]$insAce.Parameters.Add($_, [System.Data.DbType]::Object)
}

$delPending = $conn.CreateCommand()
$delPending.CommandText = "DELETE FROM folders_pending WHERE scan_id=@s AND path=@p"
[void]$delPending.Parameters.Add('@s', [System.Data.DbType]::Int64)
[void]$delPending.Parameters.Add('@p', [System.Data.DbType]::String)

$insPending = $conn.CreateCommand()
$insPending.CommandText = @"
INSERT OR IGNORE INTO folders_pending(scan_id,path,parent_id,depth) VALUES (@s,@p,@par,@d)
"@
'@s','@p','@par','@d' | ForEach-Object {
    [void]$insPending.Parameters.Add($_, [System.Data.DbType]::Object)
}

# Counters
$totalFolders = 0; $totalAces = 0; $totalErrors = 0
$status = 'running'

try {
    while ($true) {
        # Pull the next batch from the pending queue
        $batch = Invoke-SqliteQuery -SQLiteConnection $conn -Query @"
            SELECT path, parent_id, depth FROM folders_pending
            WHERE scan_id=@s ORDER BY depth ASC, path ASC LIMIT @n
"@ -SqlParameters @{ s=$scanId; n=$BatchSize }

        if (-not $batch) { break }

        $tx = $conn.BeginTransaction()
        try {
            foreach ($row in $batch) {
                $path   = [string]$row.path
                $parent = if ($row.parent_id -is [DBNull]) { $null } else { [int64]$row.parent_id }
                $depth  = [int]$row.depth

                $facts = Get-FolderFacts -Path $path

                $errText = $null
                if ($facts.ContainsKey('Error')) {
                    $errText = $facts.Error
                    Write-ScanError -Conn $conn -ScanId $scanId -ItemPath $path -Phase 'acl' -Message $errText
                    $totalErrors++
                }

                $explicit = 0
                if ($facts.Aces) { $explicit = ($facts.Aces | Where-Object { -not $_.IsInherited }).Count }

                # Insert the folder, capture its id
                $insFolder.Parameters['@s'].Value   = $scanId
                $insFolder.Parameters['@p'].Value   = $path
                $insFolder.Parameters['@par'].Value = if ($null -eq $parent) { [DBNull]::Value } else { $parent }
                $insFolder.Parameters['@d'].Value   = $depth
                $insFolder.Parameters['@o'].Value   = if ($facts.Owner) { $facts.Owner } else { [DBNull]::Value }
                $insFolder.Parameters['@i'].Value   = if ($null -ne $facts.Inheritance) { $facts.Inheritance } else { 1 }
                $insFolder.Parameters['@r'].Value   = if ($null -ne $facts.IsReparse)   { $facts.IsReparse }   else { 0 }
                $insFolder.Parameters['@ec'].Value  = $explicit
                $insFolder.Parameters['@err'].Value = if ($errText) { $errText } else { [DBNull]::Value }
                $insFolder.Parameters['@t'].Value   = [DateTime]::UtcNow.ToString('o')
                $folderId = [int64]$insFolder.ExecuteScalar()

                # Insert ACEs
                if ($facts.Aces) {
                    foreach ($a in $facts.Aces) {
                        $sid = Get-AceTrusteeSid -Ace $a

                        if (-not $sid) {
                            Write-ScanError -Conn $conn -ScanId $scanId -ItemPath $path `
                                            -Phase 'acl' `
                                            -Message ("Skipped ACE with unresolvable trustee. Account='{0}' Rights='{1}' Type='{2}'" -f `
                                                    $a.Account, $a.AccessRights, $a.AccessControlType)
                            $totalErrors++
                            continue
                        }

                        $insAce.Parameters['@f'].Value    = $folderId
                        $insAce.Parameters['@sid'].Value  = $sid
                        $insAce.Parameters['@act'].Value  = "$($a.AccessControlType)"
                        $insAce.Parameters['@rt'].Value   = "$($a.AccessRights)"
                        $insAce.Parameters['@rm'].Value   = [int64]$a.AccessRights
                        $insAce.Parameters['@if'].Value   = "$($a.InheritanceFlags)"
                        $insAce.Parameters['@pf'].Value   = "$($a.PropagationFlags)"
                        $insAce.Parameters['@ii'].Value   = [int]$a.IsInherited
                        $insAce.Parameters['@from'].Value = if ($a.InheritedFrom) { "$($a.InheritedFrom)" } else { [DBNull]::Value }
                        [void]$insAce.ExecuteNonQuery()
                        $totalAces++
                    }
                }

                # Enqueue children unless we're at MaxDepth or hit a reparse point
                if (-not $facts.IsReparse -and $depth -lt $MaxDepth) {
                    try {
                        $children = Get-ChildItem -LiteralPath $path -Directory -Force -ErrorAction Stop
                        foreach ($c in $children) {
                            $insPending.Parameters['@s'].Value   = $scanId
                            $insPending.Parameters['@p'].Value   = $c.FullName
                            $insPending.Parameters['@par'].Value = $folderId
                            $insPending.Parameters['@d'].Value   = $depth + 1
                            [void]$insPending.ExecuteNonQuery()
                        }
                    } catch {
                        Write-ScanError -Conn $conn -ScanId $scanId -ItemPath $path -Phase 'enumerate' -Message $_.Exception.Message
                        $totalErrors++
                    }
                }

                # Remove this path from the pending queue
                $delPending.Parameters['@s'].Value = $scanId
                $delPending.Parameters['@p'].Value = $path
                [void]$delPending.ExecuteNonQuery()

                $totalFolders++
            }
            $tx.Commit()
        } catch {
            try { $tx.Rollback() } catch { }
            throw
        } finally {
            $tx.Dispose()
        }

        Write-Host ("  processed {0,8} folders | {1,9} ACEs | {2,4} errors" -f $totalFolders, $totalAces, $totalErrors)
        if ($totalCount -and $totalCount -gt 0) {
            $elapsed = ([System.DateTime]::UtcNow - $runStartTime).TotalSeconds
            $rate    = if ($elapsed -gt 0) { $totalFolders / $elapsed } else { 0 }
            $remaining = [Math]::Max(0, $totalCount - $totalFolders)
            $etaSecs = if ($rate -gt 0) { $remaining / $rate } else { 0 }
            $etaUtc  = [System.DateTime]::UtcNow.AddSeconds($etaSecs)

            try {
                Update-ScanProgress -Conn $conn -ScanId $scanId `
                                    -Processed $totalFolders -Rate $rate -EtaUtc $etaUtc
            } catch { }
        }
    }
    $status = 'completed'
}
catch {
    $status = 'failed'
    $ex = $_.Exception
    Write-Host ""
    Write-Host "===== COLLECTOR FAILED =====" -ForegroundColor Red
    Write-Host "Message : $($ex.Message)"          -ForegroundColor Red
    Write-Host "Type    : $($ex.GetType().FullName)" -ForegroundColor Red
    Write-Host "Where   : $($_.InvocationInfo.PositionMessage)" -ForegroundColor Red
    if ($ex.InnerException) {
        Write-Host "Inner   : $($ex.InnerException.Message)" -ForegroundColor Red
    }
    Write-Host "Stack   :" -ForegroundColor DarkGray
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray

    # Persist to the DB if we still can
    try {
        Invoke-SqliteQuery -DataSource $Database -Query @"
            INSERT INTO scan_errors(scan_id,path,phase,message,logged_utc)
            VALUES (@s,NULL,'fatal',@m,@t)
"@ -SqlParameters @{
            s = $scanId
            m = "$($ex.GetType().FullName): $($ex.Message) @ $($_.InvocationInfo.PositionMessage)"
            t = [DateTime]::UtcNow.ToString('o')
        } | Out-Null
    } catch { }
}
finally {
    foreach ($command in @($insFolder, $insAce, $delPending, $insPending)) {
        if ($null -ne $command) { try { $command.Dispose() } catch { } }
    }
    if ($conn) {
        if ($conn.State -ne [System.Data.ConnectionState]::Closed) {
            try { $conn.Close() } catch { }
        }
        try { $conn.Dispose() } catch { }
    }
    try {
        Invoke-SqliteQuery -DataSource $Database `
            -Query "PRAGMA wal_checkpoint(TRUNCATE);" | Out-Null
    } catch { }
    Complete-ScanRecord -Path $Database -ScanId $scanId -Status $status `
                        -Folders $totalFolders -Aces $totalAces -Errors $totalErrors
    Write-Host "Scan $scanId finished: status=$status, folders=$totalFolders, aces=$totalAces, errors=$totalErrors" -ForegroundColor Green
}


# Explicit exit code so callers can detect success/failure without parsing output
if ($status -eq 'completed') { exit 0 } else { exit 1 }
