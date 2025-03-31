#Requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Elevation Check
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "This script requires administrator privileges." -ForegroundColor Yellow
    Write-Host "Attempting to relaunch with elevated privileges..." -ForegroundColor Yellow
    try {
        $scriptPath = $MyInvocation.MyCommand.Definition
        $arguments = "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $scriptPath
        Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $arguments -ErrorAction Stop
        exit 0
    } catch {
        Write-Host "Failed to elevate privileges automatically. Please run as administrator." -ForegroundColor Red
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "Script is running with administrator privileges." -ForegroundColor Green
}
#endregion

#region Load .NET Assemblies & Setup
try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Runtime.InteropServices
} catch {
    Write-Error "FATAL: Failed to load required .NET Assemblies. Error details: $($_.Exception.Message)"
    exit 1
}

if (-not (Test-Path $env:TEMP)) {
    New-Item -Path $env:TEMP -ItemType Directory -Force | Out-Null
}

# Global variables
$script:logBox = $null
$script:progressBar = $null
$script:statusLabel = $null
$script:rebootRequired = $false
$script:logFilePath = Join-Path -Path $env:TEMP -ChildPath "SystemMaintenance_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
#endregion

#region Logging Function
function Show-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','SUCCESS','DEBUG')][string]$Level = 'INFO'
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "[$timestamp] [$Level] $Message"
    $color = switch ($Level) {
        'WARN'    { 'Yellow' }
        'ERROR'   { 'Red' }
        'SUCCESS' { 'Green' }
        'DEBUG'   { 'Cyan' }
        default   { 'White' }
    }
    Write-Host $logLine -ForegroundColor $color
    if ($script:logBox -and -not $script:logBox.IsDisposed) {
        try {
            if ($script:logBox.InvokeRequired) {
                $script:logBox.BeginInvoke([Action[string]]{
                    param($text)
                    if (-not $script:logBox.IsDisposed) {
                        $script:logBox.AppendText($text + [Environment]::NewLine)
                        $script:logBox.ScrollToCaret()
                    }
                }, $logLine) | Out-Null
            } else {
                $script:logBox.AppendText($logLine + [Environment]::NewLine)
                $script:logBox.ScrollToCaret()
            }
        } catch {
            Write-Warning "Failed to write to GUI log box: $($_.Exception.Message)"
        }
    }
    try {
        Add-Content -Path $script:logFilePath -Value $logLine -ErrorAction Stop
    } catch {
        Write-Warning "Failed to write to log file '$script:logFilePath': $($_.Exception.Message)"
    }
}
#endregion

#region Helper Functions
function Release-ComObjectSafely {
    param($ComObject)
    if ($ComObject) {
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($ComObject) | Out-Null }
        catch { Show-Log "Error releasing COM object: $($_.Exception.Message)" -Level WARN }
        $ComObject = $null
    }
}

