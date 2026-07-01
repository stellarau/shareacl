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
    Window          = $null
    StatusBar       = $null
    DbInfo          = $null
    PageHost        = $null
    NavButtons      = @{}
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
    $this.StatusBar.Text = $Text
}

$Script:App | Add-Member -MemberType ScriptMethod -Name ShowError -Value {
    param([string]$Title, [string]$Message)
    [System.Windows.MessageBox]::Show($Message, $Title, 'OK', 'Error') | Out-Null
    $this.StatusBar.Text = $Message
}

$Script:App | Add-Member -MemberType ScriptMethod -Name PickPrincipal -Value {
    param(
        [string] $Title         = 'Pick a principal',
        [string] $DefaultSource = 'Database'
    )
    Show-PrincipalPicker -Title $Title -DefaultSource $DefaultSource
}

# Navigation context: outgoing pages set it, incoming pages consume it once.
$Script:App | Add-Member -NotePropertyName NavContext -NotePropertyValue $null

$Script:App | Add-Member -MemberType ScriptMethod -Name Navigate -Value {
    param([string]$PageName)
    Navigate-Page $PageName
}

# -----------------------------------------------------------------------------
# DB layer
# -----------------------------------------------------------------------------
function Open-ShareAclDatabase {
    param([string]$Path)

    if (-not (Test-Path $Path)) { throw "Database not found: $Path" }

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

    Close-ShareAclDatabase

    $conn = New-SQLiteConnection -DataSource $Path
    if ($conn.State -ne [System.Data.ConnectionState]::Open) { $conn.Open() }

    $Script:App.DbPath     = $Path
    $Script:App.Connection = $conn

    Update-DbInfoLabel
    Set-Status "Opened $Path"
}

function Close-ShareAclDatabase {
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

function Refresh-ScanCombo {
    $cmb = $Script:App.Window.FindName('CmbScan')
    $list = @([pscustomobject]@{ ScanId = $null; Display = '(none — no scan selected)' })
    $list += @(Get-ScanList)
    $cmb.ItemsSource = $list
    # Auto-select the newest real scan if present; otherwise the "none" row
    if ($list.Count -gt 1) { $cmb.SelectedIndex = 1 } else { $cmb.SelectedIndex = 0 }
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
# Page navigation
# -----------------------------------------------------------------------------
function Navigate-Page {
    param(
        [Parameter(Mandatory)] [string] $PageName
    )
    $xamlPath = Join-Path $Script:PagesRoot "$PageName.xaml"
    $codePath = Join-Path $Script:PagesRoot "$PageName.ps1"
    if (-not (Test-Path $xamlPath)) { throw "Page XAML missing: $xamlPath" }
    if (-not (Test-Path $codePath)) { throw "Page code missing: $codePath" }

    $reader = [System.Xml.XmlReader]::Create($xamlPath)
    $page   = [System.Windows.Markup.XamlReader]::Load($reader)

    # Page code-behind gets the page object and the app state
    & $codePath -Page $page -App $Script:App

    $Script:App.PageHost.Content = $page
    Set-Status "Loaded $PageName"
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
    foreach ($name in 'NavFolder','NavAccount','NavFindings','NavSwap','NavCollect') {
        $btn = $Script:App.NavButtons[$name]
        if ($btn) { $btn.IsEnabled = $Enabled }
    }
}

# -----------------------------------------------------------------------------
# Load the window
# -----------------------------------------------------------------------------
$xamlPath = Join-Path $Script:ScriptRoot 'ShareAcl.xaml'
if (-not (Test-Path $xamlPath)) { throw "Main XAML missing: $xamlPath" }

$reader = [System.Xml.XmlReader]::Create($xamlPath)
$window = [System.Windows.Markup.XamlReader]::Load($reader)

$Script:App.Window     = $window
$Script:App.StatusBar  = $window.FindName('TxtStatus')
$Script:App.DbInfo     = $window.FindName('TxtDbInfo')
$Script:App.PageHost   = $window.FindName('PageHost')

foreach ($name in 'NavFolder','NavAccount','NavFindings','NavSwap','NavCollect') {
    $Script:App.NavButtons[$name] = $window.FindName($name)
}

# Wire top-bar buttons
$window.FindName('BtnBrowseDb').Add_Click({
    $dlg = [System.Windows.Forms.OpenFileDialog]::new()
    $dlg.Filter = 'ShareACL database (*.db)|*.db|All files (*.*)|*.*'
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $window.FindName('TxtDbPath').Text = $dlg.FileName
    }
})

$window.FindName('BtnOpenDb').Add_Click({
    try {
        Open-ShareAclDatabase -Path $window.FindName('TxtDbPath').Text
        Refresh-ScanCombo
        Set-NavEnabled $true
    } catch {
        [System.Windows.MessageBox]::Show($_.Exception.Message, 'Open database failed',
            'OK', 'Error') | Out-Null
        Set-Status "Open failed: $($_.Exception.Message)"
    }
})

$window.FindName('BtnRefreshScans').Add_Click({ Refresh-ScanCombo })

$window.FindName('CmbScan').Add_SelectionChanged({
    $sel = $window.FindName('CmbScan').SelectedItem
    if (-not $sel) { return }
    $Script:App.CurrentScanId = $sel.ScanId   # may be $null
    
    $hasScan = ($null -ne $sel.ScanId)
    foreach ($name in 'NavFolder','NavAccount','NavFindings') {
        $btn = $Script:App.NavButtons[$name]
        if ($btn) { $btn.IsEnabled = $hasScan }
    }
    # NavSwap stays enabled regardless — it works in live mode without a scan.
    # NavCollect stays enabled regardless once it's wired (future iteration).

    if ($hasScan) {
        Set-Status "Active scan: #$($Script:App.CurrentScanId)"
    } else {
        Set-Status "No scan selected (Swap available in live mode only)."
    }
})

# Wire navigation
$Script:App.NavButtons['NavFolder'].Add_Click({ Navigate-Page 'FolderView' })
$Script:App.NavButtons['NavAccount'].Add_Click({ Navigate-Page 'AccountView' })
$Script:App.NavButtons['NavFindings'].Add_Click({ Navigate-Page 'FindingsView' })
$Script:App.NavButtons['NavSwap'].Add_Click({ Navigate-Page 'SwapView' })
# (others wired in v0.6 as they're built)

# Close cleanly
$window.Add_Closed({
    try {
        Close-ShareAclDatabase
    } catch { }
  
    # Detach the current page so its controls are eligible for GC
    if ($Script:App.PageHost) {
        $Script:App.PageHost.Content = $null
    }

    # Clear the nav-button event handlers and references
    foreach ($k in @($Script:App.NavButtons.Keys)) {
        $Script:App.NavButtons[$k] = $null
    }
    $Script:App.NavButtons.Clear()

    # Drop references on the App bag
    $Script:App.Window     = $null
    $Script:App.PageHost   = $null
    $Script:App.StatusBar  = $null
    $Script:App.DbInfo     = $null
    $Script:App.NavContext = $null

    # Force a collection cycle so finalisers run before the script exits
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    [System.GC]::Collect()

})

# Auto-open if a path was passed on the command line
if ($Database) {
    $window.FindName('TxtDbPath').Text = $Database
    $window.Add_Loaded({
        try {
            Open-ShareAclDatabase -Path $Database
            Refresh-ScanCombo
            Set-NavEnabled $true
        } catch {
            Set-Status "Auto-open failed: $($_.Exception.Message)"
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

[void]$window.ShowDialog()