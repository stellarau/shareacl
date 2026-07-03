[CmdletBinding()]
param(
    [Parameter(Mandatory)] $Page,
    [Parameter(Mandatory)] $App
)

# Controls
$lstFindings      = $Page.FindName('LstFindings')
$txtSummary       = $Page.FindName('TxtSummary')
$txtFindingName   = $Page.FindName('TxtFindingName')
$txtFindingDesc   = $Page.FindName('TxtFindingDesc')
$grdDetail        = $Page.FindName('GrdDetail')
$btnRefresh       = $Page.FindName('BtnRefresh')
$btnOpenFolder    = $Page.FindName('BtnOpenInFolder')
$btnSwapPrincipal = $Page.FindName('BtnSwapPrincipal')
$btnCopyPath      = $Page.FindName('BtnCopyPath')
$btnExport        = $Page.FindName('BtnExportCsv')

# Severity → colour
$severityBrush = @{
    'High'   = '#E74C3C'
    'Medium' = '#F39C12'
    'Low'    = '#F1C40F'
    'Info'   = '#3498DB'
}
$severityOrder = @{ 'High' = 0; 'Medium' = 1; 'Low' = 2; 'Info' = 3 }

# -----------------------------------------------------------------------------
# Findings catalogue — add new ones here
# -----------------------------------------------------------------------------
$findings = @(

    [pscustomobject]@{
        Id          = 'orphaned'
        Name        = 'Orphaned SIDs on ACEs'
        Severity    = 'High'
        SwapCapable = $true
        Description = 'ACEs referencing SIDs that no longer resolve to an AD principal. These are deleted accounts whose references in the filesystem persist. Core overhaul target.'
        Query       = @"
SELECT f.path                              AS Path,
       a.trustee_sid                       AS Sid,
       a.rights_text                       AS Rights,
       a.access_control_type               AS AceType,
       CASE a.is_inherited WHEN 1 THEN 'Y' ELSE 'N' END AS Inherited
FROM aces a
JOIN folders f      ON f.folder_id = a.folder_id
LEFT JOIN principals p ON p.sid    = a.trustee_sid
WHERE f.scan_id = @scan
  AND (p.sid IS NULL OR p.principal_type = 'Orphaned')
ORDER BY f.path
"@
    }

    [pscustomobject]@{
        Id          = 'everyone'
        Name        = '"Everyone" exposure'
        Severity    = 'High'
        SwapCapable = $false
        Description = 'Folders with an ACE granting the Everyone group (S-1-1-0). Almost never intentional outside legacy public shares.'
        Query       = @"
SELECT f.path                              AS Path,
       a.rights_text                       AS Rights,
       a.access_control_type               AS AceType,
       CASE a.is_inherited WHEN 1 THEN 'Y' ELSE 'N' END AS Inherited
FROM aces a
JOIN folders f ON f.folder_id = a.folder_id
WHERE f.scan_id = @scan
  AND a.trustee_sid = 'S-1-1-0'
ORDER BY f.path
"@
    }

    [pscustomobject]@{
    Id          = 'nonadmin_fullcontrol'
    Name        = 'Non-admin Full Control'
    Severity    = 'High'
    SwapCapable = $true
    Description = 'Allow ACEs granting Full Control to principals that are NOT transitively members of BUILTIN\Administrators, Domain Admins, or Enterprise Admins. Excludes well-known admin SIDs, the built-in Administrator account, and any user/group whose membership in an admin group is recorded in the resolver output.'
    Query       = @"
SELECT f.path                              AS Path,
       COALESCE(p.name, a.trustee_sid)     AS Trustee,
       COALESCE(p.principal_type, '?')     AS Type,
       a.rights_text                       AS Rights,
       CASE a.is_inherited WHEN 1 THEN 'Y' ELSE 'N' END AS Inherited
FROM aces a
JOIN folders f       ON f.folder_id = a.folder_id
LEFT JOIN principals p ON p.sid    = a.trustee_sid
WHERE f.scan_id = @scan
  AND a.access_control_type = 'Allow'
  AND (a.rights_mask & 2032127) = 2032127
  AND a.trustee_sid NOT IN (
      'S-1-5-18',           -- LOCAL SYSTEM
      'S-1-5-32-544',       -- BUILTIN\Administrators
      'S-1-3-0',            -- CREATOR OWNER
      'S-1-5-32-549'        -- Server Operators
  )
  AND a.trustee_sid NOT LIKE 'S-1-5-21-%-500'    -- Domain Administrator
  AND a.trustee_sid NOT LIKE 'S-1-5-21-%-512'    -- Domain Admins
  AND a.trustee_sid NOT LIKE 'S-1-5-21-%-519'    -- Enterprise Admins
  -- Exclude transitive members of any admin group
  AND a.trustee_sid NOT IN (
      SELECT gm.member_sid
        FROM group_members gm
       WHERE gm.group_sid = 'S-1-5-32-544'
          OR gm.group_sid LIKE 'S-1-5-21-%-512'
          OR gm.group_sid LIKE 'S-1-5-21-%-519'
  )
ORDER BY f.path
"@
    }

[pscustomobject]@{
    Id          = 'admin_member_fullcontrol'
    Name        = 'Admin principal with explicit Full Control'
    Severity    = 'Info'
    SwapCapable = $true
    Description = 'Allow Full Control ACEs held by individual users or groups that are transitively members of an admin group (BUILTIN\Administrators, Domain Admins, or Enterprise Admins). Typically benign — admin accounts are often granted explicit FC so permission edits work without elevation — but worth reviewing in environments where admin assignments should always flow through groups.'
    Query       = @"
SELECT f.path                              AS Path,
       COALESCE(p.name, a.trustee_sid)     AS Trustee,
       COALESCE(p.principal_type, '?')     AS Type,
       (SELECT GROUP_CONCAT(DISTINCT pg.name)
          FROM group_members gm
          JOIN principals pg ON pg.sid = gm.group_sid
         WHERE gm.member_sid = a.trustee_sid
           AND (gm.group_sid = 'S-1-5-32-544'
             OR gm.group_sid LIKE 'S-1-5-21-%-512'
             OR gm.group_sid LIKE 'S-1-5-21-%-519')
       )                                   AS AdminGroups,
       a.rights_text                       AS Rights,
       CASE a.is_inherited WHEN 1 THEN 'Y' ELSE 'N' END AS Inherited
FROM aces a
JOIN folders f       ON f.folder_id = a.folder_id
LEFT JOIN principals p ON p.sid    = a.trustee_sid
WHERE f.scan_id = @scan
  AND a.access_control_type = 'Allow'
  AND (a.rights_mask & 2032127) = 2032127
  AND a.trustee_sid IN (
      SELECT gm.member_sid
        FROM group_members gm
       WHERE gm.group_sid = 'S-1-5-32-544'
          OR gm.group_sid LIKE 'S-1-5-21-%-512'
          OR gm.group_sid LIKE 'S-1-5-21-%-519'
  )
ORDER BY f.path, Trustee
"@
    }

    [pscustomobject]@{
        Id          = 'unreachable'
        Name        = 'Unreachable folders'
        Severity    = 'High'
        SwapCapable = $false
        Description = 'Folders with broken inheritance AND zero explicit ACEs. Nobody but the owner and admins can access these — usually a misclick on the Security tab. High because they often hide data nobody knows is there.'
        Query       = @"
SELECT f.path                              AS Path,
       COALESCE(p.name, f.owner_sid)       AS Owner,
       f.explicit_ace_count                AS ExplicitAces
FROM folders f
LEFT JOIN principals p ON p.sid = f.owner_sid
WHERE f.scan_id = @scan
  AND f.inheritance_enabled = 0
  AND f.explicit_ace_count = 0
ORDER BY f.path
"@
    }

    [pscustomobject]@{
        Id          = 'broad_exposure'
        Name        = 'Broad principal exposure'
        Severity    = 'Medium'
        SwapCapable = $false
        Description = 'Explicit ACEs granting access to broad populations: Authenticated Users, BUILTIN\Users, or Domain Users. Sometimes deliberate at a share root, rarely deliberate on a subfolder.'
        Query       = @"
SELECT f.path                              AS Path,
       COALESCE(p.name, a.trustee_sid)     AS Trustee,
       a.trustee_sid                       AS Sid,
       a.rights_text                       AS Rights,
       a.access_control_type               AS AceType
FROM aces a
JOIN folders f       ON f.folder_id = a.folder_id
LEFT JOIN principals p ON p.sid    = a.trustee_sid
WHERE f.scan_id = @scan
  AND a.is_inherited = 0
  AND (
       a.trustee_sid = 'S-1-5-11'                    -- Authenticated Users
    OR a.trustee_sid = 'S-1-5-32-545'                -- BUILTIN\Users
    OR a.trustee_sid LIKE 'S-1-5-21-%-513'           -- Domain Users
  )
ORDER BY f.path
"@
    }

    [pscustomobject]@{
        Id          = 'direct_user_aces'
        Name        = 'Direct user ACEs (anti-pattern)'
        Severity    = 'Medium'
        SwapCapable = $true
        Description = 'Explicit ACEs assigned to individual users rather than groups. Hard to maintain, hard to off-board, and a frequent cause of permissions drift.'
        Query       = @"
SELECT f.path                              AS Path,
       p.name                              AS User,
       p.sam_account_name                  AS SAM,
       a.rights_text                       AS Rights,
       a.access_control_type               AS AceType
FROM aces a
JOIN folders f       ON f.folder_id = a.folder_id
JOIN principals p   ON p.sid       = a.trustee_sid
WHERE f.scan_id = @scan
  AND p.principal_type = 'User'
  AND a.is_inherited = 0
ORDER BY f.path, p.name
"@
    }

    [pscustomobject]@{
        Id          = 'deny_aces'
        Name        = 'Deny ACEs'
        Severity    = 'Info'
        SwapCapable = $false
        Description = 'All Deny ACEs in scope. Worth a review during overhaul: a Deny is usually a workaround for a structural problem upstream in the group design.'
        Query       = @"
SELECT f.path                              AS Path,
       COALESCE(p.name, a.trustee_sid)     AS Trustee,
       a.rights_text                       AS Rights,
       CASE a.is_inherited WHEN 1 THEN 'Y' ELSE 'N' END AS Inherited
FROM aces a
JOIN folders f       ON f.folder_id = a.folder_id
LEFT JOIN principals p ON p.sid    = a.trustee_sid
WHERE f.scan_id = @scan
  AND a.access_control_type = 'Deny'
ORDER BY f.path
"@
    }

    [pscustomobject]@{
        Id          = 'scan_errors'
        Name        = 'Scan errors'
        Severity    = 'Info'
        SwapCapable = $false
        Description = 'Paths the collector could not enumerate or read. Usually access-denied (the scanning account lacks permission) or path-too-long. Worth triaging because anything in here is a gap in your audit.'
        Query       = @"
SELECT path        AS Path,
       phase       AS Phase,
       message     AS Message,
       logged_utc  AS LoggedUtc
FROM scan_errors
WHERE scan_id = @scan
ORDER BY error_id DESC
"@
    }
)

