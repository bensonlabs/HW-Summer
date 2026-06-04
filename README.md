# HW-Summer Laptop Setup

PowerShell installer scripts for the Dell Latitude 7310 summer loaner laptops.

The intended workflow is:

1. Log in as `loaner`.
2. Open Terminal or PowerShell as Administrator.
3. Paste the command from the bensonlabs.org blog post.
4. Wait for `Setup complete.`
5. Reboot if prompted.

Logs are written to:

```text
C:\ProgramData\HW-Summer\Logs
```

Downloaded installers are kept in:

```text
C:\ProgramData\HW-Summer\Installers
```

## Testing Command

Use this while testing from the `main` branch:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-RestMethod https://raw.githubusercontent.com/bensonlabs/HW-Summer/main/scripts/bootstrap.ps1 -OutFile $env:TEMP\hw-summer-bootstrap.ps1; & $env:TEMP\hw-summer-bootstrap.ps1 -RepoRef main"
```

## Final Rollout Command

Use the `v2026-summer` tag for the final cart rollout:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-RestMethod https://raw.githubusercontent.com/bensonlabs/HW-Summer/v2026-summer/scripts/bootstrap.ps1 -OutFile $env:TEMP\hw-summer-bootstrap.ps1; & $env:TEMP\hw-summer-bootstrap.ps1 -RepoRef v2026-summer"
```

## Apps

The installer uses official MSI downloads only:

- Arduino IDE 2.3.9
- LEGO Education SPIKE 3.6.1

The script verifies SHA256 hashes before installation and skips apps that are already installed at the target version or newer.
For Arduino IDE, the script also removes older matching per-user or machine-wide installs before checking whether the target MSI is installed.

## Notes

- The `loaner` account is expected to be a local administrator.
- The bootstrap has a UAC self-elevation fallback, but the normal path is to run from an elevated PowerShell session.
- The repo should not contain secrets, product keys, passwords, student data, or private download links.
- Taskbar and Start menu pinning are intentionally out of scope for this first install script.
