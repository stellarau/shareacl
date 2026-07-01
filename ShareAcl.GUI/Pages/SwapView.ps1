[CmdletBinding()]
param(
    [Parameter(Mandatory)] $Page,
    [Parameter(Mandatory)] $App
)

# Controls
$txtSource         = $Page.FindName('TxtSource')
$txtTarget         = $Page.FindName('TxtTarget')
$txtScope          = $Page.FindName('TxtScope')
$btnPickSource     = $Page.FindName('BtnPickSource')
$btnPickTarget     = $Page.FindName('BtnPickTarget')
$btnBrowseScope    = $Page.FindName('BtnBrowseScope')
$chkIncludeFiles   = $Page.FindName('ChkIncludeFiles')
$chkSkipReparse    = $Page.FindName('ChkSkipReparse')
$chkOverrideGuard  = $Page.FindName('ChkOverrideGuard')
$rbModeScan        = $Page.FindName('RbModeScan')
$rbModeLive        = $Page.FindName('RbModeLive')

$btnPreview        = $Page.FindName('BtnPreview')
$btnExecute        = $Page.FindName('BtnExecute')
$btnVerify         = $Page.FindName('BtnVerify')
$txtPreviewStatus  = $Page.FindName('TxtPreviewStatus')
$txtConfirm        = $Page.FindName('TxtConfirm')

$grdPreview        = $Page.FindName('GrdPreview')
$txtPreviewSummary = $Page.FindName('TxtPreviewSummary')
$grdExecute        = $Page.FindName('GrdExecute')
$pbExecute         = $Page.FindName('PbExecute')
$grdVerify         = $Page.FindName('GrdVerify')
$txtVerifySummary  = $Page.FindName('TxtVerifySummary')
# $txtStatus         = $Page.FindName('TxtStatus') -- replaced by App.SetStatus()

# Page state
$state = [pscustomobject]@{
    Source         = $null        # @{ Sid; Name; Type }
    Target         = $null        # @{ Sid; Name; Type }
    Scope          = $null
    PreviewRows    = @()
    PreviewHash    = $null        # invalidated whenever any input changes
    LastExecuteRoot = $null
    DiscoveryMode  = $null        # 'scan' or 'live'
    AuditPath      = (Join-Path $PSScriptRoot '..\Logs\swap-audit.jsonl' |
                       ForEach-Object { [System.IO.Path]::GetFullPath($_) })
}

# Ensure audit dir exists
$auditDir = Split-Path $state.AuditPath -Parent
if (-not (Test-Path $auditDir)) { New-Item -ItemType Directory -Path $auditDir -Force | Out-Null }

# Well-known SIDs that we refuse to substitute without the override
$wellKnownDangerous = @(
    'S-1-5-18',           # LOCAL SYSTEM
    'S-1-5-32-544',       # BUILTIN\Administrators
    'S-1-3-0',            # CREATOR OWNER
    'S-1-1-0',            # Everyone
    'S-1-5-11'            # Authenticated Users
)

# -----------------------------------------------------------------------------
# Helpers (as closure scriptblocks — page scope dies after script returns)
# -----------------------------------------------------------------------------

$testInputsReady = {
    if (-not $state.Source) { return $false }
    if (-not $state.Target) { return $false }
    if (-not $txtScope.Text.Trim()) { return $false }
    if ($state.Source.Sid -eq $state.Target.Sid) { return $false }
    return $true
}.GetNewClosure()

$invalidatePreview = {
    $state.PreviewHash = $null
    $btnExecute.IsEnabled = $false
    $btnVerify.IsEnabled  = $false
    $txtPreviewStatus.Text = '(preview required before execute)'
}.GetNewClosure()

$computeInputHash = {
    $key = "$($state.Source.Sid)|$($state.Target.Sid)|$($txtScope.Text.Trim())|" +
           "$($chkIncludeFiles.IsChecked)|$($chkSkipReparse.IsChecked)|$($chkOverrideGuard.IsChecked)"
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try {
        ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($key)) |
            ForEach-Object { '{0:x2}' -f $_ }) -join ''
    } finally { $sha.Dispose() }
}.GetNewClosure()

