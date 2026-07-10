#Requires -Version 7.0
#Requires -Modules PSSQLite

<#
.SYNOPSIS
    ShareACL GUI shell. Hosts the reporting views and the ACL Swap workflow.

.PARAMETER Database
    Optional path to a ShareACL SQLite DB to open on startup.
#>
[CmdletBinding()]
param(
    [string] $Database
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

# Pre-run cleanup: eagerly release any state left over from a previous run
# in the same PowerShell session. Idempotent — safe on the first run too.
if ($Script:App) {
    try {
        if ($Script:App.PageHost) { $Script:App.PageHost.Content = $null }
    } catch { }
    try {
        if ($Script:App.Connection) {
            try { $Script:App.Connection.Close() }   catch { }
            try { $Script:App.Connection.Dispose() } catch { }
        }
    } catch { }
    try {
        if ($Script:App.Window) {
            $Script:App.Window.Owner = $null
            $Script:App.Window.Close()
        }
    } catch { }
    if ($Script:App.NavButtons) { $Script:App.NavButtons.Clear() }
    $Script:App = $null
}
try { [System.Data.SQLite.SQLiteConnection]::ClearAllPools() } catch { }
[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()
[System.GC]::Collect()

# -----------------------------------------------------------------------------
# Shared constants (defined once to dodge the [Type]::Member rendering trap)
# -----------------------------------------------------------------------------
$Script:DbNull          = [System.DBNull]::Value
$Script:ScriptRoot      = $PSScriptRoot
$Script:PagesRoot       = Join-Path $PSScriptRoot 'Pages'

function Get-NowUtc { [System.DateTime]::UtcNow.ToString('o') }

# -----------------------------------------------------------------------------
# Application state — one bag, passed to every page
# -----------------------------------------------------------------------------
$Script:App = [pscustomobject]@{
    DbPath          = $null
    Connection      = $null
    CurrentScanId   = $null
    CurrentPageName = $null
    CurrentPage     = $null
    Window          = $null
    StatusBar       = $null
    DbInfo          = $null
    PageHost        = $null
    BusyOverlay     = $null
    BusyText        = $null
    BusyOperationId = $null
    AsyncOperations = @{}
    Commands        = $null
    StartupDatabase = $Database
    NavButtons      = @{}
    NavContext      = $null
    IsClosing       = $false
    SuppressScanSelectionChanged = $false
}

# Expose shell helpers to page scripts via the App object.
# Pages call e.g.  & $App.Query -Query '...' -Params @{ ... }
$Script:App | Add-Member -MemberType ScriptMethod -Name Query -Value {
    param([string]$Query, [hashtable]$Params)
    if (-not $this.Connection) { throw "No database open." }
    $a = @{ SQLiteConnection = $this.Connection; Query = $Query }
    if ($Params) { $a.SqlParameters = $Params }
    Invoke-SqliteQuery @a
}

$Script:App | Add-Member -MemberType ScriptMethod -Name SetStatus -Value {
    param([string]$Text)
    if ($null -ne $this.StatusBar) { $this.StatusBar.Text = $Text }
}

$Script:App | Add-Member -MemberType ScriptMethod -Name ShowError -Value {
    param([string]$Title, [string]$Message)
    $owner = $this.Window
    if ($null -ne $owner) {
        [System.Windows.MessageBox]::Show($owner, $Message, $Title, 'OK', 'Error') | Out-Null
    } else {
        [System.Windows.MessageBox]::Show($Message, $Title, 'OK', 'Error') | Out-Null
    }
    if ($null -ne $this.StatusBar) { $this.StatusBar.Text = $Message }
}

$Script:App | Add-Member -MemberType ScriptMethod -Name GetControls -Value {
    param($Page, [string[]]$Names)

    $controls = @{}
    $missing  = [System.Collections.Generic.List[string]]::new()

    foreach ($name in $Names) {
        $control = $Page.FindName($name)
        if ($null -eq $control) {
            $missing.Add($name)
        } else {
            $controls[$name] = $control
        }
    }

    if ($missing.Count -gt 0) {
        throw "The page '$($Page.Title)' is missing required XAML control(s): $($missing -join ', ')."
    }

    $controls
}

function Test-AppPageIsCurrent {
    param($App, $PageContext)

    ($null -ne $PageContext) -and
    $PageContext.IsActive -and
    ($null -ne $App.CurrentPage) -and
    ($App.CurrentPage.Id -eq $PageContext.Id) -and
    (-not $App.IsClosing)
}

function Show-AppBusy {
    param($App, $Operation, [string]$Text)

    $App.BusyOperationId = $Operation.Id
    if ($null -ne $App.BusyText)    { $App.BusyText.Text = $Text }
    if ($null -ne $App.BusyOverlay) {
        $App.BusyOverlay.Visibility = [System.Windows.Visibility]::Visible
    }
}

function Hide-AppBusy {
    param($App, [string]$OperationId)

    if ($App.BusyOperationId -eq $OperationId) {
        $App.BusyOperationId = $null
        if ($null -ne $App.BusyOverlay) {
            $App.BusyOverlay.Visibility = [System.Windows.Visibility]::Collapsed
        }
    }
}

function Remove-AppOperationReference {
    param($App, $Operation)

    $owner = $Operation.Owner
    if ($null -ne $owner -and $owner.Operations.ContainsKey($Operation.Name)) {
        $registered = $owner.Operations[$Operation.Name]
        if ([object]::ReferenceEquals($registered, $Operation)) {
            [void]$owner.Operations.Remove($Operation.Name)
        }
    }
    if ($null -ne $App -and $App.AsyncOperations.ContainsKey($Operation.Id)) {
        [void]$App.AsyncOperations.Remove($Operation.Id)
    }
}

function Close-AppAsyncResources {
    param($Operation)

    if ($null -ne $Operation.Timer) {
        try { $Operation.Timer.Stop() } catch { }
        $Operation.Timer = $null
    }
    if ($null -ne $Operation.PowerShell) {
        try { $Operation.PowerShell.Dispose() } catch { }
        $Operation.PowerShell = $null
    }
    if ($null -ne $Operation.Runspace) {
        try { $Operation.Runspace.Close() }   catch { }
        try { $Operation.Runspace.Dispose() } catch { }
        $Operation.Runspace = $null
    }
    $Operation.Handle = $null
}

function Complete-AppAsyncOperation {
    param($App, $Operation)

    if (-not $Operation.Completed) {
        $Operation.Completed = $true
        if ($null -ne $Operation.Timer) { $Operation.Timer.Stop() }

        $wrapped = $null
        try {
            $output = $Operation.PowerShell.EndInvoke($Operation.Handle)
            $wrapped = if ($output -and $output.Count -gt 0) {
                $output[0]
            } else {
                [pscustomobject]@{
                    Ok    = $false
                    Error = 'The background operation returned no result.'
                }
            }
        } catch {
            $wrapped = [pscustomobject]@{
                Ok    = $false
                Error = $_.Exception.Message
            }
        }

        $owner    = $Operation.Owner
        $ownsSlot = $owner.Operations.ContainsKey($Operation.Name) -and
                    [object]::ReferenceEquals($owner.Operations[$Operation.Name], $Operation)

        Close-AppAsyncResources -Operation $Operation
        Remove-AppOperationReference -App $App -Operation $Operation
        Hide-AppBusy -App $App -OperationId $Operation.Id

        $canApply = $ownsSlot -and
                    (-not $Operation.CancelRequested) -and
                    (Test-AppPageIsCurrent -App $App -PageContext $owner)

        if ($canApply) {
            if ($wrapped.Ok) {
                try {
                    & $Operation.OnComplete $wrapped.Result $owner
                } catch {
                    $App.ShowError('Background completion failed', $_.Exception.Message)
                }
            } else {
                $App.ShowError($Operation.ErrorTitle, [string]$wrapped.Error)
            }
        }
    }
}

function Stop-AppOperationInstance {
    param(
        $App,
        $Operation,
        [switch]$Synchronous
    )

    if ($null -ne $Operation -and -not $Operation.Completed) {
        if ($Synchronous) {
            $Operation.CancelRequested = $true
            $Operation.Completed = $true
            if ($null -ne $Operation.Timer) { $Operation.Timer.Stop() }
            try { $Operation.PowerShell.Stop() } catch { }
            if ($null -ne $Operation.Handle -and $Operation.Handle.IsCompleted) {
                try { $null = $Operation.PowerShell.EndInvoke($Operation.Handle) } catch { }
            }
            Close-AppAsyncResources -Operation $Operation
            Remove-AppOperationReference -App $App -Operation $Operation
            Hide-AppBusy -App $App -OperationId $Operation.Id
        } elseif (-not $Operation.CancelRequested) {
            $Operation.CancelRequested = $true
            try {
                [void]$Operation.PowerShell.BeginStop($null, $null)
            } catch {
                try { $Operation.PowerShell.Stop() } catch { }
            }
        }
    }
}

function Stop-AppAsyncOperation {
    param(
        $App,
        $PageContext,
        [string]$Name,
        [switch]$Synchronous
    )

    if ($null -ne $PageContext -and $PageContext.Operations.ContainsKey($Name)) {
        $operation = $PageContext.Operations[$Name]
        Stop-AppOperationInstance -App $App -Operation $operation -Synchronous:$Synchronous
    }
}

function Stop-AppPageOperations {
    param($App, $PageContext, [switch]$Synchronous)

    if ($null -ne $PageContext) {
        foreach ($name in @($PageContext.Operations.Keys)) {
            Stop-AppAsyncOperation -App $App -PageContext $PageContext `
                -Name $name -Synchronous:$Synchronous
        }
    }
}

function Stop-AllAppOperations {
    param($App, [switch]$Synchronous)

    foreach ($operation in @($App.AsyncOperations.Values)) {
        Stop-AppOperationInstance -App $App -Operation $operation -Synchronous:$Synchronous
    }
}

function Start-AppAsyncOperation {
    param(
        $App,
        $PageContext,
        [string]$Name,
        [string]$BusyText,
        [hashtable]$Context,
        [scriptblock]$Work,
        [scriptblock]$OnComplete,
        [string]$ErrorTitle = 'Background operation failed'
    )

    $operation = $null
    try {
        if (-not (Test-AppPageIsCurrent -App $App -PageContext $PageContext)) {
            throw "Cannot start '$Name' because its page is no longer active."
        }
        if ([string]::IsNullOrWhiteSpace($App.DbPath)) {
            throw "Cannot start '$Name' because no database is open."
        }

        Stop-AppAsyncOperation -App $App -PageContext $PageContext -Name $Name

        $workerContext = @{}
        if ($null -ne $Context) {
            foreach ($key in $Context.Keys) { $workerContext[$key] = $Context[$key] }
        }
        $workerContext.DbPath = $App.DbPath

        $operation = [pscustomobject]@{
            Id              = [guid]::NewGuid().ToString('N')
            Name            = $Name
            Owner           = $PageContext
            PowerShell      = $null
            Runspace        = $null
            Handle          = $null
            Timer           = $null
            OnComplete      = $OnComplete
            ErrorTitle      = $ErrorTitle
            CancelRequested = $false
            Completed       = $false
        }
        $PageContext.Operations[$Name] = $operation
        $App.AsyncOperations[$operation.Id] = $operation
        Show-AppBusy -App $App -Operation $operation -Text $BusyText

        $initialState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault2()
        $initialState.ImportPSModule('PSSQLite')

        $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($initialState)
        $runspace.ApartmentState = 'STA'
        $runspace.ThreadOptions  = 'ReuseThread'
        $runspace.Open()

        $powershell = [System.Management.Automation.PowerShell]::Create()
        $powershell.Runspace = $runspace

        # A ScriptBlock retains the SessionState in which it was created. Never
        # invoke the UI runspace's ScriptBlock object inside another runspace.
        # Pass its text and compile a new ScriptBlock in the worker runspace.
        $workerText = $Work.ToString()
        $wrapperText = @'
param($Ctx, $WorkerText)

$ErrorActionPreference = 'Stop'
try {
    $worker = [scriptblock]::Create($WorkerText)
    $result = & $worker $Ctx
    [pscustomobject]@{
        Ok     = $true
        Result = $result
    }
} catch {
    [pscustomobject]@{
        Ok    = $false
        Error = $_.Exception.Message
    }
}
'@
        [void]$powershell.AddScript($wrapperText)
        [void]$powershell.AddArgument($workerContext)
        [void]$powershell.AddArgument($workerText)

        $operation.PowerShell = $powershell
        $operation.Runspace   = $runspace
        $operation.Handle     = $powershell.BeginInvoke()

        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [System.TimeSpan]::FromMilliseconds(75)
        $operation.Timer = $timer

        $appReference       = $App
        $operationReference = $operation
        $completionCommand  = $App.Commands.CompleteAsync
        $timer.Add_Tick({
            if ($operationReference.Handle.IsCompleted) {
                try {
                    & $completionCommand -App $appReference -Operation $operationReference
                } catch {
                    # This is a last-resort guard for the completion mechanism
                    # itself. Never leave the overlay spinning indefinitely.
                    $operationReference.Completed = $true
                    try { $operationReference.Timer.Stop() } catch { }
                    try { $operationReference.PowerShell.Dispose() } catch { }
                    try { $operationReference.Runspace.Close() } catch { }
                    try { $operationReference.Runspace.Dispose() } catch { }

                    $owner = $operationReference.Owner
                    if ($owner.Operations.ContainsKey($operationReference.Name) -and
                        [object]::ReferenceEquals(
                            $owner.Operations[$operationReference.Name],
                            $operationReference
                        )) {
                        [void]$owner.Operations.Remove($operationReference.Name)
                    }
                    [void]$appReference.AsyncOperations.Remove($operationReference.Id)
                    if ($appReference.BusyOperationId -eq $operationReference.Id) {
                        $appReference.BusyOperationId = $null
                        $appReference.BusyOverlay.Visibility = [System.Windows.Visibility]::Collapsed
                    }
                    $appReference.ShowError(
                        'Async completion failed',
                        $_.Exception.Message
                    )
                }
            }
        }.GetNewClosure())
        $timer.Start()
    } catch {
        if ($null -ne $operation) {
            $operation.Completed = $true
            Close-AppAsyncResources -Operation $operation
            Remove-AppOperationReference -App $App -Operation $operation
            Hide-AppBusy -App $App -OperationId $operation.Id
        }
        $App.ShowError('Unable to start background operation', $_.Exception.Message)
        $operation = $null
    }

    $operation
}

$Script:App | Add-Member -MemberType ScriptMethod -Name StartAsync -Value {
    param(
        $PageContext,
        [string]$Name,
        [string]$BusyText,
        [hashtable]$Context,
        [scriptblock]$Work,
        [scriptblock]$OnComplete,
        [string]$ErrorTitle = 'Background operation failed'
    )

    $command = $this.Commands.StartAsync
    & $command -App $this -PageContext $PageContext -Name $Name `
        -BusyText $BusyText -Context $Context -Work $Work `
        -OnComplete $OnComplete -ErrorTitle $ErrorTitle
}

$Script:App | Add-Member -MemberType ScriptMethod -Name CancelAsync -Value {
    param($PageContext, [string]$Name)
    $command = $this.Commands.StopOperation
    & $command -App $this -PageContext $PageContext -Name $Name
}

$Script:App | Add-Member -MemberType ScriptMethod -Name CancelPageAsync -Value {
    param($PageContext, [bool]$Synchronous = $false)
    $command = $this.Commands.StopPage
    & $command -App $this -PageContext $PageContext -Synchronous:$Synchronous
}

# Backward-compatible wrapper for any page not yet moved to named operations.
$Script:App | Add-Member -MemberType ScriptMethod -Name RunAsync -Value {
    param(
        [string]$BusyText,
        [hashtable]$Context,
        [scriptblock]$Work,
        [scriptblock]$OnComplete
    )

    if ($null -eq $this.CurrentPage) {
        throw 'No page is active for this background operation.'
    }

    $this.StartAsync(
        $this.CurrentPage,
        'LegacyPageOperation',
        $BusyText,
        $Context,
        $Work,
        $OnComplete,
        'Query failed'
    )
}

$Script:App | Add-Member -MemberType ScriptMethod -Name PickPrincipal -Value {
    param(
        [string] $Title         = 'Pick a principal',
        [string] $DefaultSource = 'Database'
    )
    $command = $this.Commands.PickPrincipal
    & $command -Title $Title -DefaultSource $DefaultSource
}

$Script:App | Add-Member -MemberType ScriptMethod -Name Navigate -Value {
    param([string]$PageName)
    $command = $this.Commands.Navigate
    & $command -PageName $PageName
}

# -----------------------------------------------------------------------------
# DB layer
# -----------------------------------------------------------------------------

function Ensure-DatabaseLoaded {
    param([string]$Reason = 'This action requires a database.')

    if ($Script:App.DbPath -and $Script:App.Connection) { return $true }

    $ans = [System.Windows.MessageBox]::Show($Script:App.Window,
        "$Reason`n`nYes: open an existing database.`nNo: create a new database.`nCancel: return without doing anything.",
        'No database loaded', 'YesNoCancel', 'Question')

    switch ($ans) {
        'Yes' {
            $window = $Script:App.Window
            $window.FindName('BtnBrowseDb').RaiseEvent(
                [System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
            if ($window.FindName('TxtDbPath').Text) {
                $window.FindName('BtnOpenDb').RaiseEvent(
                    [System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
            }
        }
        'No'    { New-ShareAclDatabase -SkipScanPrompt }
        default { }
    }

    return ($Script:App.DbPath -and $Script:App.Connection)
}

function Open-ShareAclDatabase {
    param([string]$Path)

    if (-not (Test-Path $Path)) { throw "Database not found: $Path" }

    # A report may still be reading the current database while the operator
    # opens another one. Stop that work before validation/migration to avoid a
    # stale completion or a lock when the same file is reopened.
    if ($null -ne $Script:App.CurrentPage) {
        $Script:App.CancelPageAsync($Script:App.CurrentPage, $false)
    }

    # Validate it's actually a ShareACL DB by probing for our tables
    $check = Invoke-SqliteQuery -DataSource $Path -Query @"
        SELECT COUNT(*) AS n FROM sqlite_master
        WHERE type='table' AND name IN ('scans','folders','aces','principals','group_members')
"@
    if ($check.n -lt 5) { throw "Not a ShareACL database (missing core tables): $Path" }

    #Migration: ensure swap journal tables exist (additive, idempotent)
        Invoke-SqliteQuery -DataSource $Path -Query @"
            CREATE TABLE IF NOT EXISTS swap_runs (
                run_id TEXT PRIMARY KEY,
                started_utc TEXT NOT NULL,
                completed_utc TEXT,
                operator TEXT NOT NULL,
                host TEXT NOT NULL,
                source_sid TEXT NOT NULL,
                source_name TEXT,
                target_sid TEXT NOT NULL,
                target_name TEXT,
                scope_root TEXT NOT NULL,
                based_on_scan INTEGER REFERENCES scans(scan_id),
                discovery_mode TEXT NOT NULL CHECK (discovery_mode IN ('scan','live')),
                folder_count INTEGER NOT NULL DEFAULT 0,
                ok_count INTEGER NOT NULL DEFAULT 0,
                fail_count INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS swap_results (
                result_id INTEGER PRIMARY KEY AUTOINCREMENT,
                run_id TEXT NOT NULL REFERENCES swap_runs(run_id),
                path TEXT NOT NULL,
                result TEXT NOT NULL CHECK (result IN ('ok','fail','skip','noop')),
                detail TEXT,
                when_utc TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS ix_swap_results_run ON swap_results(run_id);
            CREATE INDEX IF NOT EXISTS ix_swap_runs_source ON swap_runs(source_sid);
            CREATE INDEX IF NOT EXISTS ix_swap_runs_target ON swap_runs(target_sid);
"@ | Out-Null

    # Migration: progress tracking columns on the scans table
    $needsProgressMigration = (Invoke-SqliteQuery -DataSource $Path -Query @"
        SELECT COUNT(*) AS n FROM pragma_table_info('scans') WHERE name = 'total_folders'
"@).n -eq 0

    if ($needsProgressMigration) {
        Invoke-SqliteQuery -DataSource $Path -Query @"
            PRAGMA foreign_keys = OFF;
            BEGIN;
            CREATE TABLE scans_new (
                scan_id INTEGER PRIMARY KEY AUTOINCREMENT,
                started_utc TEXT NOT NULL,
                completed_utc TEXT,
                root_paths_json TEXT NOT NULL,
                host TEXT,
                operator TEXT,
                status TEXT NOT NULL CHECK (status IN ('counting','running','completed','failed','aborted')),
                folder_count INTEGER NOT NULL DEFAULT 0,
                ace_count INTEGER NOT NULL DEFAULT 0,
                error_count INTEGER NOT NULL DEFAULT 0,
                notes TEXT,
                total_folders INTEGER,
                processed_folders INTEGER NOT NULL DEFAULT 0,
                folders_per_second REAL,
                estimated_completion_utc TEXT,
                last_updated_utc TEXT
            );
            INSERT INTO scans_new (scan_id, started_utc, completed_utc, root_paths_json,
                                host, operator, status, folder_count, ace_count, error_count, notes)
                SELECT scan_id, started_utc, completed_utc, root_paths_json,
                    host, operator, status, folder_count, ace_count, error_count, notes
                FROM scans;
            DROP TABLE scans;
            ALTER TABLE scans_new RENAME TO scans;
            COMMIT;
            PRAGMA foreign_keys = ON;
"@ | Out-Null
    }

    Close-ShareAclDatabase

    $conn = New-SQLiteConnection -DataSource $Path
    if ($conn.State -ne [System.Data.ConnectionState]::Open) { $conn.Open() }

    $Script:App.DbPath     = $Path
    $Script:App.Connection = $conn

    Update-DbInfoLabel
    Set-Status "Opened $Path"
}

function Close-ShareAclDatabase {
    if ($null -ne $Script:App.CurrentPage) {
        $Script:App.CancelPageAsync($Script:App.CurrentPage, $false)
    }
    $Script:App.BusyOperationId = $null
    if ($null -ne $Script:App.BusyOverlay) {
        $Script:App.BusyOverlay.Visibility = [System.Windows.Visibility]::Collapsed
    }

    if ($Script:App.Connection) {
        try { $Script:App.Connection.Close()   } catch { }
        try { $Script:App.Connection.Dispose() } catch { }
    }
    $Script:App.Connection    = $null
    $Script:App.CurrentScanId = $null
}

function Invoke-AppQuery {
    <#  Wrapper that always uses the shared connection.
        Returns rows; callers shape them as needed. #>
    param(
        [Parameter(Mandatory)] [string]   $Query,
        [hashtable] $SqlParameters
    )
    if (-not $Script:App.Connection) { throw "No database open." }

    $sqlArgs = @{
        SQLiteConnection = $Script:App.Connection
        Query            = $Query
    }
    if ($SqlParameters) { $sqlArgs.SqlParameters = $SqlParameters }
    Invoke-SqliteQuery @sqlArgs
}

# -----------------------------------------------------------------------------
# Scan list
# -----------------------------------------------------------------------------
function Get-ScanList {
    Invoke-AppQuery -Query @"
        SELECT scan_id      AS ScanId,
               started_utc  AS Started,
               completed_utc AS Completed,
               status       AS Status,
               folder_count AS Folders,
               ace_count    AS Aces,
               root_paths_json AS Roots
        FROM scans
        ORDER BY scan_id DESC
"@ | ForEach-Object {
        $rootsShort = try { (($_.Roots | ConvertFrom-Json) -join ', ') } catch { $_.Roots }
        $started    = try { ([datetime]$_.Started).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } catch { $_.Started }
        [pscustomobject]@{
            ScanId  = [int]$_.ScanId
            Display = ("#{0}  [{1}]  {2}  ({3:N0} folders, {4:N0} ACEs)  {5}" -f `
                        $_.ScanId, $_.Status, $started, [int]$_.Folders, [int]$_.Aces, $rootsShort)
        }
    }
}

function Set-CurrentScan {
    param(
        $ScanId,
        [switch]$ForceRefresh
    )

    $previousScanId = $Script:App.CurrentScanId
    $Script:App.CurrentScanId = $ScanId
    $hasScan = ($null -ne $ScanId)

    foreach ($name in 'NavFolder','NavAccount','NavFindings') {
        $button = $Script:App.NavButtons[$name]
        if ($null -ne $button) { $button.IsEnabled = $hasScan }
    }

    $changed = $ForceRefresh -or ($previousScanId -ne $ScanId)
    $pageContext = $Script:App.CurrentPage
    if ($changed -and $null -ne $pageContext -and $null -ne $pageContext.State) {
        $refreshProperty = $pageContext.State.PSObject.Properties['RefreshForScan']
        if ($null -ne $refreshProperty -and $null -ne $refreshProperty.Value) {
            $Script:App.CancelPageAsync($pageContext, $false)
            & $refreshProperty.Value $pageContext.State
        }
    }

    if ($hasScan) {
        Set-Status "Active scan: #$ScanId"
    } else {
        Set-Status 'No scan selected (Swap remains available in live mode).'
    }
}

function Refresh-ScanCombo {
    $cmb = $Script:App.Window.FindName('CmbScan')
    $list = @([pscustomobject]@{ ScanId = $null; Display = '(none — no scan selected)' })
    $list += @(Get-ScanList)

    # Updating ItemsSource raises SelectionChanged more than once. Suppress those
    # intermediate events and publish one deliberate scan change after selection.
    $Script:App.SuppressScanSelectionChanged = $true
    try {
        $cmb.ItemsSource = $list
        # Preserve the original behaviour: refreshing selects the newest scan.
        $cmb.SelectedIndex = if ($list.Count -gt 1) { 1 } else { 0 }
    } finally {
        $Script:App.SuppressScanSelectionChanged = $false
    }

    $selectedScanId = if ($null -ne $cmb.SelectedItem) { $cmb.SelectedItem.ScanId } else { $null }
    Set-CurrentScan -ScanId $selectedScanId -ForceRefresh
}

# -----------------------------------------------------------------------------
# Principal picker (shared dialog used by Account view and Swap workflow)
# -----------------------------------------------------------------------------
function Show-PrincipalPicker {
    param(
        [string] $Title = 'Pick a principal',
        [ValidateSet('Database','ActiveDirectory')]
        [string] $DefaultSource = 'Database'
    )

    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$Title" Height="520" Width="640"
        WindowStartupLocation="CenterOwner" FontFamily="Segoe UI" FontSize="12">
    <DockPanel Margin="10">
        <StackPanel DockPanel.Dock="Top" Margin="0,0,0,8">
            <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
                <TextBlock Text="Search in:" VerticalAlignment="Center" Margin="0,0,8,0"/>
                <RadioButton x:Name="RbDb" Content="Database (resolved principals)"
                             VerticalAlignment="Center" Margin="0,0,12,0"/>
                <RadioButton x:Name="RbAd" Content="Active Directory (live query)"
                             VerticalAlignment="Center"/>
            </StackPanel>
            <StackPanel Orientation="Horizontal">
                <TextBlock Text="Search:" VerticalAlignment="Center" Margin="0,0,6,0"/>
                <TextBox x:Name="TxtSearch" Width="400"/>
                <Button x:Name="BtnSearch" Content="Search" Margin="6,0,0,0" Padding="10,2"/>
                <TextBlock x:Name="TxtSearchStatus" VerticalAlignment="Center" Margin="10,0,0,0" Foreground="#666"/>
            </StackPanel>
        </StackPanel>
        <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,8,0,0">
            <Button x:Name="BtnOk"     Content="OK"     IsDefault="True"  Width="80" Margin="0,0,6,0"/>
            <Button x:Name="BtnCancel" Content="Cancel" IsCancel="True"   Width="80"/>
        </StackPanel>
        <DataGrid x:Name="GrdResults" AutoGenerateColumns="False" IsReadOnly="True"
                  SelectionMode="Single" CanUserAddRows="False">
            <DataGrid.Columns>
                <DataGridTextColumn Header="Name" Binding="{Binding Name}" Width="200"/>
                <DataGridTextColumn Header="sAM"  Binding="{Binding Sam}"  Width="140"/>
                <DataGridTextColumn Header="Type" Binding="{Binding Type}" Width="100"/>
                <DataGridTextColumn Header="SID"  Binding="{Binding Sid}"  Width="*"/>
            </DataGrid.Columns>
        </DataGrid>
    </DockPanel>
</Window>
"@

    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
    $win    = [System.Windows.Markup.XamlReader]::Load($reader)
    $win.Owner = $Script:App.Window

    $rbDb         = $win.FindName('RbDb')
    $rbAd         = $win.FindName('RbAd')
    $txt          = $win.FindName('TxtSearch')
    $grd          = $win.FindName('GrdResults')
    $ok           = $win.FindName('BtnOk')
    $btn          = $win.FindName('BtnSearch')
    $searchStatus = $win.FindName('TxtSearchStatus')

    if ($DefaultSource -eq 'ActiveDirectory') { $rbAd.IsChecked = $true }
    else                                       { $rbDb.IsChecked = $true }

    $doSearch = {
        $q = $txt.Text.Trim()
        if (-not $q) { $grd.ItemsSource = @(); $searchStatus.Text = ''; return }

        if ($rbAd.IsChecked) {
            try {
                Import-Module ActiveDirectory -ErrorAction Stop
                $escaped = $q -replace '([\\*\(\)\0])', '\$1'
                $filter  = "(&(|(objectClass=user)(objectClass=group)(objectClass=computer))" +
                           "(|(sAMAccountName=*$escaped*)(name=*$escaped*)))"
                $results = Get-ADObject -LDAPFilter $filter `
                              -Properties sAMAccountName, objectClass, objectSID, Name `
                              -ResultSetSize 200 -ErrorAction Stop
                $rows = $results | ForEach-Object {
                    $type = switch ($_.objectClass) {
                        'user'     { 'User' }
                        'group'    { 'Group' }
                        'computer' { 'Computer' }
                        default    { 'Unknown' }
                    }
                    [pscustomobject]@{
                        Sid  = $_.objectSID.Value
                        Name = $_.Name
                        Sam  = $_.sAMAccountName
                        Type = $type
                    }
                }
                $grd.ItemsSource = @($rows)
                $searchStatus.Text = "AD: $(@($rows).Count) result(s)"
            } catch {
                $grd.ItemsSource = @()
                $searchStatus.Text = "AD search failed: $($_.Exception.Message)"
            }
        } else {
            try {
                $rows = Invoke-AppQuery -Query @"
                    SELECT sid AS Sid, name AS Name, sam_account_name AS Sam, principal_type AS Type
                    FROM principals
                    WHERE name LIKE @q OR sam_account_name LIKE @q OR sid = @exact
                    ORDER BY name LIMIT 200
"@ -SqlParameters @{ q = "%$q%"; exact = $q }
                $grd.ItemsSource = @($rows)
                $searchStatus.Text = "DB: $(@($rows).Count) result(s)"
            } catch {
                $grd.ItemsSource = @()
                $searchStatus.Text = "DB search failed: $($_.Exception.Message)"
            }
        }
    }
    $btn.Add_Click($doSearch)
    $txt.Add_KeyDown({ if ($_.Key -eq 'Return') { & $doSearch } })
    $rbDb.Add_Click({ if ($txt.Text.Trim()) { & $doSearch } })
    $rbAd.Add_Click({ if ($txt.Text.Trim()) { & $doSearch } })

    $script:result = $null
    $ok.Add_Click({
        if ($grd.SelectedItem) {
            $script:result = @{
                Sid  = $grd.SelectedItem.Sid
                Name = $grd.SelectedItem.Name
                Sam  = $grd.SelectedItem.Sam
                Type = $grd.SelectedItem.Type
            }
            $win.DialogResult = $true
            $win.Close()
        }
    })

    [void]$win.ShowDialog()

    # Release control references and event handlers so the window is fully collectible
    try {
        $grd.ItemsSource = $null
        $win.Owner       = $null
        $win.Content     = $null
    } catch { }
    $win = $null

    $captured = $script:result
    $script:result = $null
    return $captured
}

# -----------------------------------------------------------------------------
# New database dialog
# -----------------------------------------------------------------------------

function New-ShareAclDatabase {
    param([switch]$SkipScanPrompt)
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Title    = 'Create ShareACL database'
    $dlg.Filter   = 'ShareACL database (*.db)|*.db'
    $dlg.FileName = 'shareacl.db'
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $target = $dlg.FileName

    if (Test-Path $target) {
        $ans = [System.Windows.MessageBox]::Show(
            "$target already exists.`n`nOverwrite? This will delete any existing scans, resolver output, and swap history in that file.",
            'Overwrite existing database?', 'YesNo', 'Warning')
        if ($ans -ne 'Yes') { return }

        # Close any current connection to that file before overwriting
        if ($Script:App.DbPath -eq $target) { Close-ShareAclDatabase }
        try {
            Remove-Item -LiteralPath $target -Force -ErrorAction Stop
        } catch {
            [System.Windows.MessageBox]::Show($Script:App.Window,
                "Could not remove existing file:`n$($_.Exception.Message)",
                'New database', 'OK', 'Error') | Out-Null
            return
        }
    }

    # Delegate schema creation to the collector's Initialize-Database.
    # Rather than duplicating the schema-loading logic in the shell, we invoke
    # a minimal pwsh child that dot-sources schema.sql via PSSQLite. This keeps
    # the schema authoritative in one place (schema.sql).
    $schemaPath = [System.IO.Path]::GetFullPath((Join-Path $Script:ScriptRoot '..\schema.sql'))
    if (-not (Test-Path $schemaPath)) {
        [System.Windows.MessageBox]::Show($Script:App.Window,
            "schema.sql not found:`n$schemaPath",
            'New database', 'OK', 'Error') | Out-Null
        return
    }

    try {
        # Create the (empty) file so PSSQLite has something to open
        New-Item -ItemType File -Path $target -Force | Out-Null

        $schemaSql = Get-Content -Raw -Path $schemaPath
        Invoke-SqliteQuery -DataSource $target -Query $schemaSql | Out-Null

        # Also apply the swap-journal migration (mirrors what Open-ShareAclDatabase does)
        Invoke-SqliteQuery -DataSource $target -Query @"
            CREATE TABLE IF NOT EXISTS swap_runs (
                run_id TEXT PRIMARY KEY,
                started_utc TEXT NOT NULL,
                completed_utc TEXT,
                operator TEXT NOT NULL,
                host TEXT NOT NULL,
                source_sid TEXT NOT NULL,
                source_name TEXT,
                target_sid TEXT NOT NULL,
                target_name TEXT,
                scope_root TEXT NOT NULL,
                based_on_scan INTEGER REFERENCES scans(scan_id),
                discovery_mode TEXT NOT NULL CHECK (discovery_mode IN ('scan','live')),
                folder_count INTEGER NOT NULL DEFAULT 0,
                ok_count INTEGER NOT NULL DEFAULT 0,
                fail_count INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS swap_results (
                result_id INTEGER PRIMARY KEY AUTOINCREMENT,
                run_id TEXT NOT NULL REFERENCES swap_runs(run_id),
                path TEXT NOT NULL,
                result TEXT NOT NULL CHECK (result IN ('ok','fail','skip','noop')),
                detail TEXT,
                when_utc TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS ix_swap_results_run ON swap_results(run_id);
            CREATE INDEX IF NOT EXISTS ix_swap_runs_source ON swap_runs(source_sid);
            CREATE INDEX IF NOT EXISTS ix_swap_runs_target ON swap_runs(target_sid);
"@ | Out-Null
    } catch {
        [System.Windows.MessageBox]::Show($Script:App.Window,
            "Database creation failed:`n$($_.Exception.Message)",
            'New database', 'OK', 'Error') | Out-Null
        return
    }

    # Automatically open the new database and offer to run a scan
    $window = $Script:App.Window
    $window.FindName('TxtDbPath').Text = $target
    try {
        Open-ShareAclDatabase -Path $target
        Refresh-ScanCombo
        Set-NavEnabled $true
    } catch {
        [System.Windows.MessageBox]::Show($window,
            "Database created but open failed:`n$($_.Exception.Message)",
            'New database', 'OK', 'Error') | Out-Null
        return
    }

    if (-not $SkipScanPrompt) {
        $ans = [System.Windows.MessageBox]::Show($window,
            "Database created at:`n$target`n`nStart a new scan now?",
            'New database ready', 'YesNo', 'Question')
        if ($ans -eq 'Yes') {
            Show-NewScanDialog
        }
    }
}

# -----------------------------------------------------------------------------
# Run resolver dialog (modal window)
# -----------------------------------------------------------------------------

function Show-RunResolverDialog {
    $app = $Script:App
    $refreshScans = $app.Commands.RefreshScans
    if (-not $app.DbPath -or -not $app.Connection) {
        [System.Windows.MessageBox]::Show('Open a database first.', 'Run resolver', 'OK', 'Warning') | Out-Null
        return
    }

    $xamlPath = Join-Path $Script:PagesRoot 'RunResolverDialog.xaml'
    if (-not (Test-Path $xamlPath)) { throw "Dialog XAML missing: $xamlPath" }

    $reader = [System.Xml.XmlReader]::Create($xamlPath)
    $win    = [System.Windows.Markup.XamlReader]::Load($reader)
    $win.Owner = $app.Window

    $rbAllSids     = $win.FindName('RbAllSids')
    $rbCurrentScan = $win.FindName('RbCurrentScan')
    $chkCheckpoint = $win.FindName('ChkCheckpoint')
    $btnStart      = $win.FindName('BtnStart')
    $btnCancel     = $win.FindName('BtnCancel')
    $btnClose      = $win.FindName('BtnClose')
    $txtOutput     = $win.FindName('TxtOutput')
    $txtStatus     = $win.FindName('TxtStatus')

    $resolverPath = [System.IO.Path]::GetFullPath((Join-Path $Script:ScriptRoot '..\Invoke-ShareAclResolver.ps1'))
    if (-not (Test-Path $resolverPath)) {
        [System.Windows.MessageBox]::Show($win, "Resolver script not found:`n$resolverPath",
            'Run resolver', 'OK', 'Error') | Out-Null
        $win.Close(); return
    }

    # Force whole-DB scope if no scan is selected
    if (-not $app.CurrentScanId) {
        $rbCurrentScan.IsEnabled = $false
        $rbAllSids.IsChecked = $true
    }

    $outputQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    $dlgState = @{
        Proc         = $null
        Phase        = 'idle'
        StdoutRegId  = $null
        StderrRegId  = $null
    }

    $drainQueue = {
        $line = $null
        while ($outputQueue.TryDequeue([ref]$line)) {
            $txtOutput.AppendText($line + "`r`n")
        }
        $txtOutput.ScrollToEnd()
    }.GetNewClosure()

    $appendLine = {
        param([string]$Line)
        if ($null -eq $Line) { return }
        $txtOutput.AppendText($Line + "`r`n")
        $txtOutput.ScrollToEnd()
    }.GetNewClosure()

    $setStatus = {
        param([string]$Text)
        $txtStatus.Text = $Text
    }.GetNewClosure()

    $setRunningUi = {
        param([bool]$Running)
        $btnStart.IsEnabled      = -not $Running
        $btnCancel.IsEnabled     =      $Running
        $btnClose.IsEnabled      = -not $Running
        $rbAllSids.IsEnabled     = -not $Running
        # RbCurrentScan stays disabled if no scan is loaded regardless
        if ($app.CurrentScanId) { $rbCurrentScan.IsEnabled = -not $Running }
        $chkCheckpoint.IsEnabled = -not $Running
    }.GetNewClosure()

    $checkpointDb = {
        try {
            Invoke-SqliteQuery -DataSource $app.DbPath `
                -Query 'PRAGMA wal_checkpoint(TRUNCATE);' | Out-Null
        } catch {
            & $appendLine "Checkpoint failed: $($_.Exception.Message)"
        }
    }.GetNewClosure()

    $encodeCommand = {
        param([string]$Command)
        [System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Command))
    }.GetNewClosure()

    $onResolverExit = {
        param([int]$ExitCode)
        $cancelled = ($dlgState.Phase -eq 'cancelled')
        if ($cancelled) {
            $dlgState.Phase = 'done'
            & $setStatus 'Cancelled.'
            & $setRunningUi $false
            return
        }
        if ($ExitCode -ne 0) {
            $dlgState.Phase = 'done'
            & $setStatus "Resolver failed (exit $ExitCode). See output above."
            & $setRunningUi $false
            return
        }
        if ($chkCheckpoint.IsChecked) {
            & $setStatus 'Checkpointing database…'
            & $checkpointDb
        }
        $dlgState.Phase = 'done'
        & $setStatus 'Complete.'
        try { & $refreshScans } catch { }
        & $setRunningUi $false
    }.GetNewClosure()

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [System.TimeSpan]::FromMilliseconds(100)
    $timer.Add_Tick({
        & $drainQueue
        if ($dlgState.Proc -and $dlgState.Proc.HasExited) {
            $timer.Stop()
            if ($dlgState.StdoutRegId) {
                try { Unregister-Event -SubscriptionId $dlgState.StdoutRegId -ErrorAction SilentlyContinue } catch { }
                $dlgState.StdoutRegId = $null
            }
            if ($dlgState.StderrRegId) {
                try { Unregister-Event -SubscriptionId $dlgState.StderrRegId -ErrorAction SilentlyContinue } catch { }
                $dlgState.StderrRegId = $null
            }
            $exitCode = $dlgState.Proc.ExitCode
            Start-Sleep -Milliseconds 100
            & $drainQueue
            & $onResolverExit $exitCode
        }
    }.GetNewClosure())

    $btnStart.Add_Click({
        $dlgState.Phase = 'running'
        $txtOutput.Clear()
        & $setRunningUi $true
        & $setStatus 'Running resolver…'
        & $appendLine '===== RESOLVER STARTED ====='

        $q = "'"
        $dbEsc       = $app.DbPath.Replace($q, "$q$q")
        $resolverEsc = $resolverPath.Replace($q, "$q$q")
        $scanArg = if ($rbCurrentScan.IsChecked -and $app.CurrentScanId) {
            " -ScanId $($app.CurrentScanId)"
        } else { '' }

        $lines = @()
        $lines += '$ErrorActionPreference = ''Continue'''
        $lines += 'try {'
        $lines += "    & '$resolverEsc' -Database '$dbEsc'$scanArg"
        $lines += '    $rc = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }'
        $lines += '} catch {'
        $lines += '    Write-Host "Resolver threw: $($_.Exception.Message)"'
        $lines += '    $rc = 2'
        $lines += '}'
        $lines += 'Write-Host "===== RESOLVER EXITED (code $rc) ====="'
        $lines += 'exit $rc'
        $childScript = $lines -join "`r`n"

        $encoded = & $encodeCommand $childScript

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = 'pwsh'
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true
        [void]$psi.ArgumentList.Add('-NoProfile')
        [void]$psi.ArgumentList.Add('-NonInteractive')
        [void]$psi.ArgumentList.Add('-EncodedCommand')
        [void]$psi.ArgumentList.Add($encoded)

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi

        $stdoutReg = Register-ObjectEvent -InputObject $proc `
            -EventName OutputDataReceived `
            -MessageData $outputQueue `
            -Action {
                if ($EventArgs.Data) { $Event.MessageData.Enqueue($EventArgs.Data) }
            }
        $stderrReg = Register-ObjectEvent -InputObject $proc `
            -EventName ErrorDataReceived `
            -MessageData $outputQueue `
            -Action {
                $line = $EventArgs.Data
                if (-not $line) { return }
                # Suppress CLIXML records that PowerShell emits on stderr under
                # -NonInteractive with redirected streams. These are error/warning/
                # verbose records serialised for a parent PS host to rehydrate;
                # they're noise in our text-only output pane.
                if ($line -match '^#< CLIXML') { return }
                if ($line -match '^<Objs\b')   { return }
                if ($line -match '^<Obj\b')    { return }
                if ($line -match '^<S\b|^</S>')  { return }
                if ($line -match '^</?Objs>')  { return }
                $Event.MessageData.Enqueue("STDERR: $line")
            }

        [void]$proc.Start()
        $proc.BeginOutputReadLine()
        $proc.BeginErrorReadLine()

        $dlgState.Proc        = $proc
        $dlgState.StdoutRegId = $stdoutReg.Id
        $dlgState.StderrRegId = $stderrReg.Id
        $timer.Start()
    }.GetNewClosure())

    $btnCancel.Add_Click({
        if ($dlgState.Proc -and -not $dlgState.Proc.HasExited) {
            $dlgState.Phase = 'cancelled'
            & $setStatus 'Cancelling…'
            try { $dlgState.Proc.Kill() } catch { }
        }
    }.GetNewClosure())

    $win.Add_Closed({
        try { $timer.Stop() } catch { }
        if ($dlgState.StdoutRegId) {
            try { Unregister-Event -SubscriptionId $dlgState.StdoutRegId -ErrorAction SilentlyContinue } catch { }
        }
        if ($dlgState.StderrRegId) {
            try { Unregister-Event -SubscriptionId $dlgState.StderrRegId -ErrorAction SilentlyContinue } catch { }
        }
        try {
            if ($dlgState.Proc -and -not $dlgState.Proc.HasExited) {
                try { $dlgState.Proc.Kill() } catch { }
            }
            if ($dlgState.Proc) { try { $dlgState.Proc.Dispose() } catch { } }
        } catch { }
    }.GetNewClosure())

    [void]$win.ShowDialog()
}

# -----------------------------------------------------------------------------
# New scan dialog (modal window)
# -----------------------------------------------------------------------------

function Show-NewScanDialog {
    if (-not (Ensure-DatabaseLoaded -Reason 'A database is required before scanning.')) { return }
    
    # Capture App reference locally so closures can rely on it.
    # $Script: scope doesn't survive .GetNewClosure() across event handlers.
    $app = $Script:App
    $refreshScans = $app.Commands.RefreshScans


    $xamlPath = Join-Path $Script:PagesRoot 'NewScanDialog.xaml'
    if (-not (Test-Path $xamlPath)) { throw "Dialog XAML missing: $xamlPath" }

    $reader = [System.Xml.XmlReader]::Create($xamlPath)
    $win    = [System.Windows.Markup.XamlReader]::Load($reader)
    $win.Owner = $Script:App.Window

    $txtRoots         = $win.FindName('TxtRoots')
    $txtBatch         = $win.FindName('TxtBatchSize')
    $txtDepth         = $win.FindName('TxtMaxDepth')
    $chkResolver      = $win.FindName('ChkRunResolver')
    $chkCheckpoint    = $win.FindName('ChkCheckpoint')
    $btnBrowse        = $win.FindName('BtnBrowsePath')
    $btnPrefill       = $win.FindName('BtnPrefillPrev')
    $btnStart         = $win.FindName('BtnStart')
    $btnCancel        = $win.FindName('BtnCancel')
    $btnClose         = $win.FindName('BtnClose')
    $borderProgress   = $win.FindName('BorderProgress')
    $pbProgress       = $win.FindName('PbProgress')
    $txtProgressLeft  = $win.FindName('TxtProgressLeft')
    $txtProgressRight = $win.FindName('TxtProgressRight')
    $txtOutput        = $win.FindName('TxtOutput')
    $txtStatus        = $win.FindName('TxtStatus')

    $collectorPath = [System.IO.Path]::GetFullPath((Join-Path $Script:ScriptRoot '..\Invoke-ShareAclCollector.ps1'))
    $resolverPath  = [System.IO.Path]::GetFullPath((Join-Path $Script:ScriptRoot '..\Invoke-ShareAclResolver.ps1'))

    foreach ($p in @($collectorPath, $resolverPath)) {
        if (-not (Test-Path $p)) {
            [System.Windows.MessageBox]::Show($win, "Required script missing:`n$p",
                'New scan', 'OK', 'Error') | Out-Null
            $win.Close(); return
        }
    }

    # Cross-thread output queue — threadpool writers, UI-thread reader
    $outputQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()

    # Dialog state
    $dlgState = @{
        Proc          = $null
        Phase         = 'idle'      # idle | collecting | resolving | done | cancelled
        RunResolver   = $false
        OnExit        = $null       # scriptblock invoked on UI thread when process exits
        StdoutRegId   = $null       # event subscription IDs for cleanup
        StderrRegId   = $null
        TickCount     = 0           # for throttling UI updates
    }

    # --- UI-thread helpers (no dispatcher marshalling needed) ---

    $drainQueue = {
        $line = $null
        while ($outputQueue.TryDequeue([ref]$line)) {
            $txtOutput.AppendText($line + "`r`n")
        }
        $txtOutput.ScrollToEnd()
    }.GetNewClosure()

    $pollProgress = {
        try {
            $row = Invoke-SqliteQuery -DataSource $app.DbPath -Query @"
                SELECT scan_id, status, total_folders, processed_folders,
                    folders_per_second, estimated_completion_utc, started_utc
                FROM scans
                WHERE status IN ('counting','running')
                ORDER BY scan_id DESC LIMIT 1
"@
        } catch {
            return
        }

        if (-not $row) {
            $borderProgress.Visibility = [System.Windows.Visibility]::Collapsed
            return
        }
        $borderProgress.Visibility = [System.Windows.Visibility]::Visible

        if ($row.status -eq 'counting') {
            $pbProgress.IsIndeterminate = $true
            $txtProgressLeft.Text  = 'Counting folders…'
            $txtProgressRight.Text = ''
            return
        }

        # status = 'running'
        $pbProgress.IsIndeterminate = $false        
        $totalRaw = $row.total_folders
        $total = if ($totalRaw -and $totalRaw -isnot [System.DBNull]) { [int64]$totalRaw } else { 0 }
        $proc  = [int64]$row.processed_folders
        $pct   = if ($total -gt 0) { [Math]::Min(100, ($proc / $total) * 100) } else { 0 }
        $pbProgress.Value = $pct

        $txtProgressLeft.Text = if ($total -gt 0) {
            "{0:N0} / {1:N0} folders  ({2:N1}%)" -f $proc, $total, $pct
        } else {
            "{0:N0} folders processed (total unknown)" -f $proc
        }

        $etaRaw = $row.estimated_completion_utc
        if ($etaRaw -and $etaRaw -isnot [System.DBNull]) {
            try {
                $etaUtc = [DateTime]::Parse($etaRaw, $null,
                            [System.Globalization.DateTimeStyles]::RoundtripKind)
                $etaLocal  = $etaUtc.ToLocalTime()
                $remaining = $etaUtc - [DateTime]::UtcNow
                if ($remaining.TotalSeconds -lt 0) { $remaining = [TimeSpan]::Zero }

                $hours   = [Math]::Floor($remaining.TotalHours)
                $minutes = $remaining.Minutes
                $seconds = $remaining.Seconds
                $etaStr  = "{0}h {1:D2}m {2:D2}s" -f $hours, $minutes, $seconds

                $txtProgressRight.Text = ("ETA {0}   ·   Finish {1}" -f $etaStr,
                                        $etaLocal.ToString('yyyy-MM-dd HH:mm:ss'))
            } catch {
                $txtProgressRight.Text = 'Calculating ETA…'
            }
        } else {
            $txtProgressRight.Text = 'Calculating ETA…'
        }
    }.GetNewClosure()

    $appendLine = {
        param([string]$Line)
        if ($null -eq $Line) { return }
        $txtOutput.AppendText($Line + "`r`n")
        $txtOutput.ScrollToEnd()
    }.GetNewClosure()

    $setStatus = {
        param([string]$Text)
        $txtStatus.Text = $Text
    }.GetNewClosure()

    $setRunningUi = {
        param([bool]$Running)
        $btnStart.IsEnabled      = -not $Running
        $btnCancel.IsEnabled     =      $Running
        $btnClose.IsEnabled      = -not $Running
        $txtRoots.IsEnabled      = -not $Running
        $txtBatch.IsEnabled      = -not $Running
        $txtDepth.IsEnabled      = -not $Running
        $chkResolver.IsEnabled   = -not $Running
        $chkCheckpoint.IsEnabled = -not $Running
        $btnBrowse.IsEnabled     = -not $Running
        $btnPrefill.IsEnabled    = -not $Running
    }.GetNewClosure()

    $checkpointDb = {
        try {
            Invoke-SqliteQuery -DataSource $app.DbPath `
                -Query 'PRAGMA wal_checkpoint(TRUNCATE);' | Out-Null
        } catch {
            & $appendLine "Checkpoint failed: $($_.Exception.Message)"
        }
    }.GetNewClosure()

    $encodeCommand = {
        param([string]$Command)
        [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Command))
    }.GetNewClosure()

    $onScanExit = {
        param([int]$ExitCode)
        $cancelled = ($dlgState.Phase -eq 'cancelled')
        if ($cancelled) {
            $dlgState.Phase = 'done'
            & $setStatus 'Cancelled. Partial scan can be resumed via -Resume in a manual run.'
            & $refreshScans
            & $setRunningUi $false
            return
        }
        if ($ExitCode -ne 0) {
            $dlgState.Phase = 'done'
            & $setStatus "Scan pipeline failed (exit $ExitCode). See output above."
            & $refreshScans
            & $setRunningUi $false
            return
        }
        if ($chkCheckpoint.IsChecked) {
            & $setStatus 'Checkpointing database…'
            & $checkpointDb
        }
        $dlgState.Phase = 'done'
        & $setStatus 'Complete.'
        & $refreshScans
        & $setRunningUi $false
    }.GetNewClosure()

    # --- DispatcherTimer: drains output and polls process exit on the UI thread ---
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(100)
    $timer.Add_Tick({
        & $drainQueue
    
        $dlgState.TickCount++
        if (($dlgState.TickCount % 10) -eq 0) { & $pollProgress }

        if ($dlgState.Proc -and $dlgState.Proc.HasExited) {
            $timer.Stop()

            # Unregister event subscriptions so they don't leak across runs
            if ($dlgState.StdoutRegId) {
                try { Unregister-Event -SubscriptionId $dlgState.StdoutRegId -ErrorAction SilentlyContinue } catch { }
                $dlgState.StdoutRegId = $null
            }
            if ($dlgState.StderrRegId) {
                try { Unregister-Event -SubscriptionId $dlgState.StderrRegId -ErrorAction SilentlyContinue } catch { }
                $dlgState.StderrRegId = $null
            }
            
            $exitCode = $dlgState.Proc.ExitCode
            Start-Sleep -Milliseconds 100
            & $drainQueue

            
            # Final poll to catch the last progress update, then hide the bar
            & $pollProgress
            $borderProgress.Visibility = [System.Windows.Visibility]::Collapsed

            & $onScanExit $exitCode
        }
    }.GetNewClosure())

    # --- Start button ---
    $btnStart.Add_Click({
        $paths = @($txtRoots.Text -split "`r?`n" |
                ForEach-Object { $_.Trim() } |
                Where-Object { $_ })
        if ($paths.Count -eq 0) {
            [System.Windows.MessageBox]::Show($win, 'Provide at least one root path.',
                'New scan', 'OK', 'Warning') | Out-Null
            return
        }

        $batchSize = 500
        if (-not [int]::TryParse($txtBatch.Text.Trim(), [ref]$batchSize) -or $batchSize -lt 1) {
            [System.Windows.MessageBox]::Show($win, 'Batch size must be a positive integer.',
                'New scan', 'OK', 'Warning') | Out-Null
            return
        }

        $maxDepth = 0
        if ($txtDepth.Text.Trim()) {
            if (-not [int]::TryParse($txtDepth.Text.Trim(), [ref]$maxDepth) -or $maxDepth -lt 1) {
                [System.Windows.MessageBox]::Show($win, 'Max depth must be blank or a positive integer.',
                    'New scan', 'OK', 'Warning') | Out-Null
                return
            }
        }

        $runResolver = [bool]$chkResolver.IsChecked
        $dlgState.Phase = 'collecting'

        $borderProgress.Visibility = [System.Windows.Visibility]::Collapsed
        $pbProgress.Value = 0
        $pbProgress.IsIndeterminate = $false
        $txtProgressLeft.Text  = ''
        $txtProgressRight.Text = ''
        $dlgState.TickCount = 0

        $txtOutput.Clear()
        & $setRunningUi $true
        & $setStatus 'Running scan pipeline…'

        # Escape single quotes for embedding in single-quoted strings inside the composite
        $q = "'"
        $rootsLiteral = ($paths | ForEach-Object { "$q" + $_.Replace($q, "$q$q") + "$q" }) -join ','
        $dbEsc        = $app.DbPath.Replace($q, "$q$q")
        $collectorEsc = $collectorPath.Replace($q, "$q$q")
        $resolverEsc  = $resolverPath.Replace($q, "$q$q")
        $depthArg     = if ($maxDepth -gt 0) { " -MaxDepth $maxDepth" } else { '' }

        # Compose the child script. Single-quoted lines have no interpolation from PS7-outer;
        # double-quoted lines interpolate outer variables. `$` inside strings we want the child
        # to see literally is escaped with a backtick.
        $lines = @()
        $lines += '$ErrorActionPreference = ''Continue'''
        $lines += "Write-Host '===== COLLECTOR STARTED ====='"
        $lines += 'try {'
        $lines += "    & '$collectorEsc' -RootPath @($rootsLiteral) -Database '$dbEsc' -BatchSize $batchSize$depthArg"
        $lines += '    $collectorExit = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }'
        $lines += '} catch {'
        $lines += '    Write-Host "Collector threw: $($_.Exception.Message)"'
        $lines += '    $collectorExit = 1'
        $lines += '}'
        $lines += 'Write-Host "===== COLLECTOR EXITED (code $collectorExit) ====="'
        if ($runResolver) {
            $lines += 'if ($collectorExit -eq 0) {'
            $lines += "    Write-Host ''"
            $lines += "    Write-Host '===== RESOLVER STARTED ====='"
            $lines += '    try {'
            $lines += "        & '$resolverEsc' -Database '$dbEsc'"
            $lines += '        $resolverExit = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }'
            $lines += '    } catch {'
            $lines += '        Write-Host "Resolver threw: $($_.Exception.Message)"'
            $lines += '        $resolverExit = 2'
            $lines += '    }'
            $lines += '    Write-Host "===== RESOLVER EXITED (code $resolverExit) ====="'
            $lines += '    exit $resolverExit'
            $lines += '} else {'
            $lines += "    Write-Host 'Skipping resolver (collector did not succeed).'"
            $lines += '}'
        }
        $lines += 'exit $collectorExit'
        $childScript = $lines -join "`r`n"

        # Encode and launch
        $encoded = & $encodeCommand $childScript

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = 'pwsh'
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true
        [void]$psi.ArgumentList.Add('-NoProfile')
        [void]$psi.ArgumentList.Add('-NonInteractive')
        [void]$psi.ArgumentList.Add('-EncodedCommand')
        [void]$psi.ArgumentList.Add($encoded)

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi

        $stdoutReg = Register-ObjectEvent -InputObject $proc `
            -EventName OutputDataReceived `
            -MessageData $outputQueue `
            -Action {
                if ($EventArgs.Data) { $Event.MessageData.Enqueue($EventArgs.Data) }
            }
        $stderrReg = Register-ObjectEvent -InputObject $proc `
            -EventName ErrorDataReceived `
            -MessageData $outputQueue `
            -Action {
                $line = $EventArgs.Data
                if (-not $line) { return }
                # Suppress CLIXML records that PowerShell emits on stderr under
                # -NonInteractive with redirected streams. These are error/warning/
                # verbose records serialised for a parent PS host to rehydrate;
                # they're noise in our text-only output pane.
                if ($line -match '^#< CLIXML') { return }
                if ($line -match '^<Objs\b')   { return }
                if ($line -match '^<Obj\b')    { return }
                if ($line -match '^<S\b|^</S>')  { return }
                if ($line -match '^</?Objs>')  { return }
                $Event.MessageData.Enqueue("STDERR: $line")
            }

        [void]$proc.Start()
        $proc.BeginOutputReadLine()
        $proc.BeginErrorReadLine()

        $dlgState.Proc        = $proc
        $dlgState.StdoutRegId = $stdoutReg.Id
        $dlgState.StderrRegId = $stderrReg.Id
        $timer.Start()
        & $pollProgress
    }.GetNewClosure())

    $btnCancel.Add_Click({
        if ($dlgState.Proc -and -not $dlgState.Proc.HasExited) {
            $dlgState.Phase = 'cancelled'
            & $setStatus 'Cancelling…'
            try { $dlgState.Proc.Kill() } catch { }
        }
    }.GetNewClosure())

    $btnBrowse.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            if ($txtRoots.Text.TrimEnd() -ne '') { $txtRoots.AppendText("`r`n") }
            $txtRoots.AppendText($dlg.SelectedPath)
        }
    }.GetNewClosure())

    $btnPrefill.Add_Click({
        try {
            $row = Invoke-SqliteQuery -SQLiteConnection $app.Connection `
                -Query 'SELECT root_paths_json FROM scans ORDER BY scan_id DESC LIMIT 1'
            if (-not $row) {
                $txtStatus.Text = 'No previous scan found in this database.'
                return
            }
            $json = [string]$row.root_paths_json
            if ([string]::IsNullOrWhiteSpace($json)) {
                $txtStatus.Text = 'Previous scan has no recorded root paths.'
                return
            }
            $roots = @($json | ConvertFrom-Json)
            if ($roots.Count -eq 0) {
                $txtStatus.Text = 'Previous scan has no recorded root paths.'
                return
            }
            $txtRoots.Text = ($roots -join "`r`n")
            $txtStatus.Text = "Prefilled $($roots.Count) root path(s) from most recent scan."
        } catch {
            $txtStatus.Text = "Prefill failed: $($_.Exception.Message)"
        }
    }.GetNewClosure())

    $win.Add_Closed({
        try { $timer.Stop() } catch { }
        if ($dlgState.StdoutRegId) {
            try { Unregister-Event -SubscriptionId $dlgState.StdoutRegId -ErrorAction SilentlyContinue } catch { }
        }
        if ($dlgState.StderrRegId) {
            try { Unregister-Event -SubscriptionId $dlgState.StderrRegId -ErrorAction SilentlyContinue } catch { }
        }
        try {
            if ($dlgState.Proc -and -not $dlgState.Proc.HasExited) {
                try { $dlgState.Proc.Kill() } catch { }
            }
            if ($dlgState.Proc) { try { $dlgState.Proc.Dispose() } catch { } }
        } catch { }
    }.GetNewClosure())

    [void]$win.ShowDialog()
}

# -----------------------------------------------------------------------------
# Page navigation
# -----------------------------------------------------------------------------
function Import-WpfXamlFile {
    param([Parameter(Mandatory)] [string]$Path)

    $reader = $null
    try {
        $reader = [System.Xml.XmlReader]::Create($Path)
        [System.Windows.Markup.XamlReader]::Load($reader)
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
    }
}

function Navigate-Page {
    param(
        [Parameter(Mandatory)] [string] $PageName
    )

    $previousPage = $Script:App.CurrentPage
    if ($null -ne $previousPage) {
        $previousPage.IsActive = $false
        $Script:App.CancelPageAsync($previousPage, $false)
    }

    $Script:App.BusyOperationId = $null
    if ($null -ne $Script:App.BusyOverlay) {
        $Script:App.BusyOverlay.Visibility = [System.Windows.Visibility]::Collapsed
    }
    if ($null -ne $Script:App.PageHost) { $Script:App.PageHost.Content = $null }

    $xamlPath = Join-Path $Script:PagesRoot "$PageName.xaml"
    $codePath = Join-Path $Script:PagesRoot "$PageName.ps1"
    try {
        if (-not (Test-Path $xamlPath)) { throw "Page XAML missing: $xamlPath" }
        if (-not (Test-Path $codePath)) { throw "Page code missing: $codePath" }

        $page = Import-WpfXamlFile -Path $xamlPath
        $pageContext = [pscustomobject]@{
            Id         = [guid]::NewGuid().ToString('N')
            Name       = $PageName
            Page       = $page
            State      = $null
            IsActive   = $true
            Operations = @{}
        }
        $page.Tag = $pageContext

        $Script:App.CurrentPageName = $PageName
        $Script:App.CurrentPage     = $pageContext

        # The page creates its state and event handlers before it becomes visible.
        & $codePath -Page $page -App $Script:App

        $Script:App.PageHost.Content = $page
        Set-Status "Loaded $PageName"
    } catch {
        if ($null -ne $Script:App.CurrentPage) {
            $Script:App.CurrentPage.IsActive = $false
            $Script:App.CancelPageAsync($Script:App.CurrentPage, $false)
        }
        $Script:App.CurrentPageName = $null
        $Script:App.CurrentPage     = $null
        $Script:App.ShowError('Page load failed', $_.Exception.Message)
    }
}

# -----------------------------------------------------------------------------
# UI plumbing
# -----------------------------------------------------------------------------
function Set-Status   { param([string]$Text) $Script:App.StatusBar.Text = $Text }
function Set-DbInfo   { param([string]$Text) $Script:App.DbInfo.Text    = $Text }

function Update-DbInfoLabel {
    if (-not $Script:App.DbPath) { Set-DbInfo ""; return }
    try {
        $fi = Get-Item $Script:App.DbPath
        Set-DbInfo ("{0}  ·  {1:N1} MB" -f (Split-Path $Script:App.DbPath -Leaf), ($fi.Length / 1MB))
    } catch { Set-DbInfo $Script:App.DbPath }
}

function Set-NavEnabled {
    param([bool]$Enabled)

    # Views require a loaded DB (they read from it)
    foreach ($name in 'NavFolder','NavAccount','NavFindings') {
        $btn = $Script:App.NavButtons[$name]
        if ($btn) { $btn.IsEnabled = $Enabled }
    }

    # Actions are always available — they prompt for a DB if none is loaded
    foreach ($name in 'NavNewDb','NavCollect','NavSwap') {
        $btn = $Script:App.NavButtons[$name]
        if ($btn) { $btn.IsEnabled = $true }
    }
    
    $btn = $Script:App.NavButtons['NavResolve']
    if ($btn) { $btn.IsEnabled = $Enabled }
}

# WPF callbacks can run in a dynamic module scope where a function name from
# this script is not resolvable. Store bound ScriptBlock objects once, while the
# main script scope is active, and have every callback invoke these objects.
$Script:App.Commands = [pscustomobject]@{
    StartAsync      = (Get-Item -LiteralPath 'Function:\Start-AppAsyncOperation').ScriptBlock
    CompleteAsync   = (Get-Item -LiteralPath 'Function:\Complete-AppAsyncOperation').ScriptBlock
    StopOperation   = (Get-Item -LiteralPath 'Function:\Stop-AppAsyncOperation').ScriptBlock
    StopPage        = (Get-Item -LiteralPath 'Function:\Stop-AppPageOperations').ScriptBlock
    StopAll         = (Get-Item -LiteralPath 'Function:\Stop-AllAppOperations').ScriptBlock
    Navigate        = (Get-Item -LiteralPath 'Function:\Navigate-Page').ScriptBlock
    PickPrincipal   = (Get-Item -LiteralPath 'Function:\Show-PrincipalPicker').ScriptBlock
    OpenDatabase    = (Get-Item -LiteralPath 'Function:\Open-ShareAclDatabase').ScriptBlock
    CloseDatabase   = (Get-Item -LiteralPath 'Function:\Close-ShareAclDatabase').ScriptBlock
    RefreshScans    = (Get-Item -LiteralPath 'Function:\Refresh-ScanCombo').ScriptBlock
    SetCurrentScan  = (Get-Item -LiteralPath 'Function:\Set-CurrentScan').ScriptBlock
    SetNavEnabled   = (Get-Item -LiteralPath 'Function:\Set-NavEnabled').ScriptBlock
    SetStatus       = (Get-Item -LiteralPath 'Function:\Set-Status').ScriptBlock
    EnsureDatabase  = (Get-Item -LiteralPath 'Function:\Ensure-DatabaseLoaded').ScriptBlock
    ResolverDialog  = (Get-Item -LiteralPath 'Function:\Show-RunResolverDialog').ScriptBlock
    NewDatabase     = (Get-Item -LiteralPath 'Function:\New-ShareAclDatabase').ScriptBlock
    NewScanDialog   = (Get-Item -LiteralPath 'Function:\Show-NewScanDialog').ScriptBlock
}

# -----------------------------------------------------------------------------
# Load the window
# -----------------------------------------------------------------------------
$xamlPath = Join-Path $Script:ScriptRoot 'ShareAcl.xaml'
if (-not (Test-Path $xamlPath)) { throw "Main XAML missing: $xamlPath" }

$window = Import-WpfXamlFile -Path $xamlPath

$Script:App.Window      = $window
$Script:App.StatusBar   = $window.FindName('TxtStatus')
$Script:App.DbInfo      = $window.FindName('TxtDbInfo')
$Script:App.PageHost    = $window.FindName('PageHost')
$Script:App.BusyOverlay = $window.FindName('BusyOverlay')
$Script:App.BusyText    = $window.FindName('BusyText')
$window.DataContext     = $Script:App

foreach ($name in 'NavFolder','NavAccount','NavFindings','NavSwap','NavNewDb','NavCollect','NavResolve') {
    $Script:App.NavButtons[$name] = $window.FindName($name)
}

# Wire top-bar buttons
$window.FindName('BtnBrowseDb').Add_Click({
    param($sender, $eventArgs)

    $app = $sender.DataContext
    $dialog = [System.Windows.Forms.OpenFileDialog]::new()
    $dialog.Filter = 'ShareACL database (*.db)|*.db|All files (*.*)|*.*'
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $app.Window.FindName('TxtDbPath').Text = $dialog.FileName
    }
    $dialog.Dispose()
})