function Update-UsingWU {
    param(
        [Parameter(Mandatory = $true)][string]$UpdateType,
        [Parameter(Mandatory = $true)][string]$SearchCriteria
    )
    $session = $null; $searcher = $null; $searchResult = $null
    $updatesToInstall = $null; $updatesToDownload = $null; $downloader = $null; $installer = $null

    Show-Log "Starting $UpdateType update check..." -Level INFO
    $status = "Error in $UpdateType update process."
    try {
        $session = New-Object -ComObject "Microsoft.Update.Session"
        $searcher = $session.CreateUpdateSearcher()
        $searcher.Online = $true
        $searchResult = $searcher.Search($SearchCriteria)
        $updatesToInstall = $searchResult.Updates

        if (-not $updatesToInstall -or $updatesToInstall.Count -eq 0) {
            Show-Log "No applicable $UpdateType updates found." -Level SUCCESS
            return "No $UpdateType updates available."
        }

        Show-Log "Found $($updatesToInstall.Count) $UpdateType update(s):" -Level INFO
        $updatesToInstall | ForEach-Object { Show-Log " - $($_.Title) ($($_.KBArticleIDs -join ', '))" -Level INFO }
        $updatesToDownload = New-Object -ComObject "Microsoft.Update.UpdateColl"
        foreach ($update in $updatesToInstall) { $updatesToDownload.Add($update) | Out-Null }
        $downloader = $session.CreateUpdateDownloader()
        $downloader.Updates = $updatesToDownload
        $downloadResult = $downloader.Download()

        if ($downloadResult.ResultCode -ne 2) {
            Show-Log "Download failed (ResultCode: $($downloadResult.ResultCode))." -Level ERROR
            return "$UpdateType download failed."
        } else {
            Show-Log "Downloads completed successfully." -Level INFO
        }

        $installer = $session.CreateUpdateInstaller()
        $installer.Updates = $updatesToDownload
        $installationResult = $installer.Install()

        if ($installationResult.ResultCode -eq 2) {
            Show-Log "$UpdateType updates installed successfully." -Level SUCCESS
            $status = "$UpdateType updates installed."
            if ($installationResult.RebootRequired) {
                Show-Log "A reboot is required to complete the installation." -Level WARN
                $script:rebootRequired = $true
                $status = "$UpdateType updates installed (reboot required)."
            }
        } else {
            Show-Log "Installation did not complete successfully (Code: $($installationResult.ResultCode))." -Level ERROR
            $status = "$UpdateType installation finished with issues (Code: $($installationResult.ResultCode))."
            if ($installationResult.RebootRequired) {
                Show-Log "A reboot may still be required." -Level WARN
                $script:rebootRequired = $true
                $status += " Reboot recommended."
            }
        }
        return $status
    } catch {
        Show-Log "Error during $UpdateType update process: $($_.Exception.Message)" -Level ERROR
        return "Error during $UpdateType update process."
    } finally {
        Release-ComObjectSafely -ComObject $installer
        Release-ComObjectSafely -ComObject $downloader
        Release-ComObjectSafely -ComObject $updatesToDownload
        Release-ComObjectSafely -ComObject $updatesToInstall
        Release-ComObjectSafely -ComObject $searchResult
        Release-ComObjectSafely -ComObject $searcher
        Release-ComObjectSafely -ComObject $session
        Show-Log "$UpdateType update function finished." -Level DEBUG
    }
}

function Update-Drivers { $driverCriteria = "IsInstalled=0 and Type='Driver' and IsHidden=0 and BrowseOnly=0"; return Update-UsingWU -UpdateType "Driver" -SearchCriteria $driverCriteria }
function Update-Software { $softwareCriteria = "IsInstalled=0 and Type='Software' and IsHidden=0 and BrowseOnly=0"; return Update-UsingWU -UpdateType "Software" -SearchCriteria $softwareCriteria }

function Ensure-ServiceRunning {
    param(
        [Parameter(Mandatory = $true)][string]$ServiceName,
        [string]$ServiceDisplayName = $ServiceName
    )
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $service) { Show-Log "$ServiceDisplayName service not found." -Level ERROR; return $false }
    if ($service.Status -ne 'Running') {
        Show-Log "$ServiceDisplayName service is not running (Status: $($service.Status)). Attempting to start..." -Level WARN
        try {
            Set-Service -Name $ServiceName -StartupType Automatic -ErrorAction Stop
            Start-Service -Name $ServiceName -ErrorAction Stop
            Start-Sleep -Seconds 3
            $service.Refresh()
            if ($service.Status -eq 'Running') {
                Show-Log "Successfully started $ServiceDisplayName service." -Level SUCCESS
                return $true
            } else { Show-Log "Failed to start $ServiceDisplayName service. Current status: $($service.Status)." -Level ERROR; return $false }
        } catch { Show-Log "Error managing $ServiceDisplayName service: $($_.Exception.Message)" -Level ERROR; return $false }
    } elseif ($service.StartType -ne 'Automatic') {
        Show-Log "$ServiceDisplayName service is running but not set to Automatic. Setting startup type..." -Level WARN
        try { Set-Service -Name $ServiceName -StartupType Automatic -ErrorAction Stop; Show-Log "Startup type set to Automatic for $ServiceDisplayName service." -Level SUCCESS; return $true }
        catch { Show-Log "Error setting startup type for $ServiceDisplayName service: $($_.Exception.Message)" -Level ERROR; return $false }
    } else { Show-Log "$ServiceDisplayName service is running and set to Automatic." -Level INFO; return $true }
}
#endregion

