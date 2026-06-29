[CmdletBinding()]
param(
    [Parameter(Mandatory)] $Page,
    [Parameter(Mandatory)] $App
)

# Controls
$btnPick           = $Page.FindName('BtnPickPrincipal')
$txtPrincipalName  = $Page.FindName('TxtPrincipalName')
$txtPrincipalType  = $Page.FindName('TxtPrincipalType')
$txtPathFilter     = $Page.FindName('TxtPathFilter')
$chkAllowOnly      = $Page.FindName('ChkAllowOnly')
$chkExplicitOnly   = $Page.FindName('ChkExplicitOnly')
$btnRefresh        = $Page.FindName('BtnRefresh')
$btnExport         = $Page.FindName('BtnExportCsv')
$grdReachable      = $Page.FindName('GrdReachable')
$lstVia            = $Page.FindName('LstVia')
$btnLive           = $Page.FindName('BtnLiveEffective')
$txtEffective      = $Page.FindName('TxtEffectiveResult')

# Page state
$state = [pscustomobject]@{
    PrincipalSid  = $null
    PrincipalName = $null
    PrincipalType = $null
}

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

$buildViaQuery = {
    # Returns rows: trustee_sid (the ACE-bearing SID), trustee_name, depth
    # — every SID through which the principal inherits this folder's ACEs.
    param([string]$Sid)
    $App.Query(@"
        -- self
        SELECT @sid AS trustee_sid, p.name AS trustee_name, 0 AS depth
          FROM principals p WHERE p.sid = @sid
        UNION
        SELECT gm.group_sid AS trustee_sid, p.name AS trustee_name, gm.depth
          FROM group_members gm
          LEFT JOIN principals p ON p.sid = gm.group_sid
         WHERE gm.member_sid = @sid
"@, @{ sid = $Sid })
}.GetNewClosure()

$loadReachable = {
    if (-not $state.PrincipalSid)  { return }
    if (-not $App.CurrentScanId)   { return }

    try {
        # 1. The set of SIDs whose ACEs grant access to this principal
        $viaRows = & $buildViaQuery $state.PrincipalSid
        if (-not $viaRows) {
            $grdReachable.ItemsSource = @()
            $App.SetStatus("No membership chain for $($state.PrincipalName).")
            return
        }

        # Map sid -> name for the "via" column
        $viaMap = @{}
        foreach ($r in $viaRows) {
            $viaMap[$r.trustee_sid] = @{
                Name  = if ($r.trustee_name) { $r.trustee_name } else { $r.trustee_sid }
                Depth = [int]$r.depth
            }
        }
        $sidList = @($viaMap.Keys)

        # 2. Build parameterised IN-clause
        $sidParams = @{}
        $placeholders = for ($i = 0; $i -lt $sidList.Count; $i++) {
            $key = "sid$i"
            $sidParams[$key] = $sidList[$i]
            "@$key"
        }
        $sidParams.scan = $App.CurrentScanId

        $where = @(
            "f.scan_id = @scan"
            "a.trustee_sid IN ($($placeholders -join ','))"
        )
        if ($txtPathFilter.Text.Trim()) {
            $where += "f.path LIKE @path"
            $sidParams.path = "%$($txtPathFilter.Text.Trim())%"
        }
        if ($chkAllowOnly.IsChecked)    { $where += "a.access_control_type = 'Allow'" }
        if ($chkExplicitOnly.IsChecked) { $where += "a.is_inherited = 0" }

        $sql = @"
            SELECT f.folder_id            AS FolderId,
                   f.path                 AS Path,
                   a.trustee_sid          AS TrusteeSid,
                   a.access_control_type  AS AceType,
                   a.rights_text          AS Rights,
                   a.rights_mask          AS RightsMask,
                   CASE a.is_inherited WHEN 1 THEN 'Y' ELSE 'N' END AS Inherited
            FROM aces a
            JOIN folders f ON f.folder_id = a.folder_id
            WHERE $($where -join ' AND ')
            ORDER BY f.path, a.access_control_type DESC, a.rights_mask DESC
            LIMIT 20000
"@
        $rows = $App.Query($sql, $sidParams)

        # 3. Collapse to one row per (folder, ACE) and add the Via summary
        $shaped = foreach ($r in $rows) {
            $via = $viaMap[$r.TrusteeSid]
            $viaSummary =
                if ($null -eq $via)            { $r.TrusteeSid }
                elseif ($via.Depth -eq 0)      { 'directly' }
                else                            { "via $($via.Name) (depth $($via.Depth))" }
            [pscustomobject]@{
                FolderId    = [int]$r.FolderId
                Path        = $r.Path
                Rights      = $r.Rights
                AceType     = $r.AceType
                Inherited   = $r.Inherited
                ViaSid      = $r.TrusteeSid
                ViaSummary  = $viaSummary
            }
        }

        $grdReachable.ItemsSource = @($shaped)
        $App.SetStatus(("Account view: {0:N0} reachable entries for {1}" -f @($shaped).Count, $state.PrincipalName))
    }
    catch {
        $App.ShowError('Account view query failed', $_.Exception.Message)
    }
}.GetNewClosure()

# Show the full membership chain for the selected row's trustee SID
$loadViaPane = {
    param([string]$ViaSid)

    $lstVia.Items.Clear()
    if (-not $ViaSid) { return }

    # Walk *up* from the principal to the via SID, showing the shortest path.
    # We don't store the full path; we infer "principal -> ... -> via" by
    # listing every intermediate group whose depth is between 0 and Via.Depth
    # and which contains the principal transitively.
    $rows = $App.Query(@"
        SELECT p.name AS name, p.principal_type AS type, gm.depth AS depth
          FROM group_members gm
          JOIN principals p ON p.sid = gm.group_sid
         WHERE gm.member_sid = @sid
           AND gm.group_sid IN (
                 SELECT group_sid FROM group_members WHERE member_sid = @sid
           )
         ORDER BY gm.depth
"@, @{ sid = $state.PrincipalSid })

    [void]$lstVia.Items.Add("$($state.PrincipalName)  (you)")
    foreach ($r in $rows) {
        if ($r.name -eq $null) { continue }
        [void]$lstVia.Items.Add(("  ↳ $($r.name)   [$($r.type), depth $($r.depth)]"))
        if ($r.depth -ge 8) { [void]$lstVia.Items.Add('  …(truncated)'); break }
    }

    if ($ViaSid -ne $state.PrincipalSid) {
        # The ACE-bearing SID itself, in case it wasn't a group the principal
        # transitively belongs to (rare — usually means a Deny on the user directly)
        $bearer = $App.Query("SELECT name, principal_type AS type FROM principals WHERE sid=@s", @{ s = $ViaSid })
        if ($bearer) {
            [void]$lstVia.Items.Add(("ACE on:  $($bearer.name)   [$($bearer.type)]"))
        }
    }
}.GetNewClosure()

# Live effective access — defers the hard problem to Microsoft
$runLiveEffective = {
    if (-not $grdReachable.SelectedItem) { return }
    $path = $grdReachable.SelectedItem.Path
    $sid  = $state.PrincipalSid

    $txtEffective.Text = "Querying $path …"

    try {
        # Translate SID to NT account for Get-NTFSEffectiveAccess
        $nt = ([System.Security.Principal.SecurityIdentifier]::new($sid)).Translate(
              [System.Security.Principal.NTAccount]).Value

        Import-Module NTFSSecurity -ErrorAction Stop
        $eff = Get-NTFSEffectiveAccess -Path $path -Account $nt -ErrorAction Stop |
               Select-Object -First 1

        if ($eff) {
            $txtEffective.Text =
                "Effective for $nt on $path`n" +
                "  Rights:        $($eff.AccessRights)`n" +
                "  Inherited?     $($eff.IsInherited)`n" +
                "  Inheritance:   $($eff.InheritanceFlags) / $($eff.PropagationFlags)"
        } else {
            $txtEffective.Text = "No effective access for $nt on $path."
        }
    }
    catch {
        $txtEffective.Text = "Live check failed: $($_.Exception.Message)"
    }
}.GetNewClosure()

# -----------------------------------------------------------------------------
# Event wiring
# -----------------------------------------------------------------------------

$btnPick.Add_Click({
    $pick = $App.PickPrincipal('Pick a principal for Account view')
    if (-not $pick) { return }
    $state.PrincipalSid  = $pick.Sid
    $state.PrincipalName = $pick.Name
    $state.PrincipalType = $pick.Type
    $txtPrincipalName.Text = $pick.Name
    $txtPrincipalType.Text = "[$($pick.Type)]   $($pick.Sid)"
    $lstVia.Items.Clear()
    $txtEffective.Text = ""
    $btnLive.IsEnabled = $false
    & $loadReachable
}.GetNewClosure())

$btnRefresh.Add_Click($loadReachable)
$txtPathFilter.Add_KeyDown({ if ($_.Key -eq 'Return') { & $loadReachable } }.GetNewClosure())
$chkAllowOnly.Add_Click($loadReachable)
$chkExplicitOnly.Add_Click($loadReachable)

$grdReachable.Add_SelectionChanged({
    if ($grdReachable.SelectedItem) {
        & $loadViaPane $grdReachable.SelectedItem.ViaSid
        $btnLive.IsEnabled = $true
        $txtEffective.Text = ""
    } else {
        $lstVia.Items.Clear()
        $btnLive.IsEnabled = $false
        $txtEffective.Text = ""
    }
}.GetNewClosure())

$btnLive.Add_Click($runLiveEffective)

$btnExport.Add_Click({
    if (-not $grdReachable.ItemsSource) { return }
    $dlg = [System.Windows.Forms.SaveFileDialog]::new()
    $dlg.Filter   = 'CSV (*.csv)|*.csv'
    $safe = ($state.PrincipalName -replace '[\\/:*?"<>|]', '_')
    $dlg.FileName = "AccountView_$($safe)_scan$($App.CurrentScanId).csv"
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        @($grdReachable.ItemsSource) |
            Select-Object Path, Rights, AceType, Inherited, ViaSummary |
            Export-Csv -NoTypeInformation -Path $dlg.FileName -Encoding UTF8
        $App.SetStatus("Exported to $($dlg.FileName)")
    }
}.GetNewClosure())