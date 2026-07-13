[CmdletBinding()]
param(
    [Parameter(Mandatory)] $Page,
    [Parameter(Mandatory)] $App
)

$pageContext = $Page.Tag
if ($null -eq $pageContext) {
    throw 'FolderView was created without a page context.'
}

$controls = $App.GetControls($Page, @(
    'TxtPathFilter',
    'ChkBrokenOnly',
    'ChkExplicitOnly',
    'BtnRefresh',
    'BtnExportCsv',
    'GrdFolders',
    'GrdAces'
))

# DataContext keeps one durable reference to everything this page needs. Event
# handlers retrieve it from their sender instead of depending on script scope.
$view = [pscustomobject]@{
    App            = $App
    Context        = $pageContext
    Controls       = $controls
    LoadFolders    = $null
    LoadAces       = $null
    RefreshForScan = $null
    ApplyFolders   = $null
    ApplyAces      = $null
    ExportSql      = $null
    ExportParams   = $null
}
$Page.DataContext  = $view
$pageContext.State = $view

$view.ApplyFolders = {
    param($Rows, $Owner)

    $view = $Owner.State
    # A zero-row query must remain an empty collection. Filtering nulls also
    # protects the DataGrid from malformed provider output being treated as a
    # selectable blank row.
    $items = @($Rows | Where-Object { $null -ne $_ })
    $view.Controls.GrdFolders.ItemsSource = $items
    $view.Controls.GrdAces.ItemsSource    = @()
    $view.Controls.BtnExportCsv.IsEnabled = ($items.Count -gt 0)
    $view.App.SetStatus(("Folder view: {0:N0} rows" -f $items.Count))
}

$view.ApplyAces = {
    param($Rows, $Owner)

    $view = $Owner.State
    $view.Controls.GrdAces.ItemsSource = @($Rows | Where-Object { $null -ne $_ })
}

$view.LoadFolders = {
    param($View)

    $controls = $View.Controls
    $scanId   = $View.App.CurrentScanId

    $View.App.CancelAsync($View.Context, 'FolderAces')
    $controls.GrdAces.ItemsSource = @()

    if ($null -eq $scanId) {
        $View.App.CancelAsync($View.Context, 'FolderList')
        $controls.GrdFolders.ItemsSource = @()
        $controls.BtnExportCsv.IsEnabled = $false
        $View.App.SetStatus('Folder view: no scan selected.')
    } else {
        $where      = [System.Collections.Generic.List[string]]::new()
        $parameters = @{ scan = $scanId }
        $where.Add('f.scan_id = @scan')

        $pathFilter = $controls.TxtPathFilter.Text.Trim()
        if ($pathFilter.Length -gt 0) {
            $where.Add('f.path LIKE @path')
            $parameters.path = "%$pathFilter%"
        }
        if ($controls.ChkBrokenOnly.IsChecked) {
            $where.Add('f.inheritance_enabled = 0')
        }
        if ($controls.ChkExplicitOnly.IsChecked) {
            $where.Add('f.explicit_ace_count > 0')
        }

        $sql = @"
SELECT f.folder_id AS FolderId,
       f.path AS Path,
       CASE f.inheritance_enabled WHEN 1 THEN 'Y' ELSE 'N' END AS Inh,
       f.explicit_ace_count AS Explicit
FROM folders f
WHERE $($where -join ' AND ')
ORDER BY f.path
LIMIT 5000
"@

        # Export the same filtered folder set, flattened with the trustee detail.
        # Scan roots and broken folders produce one row per ACE. Inherited child
        # folders start with a parent-reference row, followed by every explicit ACE.
        $View.ExportSql = @"
WITH selected_folders AS (
    SELECT f.folder_id, f.path, f.parent_id, f.depth, f.inheritance_enabled, f.explicit_ace_count
    FROM folders f
    WHERE $($where -join ' AND ')
    ORDER BY f.path
    LIMIT 5000
), detail_rows AS (
    SELECT sf.folder_id, sf.path, sf.inheritance_enabled, sf.explicit_ace_count,
           a.trustee_sid, COALESCE(p.name, a.trustee_sid) AS trustee,
           a.access_control_type, a.rights_text, a.is_inherited, a.inherited_from,
           1 AS row_order
    FROM selected_folders sf
    JOIN aces a ON a.folder_id = sf.folder_id
               AND (sf.depth = 0 OR sf.inheritance_enabled = 0 OR a.is_inherited = 0)
    LEFT JOIN principals p ON p.sid = a.trustee_sid
), parent_rows AS (
    SELECT sf.folder_id, sf.path, sf.inheritance_enabled, sf.explicit_ace_count,
           NULL AS trustee_sid, 'Inherited from parent' AS trustee,
           NULL AS access_control_type, NULL AS rights_text, 1 AS is_inherited,
           parent.path AS inherited_from, 0 AS row_order
    FROM selected_folders sf
    LEFT JOIN folders parent ON parent.folder_id = sf.parent_id
    WHERE sf.depth > 0 AND sf.inheritance_enabled = 1
), export_rows AS (
    SELECT * FROM parent_rows
    UNION ALL
    SELECT * FROM detail_rows
)
SELECT er.path AS Path,
       CASE er.inheritance_enabled WHEN 1 THEN 'Y' ELSE 'N' END AS Inh,
       er.explicit_ace_count AS Explicit,
       er.trustee AS Trustee,
       er.trustee_sid AS Sid,
       er.access_control_type AS AceType,
       er.rights_text AS Rights,
       CASE er.is_inherited WHEN 1 THEN 'Y' ELSE 'N' END AS Inherited,
       CASE WHEN LOWER(COALESCE(er.inherited_from, '')) LIKE '%unknown paren%'
            THEN 'Parent out of scope'
            ELSE COALESCE(er.inherited_from, '') END AS InheritedFrom
FROM export_rows er
ORDER BY er.path, er.row_order, er.is_inherited, er.trustee
"@
        $View.ExportParams = $parameters.Clone()

        $controls.GrdFolders.ItemsSource = @()
        $controls.BtnExportCsv.IsEnabled = $false

        [void]$View.App.StartAsync(
            $View.Context,
            'FolderList',
            'Loading folders…',
            @{ Sql = $sql; Params = $parameters },
            {
                param($Ctx)
                Invoke-SqliteQuery -DataSource $Ctx.DbPath `
                    -Query $Ctx.Sql -SqlParameters $Ctx.Params
            },
            $View.ApplyFolders,
            'Folder query failed'
        )
    }
}

$view.LoadAces = {
    param($View, [int]$FolderId)

    $sql = @"
SELECT COALESCE(p.name, a.trustee_sid) AS Trustee,
       a.trustee_sid AS Sid,
       a.access_control_type AS AceType,
       a.rights_text AS Rights,
       CASE a.is_inherited WHEN 1 THEN 'Y' ELSE 'N' END AS Inherited,
       CASE WHEN LOWER(COALESCE(a.inherited_from, '')) LIKE '%unknown paren%'
            THEN 'Parent out of scope'
            ELSE COALESCE(a.inherited_from, '') END AS InheritedFrom
FROM aces a
LEFT JOIN principals p ON p.sid = a.trustee_sid
WHERE a.folder_id = @folder
ORDER BY a.is_inherited, Trustee
"@

    $View.Controls.GrdAces.ItemsSource = @()
    [void]$View.App.StartAsync(
        $View.Context,
        'FolderAces',
        'Loading ACEs…',
        @{ Sql = $sql; Params = @{ folder = $FolderId } },
        {
            param($Ctx)
            Invoke-SqliteQuery -DataSource $Ctx.DbPath `
                -Query $Ctx.Sql -SqlParameters $Ctx.Params
        },
        $View.ApplyAces,
        'ACE query failed'
    )
}

$view.RefreshForScan = {
    param($View)
    & $View.LoadFolders $View
}

$controls.BtnRefresh.Add_Click({
    param($sender, $eventArgs)
    $view = $sender.DataContext
    & $view.LoadFolders $view
})

$controls.TxtPathFilter.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.Key -eq [System.Windows.Input.Key]::Return) {
        $view = $sender.DataContext
        & $view.LoadFolders $view
    }
})

