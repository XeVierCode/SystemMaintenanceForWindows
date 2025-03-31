# System Maintenance App

A PowerShell-based GUI application for performing various system maintenance tasks on Windows. This script checks for driver and software updates, updates Chocolatey and Windows apps (using winget), verifies system settings, runs the System File Checker (SFC), and performs diagnostics on disk health and system performance.

## Features

- **Elevation Check:**  
  Automatically re-launches the script with administrator privileges if needed.

- **Windows Update:**  
  Checks for and installs available driver and software updates using Windows Update APIs.

- **Chocolatey Update:**  
  Upgrades all installed Chocolatey packages.

- **Windows App Update:**  
  Uses [winget](https://github.com/microsoft/winget-cli) to check for and upgrade Windows apps.

- **System File Checker (SFC):**  
  Runs SFC to verify and repair system file integrity.

- **Diagnostics:**  
  Checks disk health (using CIM) and system performance (CPU and memory usage).

- **Windows Settings Verification:**  
  Ensures critical settings (e.g., UAC, Windows Defender Firewall) are correctly configured.

- **GUI Interface:**  
  A Windows Forms-based GUI for running individual tasks or all maintenance tasks at once, with real-time logging.

## Prerequisites

- Windows PowerShell (v5.1 or later)
- Administrator privileges (the script auto-elevates if not run as admin)
- [Chocolatey](https://chocolatey.org/) (for Chocolatey package updates)
- [winget](https://github.com/microsoft/winget-cli) (for updating Windows apps)

## How to Use

1. **Clone or Download the Repository:**  
   Use `git clone` or download the ZIP file.

2. **Run the Script:**  
   Right-click `SystemMaintenance.ps1` and select **Run with PowerShell** or execute it from an elevated PowerShell prompt.

3. **Using the GUI:**  
   - Click individual buttons to run specific maintenance tasks.
   - Use the **Run All Maintenance Tasks** button to execute all tasks in sequence.
   - Logs are displayed in the GUI and saved to a log file in the `%TEMP%` directory.

4. **Post-Maintenance:**  
   If any task indicates that a reboot is required, please restart your computer.

## Contributing

Contributions are welcome! Feel free to fork this repository and submit pull requests with improvements or bug fixes.

## License

This project is licensed under the [MIT License](LICENSE).
