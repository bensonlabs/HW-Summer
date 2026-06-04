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

function Get-ObjectPropertyValue {
    param(
        [object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) {
        return $property.Value
    }

    return $null
}

function Test-GuidString {
    param([string]$Value)

    return $Value -match "^\{[0-9A-Fa-f-]{36}\}$"
}

function Test-ManifestFlag {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$App,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $value = Get-ObjectPropertyValue -InputObject $App -Name $Name
    if ($null -eq $value) {
        return $false
    }

    if ($value -is [bool]) {
        return $value
    }

    return ([string]$value).Trim() -in @("1", "true", "yes")
}

function Get-ManifestStringList {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$App,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $value = Get-ObjectPropertyValue -InputObject $App -Name $Name
    if ($null -eq $value) {
        return @()
    }

    if ($value -is [array]) {
        return @($value | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
    }

    if ([string]::IsNullOrWhiteSpace([string]$value)) {
        return @()
    }

    return @([string]$value)
}

function Assert-AppDefinition {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$App,
        [Parameter(Mandatory = $true)][int]$Index
    )

    $appLabel = "App #$Index"
    $requiredFields = @(
        "Name",
        "Version",
        "Url",
        "FileName",
        "Sha256",
        "ProductCode",
        "UpgradeCode",
        "InstallerType",
        "MsiProperties"
    )

    foreach ($field in $requiredFields) {
        $value = Get-ObjectPropertyValue -InputObject $App -Name $field
        if ([string]::IsNullOrWhiteSpace([string]$value)) {
            throw "$appLabel is missing required manifest field '$field'."
        }

        if ($field -eq "Name") {
            $appLabel = $value
        }
    }

    if ($App.InstallerType -ne "msi") {
        throw "$appLabel has unsupported installer type '$($App.InstallerType)'."
    }

    if ($App.Sha256 -notmatch "^[A-Fa-f0-9]{64}$") {
        throw "$appLabel has an invalid SHA256 value."
    }

    foreach ($field in @("ProductCode", "UpgradeCode")) {
        if ($App.$field -notmatch "^\{[0-9A-Fa-f-]{36}\}$") {
            throw "$appLabel has an invalid $field value."
        }
    }
}

function Get-UninstallRegistryRoot {
    return @(
        [pscustomobject]@{
            Scope = "Machine"
            Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
        },
        [pscustomobject]@{
            Scope = "Machine"
            Path = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
        },
        [pscustomobject]@{
            Scope = "CurrentUser"
            Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall"
        },
        [pscustomobject]@{
            Scope = "CurrentUser"
            Path = "HKCU:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
        }
    )
}

function Test-ApplicationEntryMatch {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$App,
        [Parameter(Mandatory = $true)][string]$ProductCode,
        [string]$DisplayName,
        [string]$UninstallString,
        [string]$QuietUninstallString,
        [string]$InstallLocation
    )

    if ($ProductCode -eq $App.ProductCode) {
        return $true
    }

    if ($DisplayName -eq $App.Name) {
        return $true
    }

    foreach ($pattern in Get-ManifestStringList -App $App -Name "RemoveExistingNamePatterns") {
        if (-not [string]::IsNullOrWhiteSpace($DisplayName) -and $DisplayName -match $pattern) {
            return $true
        }
    }

    $pathValues = @($UninstallString, $QuietUninstallString, $InstallLocation) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($pattern in Get-ManifestStringList -App $App -Name "RemoveExistingPathPatterns") {
        foreach ($pathValue in $pathValues) {
            if ($pathValue -match $pattern) {
                return $true
            }
        }
    }

    return $false
}

function Get-InstalledApplicationEntry {
    param([Parameter(Mandatory = $true)][pscustomobject]$App)

    $seenRegistryPaths = @{}

    foreach ($root in Get-UninstallRegistryRoot) {
        if (-not (Test-Path -LiteralPath $root.Path)) {
            continue
        }

        foreach ($subkey in Get-ChildItem -LiteralPath $root.Path) {
            if ($seenRegistryPaths.ContainsKey($subkey.PSPath)) {
                continue
            }

            try {
                $item = Get-ItemProperty -LiteralPath $subkey.PSPath
            }
            catch {
                continue
            }

            $displayName = Get-ObjectPropertyValue -InputObject $item -Name "DisplayName"
            $displayVersion = Get-ObjectPropertyValue -InputObject $item -Name "DisplayVersion"
            $uninstallString = Get-ObjectPropertyValue -InputObject $item -Name "UninstallString"
            $quietUninstallString = Get-ObjectPropertyValue -InputObject $item -Name "QuietUninstallString"
            $installLocation = Get-ObjectPropertyValue -InputObject $item -Name "InstallLocation"

            if (-not (Test-ApplicationEntryMatch -App $App -ProductCode $subkey.PSChildName -DisplayName $displayName -UninstallString $uninstallString -QuietUninstallString $quietUninstallString -InstallLocation $installLocation)) {
                continue
            }

            $seenRegistryPaths[$subkey.PSPath] = $true

            [pscustomobject]@{
                DisplayName = $displayName
                DisplayVersion = $displayVersion
                ProductCode = $subkey.PSChildName
                RegistryPath = $subkey.PSPath
                Scope = $root.Scope
                WindowsInstaller = Get-ObjectPropertyValue -InputObject $item -Name "WindowsInstaller"
                UninstallString = $uninstallString
                QuietUninstallString = $quietUninstallString
                InstallLocation = $installLocation
            }
        }
    }
}