#region Windows Settings Check
function Check-WindowsSettings {
    Show-Log "Starting Windows settings check..." -Level INFO
    $issuesFound = New-Object 'System.Collections.Generic.List[string]'
    $fixesAttempted = $false; $rebootHint = $false
    $status = "Error during settings check."
    try {
        if (-not (Ensure-ServiceRunning -ServiceName 'wuauserv' -ServiceDisplayName "Windows Update")) { $issuesFound.Add("Windows Update service issue.") }
        $uacPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"; $uacKey = "EnableLUA"
        try {
            if (Test-Path $uacPath) {
                $uacValue = Get-ItemProperty -Path $uacPath -Name $uacKey -ErrorAction SilentlyContinue
                if (-not $uacValue -or $uacValue.$uacKey -ne 1) {
                    $currentValue = if ($uacValue) { $uacValue.$uacKey } else { "Missing" }
                    $msg = "UAC (EnableLUA) is disabled or misconfigured (Value: $currentValue). Recommended value is 1."
                    $issuesFound.Add($msg)
                    Show-Log $msg -Level WARN
                    Set-ItemProperty -Path $uacPath -Name $uacKey -Value 1 -Type DWord -Force -ErrorAction Stop
                    Show-Log "UAC (EnableLUA) set to 1. A REBOOT IS REQUIRED for this change to take effect." -Level SUCCESS
                    $fixesAttempted = $true; $rebootHint = $true; $script:rebootRequired = $true
                } else { Show-Log "UAC (EnableLUA) is enabled (Value: 1)." -Level INFO }
            } else { $msg = "UAC registry path ($uacPath) not found. Cannot check/fix UAC setting."; $issuesFound.Add($msg); Show-Log $msg -Level ERROR }
        } catch { $errMsg = "Error checking or setting UAC registry key: $($_.Exception.Message)"; $issuesFound.Add($errMsg); Show-Log $errMsg -Level ERROR }
        if (-not (Ensure-ServiceRunning -ServiceName 'MpsSvc' -ServiceDisplayName "Windows Defender Firewall")) { $issuesFound.Add("Windows Defender Firewall service issue.") }
        Show-Log "Settings check completed." -Level INFO
        if ($issuesFound.Count -eq 0) { Show-Log "No issues found in checked settings." -Level SUCCESS; $status = "Settings check passed." }
        else {
            Show-Log "Settings check finished. Issues found:" -Level WARN
            $issuesFound | ForEach-Object { Show-Log "- $_" -Level WARN }
            $status = if ($rebootHint) { "Settings issues found; fixes applied (reboot required)." } elseif ($fixesAttempted) { "Settings issues found; attempted fixes." } else { "Settings issues found; no fixes applied." }
        }
        return $status
    } catch {
        Show-Log "Unexpected error during settings check: $($_.Exception.Message)" -Level ERROR
        $issuesFound.Add("Unexpected error: $($_.Exception.Message)")
        return "Error during settings check."
    } finally { Show-Log "Settings check function finished." -Level DEBUG }
}
#endregion

