[CmdletBinding()]
param(
    [Parameter(Mandatory)] $Page,
    [Parameter(Mandatory)] $App
)

# Resolve controls
$txtFilter   = $Page.FindName('TxtPathFilter')
$chkBroken   = $Page.FindName('ChkBrokenOnly')
$chkExplicit = $Page.FindName('ChkExplicitOnly')
$btnRefresh  = $Page.FindName('BtnRefresh')
$btnExport   = $Page.FindName('BtnExportCsv')
$grdFolders  = $Page.FindName('GrdFolders')
$grdAces     = $Page.FindName('GrdAces')

$loadFolders = {
    if (-not $App.CurrentScanId) { return }

    $where  = @("f.scan_id = @scan")
    $params = @{ scan = $App.CurrentScanId }

    if ($txtFilter.Text.Trim()) {
        $where += "f.path LIKE @path"
        $params.path = "%$($txtFilter.Text.Trim())%"
    }
    if ($chkBroken.IsChecked)   { $where += "f.inheritance_enabled = 0" }
    if ($chkExplicit.IsChecked) { $where += "f.explicit_ace_count > 0" }

    $sql = @"
        SELECT f.folder_id           AS FolderId,
               f.path                AS Path,
               CASE f.inheritance_enabled WHEN 1 THEN 'Y' ELSE 'N' END AS Inh,
               f.explicit_ace_count  AS Explicit
        FROM folders f
        WHERE $($where -join ' AND ')
        ORDER BY f.path
        LIMIT 5000
"@
    try {
        $rows = $App.Query($sql, $params)
        $grdFolders.ItemsSource = @($rows)
        $App.SetStatus(("Folder view: {0:N0} rows" -f @($rows).Count))
    } catch {
        $App.ShowError('Folder view query failed', $_.Exception.Message)
    }
}.GetNewClosure()

$loadAces = {
    param([int]$FolderId)
    try {
        $rows = $App.Query(@"
            SELECT COALESCE(p.name, a.trustee_sid) AS Trustee,
                   a.access_control_type           AS AceType,
                   a.rights_text                   AS Rights,
                   CASE a.is_inherited WHEN 1 THEN 'Y' ELSE 'N' END AS Inherited,
                   COALESCE(a.inherited_from, '')  AS InheritedFrom
            FROM aces a
            LEFT JOIN principals p ON p.sid = a.trustee_sid
            WHERE a.folder_id = @f
            ORDER BY a.is_inherited, Trustee
"@, @{ f = $FolderId })
        $grdAces.ItemsSource = @($rows)
    } catch {
        $App.ShowError('ACE query failed', $_.Exception.Message)
    }
}.GetNewClosure()

$btnRefresh.Add_Click($loadFolders)

$txtFilter.Add_KeyDown({
    if ($_.Key -eq 'Return') { & $loadFolders }
}.GetNewClosure())

$chkBroken.Add_Click($loadFolders)
$chkExplicit.Add_Click($loadFolders)

$grdFolders.Add_SelectionChanged({
    if ($grdFolders.SelectedItem) {
        & $loadAces ([int]$grdFolders.SelectedItem.FolderId)
    } else {
        $grdAces.ItemsSource = @()
    }
}.GetNewClosure())

$btnExport.Add_Click({
    if (-not $grdFolders.ItemsSource) { return }
    $dlg = [System.Windows.Forms.SaveFileDialog]::new()
    $dlg.Filter   = 'CSV (*.csv)|*.csv'
    $dlg.FileName = "FolderView_scan$($App.CurrentScanId).csv"
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        @($grdFolders.ItemsSource) |
            Export-Csv -NoTypeInformation -Path $dlg.FileName -Encoding UTF8
        $App.SetStatus("Exported to $($dlg.FileName)")
    }
}.GetNewClosure())

# Initial load
& $loadFolders