$window.FindName('BtnOpenDb').Add_Click({
    param($sender, $eventArgs)

    $app = $sender.DataContext
    try {
        $openDatabase = $app.Commands.OpenDatabase
        $refreshScans = $app.Commands.RefreshScans
        $setNavigation = $app.Commands.SetNavEnabled
        $databasePath = $app.Window.FindName('TxtDbPath').Text
        & $openDatabase -Path $databasePath
        & $refreshScans
        & $setNavigation -Enabled $true
    } catch {
        $app.ShowError('Open database failed', $_.Exception.Message)
    }
})

$window.FindName('BtnRefreshScans').Add_Click({
    param($sender, $eventArgs)
    $command = $sender.DataContext.Commands.RefreshScans
    & $command
})

$window.FindName('CmbScan').Add_SelectionChanged({
    param($sender, $eventArgs)

    $app = $sender.DataContext
    if (-not $app.SuppressScanSelectionChanged) {
        $selectedScanId = if ($null -ne $sender.SelectedItem) {
            $sender.SelectedItem.ScanId
        } else {
            $null
        }
        $command = $app.Commands.SetCurrentScan
        & $command -ScanId $selectedScanId
    }
})

# Wire navigation
$Script:App.NavButtons['NavFolder'].Add_Click({
    param($sender, $eventArgs)
    $sender.DataContext.Navigate('FolderView')
})
$Script:App.NavButtons['NavAccount'].Add_Click({
    param($sender, $eventArgs)
    $sender.DataContext.Navigate('AccountView')
})
$Script:App.NavButtons['NavFindings'].Add_Click({
    param($sender, $eventArgs)
    $sender.DataContext.Navigate('FindingsView')
})
$Script:App.NavButtons['NavSwap'].Add_Click({
    param($sender, $eventArgs)

    $app = $sender.DataContext
    $ensureDatabase = $app.Commands.EnsureDatabase
    if (& $ensureDatabase -Reason 'A database is required to record swap operations.') {
        $app.Navigate('SwapView')
    }
})
$Script:App.NavButtons['NavResolve'].Add_Click({
    param($sender, $eventArgs)

    $app = $sender.DataContext
    $ensureDatabase = $app.Commands.EnsureDatabase
    if (& $ensureDatabase -Reason 'A database is required before running the resolver.') {
        $command = $app.Commands.ResolverDialog
        & $command
    }
})
$Script:App.NavButtons['NavNewDb'].Add_Click({
    param($sender, $eventArgs)
    $command = $sender.DataContext.Commands.NewDatabase
    & $command
})
$Script:App.NavButtons['NavCollect'].Add_Click({
    param($sender, $eventArgs)
    $command = $sender.DataContext.Commands.NewScanDialog
    & $command
})