$writeAudit = {
    param([hashtable]$Record)
    $Record['ts']       = [System.DateTime]::UtcNow.ToString('o')
    $Record['operator'] = "$env:USERDOMAIN\$env:USERNAME"
    $Record['host']     = $env:COMPUTERNAME
    $line = ($Record | ConvertTo-Json -Compress)
    Add-Content -Path $state.AuditPath -Value $line -Encoding UTF8
}.GetNewClosure()

$testPathIsDangerousRoot = {
    param([string]$Path)
    $trimmed = $Path.TrimEnd('\','/').ToLowerInvariant()
    if ($trimmed -match '^[a-z]:$')                              { return $true }   # drive root: "C:"
    if ($trimmed -match '^\\\\[^\\]+\\[^\\]+$')                  { return $true }   # share root: "\\fs01\share"
    if ($trimmed -in @('c:\windows','c:\program files','c:\program files (x86)','c:\users','c:\programdata')) { return $true }
    return $false
}.GetNewClosure()

$getAceSid = {
    param($Ace)

    # 1. Direct SID access — works for most clean ACEs
    try {
        if ($Ace.Account -and $Ace.Account.Sid -and $Ace.Account.Sid.Value) {
            return [string]$Ace.Account.Sid.Value
        }
    } catch { }

    # 2. AccountName / ToString may already be a raw SID string for orphaned trustees
    $name = $null
    try { $name = [string]$Ace.Account.AccountName } catch { }
    if (-not $name) { try { $name = [string]$Ace.Account } catch { } }

    if ($name -match '^S-1-\d+(-\d+)+$') { return $name }

    # 3. Translate the NT account name back to a SID
    if ($name) {
        try {
            $nt  = [System.Security.Principal.NTAccount]::new($name)
            $sid = $nt.Translate([System.Security.Principal.SecurityIdentifier])
            return [string]$sid.Value
        } catch { }
    }

    return $null
}.GetNewClosure()

# -----------------------------------------------------------------------------
# Preview
# -----------------------------------------------------------------------------

# --- Scan-based discovery (the existing logic, refactored into its own closure) ---
$runPreviewFromScan = {
    if (-not $App.CurrentScanId) {
        $App.ShowError('No scan loaded',
            'Select a scan from the dropdown, or switch discovery mode to "Live walk".')
        return
    }

    $sourceSid = $state.Source.Sid
    $targetSid = $state.Target.Sid

    try {
        $rows = $App.Query(@"
        SELECT f.folder_id AS FolderId,
            f.path      AS Path,
            CASE f.inheritance_enabled WHEN 1 THEN 'Y' ELSE 'N' END AS Inh,
            COUNT(*)    AS AceCount,
            GROUP_CONCAT(a.access_control_type || ' ' || a.rights_text, '; ') AS SourceRights
        FROM aces a
        JOIN folders f ON f.folder_id = a.folder_id
        WHERE f.scan_id = @scan
        AND a.trustee_sid = @sid
        AND f.path LIKE @scope
        GROUP BY f.folder_id, f.path, f.inheritance_enabled
        ORDER BY f.path
"@, @{
            scan  = $App.CurrentScanId
            sid   = $sourceSid
            scope = ($txtScope.Text.TrimEnd('\') + '%')
        })
    } catch {
        $App.ShowError('Preview query failed', $_.Exception.Message)
        return
    }

    if (-not $rows -or @($rows).Count -eq 0) {
        $txtPreviewSummary.Text = "Scan #$($App.CurrentScanId): no ACEs reference $($state.Source.Name) under $($txtScope.Text)."
        $grdPreview.ItemsSource = @()
        & $invalidatePreview
        $App.SetStatus("Preview (scan): 0 affected folders")
        return
    }

    $shaped = foreach ($r in $rows) {
        [pscustomobject]@{
            FolderId = [int]$r.FolderId
            Path     = $r.Path
            Inh      = $r.Inh
            AceCount = [int]$r.AceCount
            SourceRights = $r.SourceRights
        }
    }

    $state.PreviewRows   = @($shaped)
    $state.PreviewHash   = & $computeInputHash
    $state.DiscoveryMode = 'scan'

    $grdPreview.ItemsSource = @($shaped)
    $totalAces = ($shaped | Measure-Object AceCount -Sum).Sum
    $txtPreviewSummary.Text =
        "Source: scan #$($App.CurrentScanId). Would replace $($state.Source.Name) with $($state.Target.Name) " +
        "on $($shaped.Count) folder(s), affecting $totalAces ACE(s). " +
        "Execute re-checks the live filesystem and will report drift if any."
    $txtPreviewStatus.Text = "Preview ready (scan) · type APPLY to enable Execute"
    $btnExecute.IsEnabled = $false
    $App.SetStatus("Preview (scan): $($shaped.Count) folders, $totalAces ACEs")

    & $writeAudit @{
        event = 'preview'; mode = 'scan'
        sourceSid = $sourceSid; sourceName = $state.Source.Name
        targetSid = $targetSid; targetName = $state.Target.Name
        scope = $txtScope.Text; folderCount = $shaped.Count
        aceCount = $totalAces; inputHash = $state.PreviewHash
    }
}.GetNewClosure()

# --- Live filesystem walk (new) ---
$runPreviewLive = {
    $scope     = $txtScope.Text.Trim()
    $sourceSid = $state.Source.Sid
    $targetSid = $state.Target.Sid

    if (-not (Test-Path -LiteralPath $scope)) {
        $App.ShowError('Scope not accessible', "Cannot access: $scope")
        return
    }

    try { Import-Module NTFSSecurity -ErrorAction Stop }
    catch {
        $App.ShowError('NTFSSecurity unavailable', $_.Exception.Message)
        return
    }

    $txtPreviewSummary.Text = "Walking $scope for explicit ACEs referencing $($state.Source.Name)…"
    $grdPreview.ItemsSource = @()
    $App.SetStatus("Live walk starting…")
    $Page.Dispatcher.Invoke([Action]{}, 'Background')

    $found        = New-Object System.Collections.ArrayList
    $folderCount  = 0
    $errorCount   = 0
    $skipReparse  = [bool]$chkSkipReparse.IsChecked

    $queue = [System.Collections.Generic.Queue[string]]::new()
    $queue.Enqueue($scope)

    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        $folderCount++

        $isReparse = $false
        try {
            $attr = (Get-Item -LiteralPath $current -Force -ErrorAction Stop).Attributes
            $isReparse = [bool]($attr -band [System.IO.FileAttributes]::ReparsePoint)
        } catch { }

        if (-not ($skipReparse -and $isReparse)) {
            try {
                $aces = Get-NTFSAccess -Path $current -ExcludeInherited:$true -ErrorAction Stop
                $matching = @($aces | Where-Object { (& $getAceSid $_) -eq $sourceSid })
                if ($matching.Count -gt 0) {
                    $inhStr = 'Y'
                    try {
                        $inh = Get-NTFSInheritance -Path $current -ErrorAction Stop
                        if (-not $inh.AccessInheritanceEnabled) { $inhStr = 'N' }
                    } catch { }

                    
                    $rightsSummary = ($matching |
                        ForEach-Object { "$($_.AccessControlType) $($_.AccessRights)" }) -join '; '

                    [void]$found.Add([pscustomobject]@{
                        FolderId = $null
                        Path     = $current
                        Inh      = $inhStr
                        AceCount = $matching.Count
                        SourceRights = $rightsSummary
                    })
                }
            } catch {
                $errorCount++
            }
        }

        if (-not ($skipReparse -and $isReparse)) {
            try {
                Get-ChildItem -LiteralPath $current -Directory -Force -ErrorAction Stop |
                    ForEach-Object { $queue.Enqueue($_.FullName) }
            } catch {
                $errorCount++
            }
        }

        # Pump the UI every 25 folders so the operator sees progress
        if (($folderCount % 25) -eq 0) {
            $App.SetStatus("Live walk: $folderCount folder(s) scanned, $($found.Count) hit(s), $errorCount error(s)")
            $Page.Dispatcher.Invoke([Action]{}, 'Background')
        }
    }

    if ($found.Count -eq 0) {
        $txtPreviewSummary.Text = "Live walk of $scope (scanned $folderCount folder(s)): no explicit ACEs reference $($state.Source.Name). $errorCount enumeration error(s)."
        $grdPreview.ItemsSource = @()
        & $invalidatePreview
        $App.SetStatus("Live walk: 0 affected folders")
        return
    }

    $state.PreviewRows   = @($found)
    $state.PreviewHash   = & $computeInputHash
    $state.DiscoveryMode = 'live'

    $grdPreview.ItemsSource = @($found)
    $totalAces = ($found | Measure-Object AceCount -Sum).Sum
    $txtPreviewSummary.Text =
        "Live walk of $scope (scanned $folderCount folder(s)): found $($found.Count) folder(s) with explicit ACEs " +
        "for $($state.Source.Name). Would affect $totalAces ACE(s). $errorCount enumeration error(s)."
    $txtPreviewStatus.Text = "Preview ready (live) · type APPLY to enable Execute"
    $btnExecute.IsEnabled = $false
    $App.SetStatus("Preview (live): $($found.Count) folders, $totalAces ACEs, $errorCount error(s)")

    & $writeAudit @{
        event = 'preview'; mode = 'live'
        sourceSid = $sourceSid; sourceName = $state.Source.Name
        targetSid = $targetSid; targetName = $state.Target.Name
        scope = $scope; foldersWalked = $folderCount
        folderCount = $found.Count; aceCount = $totalAces
        errors = $errorCount; inputHash = $state.PreviewHash
    }
}.GetNewClosure()

# --- Dispatcher: chooses the right discovery mode ---
$runPreview = {
    if (-not (& $testInputsReady)) {
        $App.ShowError('Inputs incomplete',
            'Set source, target, and scope, and ensure source ≠ target.')
        return
    }

    $sourceSid = $state.Source.Sid
    $targetSid = $state.Target.Sid

    # Guardrails (unchanged from original $runPreview)
    if ($wellKnownDangerous -contains $sourceSid -and -not $chkOverrideGuard.IsChecked) {
        $App.ShowError('Source is a well-known SID',
            "Refusing to substitute $($state.Source.Name) without explicit override.")
        return
    }
    if ($wellKnownDangerous -contains $targetSid) {
        $App.ShowError('Target is a well-known SID',
            "Refusing to substitute INTO $($state.Target.Name) under any circumstances.")
        return
    }
    if (& $testPathIsDangerousRoot $txtScope.Text) {
        $App.ShowError('Scope is too broad',
            "Refusing to operate on $($txtScope.Text). Pick a subfolder.")
        return
    }

    if ($rbModeLive.IsChecked) {
        & $runPreviewLive
    } else {
        & $runPreviewFromScan
    }
}.GetNewClosure()

# -----------------------------------------------------------------------------
# Execute
# -----------------------------------------------------------------------------

$runExecute = {
    if (-not $state.PreviewRows -or $state.PreviewRows.Count -eq 0) { return }
    if ($state.PreviewHash -ne (& $computeInputHash)) {
        $App.ShowError('Inputs changed', 'Inputs changed since preview. Re-run preview.')
        & $invalidatePreview
        $txtConfirm.Text = ''
        return
    }
    if ($txtConfirm.Text.Trim().ToUpper() -ne 'APPLY') {
        $App.ShowError('Confirmation required', "Type APPLY in the confirmation box.")
        $txtConfirm.Text = ''
        $txtConfirm.Focus()
        return
    }

    $runId = [System.Guid]::NewGuid().ToString()
    $txtConfirm.Text = ''
    $btnExecute.IsEnabled = $false
    $Page.Dispatcher.Invoke([Action]{}, 'Background')
    $startUtc = [System.DateTime]::UtcNow.ToString('o')

    # JSONL envelope (forensic log)
    & $writeAudit @{
        event = 'execute_begin'; runId = $runId
        mode = $state.DiscoveryMode
        inputHash = $state.PreviewHash; folderCount = $state.PreviewRows.Count
    }

    # DB journal envelope (queryable log)
    try {
        $App.Query(@"
            INSERT INTO swap_runs(run_id, started_utc, operator, host,
                                  source_sid, source_name, target_sid, target_name,
                                  scope_root, based_on_scan, discovery_mode, folder_count)
            VALUES (@id, @start, @op, @hostname, @ss, @sn, @ts, @tn, @scope, @scan, @mode, @fc)
"@, @{
            id    = $runId
            start = $startUtc
            op    = "$env:USERDOMAIN\$env:USERNAME"
            hostname = $env:COMPUTERNAME
            ss    = $state.Source.Sid
            sn    = $state.Source.Name
            ts    = $state.Target.Sid
            tn    = $state.Target.Name
            scope = $txtScope.Text.Trim()
            scan  = if ($state.DiscoveryMode -eq 'scan' -and $App.CurrentScanId) {
                        $App.CurrentScanId
                    } else { [System.DBNull]::Value }
            mode  = $state.DiscoveryMode
            fc    = $state.PreviewRows.Count
        }) | Out-Null
    } catch {
        # Non-fatal: JSONL is authoritative; DB journal is best-effort
        & $writeAudit @{ event = 'swap_runs_insert_failed'; runId = $runId; message = $_.Exception.Message }
    }

    $logRows = New-Object System.Collections.ArrayList
    $grdExecute.ItemsSource = $logRows
    $pbExecute.Minimum = 0
    $pbExecute.Maximum = $state.PreviewRows.Count
    $pbExecute.Value   = 0

    $btnExecute.IsEnabled = $false
    $btnPreview.IsEnabled = $false

    $okCount = 0; $failCount = 0

    foreach ($row in $state.PreviewRows) {
        $when       = [System.DateTime]::Now.ToString('HH:mm:ss')
        $whenUtc    = [System.DateTime]::UtcNow.ToString('o')
        $resultCode = $null
        $resultText = ''

        $skip = $false
        if ($chkSkipReparse.IsChecked) {
            try {
                $attr = (Get-Item -LiteralPath $row.Path -Force -ErrorAction Stop).Attributes
                if ($attr -band [System.IO.FileAttributes]::ReparsePoint) { $skip = $true }
            } catch { }
        }

        if ($skip) {
            $resultCode = 'skip'
            $resultText = 'reparse point'
        } else {
            try {
                $liveAces   = Get-NTFSAccess -Path $row.Path -ExcludeInherited:$true -ErrorAction Stop
                $sourceAces = @($liveAces | Where-Object { (& $getAceSid $_) -eq $state.Source.Sid })

                if ($sourceAces.Count -eq 0) {
                    $resultCode = 'noop'
                    $resultText = 'Source SID no longer present (drift since discovery)'
                } else {
                    $added = 0
                    foreach ($ace in $sourceAces) {
                        Add-NTFSAccess -Path $row.Path `
                            -Account          $state.Target.Sid `
                            -AccessRights     $ace.AccessRights `
                            -AccessType       $ace.AccessControlType `
                            -InheritanceFlags $ace.InheritanceFlags `
                            -PropagationFlags $ace.PropagationFlags `
                            -ErrorAction Stop
                        $added++
                    }
                    $sourceAces | Remove-NTFSAccess -ErrorAction Stop

                    $okCount++
                    $resultCode = 'ok'
                    $resultText = "Swapped $added ACE(s)"
                }
            } catch {
                $failCount++
                $resultCode = 'fail'
                $resultText = $_.Exception.Message
            }
        }

        # In-memory log row
        [void]$logRows.Add([pscustomobject]@{
            When = $when; Path = $row.Path
            Result = $resultCode.ToUpper(); Detail = $resultText
        })

        # JSONL audit (forensic)
        & $writeAudit @{
            event = 'execute_op'; runId = $runId
            path = $row.Path; result = $resultCode; detail = $resultText
        }

        # DB journal (queryable)
        try {
            $App.Query(@"
                INSERT INTO swap_results(run_id, path, result, detail, when_utc)
                VALUES (@id, @p, @r, @d, @t)
"@, @{
                id = $runId; p = $row.Path; r = $resultCode
                d  = $resultText; t = $whenUtc
            }) | Out-Null
        } catch { }

        $pbExecute.Value += 1
        $Page.Dispatcher.Invoke([Action]{}, 'Background')
    }

    # Close out the run
    & $writeAudit @{
        event = 'execute_end'; runId = $runId
        ok = $okCount; failed = $failCount
    }
    try {
        $App.Query(@"
            UPDATE swap_runs SET completed_utc=@done, ok_count=@ok, fail_count=@fail
            WHERE run_id=@id
"@, @{
            done = [System.DateTime]::UtcNow.ToString('o')
            ok = $okCount; fail = $failCount; id = $runId
        }) | Out-Null
    } catch { }

    # Persist target principal so it's pickable for a reverse swap
    if ($okCount -gt 0) {
        try {
            $App.Query(@"
                INSERT INTO principals(sid, name, domain, sam_account_name,
                                       principal_type, is_well_known, last_resolved_utc)
                VALUES (@sid, @name, @domain, @sam, @type, 0, @now)
                ON CONFLICT(sid) DO UPDATE SET
                    name              = excluded.name,
                    sam_account_name  = excluded.sam_account_name,
                    principal_type    = excluded.principal_type,
                    last_resolved_utc = excluded.last_resolved_utc
"@, @{
                sid    = $state.Target.Sid
                name   = $state.Target.Name
                domain = $env:USERDOMAIN
                sam    = $state.Target.Sam
                type   = $state.Target.Type
                now    = [System.DateTime]::UtcNow.ToString('o')
            }) | Out-Null
            & $writeAudit @{ event = 'persist_target'; runId = $runId; sid = $state.Target.Sid; name = $state.Target.Name }
        } catch {
            & $writeAudit @{ event = 'persist_target_failed'; runId = $runId; message = $_.Exception.Message }
        }
    }

    $state.LastExecuteRoot = $txtScope.Text
    $btnPreview.IsEnabled = $true
    $btnVerify.IsEnabled  = $true
    $App.SetStatus("Execute complete: $okCount OK, $failCount failed")
}.GetNewClosure()