#region System File Checker (SFC)
function Run-SFC {
    Show-Log "Starting System File Checker (SFC /scannow)..." -Level INFO
    $sfcExe = Join-Path -Path $env:SystemRoot -ChildPath "System32\sfc.exe"
    if (-not (Test-Path $sfcExe)) { Show-Log "sfc.exe not found at '$sfcExe'." -Level ERROR; return "SFC executable not found." }
    $tempDir = $env:TEMP; $outputLog = Join-Path -Path $tempDir -ChildPath "sfc_output_$($PID).log"; $errorLog = Join-Path -Path $tempDir -ChildPath "sfc_error_$($PID).log"
    $status = "Error running SFC."
    try {
        $process = Start-Process -FilePath $sfcExe -ArgumentList "/scannow" -Wait -PassThru -NoNewWindow -RedirectStandardOutput $outputLog -RedirectStandardError $errorLog
        $exitCode = $process.ExitCode
        $output = if (Test-Path $outputLog) { Get-Content $outputLog -Encoding Unicode -Raw -ErrorAction SilentlyContinue } else { "" }
        $errors = if (Test-Path $errorLog) { Get-Content $errorLog -Encoding Unicode -Raw -ErrorAction SilentlyContinue } else { "" }
        if ($errors) {
            Show-Log "SFC reported errors via stderr:" -Level ERROR
            $errors.Split([Environment]::NewLine) | Select-Object -First 10 | ForEach-Object { Show-Log "  $_" -Level ERROR }
        }
        if ($output) {
            Show-Log "SFC Standard Output:" -Level INFO
            $output.Split([Environment]::NewLine) | Where-Object { $_ -match "Windows Resource Protection" } | ForEach-Object { Show-Log $_ -Level INFO }
        } else { Show-Log "No SFC standard output produced." -Level WARN }
        if ($output -match "did not find any integrity violations") {
            Show-Log "SFC scan completed. No integrity violations found." -Level SUCCESS; $status = "SFC: No issues found."
        } elseif ($output -match "found corrupt files and successfully repaired them") {
            Show-Log "SFC scan found and repaired corrupt files." -Level SUCCESS; Show-Log "A reboot is recommended." -Level WARN; $script:rebootRequired = $true; $status = "SFC: Repaired files (reboot recommended)."
        } elseif ($output -match "found corrupt files but was unable to fix some") {
            Show-Log "SFC scan found corrupt files but was unable to fix them." -Level WARN; $status = "SFC: Issues found, but not fully repaired."
        } elseif ($output -match "could not perform the requested operation") {
            Show-Log "SFC could not perform the requested operation." -Level ERROR; $status = "SFC: Operation failed."
        } else {
            Show-Log "SFC scan finished; result unclear." -Level WARN; $status = "SFC: Result unknown."
        }
        return $status
    } catch {
        Show-Log "Error running SFC: $($_.Exception.Message)" -Level ERROR; return "Error running SFC."
    } finally {
        if (Test-Path $outputLog) { Remove-Item $outputLog -Force -ErrorAction SilentlyContinue }
        if (Test-Path $errorLog) { Remove-Item $errorLog -Force -ErrorAction SilentlyContinue }
        Show-Log "SFC function finished." -Level DEBUG
    }
}
#endregion

#region Diagnostics & Maintenance
function Check-DiskHealth {
    Show-Log "Starting disk health check..." -Level INFO
    $issuesFound = New-Object 'System.Collections.Generic.List[string]'
    $status = "Disk health check passed."
    try {
        $disks = Get-CimInstance -Namespace root\Microsoft\Windows\Storage -ClassName MSFT_PhysicalDisk
        foreach ($disk in $disks) {
            if ($disk.HealthStatus -ne 1) {
                $msg = "Disk $($disk.DeviceId) has health issues (Status: $($disk.HealthStatus))."
                $issuesFound.Add($msg)
                Show-Log $msg -Level WARN
            }
        }
        if ($issuesFound.Count -gt 0) {
            Show-Log "Disk health check finished. Issues found:" -Level WARN
            $issuesFound | ForEach-Object { Show-Log "- $_" -Level WARN }
            $status = "Disk health issues found."
        } else { Show-Log "Disk health check completed. No issues found." -Level SUCCESS }
        return $status
    } catch {
        Show-Log "Error during disk health check: $($_.Exception.Message)" -Level ERROR; return "Error during disk health check."
    } finally { Show-Log "Disk health check function finished." -Level DEBUG }
}

function Check-Performance {
    Show-Log "Starting system performance check..." -Level INFO
    $issuesFound = New-Object 'System.Collections.Generic.List[string]'
    $status = "System performance check passed."
    try {
        $cpuLoad = (Get-Counter '\Processor(_Total)\% Processor Time').CounterSamples.CookedValue
        $memoryUsage = (Get-Counter '\Memory\% Committed Bytes In Use').CounterSamples.CookedValue
        if ($cpuLoad -gt 90) { $msg = "High CPU load detected: $([Math]::Round($cpuLoad,2))%"; $issuesFound.Add($msg); Show-Log $msg -Level WARN }
        if ($memoryUsage -gt 90) { $msg = "High memory usage detected: $([Math]::Round($memoryUsage,2))%"; $issuesFound.Add($msg); Show-Log $msg -Level WARN }
        if ($issuesFound.Count -gt 0) {
            Show-Log "Performance check finished. Issues found:" -Level WARN
            $issuesFound | ForEach-Object { Show-Log "- $_" -Level WARN }
            $status = "System performance issues found."
        } else { Show-Log "Performance check completed. No issues found." -Level SUCCESS }
        return $status
    } catch {
        Show-Log "Error during performance check: $($_.Exception.Message)" -Level ERROR; return "Error during performance check."
    } finally { Show-Log "Performance check function finished." -Level DEBUG }
}