# Decorate with rendering helpers
foreach ($f in $findings) {
    $f | Add-Member -NotePropertyName SeverityBrush -NotePropertyValue $severityBrush[$f.Severity]
    $f | Add-Member -NotePropertyName CountDisplay  -NotePropertyValue '…'
    $f | Add-Member -NotePropertyName Count         -NotePropertyValue $null
    $f | Add-Member -NotePropertyName SeverityRank  -NotePropertyValue $severityOrder[$f.Severity]
}

# -----------------------------------------------------------------------------
# Behaviour
# -----------------------------------------------------------------------------

$refreshCatalogue = {
    if (-not $App.CurrentScanId) {
        $txtSummary.Text = '(no scan selected)'
        return
    }

    $totalHigh = 0
    $totalMed  = 0
    foreach ($f in $findings) {
        try {
            $row = $App.Query("SELECT COUNT(*) AS n FROM ($($f.Query))",
                              @{ scan = $App.CurrentScanId })
            $n = [int]$row.n
        } catch {
            $n = -1
        }
        $f.Count        = $n
        $f.CountDisplay = if ($n -lt 0) { 'err' } else { '{0:N0}' -f $n }
        if ($n -gt 0 -and $f.Severity -eq 'High')   { $totalHigh += $n }
        if ($n -gt 0 -and $f.Severity -eq 'Medium') { $totalMed  += $n }
    }

    # Sort: severity desc, then count desc, then name
    $sorted = $findings | Sort-Object SeverityRank, @{ Expression = 'Count'; Descending = $true }, Name
    $lstFindings.ItemsSource = @($sorted)
    $txtSummary.Text = "Scan #$($App.CurrentScanId)  ·  High: $totalHigh   Medium: $totalMed"
}.GetNewClosure()