# -----------------------------------------------------------------------------
# Verify
# -----------------------------------------------------------------------------

$runVerify = {
    if (-not $state.PreviewRows -or $state.PreviewRows.Count -eq 0) { return }

    $txtVerifySummary.Text = "Verifying live ACLs for $($state.PreviewRows.Count) folders…"
    $rows = New-Object System.Collections.ArrayList
    $grdVerify.ItemsSource = $rows

    Import-Module NTFSSecurity -ErrorAction SilentlyContinue

    $stillSource = 0; $hasTarget = 0; $clean = 0; $errors = 0

    foreach ($r in $state.PreviewRows) {
        try {
            $live = Get-NTFSAccess -Path $r.Path -ExcludeInherited:$false -ErrorAction Stop
            $sourceSids = @($live | Where-Object { (& $getAceSid $_) -eq $state.Source.Sid })
            $targetSids = @($live | Where-Object { (& $getAceSid $_) -eq $state.Target.Sid })

            $status =
                if ($sourceSids.Count -gt 0) { 'SOURCE_REMAINS'; $stillSource++ }
                elseif ($targetSids.Count -gt 0) { 'OK'; $clean++; $hasTarget++ }
                else { 'NO_TRACE'; $clean++ }

            $detail =
                if ($sourceSids.Count -gt 0) {
                    "Source SID still present on $($sourceSids.Count) ACE(s)"
                } elseif ($targetSids.Count -gt 0) {
                    "Target SID present on $($targetSids.Count) ACE(s)"
                } else {
                    "Neither SID present (folder may have only inherited ACEs)"
                }

            [void]$rows.Add([pscustomobject]@{
                Path = $r.Path; Status = $status; Detail = $detail
            })
        } catch {
            $errors++
            [void]$rows.Add([pscustomobject]@{
                Path = $r.Path; Status = 'ERR'; Detail = $_.Exception.Message
            })
        }
    }

    $txtVerifySummary.Text =
        "Verification: $clean clean, $stillSource still contain source SID, $errors error(s). " +
        "If 'still contain source' is non-zero, those folders need a follow-up run."
    $App.SetStatus("Verify: $clean clean, $stillSource remaining, $errors errors")

    & $writeAudit @{
        event       = 'verify'
        clean       = $clean
        stillSource = $stillSource
        errors      = $errors
    }
}.GetNewClosure()