function Run-AllMaintenance {
    $totalTasks = 8
    $currentTask = 0
    Show-Log "Starting all system maintenance tasks..." -Level INFO

    if ($script:statusLabel) { $script:statusLabel.Text = "Running Software update..." }
    Update-Software | Out-Null; $currentTask++
    $script:progressBar.Value = [math]::Round(($currentTask / $totalTasks) * 100)

    if ($script:statusLabel) { $script:statusLabel.Text = "Running Driver update..." }
    Update-Drivers | Out-Null; $currentTask++
    $script:progressBar.Value = [math]::Round(($currentTask / $totalTasks) * 100)

    if ($script:statusLabel) { $script:statusLabel.Text = "Running Chocolatey update..." }
    Update-Chocolatey | Out-Null; $currentTask++
    $script:progressBar.Value = [math]::Round(($currentTask / $totalTasks) * 100)

    if ($script:statusLabel) { $script:statusLabel.Text = "Running Windows Apps update..." }
    Update-Apps | Out-Null; $currentTask++
    $script:progressBar.Value = [math]::Round(($currentTask / $totalTasks) * 100)

    if ($script:statusLabel) { $script:statusLabel.Text = "Checking Windows settings..." }
    Check-WindowsSettings | Out-Null; $currentTask++
    $script:progressBar.Value = [math]::Round(($currentTask / $totalTasks) * 100)

    if ($script:statusLabel) { $script:statusLabel.Text = "Running System File Checker (SFC)..." }
    Run-SFC | Out-Null; $currentTask++
    $script:progressBar.Value = [math]::Round(($currentTask / $totalTasks) * 100)

    if ($script:statusLabel) { $script:statusLabel.Text = "Checking disk health..." }
    Check-DiskHealth | Out-Null; $currentTask++
    $script:progressBar.Value = [math]::Round(($currentTask / $totalTasks) * 100)

    if ($script:statusLabel) { $script:statusLabel.Text = "Checking system performance..." }
    Check-Performance | Out-Null; $currentTask++
    $script:progressBar.Value = [math]::Round(($currentTask / $totalTasks) * 100)

    if ($script:statusLabel) { $script:statusLabel.Text = "All tasks completed." }
    Show-Log "All system maintenance tasks completed." -Level INFO
}
#endregion

