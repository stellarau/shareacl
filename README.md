# ShareACL

ShareACL is a PowerShell GUI tool for mass auditing folder permissions. It also provides built-in functionality for drop-in swapping principals in folder ACLs.

The main use case is simple: point ShareACL at one or more file share roots, let it collect NTFS permissions into a local SQLite database, then use the views to find risky or messy permissions without clicking through every folder by hand.

ShareACL does not replace normal change control. Treat the scan output as audit evidence, and treat ACL Swap as a change tool.

## Features

The following features are currently implemented:

| Feature | Description |
| --- | --- |
| 📁 Folder view | Per-folder view of all assigned principals and their access levels |
| 👤 Account view | Per-account view of folders the selected principal has access to |
| 📋 Findings view | A summary of potential problems in the permission structure |
| 🔃 ACL Swap | A tool to replace one principal with another in a folder structure |
| 🔍 Scan functionality | The core of the tool providing information to each of the views listed above |

The scan collector and resolver can also be run independently without the GUI wrapper.

At a high level:

1. The collector walks the selected folder roots and records folders, owners, inheritance state, and ACEs.
2. The resolver looks up the SIDs from the scan in Active Directory and records names, account types, and group membership.
3. The GUI reads the database and presents the results.

## Prerequisites

- PowerShell 7+
- ActiveDirectory module
- PSSQLite module
- NTFSSecurity module

Run the tool from a Windows device that can reach the file shares and the domain controllers for the target environment.

The account running the scan needs read access to the folders being scanned. If the account cannot read a folder, ShareACL will keep going and record the error in the scan results.

For ACL Swap, run PowerShell as Administrator where possible. ACL writes still depend on the permissions of the account running the tool.

### Checking prerequisites

Open PowerShell 7 and run:

```powershell
$PSVersionTable.PSVersion
Get-Module -ListAvailable ActiveDirectory, PSSQLite, NTFSSecurity
```

If a module is missing:

- `ActiveDirectory` is normally installed through RSAT or Windows Server management tools.
- `PSSQLite` and `NTFSSecurity` can normally be installed from the PowerShell Gallery if your workstation has access to it:

```powershell
Install-Module PSSQLite -Scope CurrentUser
Install-Module NTFSSecurity -Scope CurrentUser
```

## Installation and usage

### Getting started

1. Clone the repository to a device with access to your AD and file shares
2. Run `ShareAcl.GUI\Start-ShareAcl.ps1` (see note below)
3. On first run, you will need to create a new database

> **NOTE:** The `Start-ShareAcl.ps1` launcher is used to contain the tool into its own PowerShell process, which prevents excessive handle leakage across multiple runs.

Simple first run:

```powershell
cd "C:\Path\To\NTFS Permissions"
.\ShareAcl.GUI\Start-ShareAcl.ps1
```

When the window opens:

1. Click **New database...**
2. Save the database somewhere sensible, for example `C:\Temp\shareacl.db`
3. Click **New scan...**
4. Enter the share root paths you need to scan
5. Leave **Run resolver after** ticked
6. Click **Start scan**

You can also open an existing database by using the **Database** box at the top of the window:

1. Click **Browse...**
2. Select the `.db` file
3. Click **Open**
4. Pick a scan from the **Scan** dropdown

### Scanning a folder

1. Click the **New scan...** button to open a Scan dialog
2. Pick at least one root folder to scan (separate multiple folders with line breaks)
3. Choose your scan options (default is usually fine)
4. Click **Start scan**
5. The collector output will be displayed in the Output box
6. If you ticked "Run resolver after", the resolver will run directly after the collector. The resolver has no other output aside from a success or failure message.

> **NOTE:** There is currently no GUI option to run the resolver separately. Keep the "Run resolver after" box ticked unless you are comfortable running the resolver manually from the Terminal.

Use UNC paths where possible, for example:

```text
\\fileserver01\Finance
\\fileserver01\HR
```

The scan has two main phases:

- **Counting**: ShareACL counts folders so it can show progress and an estimated finish time.
- **Running**: ShareACL records folders and ACLs into the database.

If a scan fails, check the Output box first. Common causes are missing modules, no access to the share, a disconnected VPN, or a database file that is already locked by another process.

For large shares, start with one share root first. Once you know the tool is working from that workstation and account, scan larger scopes.

### Navigating a completed scan

Once you have a completed scan loaded, you can navigate the different views from the left navigation bar.

### Folder view

Use **Folder view** when you know the folder path and want to see what is directly on it.

Useful checks:

1. Type part of a folder path in the filter box
2. Press **Enter** or click **Refresh**
3. Select a folder in the top grid
4. Review the ACEs in the lower grid

