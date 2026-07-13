[CmdletBinding()]
param(
    [Parameter(Mandatory)] $Page,
    [Parameter(Mandatory)] $App
)

$pageContext = $Page.Tag
if ($null -eq $pageContext) {
    throw 'AccountView was created without a page context.'
}

$controls = $App.GetControls($Page, @(
    'BtnPickPrincipal',
    'TxtPrincipalName',
    'TxtPrincipalType',
    'TxtPathFilter',
    'ChkAllowOnly',
    'ChkExplicitOnly',
    'BtnRefresh',
    'BtnExportCsv',
    'GrdReachable',
    'LstVia',
    'BtnLiveEffective',
    'TxtEffectiveResult'
))

$view = [pscustomobject]@{
    App             = $App
    Context         = $pageContext
    Controls        = $controls
    PrincipalSid    = $null
    PrincipalName   = $null
    PrincipalType   = $null
    MembershipRows  = @()
    LoadReachable   = $null
    ShowViaPane     = $null
    RunLiveEffective = $null
    RefreshForScan  = $null
    ApplyReachable  = $null
    ApplyLiveResult = $null
}
$Page.DataContext  = $view
$pageContext.State = $view

$view.ApplyReachable = {
    param($Payload, $Owner)

    $view = $Owner.State
    $controls = $view.Controls
    $rows = @($Payload.Rows)
    $membershipRows = @($Payload.MembershipRows)

    $viaMap = @{}
    foreach ($membership in $membershipRows) {
        $viaMap[[string]$membership.TrusteeSid] = [pscustomobject]@{
            Name  = if ($membership.TrusteeName) {
                [string]$membership.TrusteeName
            } else {
                [string]$membership.TrusteeSid
            }
            Depth = [int]$membership.Depth
        }
    }

    $shaped = foreach ($row in $rows) {
        $via = $viaMap[[string]$row.TrusteeSid]
        $viaSummary = if ($null -eq $via) {
            [string]$row.TrusteeSid
        } elseif ($via.Depth -eq 0) {
            'directly'
        } else {
            "via $($via.Name) (depth $($via.Depth))"
        }

        [pscustomobject]@{
            FolderId   = [int]$row.FolderId
            Path       = [string]$row.Path
            Rights     = [string]$row.Rights
            AceType    = [string]$row.AceType
            Inherited  = [string]$row.Inherited
            ViaSid     = [string]$row.TrusteeSid
            ViaSummary = $viaSummary
        }
    }

    $view.MembershipRows = $membershipRows
    $controls.GrdReachable.ItemsSource = @($shaped)
    $controls.LstVia.Items.Clear()
    $controls.TxtEffectiveResult.Text = ''
    $controls.BtnLiveEffective.IsEnabled = $false
    $controls.BtnExportCsv.IsEnabled = (@($shaped).Count -gt 0)

    $limitNote = if (@($shaped).Count -ge 20000) { ' (display limit reached)' } else { '' }
    $view.App.SetStatus((
        'Account view: {0:N0} reachable entries for {1}{2}' -f
        @($shaped).Count, $view.PrincipalName, $limitNote
    ))
}

$view.ApplyLiveResult = {
    param($ResultText, $Owner)

    $view = $Owner.State
    $view.Controls.TxtEffectiveResult.Text = [string]$ResultText
}

