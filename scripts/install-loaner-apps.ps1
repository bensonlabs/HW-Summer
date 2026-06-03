[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ManifestPath,
    [string]$BasePath = "C:\ProgramData\HW-Summer"
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-Version {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    try {
        return [version]$Value
    }
    catch {
        return $null
    }
}

function Get-InstalledApplication {
    param([Parameter(Mandatory = $true)][pscustomobject]$App)

    $registryRoots = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    )

    foreach ($root in $registryRoots) {
        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }

        $productCodePath = Join-Path $root $App.ProductCode
        if (Test-Path -LiteralPath $productCodePath) {
            $item = Get-ItemProperty -LiteralPath $productCodePath
            return [pscustomobject]@{
                DisplayName = $item.DisplayName
                DisplayVersion = $item.DisplayVersion
                ProductCode = $App.ProductCode
                RegistryPath = $productCodePath
            }
        }
    }

    foreach ($root in $registryRoots) {
        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }

        $matches = Get-ChildItem -LiteralPath $root |
            ForEach-Object {
                try {
                    Get-ItemProperty -LiteralPath $_.PSPath
                }
                catch {
                    $null
                }
            } |
            Where-Object {
                $_ -and
                $_.DisplayName -eq $App.Name -and
                $_.DisplayVersion
            }

        foreach ($match in $matches) {
            return [pscustomobject]@{
                DisplayName = $match.DisplayName
                DisplayVersion = $match.DisplayVersion
                ProductCode = $match.PSChildName
                RegistryPath = $match.PSPath
            }
        }
    }

    return $null
}

function Test-AppInstalledAtTargetVersion {
    param([Parameter(Mandatory = $true)][pscustomobject]$App)

    $installed = Get-InstalledApplication -App $App
    if (-not $installed) {
        return $false
    }

    $installedVersion = ConvertTo-Version -Value $installed.DisplayVersion
    $targetVersion = ConvertTo-Version -Value $App.Version

    if ($installedVersion -and $targetVersion) {
        if ($installedVersion -ge $targetVersion) {
            Write-Host "$($App.Name) $($installed.DisplayVersion) is already installed. Skipping."
            return $true
        }
    }
    elseif ($installed.DisplayVersion -eq $App.Version) {
        Write-Host "$($App.Name) $($installed.DisplayVersion) is already installed. Skipping."
        return $true
    }

    Write-Host "$($App.Name) is installed at version $($installed.DisplayVersion), target is $($App.Version). Installing target version."
    return $false
}

function Invoke-DownloadFile {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$OutFile
    )

    Write-Host "Downloading $Uri"
    Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing
}

function Assert-FileHash {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedHash
    )

    $actualHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
    $expected = $ExpectedHash.ToUpperInvariant()

    if ($actualHash -ne $expected) {
        throw "SHA256 mismatch for $Path. Expected $expected, got $actualHash."
    }

    Write-Host "Verified SHA256 for $Path"
}

function Install-MsiPackage {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$App,
        [Parameter(Mandatory = $true)][string]$InstallerPath,
        [Parameter(Mandatory = $true)][string]$LogPath
    )

    $argumentList = @(
        "/i",
        "`"$InstallerPath`"",
        "/qn",
        "/norestart",
        "/L*v",
        "`"$LogPath`""
    )

    if ($App.MsiProperties) {
        $argumentList += $App.MsiProperties
    }

    Write-Host "Installing $($App.Name) $($App.Version)"
    $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $argumentList -Wait -PassThru

    if ($process.ExitCode -eq 0) {
        Write-Host "$($App.Name) installed successfully."
        return 0
    }

    if ($process.ExitCode -eq 3010) {
        Write-Host "$($App.Name) installed successfully. Reboot is required."
        return 3010
    }

    throw "$($App.Name) install failed with MSI exit code $($process.ExitCode). See $LogPath"
}

if (-not (Test-IsAdministrator)) {
    throw "install-loaner-apps.ps1 must be run as Administrator."
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$installerDirectory = Join-Path $BasePath "Installers"
$logDirectory = Join-Path $BasePath "Logs"

foreach ($directory in @($installerDirectory, $logDirectory)) {
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
}

if (-not (Test-Path -LiteralPath $ManifestPath)) {
    throw "Manifest not found: $ManifestPath"
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$scriptLog = Join-Path $logDirectory "install-loaner-apps-$timestamp.log"
Start-Transcript -Path $scriptLog -Append | Out-Null

$failedApps = New-Object System.Collections.Generic.List[string]
$rebootRequired = $false

try {
    $apps = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json

    foreach ($app in $apps) {
        try {
            Write-Host ""
            Write-Host "== $($app.Name) =="

            if ($app.InstallerType -ne "msi") {
                throw "Unsupported installer type '$($app.InstallerType)' for $($app.Name)."
            }

            if (Test-AppInstalledAtTargetVersion -App $app) {
                continue
            }

            $installerPath = Join-Path $installerDirectory $app.FileName
            $needsDownload = $true

            if (Test-Path -LiteralPath $installerPath) {
                try {
                    Assert-FileHash -Path $installerPath -ExpectedHash $app.Sha256
                    $needsDownload = $false
                    Write-Host "Using cached installer: $installerPath"
                }
                catch {
                    Write-Host "Cached installer is invalid and will be downloaded again."
                    Remove-Item -LiteralPath $installerPath -Force
                }
            }

            if ($needsDownload) {
                Invoke-DownloadFile -Uri $app.Url -OutFile $installerPath
                Assert-FileHash -Path $installerPath -ExpectedHash $app.Sha256
            }

            $safeLogName = ($app.Name -replace '[^A-Za-z0-9.-]+', '-').Trim("-")
            $msiLog = Join-Path $logDirectory "$safeLogName-$($app.Version)-$timestamp.msi.log"
            $exitCode = Install-MsiPackage -App $app -InstallerPath $installerPath -LogPath $msiLog

            if ($exitCode -eq 3010) {
                $rebootRequired = $true
            }
        }
        catch {
            $message = "$($app.Name): $($_.Exception.Message)"
            Write-Host "ERROR: $message"
            $failedApps.Add($message)
        }
    }

    Write-Host ""
    if ($failedApps.Count -gt 0) {
        Write-Host "Setup completed with errors:"
        foreach ($failure in $failedApps) {
            Write-Host " - $failure"
        }
        exit 1
    }

    if ($rebootRequired) {
        Write-Host "Setup complete. Reboot required."
        exit 3010
    }

    Write-Host "Setup complete."
    exit 0
}
finally {
    Stop-Transcript | Out-Null
}
