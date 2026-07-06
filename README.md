# ShareACL

ShareACL is a PowerShell GUI tool for mass auditing folder permissions. It also provides built-in functionality for drop-in swapping principals in folder ACLs.

## Features

The following features are currently implemented:

| Feature | Description |
| --- | --- |
| 📁 Folder view | Per-folder view of all assigned principals and their access levels |
| 👤 Account view | Per-account view of folders the selected principal has access to |
| 📋 Findings view | A summary of potential problems in the permission structure |
| 🔃 ACL Swap | A tool to replace one principal with another in a folder structure |
| 🔍 Scan funtionality | The core of the tool providing information to each of the views listed above |

The scan collector and resolver can also be run independently without the GUI wrapper.

## Prerequisites

- PowerShell 7+
- ActiveDirectory module
- PSSQLite module
- NTFSSecurity module

## Installation and usage

### Getting started

1. Clone the repository to a device with access to your AD and file shares
2. Run `ShareAcl.GUI\Start-Share-Acl.ps1` (see note below)
3. On first run, you will need to create a new Database

> **NOTE:** The `Start-Share-Acl.ps1` launcher is used to contain the tool into its own PowerShell process, which prevents excessive handle leakage across multiple runs.

### Scanning a folder

1. Click the **New scan...** button to open a Scan dialog
2. Pick at least one root folder to scan (separate multiple folders with line breaks)
3. Choose your scan options (default is usually fine)
4. Click **Start scan**
5. The collector output will be displayed in the Output box
6. If you ticked "Run resolver after", the resolver will run directly after the collector. The resolver has no other output aside from a success or failure message.

> **NOTE:** There is currently no GUI option to run the resolver separately. Keep the "Run resolver after" box ticked unless you are comfortable running the resolver manually from the Terminal.

### Navigating a completed scan

Once you have a completed scan loaded, you can navigate the different views from the left navigation bar. Detailed explanations for each view will be coming later.

### Swapping ACLs

The ACL Swap functionality can be used with or without an existing folder scan. A database is required to record each swap in the database. Auditing for previous swaps is planned in a future release. If no scan is loaded, principals can only be picked directly from AD, and target folders have to be walked live. This may have significant performance implications on larger shares.

When a scan is loaded, you can pre-fill the source principal and target folder directly from certain findings in the Findings view.

---

Further instructions coming. In the meantime, ask Jono.