function Get-InstalledApplication {
    param([Parameter(Mandatory = $true)][pscustomobject]$App)

    $installedApplications = @(Get-InstalledApplicationEntry -App $App)
    if ($installedApplications.Count -eq 0) {
        return $null
    }

    $targetProduct = $installedApplications | Where-Object { $_.ProductCode -eq $App.ProductCode } | Select-Object -First 1
    if ($targetProduct) {
        return $targetProduct
    }

    return $installedApplications |
        Sort-Object @{ Expression = { ConvertTo-Version -Value $_.DisplayVersion }; Descending = $true }, DisplayVersion |
        Select-Object -First 1
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

function Split-CommandLine {
    param([Parameter(Mandatory = $true)][string]$CommandLine)

    $trimmed = $CommandLine.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        throw "Uninstall command is empty."
    }

    if ($trimmed.StartsWith('"')) {
        $endQuote = $trimmed.IndexOf('"', 1)
        if ($endQuote -lt 1) {
            throw "Cannot parse uninstall command: $CommandLine"
        }

        return [pscustomobject]@{
            FilePath = $trimmed.Substring(1, $endQuote - 1)
            Arguments = $trimmed.Substring($endQuote + 1).Trim()
        }
    }

    $firstSpace = $trimmed.IndexOf(" ")
    if ($firstSpace -lt 0) {
        return [pscustomobject]@{
            FilePath = $trimmed
            Arguments = ""
        }
    }

    $exeIndex = $trimmed.IndexOf(".exe", [System.StringComparison]::OrdinalIgnoreCase)
    if ($exeIndex -ge 0) {
        $exeEnd = $exeIndex + 4
        return [pscustomobject]@{
            FilePath = $trimmed.Substring(0, $exeEnd)
            Arguments = $trimmed.Substring($exeEnd).Trim()
        }
    }

    return [pscustomobject]@{
        FilePath = $trimmed.Substring(0, $firstSpace)
        Arguments = $trimmed.Substring($firstSpace + 1).Trim()
    }
}

