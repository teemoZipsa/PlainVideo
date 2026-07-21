# PlainVideo MSIX packaging

The manifest is bound to the Partner Center identity observed on 2026-07-21:

- Store ID: `9PDKQ88FKG1L`
- Identity name: `SeonkyuIM.PlainVideo`
- Publisher: `CN=8958BE04-B1E7-4AE6-84E9-592921EBB405`
- Publisher display name: `SeonkyuIM`

Build a developer-signed local proof with:

```powershell
.\scripts\build-msix.ps1
```

Output stays under `.runtime\msix`. The default package deliberately includes
`DEVELOPER_PACKAGE_README.txt` and is not uploadable because the current LGPL
runtime candidate is not release-approved.

`-ForStoreUpload` is fail-closed: it requires a clean Git worktree, both the
Store release state and runtime manifest to mark the candidate eligible, and a
successful public availability check of the exact corresponding-source archive.
The Store package is intentionally unsigned because Microsoft signs the
accepted package; use the default developer build for local signing and WACK.