#region Chocolatey Update
function Update-Chocolatey {
    Show-Log "Starting Chocolatey package update..." -Level INFO
    $chocoExe = Get-Command choco -ErrorAction SilentlyContinue
    if (-not $chocoExe) {
        Show-Log "Chocolatey command ('choco') not found in PATH. Please install Chocolatey first." -Level WARN
        return "Chocolatey not installed."
    }
    $tempDir = $env:TEMP
    $outputLog = Join-Path -Path $tempDir -ChildPath "choco_output_$($PID).log"
    $errorLog = Join-Path -Path $tempDir -ChildPath "choco_error_$($PID).log"
    $status = "Error running Chocolatey update."
    try {
        $chocoArgs = "upgrade all -y --limit-output"
        $process = Start-Process -FilePath $chocoExe.Source -ArgumentList $chocoArgs -Wait -PassThru -NoNewWindow `
            -RedirectStandardOutput $outputLog -RedirectStandardError $errorLog
        $exitCode = $process.ExitCode
        $output = if (Test-Path $outputLog) { Get-Content $outputLog -Raw -ErrorAction SilentlyContinue } else { "" }
        $errors = if (Test-Path $errorLog) { Get-Content $errorLog -Raw -ErrorAction SilentlyContinue } else { "" }
        if ($errors) {
            Show-Log "Chocolatey reported errors (Exit Code: $exitCode):" -Level ERROR
            $errors.Split([Environment]::NewLine) | Select-Object -First 10 | ForEach-Object { Show-Log "  $_" -Level ERROR }
            if (($errors.Split([Environment]::NewLine)).Count -gt 10) { Show-Log "  [... see $errorLog for full details ...]" -Level ERROR }
        }
        if ($output) {
            Show-Log "Chocolatey Output:" -Level INFO
            $output.Split([Environment]::NewLine) | Select-Object -First 20 | ForEach-Object { Show-Log "  $_" -Level INFO }
            if (($output.Split([Environment]::NewLine)).Count -gt 20) { Show-Log "  [... see $outputLog for full details ...]" -Level INFO }
        }
        if ($exitCode -eq 0) {
            if ($output -match "Chocolatey upgraded \d+/\d+ package\(s\)") {
                Show-Log "Chocolatey upgrade completed successfully." -Level SUCCESS
                $summary = $output | Select-String -Pattern "Chocolatey upgraded \d+/\d+" | Select-Object -First 1
                if ($summary) { Show-Log "Summary: $($summary.Line)" -Level SUCCESS }
                $status = "Chocolatey packages updated."
            } elseif ($output -match "no packages found that are upgradable" -or $output -match "0 packages upgraded" -or $output -match "Chocolatey upgraded 0/1 packages.") {
                Show-Log "No packages needed upgrading." -Level SUCCESS
                $status = "No Chocolatey updates needed."
            } else {
                Show-Log "Chocolatey process completed (Exit Code 0), but upgrade status is unclear." -Level WARN
                $status = "Chocolatey update ran (outcome uncertain)."
            }
        } elseif ($exitCode -eq 1605) {
            Show-Log "No packages needed upgrading (Exit Code 1605)." -Level SUCCESS
            $status = "No Chocolatey updates needed."
        } else {
            Show-Log "Chocolatey process failed or completed with errors (Exit Code: $exitCode). Check logs." -Level ERROR
            $status = "Chocolatey update failed (Exit Code: $exitCode)."
        }
        if ($output -match "requires restart") {
            Show-Log "Chocolatey output suggests a reboot might be needed." -Level WARN
            $script:rebootRequired = $true
            $status += " (reboot recommended)"
        }
        return $status
    } catch {
        Show-Log "Error running Chocolatey update: $($_.Exception.Message)" -Level ERROR
        return "Error running Chocolatey update."
    } finally {
        if (Test-Path $outputLog) { Remove-Item $outputLog -Force -ErrorAction SilentlyContinue }
        if (Test-Path $errorLog) { Remove-Item $errorLog -Force -ErrorAction SilentlyContinue }
        Show-Log "Chocolatey update function finished." -Level DEBUG
    }
}
#endregion

#region App Update (winget)
function Update-Apps {
    Show-Log "Starting Windows App update using winget..." -Level INFO
    $wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $wingetCmd) {
        Show-Log "winget is not installed. Attempting to install winget..." -Level INFO
        try {
            Start-Process "ms-windows-store://pdp/?productid=9NBLGGH4NNS1"
            Show-Log "Opened Microsoft Store to install winget. Please install winget and run the script again." -Level WARN
        } catch {
            Show-Log "Failed to open Microsoft Store: $($_.Exception.Message)" -Level ERROR
        }
        return "winget not installed."
    }
    if ($script:progressBar) { $script:progressBar.Value = 10 }
    $tempDir = $env:TEMP
    $wingetOutput = Join-Path -Path $tempDir -ChildPath "winget_output_$($PID).log"
    $wingetError = Join-Path -Path $tempDir -ChildPath "winget_error_$($PID).log"
    try {
        if ($script:progressBar) { $script:progressBar.Value = 20 }
        $process = Start-Process -FilePath $wingetCmd.Source -ArgumentList "upgrade --all --accept-source-agreements --accept-package-agreements" -Wait -PassThru -NoNewWindow `
            -RedirectStandardOutput $wingetOutput -RedirectStandardError $wingetError
        if ($script:progressBar) { $script:progressBar.Value = 80 }
        $exitCode = $process.ExitCode
        $output = if (Test-Path $wingetOutput) { Get-Content $wingetOutput -Raw -ErrorAction SilentlyContinue } else { "" }
        $errors = if (Test-Path $wingetError) { Get-Content $wingetError -Raw -ErrorAction SilentlyContinue } else { "" }
        if ($errors) { Show-Log "winget reported errors: $errors" -Level ERROR }
        if ($exitCode -eq 0) {
            Show-Log "Windows apps updated successfully using winget." -Level SUCCESS
            if ($script:progressBar) { $script:progressBar.Value = 100 }
            return "Apps updated successfully."
        } else {
            Show-Log "winget update completed with errors. Exit Code: $exitCode" -Level ERROR
            if ($script:progressBar) { $script:progressBar.Value = 100 }
            return "winget update encountered issues."
        }
    } catch {
        Show-Log "Error updating apps: $($_.Exception.Message)" -Level ERROR
        if ($script:progressBar) { $script:progressBar.Value = 100 }
        return "Error updating apps."
    } finally {
        if (Test-Path $wingetOutput) { Remove-Item $wingetOutput -Force -ErrorAction SilentlyContinue }
        if (Test-Path $wingetError) { Remove-Item $wingetError -Force -ErrorAction SilentlyContinue }
        Show-Log "winget update function finished." -Level DEBUG
    }
}
#endregion

