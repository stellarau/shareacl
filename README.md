# ShareACL
ShareACL is a PowerShell GUI tool for mass auditing folder permissions. It also provides built-in functionality for drop-in swapping principals in folder ACLs.

## Features
The following features are currently implemented:

| Feature | Description |
| --- | --- |
| 📁 Folder view | Per-folder view of all assigned principals and their access levels |
| 👤 Account view | Per-account view of folders the selected principal has access to |
| 🔍 Findings view | A summary of potential problems in the permission structure |
| 🔃 Swap ACL | A tool to replace one principal with another in a folder structure |

## Prerequisites
- PowerShell 7+
- ActiveDirectory module
- PSSQLite module
- NTFSSecurity module

## Installation and usage
1. Clone the repository to a device with access to your AD and file shares
2. Run `ShareAcl.GUI\Start-Share-Acl.ps1`
3. On first run, you will be asked to create a new Database

Further instructions coming. In the meantime, ask Jono.