$view.LoadReachable = {
    param($View)

    $controls = $View.Controls
    $scanId   = $View.App.CurrentScanId

    $View.App.CancelAsync($View.Context, 'AccountLiveEffective')
    $controls.GrdReachable.ItemsSource = @()
    $controls.LstVia.Items.Clear()
    $controls.TxtEffectiveResult.Text = ''
    $controls.BtnLiveEffective.IsEnabled = $false
    $controls.BtnExportCsv.IsEnabled = $false

    if ([string]::IsNullOrWhiteSpace([string]$View.PrincipalSid)) {
        $View.App.CancelAsync($View.Context, 'AccountReachable')
        $View.App.SetStatus('Account view: pick a principal to begin.')
    } elseif ($null -eq $scanId) {
        $View.App.CancelAsync($View.Context, 'AccountReachable')
        $View.App.SetStatus('Account view: no scan selected.')
    } else {
        $workerContext = @{
            ScanId         = $scanId
            PrincipalSid   = [string]$View.PrincipalSid
            PrincipalName  = [string]$View.PrincipalName
            PathFilter     = $controls.TxtPathFilter.Text.Trim()
            AllowOnly      = [bool]$controls.ChkAllowOnly.IsChecked
            ExplicitOnly   = [bool]$controls.ChkExplicitOnly.IsChecked
        }

        [void]$View.App.StartAsync(
            $View.Context,
            'AccountReachable',
            'Loading reachable folders…',
            $workerContext,
            {
                param($Ctx)

                $membershipRows = @(Invoke-SqliteQuery -DataSource $Ctx.DbPath -Query @"
SELECT @sid AS TrusteeSid,
       COALESCE((SELECT name FROM principals WHERE sid = @sid), @principalName) AS TrusteeName,
       0 AS Depth
UNION ALL
SELECT gm.group_sid AS TrusteeSid,
       COALESCE(p.name, gm.group_sid) AS TrusteeName,
       MIN(gm.depth) AS Depth
FROM group_members gm
LEFT JOIN principals p ON p.sid = gm.group_sid
WHERE gm.member_sid = @sid
GROUP BY gm.group_sid, COALESCE(p.name, gm.group_sid)
ORDER BY Depth, TrusteeName
"@ -SqlParameters @{
                    sid           = $Ctx.PrincipalSid
                    principalName = $Ctx.PrincipalName
                })

                $sidList = @($membershipRows | ForEach-Object { [string]$_.TrusteeSid } | Select-Object -Unique)
                $parameters = @{ scan = $Ctx.ScanId }
                $placeholders = for ($index = 0; $index -lt $sidList.Count; $index++) {
                    $key = "sid$index"
                    $parameters[$key] = $sidList[$index]
                    "@$key"
                }

                $where = [System.Collections.Generic.List[string]]::new()
                $where.Add('f.scan_id = @scan')
                $where.Add("a.trustee_sid IN ($($placeholders -join ','))")

                if (-not [string]::IsNullOrWhiteSpace($Ctx.PathFilter)) {
                    $where.Add('f.path LIKE @path')
                    $parameters.path = "%$($Ctx.PathFilter)%"
                }
                if ($Ctx.AllowOnly) {
                    $where.Add("a.access_control_type = 'Allow'")
                }
                if ($Ctx.ExplicitOnly) {
                    $where.Add('a.is_inherited = 0')
                }

                $rows = @(Invoke-SqliteQuery -DataSource $Ctx.DbPath -Query @"
SELECT f.folder_id AS FolderId,
       f.path AS Path,
       a.trustee_sid AS TrusteeSid,
       a.access_control_type AS AceType,
       a.rights_text AS Rights,
       a.rights_mask AS RightsMask,
       CASE a.is_inherited WHEN 1 THEN 'Y' ELSE 'N' END AS Inherited
FROM aces a
JOIN folders f ON f.folder_id = a.folder_id
WHERE $($where -join ' AND ')
ORDER BY f.path, a.access_control_type DESC, a.rights_mask DESC
LIMIT 20000
"@ -SqlParameters $parameters)

                [pscustomobject]@{
                    Rows           = $rows
                    MembershipRows = $membershipRows
                }
            },
            $View.ApplyReachable,
            'Account query failed'
        )
    }
}

$view.ShowViaPane = {
    param($View, $SelectedRow)

    $list = $View.Controls.LstVia
    $list.Items.Clear()

    if ($null -ne $SelectedRow) {
        [void]$list.Items.Add("$($View.PrincipalName)  (selected principal)")

        $sortedMemberships = @($View.MembershipRows |
            Sort-Object -Property @('Depth', 'TrusteeName'))
        foreach ($membership in $sortedMemberships) {
            if ([int]$membership.Depth -gt 0) {
                $marker = if ([string]$membership.TrusteeSid -eq [string]$SelectedRow.ViaSid) {
                    '  ★ ACE-bearing trustee'
                } else {
                    ''
                }
                [void]$list.Items.Add((
                    '  ↳ {0}   [depth {1}]{2}' -f
                    $membership.TrusteeName, $membership.Depth, $marker
                ))
            }
        }

        if ([string]$SelectedRow.ViaSid -eq [string]$View.PrincipalSid) {
            [void]$list.Items.Add('ACE is assigned directly to the selected principal.')
        }
    }
}