#region GUI Setup
# Increase overall form size to 1000x800 and enable scrolling
$form = New-Object System.Windows.Forms.Form
$form.Text = "System Maintenance App"
$form.Size = New-Object System.Drawing.Size(1000,800)
$form.StartPosition = "CenterScreen"
$form.BackColor = "Black"
$form.Font = New-Object System.Drawing.Font("Segoe UI",10)
$form.AutoScroll = $true

# Header Label
$headerLabel = New-Object System.Windows.Forms.Label
$headerLabel.Location = New-Object System.Drawing.Point(10,10)
$headerLabel.Size = New-Object System.Drawing.Size(980,30)
$headerLabel.Text = "System Maintenance App"
$headerLabel.ForeColor = "White"
$headerLabel.Font = New-Object System.Drawing.Font("Segoe UI",14,[System.Drawing.FontStyle]::Bold)
$form.Controls.Add($headerLabel)

# Instructions Box
$instructionsBox = New-Object System.Windows.Forms.RichTextBox
$instructionsBox.Location = New-Object System.Drawing.Point(10,50)
$instructionsBox.Size = New-Object System.Drawing.Size(980,60)
$instructionsBox.Text = "This application updates drivers, software, Chocolatey packages, and Windows apps (via winget), " +
                         "checks system settings, runs the System File Checker (SFC), and performs diagnostics. " +
                         "Use the buttons below to run individual tasks or click 'Run All Maintenance Tasks' to execute all."
$instructionsBox.ReadOnly = $true
$instructionsBox.BackColor = "Gray"
$instructionsBox.ForeColor = "White"
$form.Controls.Add($instructionsBox)

# Status Label
$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Location = New-Object System.Drawing.Point(10,120)
$statusLabel.Size = New-Object System.Drawing.Size(980,25)
$statusLabel.Text = "Status: Idle"
$statusLabel.ForeColor = "LightGreen"
$statusLabel.Font = New-Object System.Drawing.Font("Segoe UI",10,[System.Drawing.FontStyle]::Italic)
$form.Controls.Add($statusLabel)
$script:statusLabel = $statusLabel

# GroupBox: Update Tasks
$updateGroup = New-Object System.Windows.Forms.GroupBox
$updateGroup.Location = New-Object System.Drawing.Point(10,155)
$updateGroup.Size = New-Object System.Drawing.Size(480,140)
$updateGroup.Text = "Update Tasks"
$updateGroup.ForeColor = "White"
$updateGroup.Font = New-Object System.Drawing.Font("Segoe UI",10)
$form.Controls.Add($updateGroup)

# GroupBox: Maintenance Checks
$checkGroup = New-Object System.Windows.Forms.GroupBox
$checkGroup.Location = New-Object System.Drawing.Point(500,155)
$checkGroup.Size = New-Object System.Drawing.Size(480,140)
$checkGroup.Text = "Maintenance Checks"
$checkGroup.ForeColor = "White"
$checkGroup.Font = New-Object System.Drawing.Font("Segoe UI",10)
$form.Controls.Add($checkGroup)

# Create a ToolTip for buttons
$toolTip = New-Object System.Windows.Forms.ToolTip

