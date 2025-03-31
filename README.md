# System Maintenance App

A PowerShell-based GUI application for performing various system maintenance tasks on Windows. This tool updates drivers, software, Chocolatey packages, and Windows apps (via winget), verifies system settings, runs the System File Checker (SFC), and performs diagnostics on disk health and performance.

---

## Release: v1.0.0 – Modernized GUI & Maintenance Enhancements

### Overview
This initial release introduces a fully modernized GUI that improves the user experience and overall functionality. Key enhancements include a reorganized layout with clearly grouped update tasks and maintenance checks, a dynamic status label that shows the current task, and a progress bar that updates as each task completes.

### Key Enhancements
- **Modernized User Interface:**  
  - Two group boxes separate the update tasks (drivers, software, Chocolatey, and apps) from the maintenance checks (settings, SFC, disk health, performance).  
  - A dynamic status label displays the current task.  
  - A progress bar visually indicates the overall progress of maintenance tasks.  
  - Improved spacing, anchoring, and auto-scrolling ensure that no controls are cut off, even on smaller screens.
  
- **Enhanced Maintenance Features:**  
  - Supports updating drivers and software through Windows Update.  
  - Upgrades all installed Chocolatey packages.  
  - Updates Windows apps using winget (and prompts installation via Microsoft Store if winget is missing).  
  - Checks important Windows settings (e.g., UAC, Windows Update service, and Windows Defender Firewall).  
  - Runs the System File Checker (SFC) and performs diagnostic tests on disk health and system performance.

- **Robust Logging & Error Handling:**  
  - Detailed logging is available both in the GUI and as a log file in the `%TEMP%` folder.
  - Error messages and progress updates help users troubleshoot if any tasks fail.

---

## Prerequisites

- Windows PowerShell (v5.1 or later)
- Administrator privileges (the script auto-elevates if necessary)
- [Chocolatey](https://chocolatey.org/) (for Chocolatey package updates)
- [winget](https://github.com/microsoft/winget-cli) (for updating Windows apps)

---

## How to Use

1. **Clone or Download the Repository:**

   ```bash
   git clone https://github.com/XeVierCode/SystemMaintenanceForWindows
   ```

2. **Run the Script:**

   Double-click **SystemMaintenance.bat** and click **Yes** when prompted for administrator permissions.  
   The BAT file launches **Core.ps1**, which contains the GUI and core functionality.

3. **Using the GUI:**

   - Read the instructions displayed at the top of the application.
   - Use the **Update Tasks** group to run individual update tasks (Drivers, Software, Chocolatey, and Windows Apps).
   - Use the **Maintenance Checks** group for system diagnostics (Settings, SFC, Disk Health, Performance).
   - Click the **Run All Maintenance Tasks** button to execute all tasks sequentially. The status label will indicate the current task, and the progress bar will update accordingly.
   - View logs in the log box; a complete log is saved to the `%TEMP%` folder.

4. **Post-Maintenance:**

   If any task indicates that a reboot is required, please restart your computer to complete the updates.

---

## Contributing

Contributions are welcome! Feel free to fork the repository and submit pull requests with improvements, bug fixes, or additional features.

---

## License

This project is licensed under the [MIT License](LICENSE).
