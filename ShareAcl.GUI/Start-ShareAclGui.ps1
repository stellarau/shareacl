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

    $args = @{
        SQLiteConnection = $Script:App.Connection
        Query            = $Query
    }
    if ($SqlParameters) { $args.SqlParameters = $SqlParameters }
    Invoke-SqliteQuery @args
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
    $cmb.ItemsSource = @(Get-ScanList)
    if ($cmb.Items.Count -gt 0) {
        $cmb.SelectedIndex = 0   # newest first
    }
}

# -----------------------------------------------------------------------------
# Principal picker (shared dialog used by Account view and Swap workflow)
# -----------------------------------------------------------------------------
function Show-PrincipalPicker {
    <#  Returns a hashtable @{ Sid; Name; Type } or $null if cancelled.
        Searches the principals table by name fragment. #>
    param([string]$Title = 'Pick a principal')

    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$Title" Height="500" Width="600"
        WindowStartupLocation="CenterOwner" FontFamily="Segoe UI" FontSize="12">
    <DockPanel Margin="10">
        <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,8">
            <TextBlock Text="Search:" VerticalAlignment="Center" Margin="0,0,6,0"/>
            <TextBox x:Name="TxtSearch" Width="400"/>
            <Button x:Name="BtnSearch" Content="Search" Margin="6,0,0,0" Padding="10,2"/>
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

    $txt = $win.FindName('TxtSearch')
    $grd = $win.FindName('GrdResults')
    $ok  = $win.FindName('BtnOk')
    $btn = $win.FindName('BtnSearch')

    $doSearch = {
        $q = $txt.Text.Trim()
        if (-not $q) { $grd.ItemsSource = @(); return }
        $rows = Invoke-AppQuery -Query @"
            SELECT sid AS Sid, name AS Name, sam_account_name AS Sam, principal_type AS Type
            FROM principals
            WHERE name LIKE @q OR sam_account_name LIKE @q OR sid = @exact
            ORDER BY name LIMIT 200
"@ -SqlParameters @{ q = "%$q%"; exact = $q }
        $grd.ItemsSource = @($rows)
    }
    $btn.Add_Click($doSearch)
    $txt.Add_KeyDown({ if ($_.Key -eq 'Return') { & $doSearch } })

    $result = $null
    $ok.Add_Click({
        if ($grd.SelectedItem) {
            $script:result = @{
                Sid  = $grd.SelectedItem.Sid
                Name = $grd.SelectedItem.Name
                Type = $grd.SelectedItem.Type
            }
            $win.DialogResult = $true
            $win.Close()
        }
    })

    [void]$win.ShowDialog()
    return $script:result
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

    $Script:App.PageHost.Navigate($page)
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
    if ($sel) {
        $Script:App.CurrentScanId = [int]$sel.ScanId
        Set-Status "Active scan: #$($Script:App.CurrentScanId)"
    }
})

# Wire navigation
$Script:App.NavButtons['NavFolder'].Add_Click({ Navigate-Page 'FolderView' })
# (others wired in v0.2 as they're built)

# Close cleanly
$window.Add_Closed({ Close-ShareAclDatabase })

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
[void]$window.ShowDialog()