# Update Tasks Buttons
$updateButtons = @(
    @{ Text = "Update Drivers";      Tooltip = "Search and install driver updates via Windows Update.";       Action = { Update-Drivers | Out-Null } },
    @{ Text = "Update Software";     Tooltip = "Search and install software updates via Windows Update.";     Action = { Update-Software | Out-Null } },
    @{ Text = "Update Chocolatey";   Tooltip = "Upgrade all installed Chocolatey packages.";                  Action = { Update-Chocolatey | Out-Null } },
    @{ Text = "Update Apps";         Tooltip = "Update Windows apps using winget.";                          Action = { Update-Apps | Out-Null } }
)
$xPos = 10; $yPos = 25
foreach ($btn in $updateButtons) {
    $button = New-Object System.Windows.Forms.Button
    $button.Location = New-Object System.Drawing.Point($xPos,$yPos)
    $button.Size = New-Object System.Drawing.Size(220,30)
    $button.Text = $btn.Text
    $button.BackColor = "DarkBlue"
    $button.ForeColor = "White"
    $button.FlatStyle = 'Flat'
    $button.Add_Click($btn.Action)
    $toolTip.SetToolTip($button, $btn.Tooltip)
    $updateGroup.Controls.Add($button)
    $yPos += 40
}

# Maintenance Checks Buttons
$checkButtons = @(
    @{ Text = "Check Settings";    Tooltip = "Verify Windows settings (UAC, Windows Update, Firewall).";  Action = { Check-WindowsSettings | Out-Null } },
    @{ Text = "Run SFC";           Tooltip = "Run System File Checker to repair system files.";                 Action = { Run-SFC | Out-Null } },
    @{ Text = "Check Disk Health"; Tooltip = "Perform a disk health check.";                                    Action = { Check-DiskHealth | Out-Null } },
    @{ Text = "Check Performance"; Tooltip = "Check system performance (CPU/memory usage).";                    Action = { Check-Performance | Out-Null } }
)
$xPos = 10; $yPos = 25
foreach ($btn in $checkButtons) {
    $button = New-Object System.Windows.Forms.Button
    $button.Location = New-Object System.Drawing.Point($xPos,$yPos)
    $button.Size = New-Object System.Drawing.Size(220,30)
    $button.Text = $btn.Text
    $button.BackColor = "DarkBlue"
    $button.ForeColor = "White"
    $button.FlatStyle = 'Flat'
    $button.Add_Click($btn.Action)
    $toolTip.SetToolTip($button, $btn.Tooltip)
    $checkGroup.Controls.Add($button)
    $yPos += 40
}

# "Run All Maintenance Tasks" Button
$runAllButton = New-Object System.Windows.Forms.Button
$runAllButton.Location = New-Object System.Drawing.Point(10,305)
$runAllButton.Size = New-Object System.Drawing.Size(980,40)
$runAllButton.Text = "Run All Maintenance Tasks"
$runAllButton.BackColor = "DarkGreen"
$runAllButton.ForeColor = "White"
$runAllButton.FlatStyle = 'Flat'
$runAllButton.Add_Click({ Run-AllMaintenance | Out-Null })
$toolTip.SetToolTip($runAllButton, "Execute all update and diagnostic tasks sequentially.")
$form.Controls.Add($runAllButton)

# Log Text Box
$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Location = New-Object System.Drawing.Point(10,355)
$logBox.Size = New-Object System.Drawing.Size(980,300)
$logBox.Multiline = $true
$logBox.ScrollBars = "Vertical"
$logBox.ReadOnly = $true
$logBox.BackColor = "Gray"
$logBox.ForeColor = "White"
$logBox.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Bottom
$form.Controls.Add($logBox)
$script:logBox = $logBox

# Progress Bar at the bottom
$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(10,665)
$progressBar.Size = New-Object System.Drawing.Size(980,25)
$progressBar.Style = 'Continuous'
$progressBar.Minimum = 0
$progressBar.Maximum = 100
$progressBar.Value = 0
$progressBar.Anchor = [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Bottom
$form.Controls.Add($progressBar)
$script:progressBar = $progressBar

# Hide the console window if running in ConsoleHost
if ($Host.Name -eq 'ConsoleHost') {
    try {
        Add-Type -Name Window -Namespace Console -MemberDefinition @'
            [DllImport("kernel32.dll")]
            public static extern IntPtr GetConsoleWindow();
            [DllImport("user32.dll")]
            public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@
        $consolePtr = [Console.Window]::GetConsoleWindow()
        if ($consolePtr -ne [IntPtr]::Zero) {
            [Console.Window]::ShowWindow($consolePtr, 0)
        }
    } catch {
        Write-Warning "Failed to hide console window: $($_.Exception.Message)"
    }
} else {
    Write-Debug "Not running in console host, skipping console window hiding."
}

$form.ShowDialog() | Out-Null
#endregion
