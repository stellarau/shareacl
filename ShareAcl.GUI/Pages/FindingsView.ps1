[CmdletBinding()]
param(
    [Parameter(Mandatory)] $Page,
    [Parameter(Mandatory)] $App
)

$pageContext = $Page.Tag
if ($null -eq $pageContext) {
    throw 'FindingsView was created without a page context.'
}

$controls = $App.GetControls($Page, @(
    'LstFindings',
    'TxtSummary',
    'TxtFindingName',
    'TxtFindingDesc',
    'GrdDetail',
    'BtnRefresh',
    'BtnOpenInFolder',
    'BtnSwapPrincipal',
    'BtnCopyPath',
    'BtnExportCsv'
))

$severityBrush = @{
    High   = '#E74C3C'
    Medium = '#F39C12'
    Low    = '#F1C40F'
    Info   = '#3498DB'
}
$severityOrder = @{ High = 0; Medium = 1; Low = 2; Info = 3 }

# Add or amend catalogue entries here. Every swap-capable query deliberately
# returns Sid so that a display name is never used to guess the swap source.
$catalogue = @(
    [pscustomobject]@{
        Id          = 'orphaned'
        Name        = 'Orphaned SIDs on ACEs'
        Severity    = 'High'
        SwapCapable = $true
        Description = 'ACEs referencing SIDs that no longer resolve to an AD principal. These are deleted accounts whose references in the filesystem persist. Core overhaul target.'
        Query       = @"
SELECT f.path AS Path,
       a.trustee_sid AS Sid,
       a.rights_text AS Rights,
       a.access_control_type AS AceType,
       CASE a.is_inherited WHEN 1 THEN 'Y' ELSE 'N' END AS Inherited
FROM aces a
JOIN folders f ON f.folder_id = a.folder_id
LEFT JOIN principals p ON p.sid = a.trustee_sid
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
        Description = 'Folders with an Allow ACE granting the Everyone group (S-1-1-0). Almost never intentional outside legacy public shares.'
        Query       = @"
SELECT f.path AS Path,
       a.rights_text AS Rights,
       a.access_control_type AS AceType,
       CASE a.is_inherited WHEN 1 THEN 'Y' ELSE 'N' END AS Inherited
FROM aces a
JOIN folders f ON f.folder_id = a.folder_id
WHERE f.scan_id = @scan
  AND a.trustee_sid = 'S-1-1-0'
  AND a.access_control_type = 'Allow'
ORDER BY f.path
"@
    }

    [pscustomobject]@{
        Id          = 'nonadmin_fullcontrol'
        Name        = 'Non-admin Full Control'
        Severity    = 'High'
        SwapCapable = $true
        Description = 'Allow ACEs granting Full Control to principals that are not transitively members of BUILTIN\Administrators, Domain Admins, or Enterprise Admins. Excludes well-known admin SIDs, the built-in Administrator account, and identities whose admin-group membership is recorded in the resolver output.'
        Query       = @"
SELECT f.path AS Path,
       a.trustee_sid AS Sid,
       COALESCE(p.name, a.trustee_sid) AS Trustee,
       COALESCE(p.principal_type, '?') AS Type,
       a.rights_text AS Rights,
       CASE a.is_inherited WHEN 1 THEN 'Y' ELSE 'N' END AS Inherited
FROM aces a
JOIN folders f ON f.folder_id = a.folder_id
LEFT JOIN principals p ON p.sid = a.trustee_sid
WHERE f.scan_id = @scan
  AND a.access_control_type = 'Allow'
  AND (a.rights_mask & 2032127) = 2032127
  AND a.trustee_sid NOT IN (
      'S-1-5-18',
      'S-1-5-32-544',
      'S-1-3-0',
      'S-1-5-32-549'
  )
  AND a.trustee_sid NOT LIKE 'S-1-5-21-%-500'
  AND a.trustee_sid NOT LIKE 'S-1-5-21-%-512'
  AND a.trustee_sid NOT LIKE 'S-1-5-21-%-519'
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
        Description = 'Allow Full Control ACEs held by individual users or groups that are transitively members of an admin group. Typically benign, but worth reviewing where admin assignments should always flow through groups.'
        Query       = @"
SELECT f.path AS Path,
       a.trustee_sid AS Sid,
       COALESCE(p.name, a.trustee_sid) AS Trustee,
       COALESCE(p.principal_type, '?') AS Type,
       (SELECT GROUP_CONCAT(DISTINCT pg.name)
        FROM group_members gm
        JOIN principals pg ON pg.sid = gm.group_sid
        WHERE gm.member_sid = a.trustee_sid
          AND (gm.group_sid = 'S-1-5-32-544'
            OR gm.group_sid LIKE 'S-1-5-21-%-512'
            OR gm.group_sid LIKE 'S-1-5-21-%-519')) AS AdminGroups,
       a.rights_text AS Rights,
       CASE a.is_inherited WHEN 1 THEN 'Y' ELSE 'N' END AS Inherited
FROM aces a
JOIN folders f ON f.folder_id = a.folder_id
LEFT JOIN principals p ON p.sid = a.trustee_sid
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
        Description = 'Folders with protected inheritance and zero explicit ACEs. Their DACL normally grants no access, although an owner or administrator with the necessary privileges can repair it.'
        Query       = @"
SELECT f.path AS Path,
       COALESCE(p.name, f.owner_sid) AS Owner,
       f.explicit_ace_count AS ExplicitAces
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
        Description = 'Explicit Allow ACEs granting access to Authenticated Users, BUILTIN\Users, or Domain Users. Sometimes deliberate at a share root, rarely deliberate on a subfolder.'
        Query       = @"
SELECT f.path AS Path,
       COALESCE(p.name, a.trustee_sid) AS Trustee,
       a.trustee_sid AS Sid,
       a.rights_text AS Rights,
       a.access_control_type AS AceType
FROM aces a
JOIN folders f ON f.folder_id = a.folder_id
LEFT JOIN principals p ON p.sid = a.trustee_sid
WHERE f.scan_id = @scan
  AND a.is_inherited = 0
  AND a.access_control_type = 'Allow'
  AND (
       a.trustee_sid = 'S-1-5-11'
    OR a.trustee_sid = 'S-1-5-32-545'
    OR a.trustee_sid LIKE 'S-1-5-21-%-513'
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
SELECT f.path AS Path,
       a.trustee_sid AS Sid,
       p.name AS User,
       p.sam_account_name AS SAM,
       a.rights_text AS Rights,
       a.access_control_type AS AceType
FROM aces a
JOIN folders f ON f.folder_id = a.folder_id
JOIN principals p ON p.sid = a.trustee_sid
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
        Description = 'All Deny ACEs in scope. Worth reviewing during an overhaul because Deny is frequently a workaround for a structural problem in the group design.'
        Query       = @"
SELECT f.path AS Path,
       COALESCE(p.name, a.trustee_sid) AS Trustee,
       a.rights_text AS Rights,
       CASE a.is_inherited WHEN 1 THEN 'Y' ELSE 'N' END AS Inherited
FROM aces a
JOIN folders f ON f.folder_id = a.folder_id
LEFT JOIN principals p ON p.sid = a.trustee_sid
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
        Description = 'Paths the collector could not enumerate or read. These are commonly access-denied or path-related errors and represent gaps in the audit.'
        Query       = @"
SELECT path AS Path,
       phase AS Phase,
       message AS Message,
       logged_utc AS LoggedUtc
FROM scan_errors
WHERE scan_id = @scan
ORDER BY error_id DESC
"@
    }
)

foreach ($finding in $catalogue) {
    $baseQuery = [regex]::Replace(
        $finding.Query.Trim(),
        '(?is)\s+ORDER\s+BY\s+.*$',
        ''
    )
    $finding | Add-Member -NotePropertyName SeverityBrush -NotePropertyValue $severityBrush[$finding.Severity]
    $finding | Add-Member -NotePropertyName SeverityRank  -NotePropertyValue $severityOrder[$finding.Severity]
    $finding | Add-Member -NotePropertyName CountDisplay  -NotePropertyValue '…'
    $finding | Add-Member -NotePropertyName Count         -NotePropertyValue $null
    $finding | Add-Member -NotePropertyName CountQuery    -NotePropertyValue $baseQuery
}

$view = [pscustomobject]@{
    App                = $App
    Context            = $pageContext
    Controls           = $controls
    Catalogue          = $catalogue
    SelectedFindingId  = $null
    RefreshCatalogue   = $null
    LoadDetail         = $null
    ResolveRowPrincipal = $null
    RefreshForScan     = $null
    ApplyCatalogue     = $null
    ApplyDetail        = $null
}
$Page.DataContext  = $view
$pageContext.State = $view

$view.ApplyCatalogue = {
    param($Payload, $Owner)

    $view = $Owner.State
    $results = $Payload.Results
    $errors  = $Payload.Errors
    $highCount = 0
    $mediumCount = 0

    foreach ($finding in $view.Catalogue) {
        $count = if ($results.ContainsKey($finding.Id)) { [int]$results[$finding.Id] } else { -1 }
        $finding.Count = $count
        $finding.CountDisplay = if ($count -ge 0) { '{0:N0}' -f $count } else { 'err' }

        if ($count -gt 0 -and $finding.Severity -eq 'High')   { $highCount += $count }
        if ($count -gt 0 -and $finding.Severity -eq 'Medium') { $mediumCount += $count }
    }

    $sortProperties = @(
        'SeverityRank'
        @{ Expression = 'Count'; Descending = $true }
        'Name'
    )
    $sorted = @($view.Catalogue | Sort-Object -Property $sortProperties)
    $view.Controls.LstFindings.ItemsSource = $sorted

    if ($null -ne $view.SelectedFindingId) {
        $selection = $sorted | Where-Object Id -EQ $view.SelectedFindingId | Select-Object -First 1
        $view.Controls.LstFindings.SelectedItem = $selection
    }

    $errorText = if ($errors.Count -gt 0) { "   Count errors: $($errors.Count)" } else { '' }
    $view.Controls.TxtSummary.Text = (
        "Scan #$($view.App.CurrentScanId)  ·  High: $highCount   Medium: $mediumCount$errorText"
    )
    $view.App.SetStatus("Findings catalogue refreshed for scan #$($view.App.CurrentScanId).")
}

$view.ApplyDetail = {
    param($Payload, $Owner)

    $view = $Owner.State
    $rows = @($Payload.Rows)
    $view.Controls.GrdDetail.ItemsSource = $rows
    $view.Controls.BtnExportCsv.IsEnabled = ($rows.Count -gt 0)
    $view.Controls.BtnOpenInFolder.IsEnabled = $false
    $view.Controls.BtnCopyPath.IsEnabled = $false
    $view.Controls.BtnSwapPrincipal.IsEnabled = $false
    $view.App.SetStatus((
        'Findings · {0}: {1:N0} rows' -f $Payload.Name, $rows.Count
    ))
}

$view.RefreshCatalogue = {
    param($View)

    $scanId = $View.App.CurrentScanId
    $View.App.CancelAsync($View.Context, 'FindingDetail')
    $View.Controls.GrdDetail.ItemsSource = @()
    $View.Controls.TxtFindingName.Text = ''
    $View.Controls.TxtFindingDesc.Text = ''
    $View.Controls.BtnExportCsv.IsEnabled = $false
    $View.Controls.BtnOpenInFolder.IsEnabled = $false
    $View.Controls.BtnCopyPath.IsEnabled = $false
    $View.Controls.BtnSwapPrincipal.IsEnabled = $false

    if ($null -eq $scanId) {
        $View.App.CancelAsync($View.Context, 'FindingCatalogue')
        $View.Controls.LstFindings.ItemsSource = @()
        $View.Controls.TxtSummary.Text = '(no scan selected)'
        $View.App.SetStatus('Findings: no scan selected.')
    } else {
        $queries = foreach ($finding in $View.Catalogue) {
            [pscustomobject]@{
                Id       = $finding.Id
                CountSql = "SELECT COUNT(*) AS n FROM ($($finding.CountQuery)) AS finding_rows"
            }
        }

        foreach ($finding in $View.Catalogue) {
            $finding.Count        = $null
            $finding.CountDisplay = '…'
        }
        $View.Controls.LstFindings.ItemsSource = @(
            $View.Catalogue | Sort-Object -Property @('SeverityRank', 'Name')
        )
        $View.Controls.TxtSummary.Text = "Refreshing scan #$scanId…"

        [void]$View.App.StartAsync(
            $View.Context,
            'FindingCatalogue',
            'Refreshing findings catalogue…',
            @{ ScanId = $scanId; Queries = @($queries) },
            {
                param($Ctx)

                $results = @{}
                $errors  = @{}
                foreach ($query in $Ctx.Queries) {
                    try {
                        $row = Invoke-SqliteQuery -DataSource $Ctx.DbPath `
                            -Query $query.CountSql -SqlParameters @{ scan = $Ctx.ScanId } `
                            -ErrorAction Stop
                        $results[$query.Id] = [int]$row.n
                    } catch {
                        $results[$query.Id] = -1
                        $errors[$query.Id] = $_.Exception.Message
                    }
                }

                [pscustomobject]@{
                    Results = $results
                    Errors  = $errors
                }
            },
            $View.ApplyCatalogue,
            'Findings catalogue query failed'
        )
    }
}

$view.LoadDetail = {
    param($View, $Finding)

    $View.SelectedFindingId = [string]$Finding.Id
    $View.Controls.TxtFindingName.Text = [string]$Finding.Name
    $View.Controls.TxtFindingDesc.Text = [string]$Finding.Description
    $View.Controls.GrdDetail.ItemsSource = @()
    $View.Controls.BtnExportCsv.IsEnabled = $false
    $View.Controls.BtnOpenInFolder.IsEnabled = $false
    $View.Controls.BtnCopyPath.IsEnabled = $false
    $View.Controls.BtnSwapPrincipal.IsEnabled = $false

    [void]$View.App.StartAsync(
        $View.Context,
        'FindingDetail',
        "Loading finding: $($Finding.Name)…",
        @{
            ScanId = $View.App.CurrentScanId
            Sql    = [string]$Finding.Query
            Name   = [string]$Finding.Name
        },
        {
            param($Ctx)
            $rows = @(Invoke-SqliteQuery -DataSource $Ctx.DbPath `
                -Query $Ctx.Sql -SqlParameters @{ scan = $Ctx.ScanId })
            [pscustomobject]@{
                Rows = $rows
                Name = $Ctx.Name
            }
        },
        $View.ApplyDetail,
        'Finding detail query failed'
    )
}

$view.ResolveRowPrincipal = {
    param($View, $Row)

    $resolved = $null
    if ($null -ne $Row -and $Row.PSObject.Properties.Match('Sid').Count -gt 0 -and $Row.Sid) {
        $name = [string]$Row.Sid
        foreach ($propertyName in 'Trustee', 'User', 'SAM') {
            if ($Row.PSObject.Properties.Match($propertyName).Count -gt 0 -and $Row.$propertyName) {
                $name = [string]$Row.$propertyName
                break
            }
        }
        $resolved = [pscustomobject]@{
            Sid  = [string]$Row.Sid
            Name = $name
        }
    }
    $resolved
}

$view.RefreshForScan = {
    param($View)
    $View.SelectedFindingId = $null
    & $View.RefreshCatalogue $View
}

$controls.BtnRefresh.Add_Click({
    param($sender, $eventArgs)
    $view = $sender.DataContext
    & $view.RefreshCatalogue $view
})

$controls.LstFindings.Add_SelectionChanged({
    param($sender, $eventArgs)

    $view = $sender.DataContext
    $finding = $sender.SelectedItem
    if ($null -ne $finding) {
        & $view.LoadDetail $view $finding
    }
})

$controls.GrdDetail.Add_SelectionChanged({
    param($sender, $eventArgs)

    $view = $sender.DataContext
    $row = $sender.SelectedItem
    $hasPath = ($null -ne $row) -and
               ($row.PSObject.Properties.Match('Path').Count -gt 0) -and
               (-not [string]::IsNullOrWhiteSpace([string]$row.Path))

    $view.Controls.BtnOpenInFolder.IsEnabled = $hasPath
    $view.Controls.BtnCopyPath.IsEnabled     = $hasPath

    $finding = $view.Controls.LstFindings.SelectedItem
    $principal = & $view.ResolveRowPrincipal $view $row
    $view.Controls.BtnSwapPrincipal.IsEnabled = (
        $null -ne $finding -and $finding.SwapCapable -and $null -ne $principal
    )
})

$controls.BtnCopyPath.Add_Click({
    param($sender, $eventArgs)

    $view = $sender.DataContext
    $row = $view.Controls.GrdDetail.SelectedItem
    if ($null -ne $row -and $row.Path) {
        [System.Windows.Clipboard]::SetText([string]$row.Path)
        $view.App.SetStatus("Copied: $($row.Path)")
    }
})

$controls.BtnOpenInFolder.Add_Click({
    param($sender, $eventArgs)

    $view = $sender.DataContext
    $row = $view.Controls.GrdDetail.SelectedItem
    if ($null -ne $row -and $row.Path) {
        $view.App.NavContext = @{ PathFilter = [string]$row.Path }
        $view.App.Navigate('FolderView')
    }
})

$controls.BtnSwapPrincipal.Add_Click({
    param($sender, $eventArgs)

    $view = $sender.DataContext
    $row = $view.Controls.GrdDetail.SelectedItem
    $principal = & $view.ResolveRowPrincipal $view $row

    if ($null -eq $principal) {
        $view.App.ShowError(
            'Cannot resolve principal',
            'The selected finding did not return a SID. Refresh the finding and try again.'
        )
    } else {
        $context = @{
            SourceSid  = $principal.Sid
            SourceName = $principal.Name
        }
        if ($row.PSObject.Properties.Match('Path').Count -gt 0 -and $row.Path) {
            $context.Scope = [string]$row.Path
        }
        $view.App.NavContext = $context
        $view.App.Navigate('SwapView')
    }
})

$controls.BtnExportCsv.Add_Click({
    param($sender, $eventArgs)

    $view = $sender.DataContext
    $finding = $view.Controls.LstFindings.SelectedItem
    $rows = @($view.Controls.GrdDetail.ItemsSource)
    if ($null -ne $finding -and $rows.Count -gt 0) {
        $dialog = [System.Windows.Forms.SaveFileDialog]::new()
        try {
            $dialog.Filter = 'CSV (*.csv)|*.csv'
            $safeId = ($finding.Id -replace '[\\/:*?"<>|]', '_')
            $dialog.FileName = "Finding_$($safeId)_scan$($view.App.CurrentScanId).csv"

            if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $rows | Export-Csv -NoTypeInformation -Path $dialog.FileName -Encoding UTF8
                $view.App.SetStatus("Exported to $($dialog.FileName)")
            }
        } finally {
            $dialog.Dispose()
        }
    }
})

$Page.Add_Unloaded({
    param($sender, $eventArgs)

    $view = $sender.DataContext
    if ($null -ne $view) {
        $view.App.CancelPageAsync($view.Context, $false)
        $view.Controls.LstFindings.ItemsSource = $null
        $view.Controls.GrdDetail.ItemsSource   = $null
    }
})

& $view.RefreshCatalogue $view