# -----------------------------------------------------------------------------
# Event wiring
# -----------------------------------------------------------------------------

$btnPickSource.Add_Click({
    $defaultSource = if ($App.CurrentScanId) { 'Database' } else { 'ActiveDirectory' }
    $pick = $App.PickPrincipal('Pick the source principal (to be replaced)', $defaultSource)
    if (-not $pick) { return }
    $state.Source = $pick
    $txtSource.Text = "$($pick.Name)   [$($pick.Type)]   $($pick.Sid)"
    & $invalidatePreview
}.GetNewClosure())

$btnPickTarget.Add_Click({
    $pick = $App.PickPrincipal('Pick the target principal (replacement)', 'ActiveDirectory')
    if (-not $pick) { return }
    $state.Target = $pick
    $txtTarget.Text = "$($pick.Name)   [$($pick.Type)]   $($pick.Sid)"
    & $invalidatePreview
}.GetNewClosure())

$btnBrowseScope.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Pick the scope root for the substitution'
    if (-not [string]::IsNullOrWhiteSpace($txtScope.Text)) {
        $dlg.SelectedPath = $txtScope.Text
    }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtScope.Text = $dlg.SelectedPath
        & $invalidatePreview
    }
}.GetNewClosure())

$txtScope.Add_TextChanged({ & $invalidatePreview }.GetNewClosure())
$chkIncludeFiles.Add_Click({ & $invalidatePreview }.GetNewClosure())
$chkSkipReparse.Add_Click({ & $invalidatePreview }.GetNewClosure())
$chkOverrideGuard.Add_Click({ & $invalidatePreview }.GetNewClosure())