$view.RunLiveEffective = {
    param($View)

    $selected = $View.Controls.GrdReachable.SelectedItem
    if ($null -ne $selected) {
        $View.Controls.TxtEffectiveResult.Text = "Querying $($selected.Path)…"

        [void]$View.App.StartAsync(
            $View.Context,
            'AccountLiveEffective',
            'Checking live effective access…',
            @{
                Path = [string]$selected.Path
                Sid  = [string]$View.PrincipalSid
            },
            {
                param($Ctx)

                Import-Module NTFSSecurity -ErrorAction Stop
                $sidObject = [System.Security.Principal.SecurityIdentifier]::new($Ctx.Sid)
                $account = $sidObject.Translate(
                    [System.Security.Principal.NTAccount]
                ).Value

                $effective = Get-NTFSEffectiveAccess -Path $Ctx.Path -Account $account `
                    -ErrorAction Stop | Select-Object -First 1

                if ($null -ne $effective) {
                    "Effective for $account on $($Ctx.Path)`n" +
                    "  Rights:        $($effective.AccessRights)`n" +
                    "  Inherited?     $($effective.IsInherited)`n" +
                    "  Inheritance:   $($effective.InheritanceFlags) / $($effective.PropagationFlags)"
                } else {
                    "No effective access for $account on $($Ctx.Path)."
                }
            },
            $View.ApplyLiveResult,
            'Live effective-access check failed'
        )
    }
}

$view.RefreshForScan = {
    param($View)
    & $View.LoadReachable $View
}

$controls.BtnPickPrincipal.Add_Click({
    param($sender, $eventArgs)

    $view = $sender.DataContext
    $pick = $view.App.PickPrincipal('Pick a principal for Account view')
    if ($null -ne $pick) {
        $view.PrincipalSid  = [string]$pick.Sid
        $view.PrincipalName = [string]$pick.Name
        $view.PrincipalType = [string]$pick.Type
        $view.Controls.TxtPrincipalName.Text = $view.PrincipalName
        $view.Controls.TxtPrincipalType.Text = "[$($view.PrincipalType)]   $($view.PrincipalSid)"
        & $view.LoadReachable $view
    }
})

$controls.BtnRefresh.Add_Click({
    param($sender, $eventArgs)
    $view = $sender.DataContext
    & $view.LoadReachable $view
})

$controls.TxtPathFilter.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.Key -eq [System.Windows.Input.Key]::Return) {
        $view = $sender.DataContext
        & $view.LoadReachable $view
    }
})

foreach ($checkBox in @($controls.ChkAllowOnly, $controls.ChkExplicitOnly)) {
    $checkBox.Add_Click({
        param($sender, $eventArgs)
        $view = $sender.DataContext
        & $view.LoadReachable $view
    })
}

$controls.GrdReachable.Add_SelectionChanged({
    param($sender, $eventArgs)

    $view = $sender.DataContext
    $selected = $sender.SelectedItem
    & $view.ShowViaPane $view $selected
    $view.Controls.BtnLiveEffective.IsEnabled = ($null -ne $selected)
    $view.Controls.TxtEffectiveResult.Text = ''
})

$controls.BtnLiveEffective.Add_Click({
    param($sender, $eventArgs)
    $view = $sender.DataContext
    & $view.RunLiveEffective $view
})

$controls.BtnExportCsv.Add_Click({
    param($sender, $eventArgs)

    $view = $sender.DataContext
    $rows = @($view.Controls.GrdReachable.ItemsSource)
    if ($rows.Count -gt 0) {
        $dialog = [System.Windows.Forms.SaveFileDialog]::new()
        try {
            $dialog.Filter = 'CSV (*.csv)|*.csv'
            $safeName = ($view.PrincipalName -replace '[\\/:*?"<>|]', '_')
            $dialog.FileName = "AccountView_$($safeName)_scan$($view.App.CurrentScanId).csv"

            if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $rows |
                    Select-Object -Property @('Path', 'Rights', 'AceType', 'Inherited', 'ViaSummary') |
                    Export-Csv -NoTypeInformation -Path $dialog.FileName -Encoding UTF8
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
        $view.Controls.GrdReachable.ItemsSource = $null
        $view.Controls.LstVia.Items.Clear()
    }
})

$controls.BtnExportCsv.IsEnabled = $false
$App.SetStatus('Account view: pick a principal to begin.')