function Uninstall-InstalledApplication {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Entry,
        [Parameter(Mandatory = $true)][string]$LogPath
    )

    $versionText = ""
    if (-not [string]::IsNullOrWhiteSpace($Entry.DisplayVersion)) {
        $versionText = " $($Entry.DisplayVersion)"
    }

    Write-Host "Uninstalling existing $($Entry.DisplayName)$versionText from $($Entry.Scope)."
    $isMsi = ($Entry.WindowsInstaller -eq 1 -or $Entry.WindowsInstaller -eq "1" -or $Entry.UninstallString -match "MsiExec") -and (Test-GuidString -Value $Entry.ProductCode)

    if ($isMsi) {
        $argumentList = @(
            "/x",
            $Entry.ProductCode,
            "/qn",
            "/norestart",
            "/L*v",
            "`"$LogPath`""
        )

        $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $argumentList -Wait -PassThru
    }
    else {
        $commandLine = $Entry.QuietUninstallString
        $usedQuietUninstall = $true

        if ([string]::IsNullOrWhiteSpace($commandLine)) {
            $commandLine = $Entry.UninstallString
            $usedQuietUninstall = $false
        }

        if ([string]::IsNullOrWhiteSpace($commandLine)) {
            throw "No uninstall command found for $($Entry.DisplayName) at $($Entry.RegistryPath)."
        }

        $parsedCommand = Split-CommandLine -CommandLine $commandLine
        $filePath = [Environment]::ExpandEnvironmentVariables($parsedCommand.FilePath)
        $arguments = $parsedCommand.Arguments

        if (-not $usedQuietUninstall -and $filePath -match "\.exe$" -and $arguments -notmatch '(^|\s)/S($|\s)') {
            $arguments = (@($arguments, "/S") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join " "
        }

        $startProcessParameters = @{
            FilePath = $filePath
            Wait = $true
            PassThru = $true
        }

        if (-not [string]::IsNullOrWhiteSpace($arguments)) {
            $startProcessParameters.ArgumentList = $arguments
        }

        $process = Start-Process @startProcessParameters
    }

    if ($process.ExitCode -eq 0) {
        Write-Host "$($Entry.DisplayName)$versionText uninstalled successfully."
        return 0
    }

    if ($process.ExitCode -eq 3010) {
        Write-Host "$($Entry.DisplayName)$versionText uninstalled successfully. Reboot is required."
        return 3010
    }

    throw "$($Entry.DisplayName)$versionText uninstall failed with exit code $($process.ExitCode)."
}

function Resolve-ExpandedPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $expandedPath = [Environment]::ExpandEnvironmentVariables($Path)
    if ([string]::IsNullOrWhiteSpace($expandedPath)) {
        return $null
    }

    return [System.IO.Path]::GetFullPath($expandedPath)
}

function Test-SafeCleanupPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = Resolve-ExpandedPath -Path $Path
    if ([string]::IsNullOrWhiteSpace($fullPath)) {
        return $false
    }

    $normalizedPath = $fullPath.TrimEnd("\")
    if ($normalizedPath -notmatch "Arduino") {
        throw "Refusing to remove cleanup path without Arduino in the path: $fullPath"
    }

    $blockedPaths = @(
        "$env:SystemDrive\",
        $env:ProgramFiles,
        [Environment]::GetEnvironmentVariable("ProgramFiles(x86)"),
        $env:LOCALAPPDATA,
        $env:APPDATA,
        $env:ProgramData,
        $env:USERPROFILE,
        [Environment]::GetEnvironmentVariable("Public")
    ) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { [System.IO.Path]::GetFullPath($_).TrimEnd("\") }

    if ($blockedPaths -contains $normalizedPath) {
        throw "Refusing to remove broad cleanup path: $fullPath"
    }

    return $true
}

function Invoke-StaleApplicationPathCleanup {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = Resolve-ExpandedPath -Path $Path
    if ([string]::IsNullOrWhiteSpace($fullPath)) {
        return
    }

    if (-not (Test-Path -LiteralPath $fullPath)) {
        return
    }

    if (-not (Test-SafeCleanupPath -Path $fullPath)) {
        return
    }

    Write-Host "Removing stale path: $fullPath"
    $item = Get-Item -LiteralPath $fullPath -Force
    if ($item.PSIsContainer) {
        Remove-Item -LiteralPath $fullPath -Recurse -Force
    }
    else {
        Remove-Item -LiteralPath $fullPath -Force
    }
}

function Invoke-ExistingApplicationCleanup {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$App,
        [Parameter(Mandatory = $true)][string]$LogDirectory,
        [Parameter(Mandatory = $true)][string]$Timestamp
    )

    $installedApplications = @(Get-InstalledApplicationEntry -App $App)
    $rebootRequiredByUninstall = $false

    if ($installedApplications.Count -eq 0) {
        Write-Host "No existing $($App.Name) registry entries found for cleanup."
    }

    foreach ($entry in $installedApplications) {
        $safeName = ($entry.DisplayName -replace '[^A-Za-z0-9.-]+', '-').Trim("-")
        if ([string]::IsNullOrWhiteSpace($safeName)) {
            $safeName = "existing-app"
        }

        $safeVersion = ($entry.DisplayVersion -replace '[^A-Za-z0-9.-]+', '-').Trim("-")
        if ([string]::IsNullOrWhiteSpace($safeVersion)) {
            $safeVersion = "unknown-version"
        }

        $uninstallLog = Join-Path $LogDirectory "$safeName-$safeVersion-uninstall-$Timestamp.log"
        $exitCode = Uninstall-InstalledApplication -Entry $entry -LogPath $uninstallLog

        if ($exitCode -eq 3010) {
            $rebootRequiredByUninstall = $true
        }
    }

    foreach ($cleanupPath in Get-ManifestStringList -App $App -Name "CleanupPaths") {
        Invoke-StaleApplicationPathCleanup -Path $cleanupPath
    }

    foreach ($cleanupShortcut in Get-ManifestStringList -App $App -Name "CleanupShortcuts") {
        Invoke-StaleApplicationPathCleanup -Path $cleanupShortcut
    }

    if ($rebootRequiredByUninstall) {
        return 3010
    }

    return 0
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
    if (-not $apps) {
        throw "Manifest contains no app entries."
    }

    $appIndex = 0
    foreach ($app in $apps) {
        $appIndex++
        $appName = "App #$appIndex"

        try {
            Assert-AppDefinition -App $app -Index $appIndex
            $appName = $app.Name

            Write-Host ""
            Write-Host "== $appName =="

            if (Test-ManifestFlag -App $app -Name "RemoveExistingBeforeInstall") {
                $cleanupExitCode = Invoke-ExistingApplicationCleanup -App $app -LogDirectory $logDirectory -Timestamp $timestamp
                if ($cleanupExitCode -eq 3010) {
                    $rebootRequired = $true
                }
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
            $message = "${appName}: $($_.Exception.Message)"
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