$loadDetail = {
    param($Finding)
    if (-not $Finding) { return }

    $txtFindingName.Text = $Finding.Name
    $txtFindingDesc.Text = $Finding.Description

    try {
        $rows = $App.Query($Finding.Query, @{ scan = $App.CurrentScanId })
        $grdDetail.ItemsSource = @($rows)
        $App.SetStatus(("Findings · {0}: {1:N0} rows" -f $Finding.Name, @($rows).Count))
        $btnExport.IsEnabled = @($rows).Count -gt 0
    } catch {
        $App.ShowError("Finding '$($Finding.Name)' query failed", $_.Exception.Message)
        $grdDetail.ItemsSource = @()
        $btnExport.IsEnabled = $false
    }

    $btnOpenFolder.IsEnabled = $false
    $btnCopyPath.IsEnabled   = $false
}.GetNewClosure()

$getRowSidAndName = {
    param($Row, $Finding)
    if (-not $Row) { return $null }
    $props = $Row.PSObject.Properties.Name

    # Prefer explicit Sid column (orphaned finding), then look up name via principals table
    if ('Sid' -in $props -and $Row.Sid) {
        $sid = [string]$Row.Sid
        $name = try {
            $p = $App.Query('SELECT name FROM principals WHERE sid = @s', @{ s = $sid })
            if ($p -and $p.name) { $p.name } else { $sid }
        } catch { $sid }
        return @{ Sid = $sid; Name = $name }
    }

    # Trustee or User column: look up SID via principals table
    $trusteeText = $null
    foreach ($col in 'Trustee','User') {
        if ($col -in $props -and $Row.$col) { $trusteeText = [string]$Row.$col; break }
    }
    if (-not $trusteeText) { return $null }

    # If the trustee text already looks like a SID, use it directly
    if ($trusteeText -match '^S-1-\d+(-\d+)+$') {
        return @{ Sid = $trusteeText; Name = $trusteeText }
    }

    try {
        $p = $App.Query(
            'SELECT sid, name FROM principals WHERE name = @n OR sam_account_name = @n LIMIT 1',
            @{ n = $trusteeText })
        if ($p -and $p.sid) {
            return @{ Sid = [string]$p.sid; Name = [string]$p.name }
        }
    } catch { }

    return $null
}.GetNewClosure()