foreach ($checkBox in @($controls.ChkBrokenOnly, $controls.ChkExplicitOnly)) {
    $checkBox.Add_Click({
        param($sender, $eventArgs)
        $view = $sender.DataContext
        & $view.LoadFolders $view
    })
}

$controls.GrdFolders.Add_SelectionChanged({
    param($sender, $eventArgs)

    $view = $sender.DataContext
    $selected = $sender.SelectedItem
    if ($null -ne $selected) {
        & $view.LoadAces $view ([int]$selected.FolderId)
    } else {
        $view.App.CancelAsync($view.Context, 'FolderAces')
        $view.Controls.GrdAces.ItemsSource = @()
    }
})

$controls.BtnExportCsv.Add_Click({
    param($sender, $eventArgs)

    $view = $sender.DataContext
    $rows = @($view.Controls.GrdFolders.ItemsSource)
    if ($rows.Count -gt 0) {
        $dialog = [System.Windows.Forms.SaveFileDialog]::new()
        try {
            $dialog.Filter   = 'CSV (*.csv)|*.csv'
            $dialog.FileName = "FolderView_scan$($view.App.CurrentScanId).csv"
            if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $exportRows = @($view.App.Query($view.ExportSql, $view.ExportParams))
                $exportRows | Export-Csv -NoTypeInformation -Path $dialog.FileName -Encoding UTF8
                $view.App.SetStatus("Exported to $($dialog.FileName)")
            }
        } catch {
            $view.App.ShowError('Folder CSV export failed', $_.Exception.Message, $_.Exception.ToString(), 'Folder view export')
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
        $view.Controls.GrdFolders.ItemsSource = $null
        $view.Controls.GrdAces.ItemsSource    = $null
    }
})

# Preserve the Findings -> Folder drill-through feature.
$navigationContext = $App.NavContext
if ($null -ne $navigationContext -and $navigationContext.PathFilter) {
    $controls.TxtPathFilter.Text = [string]$navigationContext.PathFilter
    $App.NavContext = $null
}

& $view.LoadFolders $view