Tick **Broken inheritance only** to show folders where inheritance is disabled. Tick **Explicit ACEs only** to show folders with permissions set directly on the folder.

Use **Export CSV** if you need to send the list to another team.

### Account view

Use **Account view** when someone asks, "What can this user or group access?"

Basic steps:

1. Click **Pick principal**
2. Search for the user, group, or computer account
3. Select the correct result and click **OK**
4. Use the path filter if you only care about one share or folder
5. Review the folders listed in the grid

The **Via** information shows whether access is direct or through group membership. If the resolver has not been run, this view will be much less useful because group membership will be missing.

The **Live effective access** button asks the filesystem for the selected account's effective access on the selected folder. Use this when the database says access should exist but you need to confirm what Windows currently reports.

### Findings view

Use **Findings** as the first pass for cleanup work. It groups common permission problems into a small number of lists.

Current findings include:

- Orphaned SIDs on ACEs
- Everyone exposure
- Non-admin Full Control
- Admin principal with explicit Full Control
- Unreachable folders
- Broad principal exposure
- Direct user ACEs
- Deny ACEs
- Scan errors

Select a finding on the left to load the matching folders on the right. Use **Export CSV** when the result needs to be reviewed outside the tool.

For findings that support it, **Swap principal** will pre-fill the ACL Swap page with the selected source principal and folder scope.

### Swapping ACLs

The ACL Swap functionality can be used with or without an existing folder scan. A database is required to record each swap. A fuller audit view for previous swaps is planned in a future release. If no scan is loaded, principals can only be picked directly from AD, and target folders have to be walked live. This may have significant performance implications on larger shares.

When a scan is loaded, you can pre-fill the source principal and target folder directly from certain findings in the Findings view.

Use ACL Swap when you need to replace one principal with another while keeping the same rights. For example, replacing a direct user ACE with a new AD group ACE.

Basic steps:

1. Open a database
2. Select a scan if you want to use scan-based discovery
3. Click **ACL Swap**
4. Pick the **Source** principal to replace
5. Pick the **Target** principal to add
6. Pick the **Scope** folder
7. Leave **Scan** mode selected if you have a current scan, or use **Live walk** if you do not
8. Click **Preview**
9. Review the affected folders
10. Type `APPLY` in the confirmation box
11. Click **Execute**
12. Click **Verify** after the run completes

Important safety notes:

- Do not run ACL Swap against a whole drive root or whole share root unless you have a clear change request.
- Preview first, every time.
- If the preview result is larger than expected, stop and narrow the scope.
- The tool refuses some dangerous well-known SID swaps unless an override is selected.
- The target principal must not be a broad built-in identity like Everyone or Authenticated Users.

Swap activity is written to the database and to `ShareAcl.GUI\Logs\swap-audit.jsonl`.

## Running without the GUI

The collector and resolver can be run from PowerShell 7 without opening the GUI.

Collector example:

```powershell
pwsh -NoProfile -File .\Invoke-ShareAclCollector.ps1 `
  -RootPath "\\fileserver01\Finance","\\fileserver01\HR" `
  -Database "C:\Temp\shareacl.db"
```

Resolver example:

```powershell
pwsh -NoProfile -File .\Invoke-ShareAclResolver.ps1 `
  -Database "C:\Temp\shareacl.db"
```

Resume the most recent running scan in a database:

```powershell
pwsh -NoProfile -File .\Invoke-ShareAclCollector.ps1 `
  -RootPath "\\fileserver01\Finance" `
  -Database "C:\Temp\shareacl.db" `
  -Resume
```

Limit scan depth while testing:

```powershell
pwsh -NoProfile -File .\Invoke-ShareAclCollector.ps1 `
  -RootPath "\\fileserver01\Finance" `
  -Database "C:\Temp\shareacl-test.db" `
  -MaxDepth 3
```

## Troubleshooting

### The GUI does not start

Check that you are using PowerShell 7, not Windows PowerShell 5.1:

```powershell
pwsh -NoProfile -File .\ShareAcl.GUI\Start-ShareAcl.ps1
```

If it still fails, check the error text for a missing module name.

### The scan shows access denied errors

This usually means the account running the scan cannot read one or more folders. The scan can still be useful, but those folders are audit gaps. Re-run with an account that has enough access if the missing folders matter.

### The findings show SIDs instead of names

Run the resolver. In the GUI, keep **Run resolver after** ticked when starting a scan. From the terminal, run `Invoke-ShareAclResolver.ps1` against the database.

### Account view does not show expected group access

Run the resolver and make sure the workstation can query Active Directory. Group membership is recorded by the resolver, not by the collector.

### ACL Swap preview is slow

Use scan mode where possible. Live walk reads the filesystem directly and can be slow on large folder trees.

---

This tool is in active development. When in doubt, ask Jono.
