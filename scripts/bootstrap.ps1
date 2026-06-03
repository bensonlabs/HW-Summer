[CmdletBinding()]
param(
    [string]$RepoOwner = "bensonlabs",
    [string]$RepoName = "HW-Summer",
    [string]$RepoRef = "main",
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

function Join-CommandLineArgument {
    param([string[]]$Arguments)

    $escaped = foreach ($argument in $Arguments) {
        if ($null -eq $argument) {
            continue
        }

        if ($argument -match '[\s"]') {
            '"' + ($argument -replace '"', '\"') + '"'
        }
        else {
            $argument
        }
    }

    return ($escaped -join " ")
}

function Invoke-DownloadFile {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$OutFile
    )

    Write-Host "Downloading $Uri"
    Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing
}

if (-not (Test-IsAdministrator)) {
    Write-Host "Administrator rights are required. Requesting elevation..."

    $scriptPath = $PSCommandPath
    if (-not $scriptPath) {
        throw "Cannot self-elevate because the bootstrap script path is unavailable."
    }

    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $scriptPath,
        "-RepoOwner", $RepoOwner,
        "-RepoName", $RepoName,
        "-RepoRef", $RepoRef,
        "-BasePath", $BasePath
    )

    $process = Start-Process -FilePath "powershell.exe" -ArgumentList (Join-CommandLineArgument -Arguments $arguments) -Verb RunAs -Wait -PassThru
    exit $process.ExitCode
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$scriptDirectory = Join-Path $BasePath "Scripts"
$manifestDirectory = Join-Path $BasePath "Manifests"
$installerDirectory = Join-Path $BasePath "Installers"
$logDirectory = Join-Path $BasePath "Logs"

foreach ($directory in @($scriptDirectory, $manifestDirectory, $installerDirectory, $logDirectory)) {
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$bootstrapLog = Join-Path $logDirectory "bootstrap-$timestamp.log"
$bootstrapExitCode = 0
Start-Transcript -Path $bootstrapLog -Append | Out-Null

try {
    Write-Host "HW-Summer bootstrap"
    Write-Host "Repository: $RepoOwner/$RepoName"
    Write-Host "Ref: $RepoRef"
    Write-Host "Base path: $BasePath"

    $rawBaseUrl = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$RepoRef"
    $installScriptPath = Join-Path $scriptDirectory "install-loaner-apps.ps1"
    $manifestPath = Join-Path $manifestDirectory "apps.json"

    Invoke-DownloadFile -Uri "$rawBaseUrl/scripts/install-loaner-apps.ps1" -OutFile $installScriptPath
    Invoke-DownloadFile -Uri "$rawBaseUrl/manifests/apps.json" -OutFile $manifestPath

    Write-Host "Running installer script..."
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installScriptPath -ManifestPath $manifestPath -BasePath $BasePath
    $installerExitCode = $LASTEXITCODE

    if ($installerExitCode -eq 3010) {
        Write-Host "Setup complete. Reboot required."
        $bootstrapExitCode = 3010
    }
    elseif ($installerExitCode -ne 0) {
        throw "Installer script failed with exit code $installerExitCode."
    }
    else {
        Write-Host "Setup complete."
    }
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)"
    $bootstrapExitCode = 1
}
finally {
    Stop-Transcript | Out-Null
}

exit $bootstrapExitCode