$btnPreview.Add_Click($runPreview)

$txtConfirm.Add_TextChanged({
    $btnExecute.IsEnabled = (
        $state.PreviewRows -and
        $state.PreviewRows.Count -gt 0 -and
        $txtConfirm.Text.Trim().ToUpper() -eq 'APPLY'
    )
}.GetNewClosure())

$btnExecute.Add_Click($runExecute)
$btnVerify.Add_Click($runVerify)

# Initial UI state
# Default discovery mode: scan if one is loaded, live otherwise.
# Disable the Scan option entirely when no scan is selected so the choice is unambiguous.
if ($App.CurrentScanId) {
    $rbModeScan.IsChecked = $true
} else {
    $rbModeScan.IsEnabled = $false
    $rbModeLive.IsChecked = $true
}

# Re-invalidate preview if the operator switches modes after picking one
$rbModeScan.Add_Click({ & $invalidatePreview }.GetNewClosure())
$rbModeLive.Add_Click({ & $invalidatePreview }.GetNewClosure())

# Release grid data when the page is unloaded (Frame.Content swap or window close)
$Page.Add_Unloaded({
    try { $grdPreview.ItemsSource = $null } catch { }
    try { $grdExecute.ItemsSource = $null } catch { }
    try { $grdVerify.ItemsSource  = $null } catch { }
    $state.PreviewRows = @()
}.GetNewClosure())

& $invalidatePreview
$App.SetStatus("Swap workflow loaded.")

# Pre-fill scope if navigated from another view that set NavContext.Scope
if ($App.NavContext -and $App.NavContext.Scope) {
    $txtScope.Text = [string]$App.NavContext.Scope
    $App.NavContext = $null
}