# Auto-open if a path was passed on the command line
if ($Database) {
    $window.FindName('TxtDbPath').Text = $Database
    $window.Add_Loaded({
        param($sender, $eventArgs)

        $app = $sender.DataContext
        try {
            $openDatabase = $app.Commands.OpenDatabase
            $refreshScans = $app.Commands.RefreshScans
            $setNavigation = $app.Commands.SetNavEnabled
            & $openDatabase -Path $app.StartupDatabase
            & $refreshScans
            & $setNavigation -Enabled $true
        } catch {
            $app.SetStatus("Auto-open failed: $($_.Exception.Message)")
        }
    })
}

Set-NavEnabled $false   # locked until a DB is open

# Warn (not block) if not elevated. Some operations work fine without elevation
# (e.g., where the user has Modify on the share); others need it.
$ident = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$princ = [System.Security.Principal.WindowsPrincipal]::new($ident)
if (-not $princ.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $Script:App.StatusBar.Text =
        "Running non-elevated. ACL writes will only succeed where your user has direct rights."
}

try {
    [void]$window.ShowDialog()
} finally {
    # Runspace shutdown must not happen inside a WPF event callback. Performing
    # it here avoids re-entering PowerShell's event pipeline while Stop() is
    # restoring runspace scopes.
    $Script:App.IsClosing = $true
    if ($null -ne $Script:App.CurrentPage) {
        $Script:App.CurrentPage.IsActive = $false
    }
    if ($null -ne $Script:App.PageHost) {
        $Script:App.PageHost.Content = $null
    }

    $stopAll = $Script:App.Commands.StopAll
    & $stopAll -App $Script:App -Synchronous

    $closeDatabase = $Script:App.Commands.CloseDatabase
    try { & $closeDatabase } catch { }

    foreach ($key in @($Script:App.NavButtons.Keys)) {
        $Script:App.NavButtons[$key] = $null
    }
    $Script:App.NavButtons.Clear()

    $Script:App.Window          = $null
    $Script:App.PageHost        = $null
    $Script:App.StatusBar       = $null
    $Script:App.DbInfo          = $null
    $Script:App.NavContext      = $null
    $Script:App.CurrentPage     = $null
    $Script:App.CurrentPageName = $null
}