# Row selection inside the detail grid
$grdDetail.Add_SelectionChanged({
    $sel = $grdDetail.SelectedItem
    $hasPath = ($sel -ne $null) -and ($sel.PSObject.Properties.Match('Path').Count -gt 0) -and $sel.Path
    $btnOpenFolder.IsEnabled = [bool]$hasPath
    $btnCopyPath.IsEnabled   = [bool]$hasPath

    $currentFinding = $lstFindings.SelectedItem
    $canSwap = $sel -and $currentFinding -and $currentFinding.SwapCapable
    if ($canSwap) {
        $resolved = & $getRowSidAndName $sel $currentFinding
        $canSwap = ($null -ne $resolved)
    }
    $btnSwapPrincipal.IsEnabled = [bool]$canSwap
}.GetNewClosure())

# Catalogue selection
$lstFindings.Add_SelectionChanged({
    if ($lstFindings.SelectedItem) { & $loadDetail $lstFindings.SelectedItem }
}.GetNewClosure())

$btnRefresh.Add_Click($refreshCatalogue)

$btnCopyPath.Add_Click({
    $sel = $grdDetail.SelectedItem
    if ($sel -and $sel.Path) {
        [System.Windows.Clipboard]::SetText([string]$sel.Path)
        $App.SetStatus("Copied: $($sel.Path)")
    }
}.GetNewClosure())

$btnOpenFolder.Add_Click({
    $sel = $grdDetail.SelectedItem
    if ($sel -and $sel.Path) {
        $App.NavContext = @{ PathFilter = [string]$sel.Path }
        $App.Navigate('FolderView')
    }
}.GetNewClosure())

$btnSwapPrincipal.Add_Click({
    $sel = $grdDetail.SelectedItem
    $currentFinding = $lstFindings.SelectedItem
    if (-not $sel -or -not $currentFinding) { return }

    $resolved = & $getRowSidAndName $sel $currentFinding
    if (-not $resolved) {
        $App.ShowError('Cannot resolve principal',
            'Could not determine a SID for the selected row. Try running the resolver against this scan.')
        return
    }

    $ctx = @{
        SourceSid  = $resolved.Sid
        SourceName = $resolved.Name
    }
    # Path is optional but useful — pre-fill scope if the finding row carries one
    if ($sel.PSObject.Properties.Match('Path').Count -gt 0 -and $sel.Path) {
        $ctx.Scope = [string]$sel.Path
    }

    $App.NavContext = $ctx
    $App.Navigate('SwapView')
}.GetNewClosure())

$btnExport.Add_Click({
    $sel = $lstFindings.SelectedItem
    if (-not $sel -or -not $grdDetail.ItemsSource) { return }
    $dlg = [System.Windows.Forms.SaveFileDialog]::new()
    $dlg.Filter   = 'CSV (*.csv)|*.csv'
    $safe = ($sel.Id -replace '[\\/:*?"<>|]', '_')
    $dlg.FileName = "Finding_${safe}_scan$($App.CurrentScanId).csv"
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        @($grdDetail.ItemsSource) |
            Export-Csv -NoTypeInformation -Path $dlg.FileName -Encoding UTF8
        $App.SetStatus("Exported to $($dlg.FileName)")
    }
}.GetNewClosure())

# Honour navigation context (e.g. drilled-in from Findings)
if ($App.NavContext -and $App.NavContext.PathFilter) {
    $txtFilter.Text = [string]$App.NavContext.PathFilter
    $App.NavContext = $null   # consume once
}

# Initial load
& $refreshCatalogue