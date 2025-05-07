#!/usr/bin/env python3
"""
MiracleCast GUI - A user-friendly interface for WiFi Display functionality
"""

import sys
import os
import subprocess
import re
import time
import shlex
import atexit
from PyQt5.QtWidgets import (
    QApplication, QMainWindow, QPushButton, QVBoxLayout, QWidget,
    QTabWidget, QTextEdit, QLabel, QComboBox, QMessageBox,
    QGroupBox, QGridLayout, QCheckBox, QHBoxLayout,
    QListWidget, QListWidgetItem, QStackedWidget, QLineEdit
)
from PyQt5.QtCore import QProcess, Qt, QTimer, QProcessEnvironment
from PyQt5.QtGui import QIcon, QFont

class MiracleCastGUI(QMainWindow):
    """Main application window"""
    def __init__(self):
        super().__init__()
        self.processes = {}
        self.interfaces = []
        self.mirror_commands = []
        self.universal_script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "miraclecast-universal.sh")
        self.init_ui()
        QTimer.singleShot(100, self.check_dependencies)
        
        # Register cleanup on exit
        atexit.register(self.cleanup_on_exit)
        
    def cleanup_on_exit(self):
        """Ensure all processes are properly terminated on exit"""
        for name, process in self.processes.items():
            try:
                if process.state() != QProcess.NotRunning:
                    self.log(f"Cleaning up process: {name}")
                    process.terminate()
                    if not process.waitForFinished(2000):
                        process.kill()
            except Exception as e:
                print(f"Error cleaning up process {name}: {e}")

    def init_ui(self):
        """Initialize user interface"""
        self.setWindowTitle("MiracleCast Controller")
        self.setGeometry(100, 100, 900, 650)

        try:
            self.setWindowIcon(QIcon.fromTheme("video-display"))
        except Exception:
            pass

        main_widget = QWidget()
        layout = QVBoxLayout()

        # Tab widget
        tabs = QTabWidget()
        self.sink_tab = self.create_sink_tab()
        self.source_tab = self.create_source_tab()
        self.setup_tab = self.create_setup_tab()

        tabs.addTab(self.sink_tab, "Receive Display (Sink)")
        tabs.addTab(self.source_tab, "Send Display (Source)")
        tabs.addTab(self.setup_tab, "Setup")

        # Console output
        console_group = QGroupBox("Console Output")
        console_layout = QVBoxLayout()
        self.console = QTextEdit()
        self.console.setReadOnly(True)
        self.console.setFont(QFont("Monospace", 10))
        console_layout.addWidget(self.console)

        clear_btn = QPushButton("Clear Console")
        clear_btn.clicked.connect(self.console.clear)
        console_layout.addWidget(clear_btn)
        console_group.setLayout(console_layout)

        # Main layout assembly
        layout.addWidget(tabs)
        layout.addWidget(console_group)
        main_widget.setLayout(layout)
        self.setCentralWidget(main_widget)

    def create_sink_tab(self):
        """Create sink control tab"""
        tab = QWidget()
        layout = QVBoxLayout()

        # Interface selection
        iface_group = QGroupBox("Network Interface")
        iface_layout = QHBoxLayout()
        self.iface_combo = QComboBox()
        refresh_btn = QPushButton("Refresh")
        refresh_btn.clicked.connect(self.refresh_interfaces)
        iface_layout.addWidget(QLabel("Select Interface:"))
        iface_layout.addWidget(self.iface_combo)
        iface_layout.addWidget(refresh_btn)
        iface_group.setLayout(iface_layout)

        # Options group
        options_group = QGroupBox("Sink Options")
        options_layout = QVBoxLayout()
        
        # UIBC Support
        self.uibc_check = QCheckBox("Enable User Input Back-Channel (UIBC)")
        options_layout.addWidget(self.uibc_check)
        
        # Green screen fix
        self.green_screen_check = QCheckBox("Apply green screen fix")
        self.green_screen_check.setToolTip("Apply fix for green screen issues when using GStreamer")
        options_layout.addWidget(self.green_screen_check)
        
        # Hardware fixes
        self.hw_fixes_check = QCheckBox("Apply hardware compatibility fixes")
        self.hw_fixes_check.setChecked(True)
        self.hw_fixes_check.setToolTip("Run hardware compatibility checks and fixes")
        options_layout.addWidget(self.hw_fixes_check)
        
        # Session management
        self.session_check = QCheckBox("Use session-based network management")
        self.session_check.setChecked(True)
        self.session_check.setToolTip("Preserve network state instead of completely stopping services")
        options_layout.addWidget(self.session_check)
        
        options_group.setLayout(options_layout)

        # Control buttons
        control_group = QGroupBox("Sink Control")
        control_layout = QHBoxLayout()
        self.start_sink_btn = QPushButton("Start Sink Mode")
        self.start_sink_btn.clicked.connect(self.start_sink_service)
        self.stop_sink_btn = QPushButton("Stop Sink Mode")
        self.stop_sink_btn.clicked.connect(self.stop_sink_service)
        control_layout.addWidget(self.start_sink_btn)
        control_layout.addWidget(self.stop_sink_btn)
        control_group.setLayout(control_layout)

        # Status
        status_group = QGroupBox("Status")
        self.sink_status_label = QLabel("Not Running")
        status_group.setLayout(QVBoxLayout())
        status_group.layout().addWidget(self.sink_status_label)

        instructions = QLabel(
            "<b>Instructions:</b><br>"
            "1. Select wireless interface<br>"
            "2. Configure sink options<br>"
            "3. Click 'Start Sink Mode'<br>"
            "4. The universal script will handle all background services<br>"
            "5. Connect from source device"
        )
        instructions.setWordWrap(True)

        # Tab layout assembly
        layout.addWidget(iface_group)
        layout.addWidget(options_group)
        layout.addWidget(control_group)
        layout.addWidget(status_group)
        layout.addWidget(instructions)
        tab.setLayout(layout)
        return tab

    def create_source_tab(self):
        """Create source control tab"""
        tab = QWidget()
        layout = QVBoxLayout()

        # Interface selection
        iface_group = QGroupBox("Network Interface")
        iface_layout = QHBoxLayout()
        self.source_iface_combo = QComboBox()
        refresh_btn = QPushButton("Refresh")
        refresh_btn.clicked.connect(lambda: self.refresh_interfaces(self.source_iface_combo))
        iface_layout.addWidget(QLabel("Select Interface:"))
        iface_layout.addWidget(self.source_iface_combo)
        iface_layout.addWidget(refresh_btn)
        iface_group.setLayout(iface_layout)

        # Source options
        options_group = QGroupBox("Source Options")
        options_layout = QVBoxLayout()
        
        # Resolution settings
        res_layout = QHBoxLayout()
        res_layout.addWidget(QLabel("Resolution:"))
        self.source_res_width = QLineEdit("1280")
        self.source_res_width.setMaximumWidth(60)
        res_layout.addWidget(self.source_res_width)
        res_layout.addWidget(QLabel("x"))
        self.source_res_height = QLineEdit("720")
        self.source_res_height.setMaximumWidth(60)
        res_layout.addWidget(self.source_res_height)
        options_layout.addLayout(res_layout)
        
        # FPS and bitrate
        perf_layout = QHBoxLayout()
        perf_layout.addWidget(QLabel("FPS:"))
        self.source_fps = QLineEdit("30")
        self.source_fps.setMaximumWidth(40)
        perf_layout.addWidget(self.source_fps)
        perf_layout.addWidget(QLabel("Bitrate (kbps):"))
        self.source_bitrate = QLineEdit("8192")
        perf_layout.addWidget(self.source_bitrate)
        options_layout.addLayout(perf_layout)
        
        # Hardware fixes
        self.source_hw_fixes_check = QCheckBox("Apply hardware compatibility fixes")
        self.source_hw_fixes_check.setChecked(True)
        self.source_hw_fixes_check.setToolTip("Run hardware compatibility checks and fixes")
        options_layout.addWidget(self.source_hw_fixes_check)
        
        # Session management
        self.source_session_check = QCheckBox("Use session-based network management")
        self.source_session_check.setChecked(True)
        self.source_session_check.setToolTip("Preserve network state instead of completely stopping services")
        options_layout.addWidget(self.source_session_check)
        
        options_group.setLayout(options_layout)

        # Control buttons
        control_group = QGroupBox("Source Control")
        control_layout = QHBoxLayout()
        self.start_source_btn = QPushButton("Start Source Mode")
        self.start_source_btn.clicked.connect(self.start_source_service)
        self.stop_source_btn = QPushButton("Stop Source Mode")
        self.stop_source_btn.clicked.connect(self.stop_source_service)
        control_layout.addWidget(self.start_source_btn)
        control_layout.addWidget(self.stop_source_btn)
        control_group.setLayout(control_layout)

        # Output display for interactive wifictl
        output_group = QGroupBox("Source Interactive Mode")
        output_layout = QVBoxLayout()
        output_help = QLabel("After the source mode starts, use these commands to connect and stream:")
        output_help.setWordWrap(True)
        output_layout.addWidget(output_help)
        
        commands_label = QLabel(
            "<b>Commands:</b><br>"
            "- <code>connect PEER_ID</code> - Connect to a peer device<br>"
            "- <code>stream-start PEER_ID</code> - Start streaming to peer<br>"
            "- <code>stream-stop</code> - Stop streaming<br>"
            "- <code>exit</code> - Quit interactive mode"
        )
        commands_label.setTextFormat(Qt.RichText)
        output_layout.addWidget(commands_label)
        output_group.setLayout(output_layout)

        # Status
        status_group = QGroupBox("Status")
        self.source_status_label = QLabel("Not Running")
        status_group.setLayout(QVBoxLayout())
        status_group.layout().addWidget(self.source_status_label)

        # Assembly
        layout.addWidget(iface_group)
        layout.addWidget(options_group)
        layout.addWidget(control_group)
        layout.addWidget(output_group)
        layout.addWidget(status_group)
        tab.setLayout(layout)
        return tab

    def create_setup_tab(self):
        """Create setup tab"""
        tab = QWidget()
        layout = QVBoxLayout()

        # Service management
        svc_group = QGroupBox("Network Services")
        svc_layout = QGridLayout()

        self.nm_stop_btn = QPushButton("Stop NetworkManager")
        self.nm_start_btn = QPushButton("Start NetworkManager")
        self.wpa_stop_btn = QPushButton("Stop wpa_supplicant")
        self.wpa_start_btn = QPushButton("Start wpa_supplicant")

        svc_layout.addWidget(self.nm_stop_btn, 0, 0)
        svc_layout.addWidget(self.nm_start_btn, 0, 1)
        svc_layout.addWidget(self.wpa_stop_btn, 1, 0)
        svc_layout.addWidget(self.wpa_start_btn, 1, 1)

        self.nm_status = QLabel("Unknown")
        self.wpa_status = QLabel("Unknown")
        svc_layout.addWidget(QLabel("NetworkManager:"), 0, 2)
        svc_layout.addWidget(self.nm_status, 0, 3)
        svc_layout.addWidget(QLabel("wpa_supplicant:"), 1, 2)
        svc_layout.addWidget(self.wpa_status, 1, 3)

        refresh_btn = QPushButton("Refresh Status")
        refresh_btn.clicked.connect(self.check_services_status)
        svc_layout.addWidget(refresh_btn, 2, 0, 1, 4)

        self.nm_stop_btn.clicked.connect(lambda: self.manage_service("NetworkManager", False))
        self.nm_start_btn.clicked.connect(lambda: self.manage_service("NetworkManager", True))
        self.wpa_stop_btn.clicked.connect(lambda: self.manage_service("wpa_supplicant", False))
        self.wpa_start_btn.clicked.connect(lambda: self.manage_service("wpa_supplicant", True))
        svc_group.setLayout(svc_layout)

        # Universal script info
        universal_group = QGroupBox("Universal Script")
        universal_layout = QVBoxLayout()
        universal_path = QLabel(f"Script path: {self.universal_script}")
        universal_layout.addWidget(universal_path)
        
        script_info = QLabel(
            "The universal script provides an integrated solution that:<br>"
            "- Handles network configuration automatically<br>"
            "- Applies hardware compatibility fixes<br>"
            "- Supports both sink and source modes<br>"
            "- Includes fixes for common issues (green screen, etc.)<br>"
            "- Manages session properly for clean shutdown"
        )
        script_info.setTextFormat(Qt.RichText)
        universal_layout.addWidget(script_info)
        universal_group.setLayout(universal_layout)

        # Information section
        info_group = QGroupBox("About MiracleCast")
        info_layout = QVBoxLayout()
        info_text = QLabel(
            "MiracleCast implements WiFi Display (Miracast) specification\n\n"
            "Source: Mirror screen to sink device\n"
            "Sink: Display content from source device\n\n"
            "Project page: <a href='https://github.com/albfan/miraclecast'>GitHub</a>"
        )
        info_text.setOpenExternalLinks(True)
        info_layout.addWidget(info_text)
        info_group.setLayout(info_layout)

        layout.addWidget(svc_group)
        layout.addWidget(universal_group)
        layout.addWidget(info_group)
        QTimer.singleShot(500, self.check_services_status)
        tab.setLayout(layout)
        return tab

    # Core functionality methods
    def check_dependencies(self):
        """Verify required components are installed"""
        required = ['miracle-wifid', 'miracle-sinkctl', 'miracle-wifictl']
        
        # Check if universal script exists
        if not os.path.exists(self.universal_script):
            self.show_error(f"Universal script not found at: {self.universal_script}")
            return
            
        missing = []
        for cmd in required:
            if not self.command_exists(cmd):
                missing.append(cmd)

        if missing:
            self.show_error(f"Missing components:\n{', '.join(missing)}\nInstall via Setup instructions")
        else:
            self.refresh_interfaces()

    def command_exists(self, cmd):
        """Check if command exists in system PATH"""
        return subprocess.call(['which', cmd],
                              stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL) == 0

    def refresh_interfaces(self, combo=None):
        """Refresh available network interfaces"""
        try:
            # Use the miracle-utils.sh function via universal script to find wireless interfaces
            cmd = f"{self.universal_script} --list-interfaces"
            result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
            
            if result.returncode != 0:
                # Fallback to direct method if script fails
                result = subprocess.run(['ip', 'link', 'show'], capture_output=True, text=True)
                interfaces = re.findall(r'\d+: ([^:]+):', result.stdout)
                valid_ifaces = [iface for iface in interfaces
                              if not iface.startswith(('lo', 'virbr', 'docker'))]
            else:
                valid_ifaces = result.stdout.strip().split('\n')

            targets = [self.iface_combo, self.source_iface_combo] if combo is None else [combo]
            for widget in targets:
                widget.clear()
                widget.addItems(valid_ifaces)
        except Exception as e:
            self.log(f"Interface refresh failed: {str(e)}", error=True)

    def check_services_status(self):
        """Update service status indicators"""
        try:
            nm_active = subprocess.call(['systemctl', 'is-active', 'NetworkManager']) == 0
            wpa_active = subprocess.call(['systemctl', 'is-active', 'wpa_supplicant']) == 0
            self.nm_status.setText("Running" if nm_active else "Stopped")
            self.wpa_status.setText("Running" if wpa_active else "Stopped")
        except Exception as e:
            self.log(f"Service status check failed: {str(e)}", error=True)
    
    def show_error(self, message):
        """Display error message dialog"""
        QMessageBox.critical(self, "Error", message)
        
    def log(self, message, error=False):
        """Add message to console log"""
        timestamp = time.strftime("[%H:%M:%S]")
        prefix = "[ERROR] " if error else ""
        self.console.append(f"{timestamp} {prefix}{message}")
        if error:
            print(f"ERROR: {message}", file=sys.stderr)

    def build_universal_cmd(self, mode):
        """Build command line for universal script"""
        if mode == "sink":
            iface = self.iface_combo.currentText()
            # Build options for sink mode
            cmd = [self.universal_script, "-i", iface, "-m", "sink"]
            
            # Add UIBC if enabled
            if self.uibc_check.isChecked():
                cmd.append("-u")
                
            # Add green screen fix if enabled
            if self.green_screen_check.isChecked():
                cmd.append("-g")
                
            # Add hardware fix option
            if not self.hw_fixes_check.isChecked():
                cmd.append("-n")
                
            # Add session management option
            if not self.session_check.isChecked():
                cmd.append("-s")
                
        elif mode == "source":
            iface = self.source_iface_combo.currentText()
            # Build options for source mode
            cmd = [self.universal_script, "-i", iface, "-m", "source"]
            
            # Add resolution if set with validation
            width = self.source_res_width.text().strip()
            height = self.source_res_height.text().strip()
            if width and height and width.isdigit() and height.isdigit():
                width_val, height_val = int(width), int(height)
                if 320 <= width_val <= 3840 and 240 <= height_val <= 2160:
                    cmd.extend(["-r", f"{width}x{height}"])
                else:
                    self.show_error("Invalid resolution. Width must be 320-3840, height 240-2160.")
                    return None
                
            # Add FPS if set with validation
            fps = self.source_fps.text().strip()
            if fps and fps.isdigit():
                fps_val = int(fps)
                if 10 <= fps_val <= 60:
                    cmd.extend(["-f", fps])
                else:
                    self.show_error("Invalid FPS. Must be between 10-60.")
                    return None
                
            # Add bitrate if set with validation
            bitrate = self.source_bitrate.text().strip()
            if bitrate and bitrate.isdigit():
                bitrate_val = int(bitrate)
                if 1000 <= bitrate_val <= 20000:
                    cmd.extend(["-b", bitrate])
                else:
                    self.show_error("Invalid bitrate. Must be between 1000-20000 kbps.")
                    return None
                
            # Add hardware fix option
            if not self.source_hw_fixes_check.isChecked():
                cmd.append("-n")
                
            # Add session management option
            if not self.source_session_check.isChecked():
                cmd.append("-s")
        
        return cmd
            
    def start_sink_service(self):
        """Start sink mode using universal script"""
        iface = self.iface_combo.currentText()
        if not iface:
            self.show_error("Select network interface first")
            return

        # Build command with options
        cmd = self.build_universal_cmd("sink")
        self.run_command(cmd, 'sink')
        self.sink_status_label.setText("Running")
        self.log(f"Started sink mode with universal script on {iface}")
            
    def stop_sink_service(self):
        """Stop sink service with proper termination handling"""
        if 'sink' in self.processes:
            process = self.processes['sink']
            process.terminate()
            # Wait up to 3 seconds for process to terminate
            if not process.waitForFinished(3000):
                self.log("Process didn't terminate gracefully, forcing...", error=True)
                process.kill()
            self.sink_status_label.setText("Not Running")
            self.log("Stopped sink service")
            
    def start_source_service(self):
        """Start source mode using universal script"""
        iface = self.source_iface_combo.currentText()
        if not iface:
            self.show_error("Select network interface first")
            return

        # Build command with options
        cmd = self.build_universal_cmd("source")
        self.run_command(cmd, 'source')
        self.source_status_label.setText("Running")
        self.log(f"Started source mode with universal script on {iface}")
            
    def stop_source_service(self):
        """Stop source service with proper termination handling"""
        if 'source' in self.processes:
            process = self.processes['source']
            process.terminate()
            # Wait up to 3 seconds for process to terminate
            if not process.waitForFinished(3000):
                self.log("Process didn't terminate gracefully, forcing...", error=True)
                process.kill()
            self.source_status_label.setText("Not Running")
            self.log("Stopped source service")
            
    def run_command(self, cmd, process_name):
        """Run a command using QProcess with improved error handling"""
        # Check if command is valid
        if cmd is None:
            self.log("Invalid command parameters, cannot execute", error=True)
            return
            
        if process_name in self.processes:
            # Stop existing process with timeout handling
            process = self.processes[process_name]
            process.terminate()
            if not process.waitForFinished(3000):  # 3 second timeout
                self.log(f"Process didn't terminate gracefully, forcing kill", error=True)
                process.kill()
            
        # Log the command to be executed
        self.log(f"Running: {' '.join(cmd)}")
            
        # Create new process
        process = QProcess(self)
        self.processes[process_name] = process
        
        # Connect signals
        process.readyReadStandardOutput.connect(
            lambda: self.process_output(process, process_name, False))
        process.readyReadStandardError.connect(
            lambda: self.process_output(process, process_name, True))
        process.finished.connect(
            lambda exit_code, exit_status: self.process_finished(process_name, exit_code, exit_status))
        
        # Start process with error handling
        try:
            process.start(cmd[0], cmd[1:])
            if not process.waitForStarted(5000):  # 5 second timeout
                self.log(f"Failed to start process: {cmd[0]}", error=True)
                self.processes.pop(process_name, None)
                if process_name == 'sink':
                    self.sink_status_label.setText("Start Failed")
                elif process_name == 'source':
                    self.source_status_label.setText("Start Failed")
        except Exception as e:
            self.log(f"Exception starting process: {str(e)}", error=True)
            self.processes.pop(process_name, None)
            
    def process_finished(self, process_name, exit_code, exit_status):
        """Handle process completion"""
        if exit_code != 0:
            self.log(f"Process '{process_name}' exited with code {exit_code}", error=True)
            if process_name == 'sink':
                self.sink_status_label.setText("Error")
            elif process_name == 'source':
                self.source_status_label.setText("Error")
        else:
            self.log(f"Process '{process_name}' completed successfully")
            if process_name == 'sink':
                self.sink_status_label.setText("Not Running")
            elif process_name == 'source':
                self.source_status_label.setText("Not Running")
        
    def process_output(self, process, name, is_error):
        """Handle process output"""
        if is_error:
            output = process.readAllStandardError().data().decode('utf-8', errors='replace')
            self.log(f"[{name}] {output}", error=True)
        else:
            output = process.readAllStandardOutput().data().decode('utf-8', errors='replace')
            self.log(f"[{name}] {output}")
            
    def manage_service(self, service_name, start=True):
        """Manage system services with improved validation"""
        # Validate service name to prevent command injection
        if not re.match(r'^[a-zA-Z0-9_.-]+$', service_name):$', service_name):
            error_msg = f"Invalid service name format: {service_name}"
            self.show_error(error_msg)
            self.log(error_msg, error=True)
            return
            
        action = "start" if start else "stop"
        try:
            # Use a whitelist approach for allowed services
            allowed_services = ["NetworkManager", "wpa_supplicant", "network-manager"]
            if service_name not in allowed_services:
                error_msg = f"Service management not allowed for: {service_name}"
                self.show_error(error_msg)
                self.log(error_msg, error=True)
                return
                
            result = subprocess.run(['sudo', 'systemctl', action, service_name], 
                                   capture_output=True, text=True)
            if result.returncode == 0:
                self.log(f"{service_name} {action}ed successfully")
                self.check_services_status()
            else:
                error_msg = result.stderr.strip() or f"Failed to {action} {service_name}"
                self.show_error(error_msg)
                self.log(error_msg, error=True)
        except Exception as e:
            self.show_error(f"Error: {str(e)}")
            self.log(str(e), error=True)


# Add a helper function to the universal script
def add_list_interfaces_option():
    """Add --list-interfaces option to universal script to list wireless interfaces only"""
    script_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "miraclecast-universal.sh")
    
    # Check if the option already exists
    with open(script_path, 'r') as f:
        content = f.read()
        if '--list-interfaces' in content:
            return  # Option already exists
    
    # Add the option handling to the getopts section
    updated_content = content.replace(
        "while getopts \"i:m:r:f:b:ugnsh\" opt; do",
        "while getopts \"i:m:r:f:b:ugnslh\" opt; do",
    )
    
    # Add case for the new option
    updated_content = updated_content.replace(
        "        h)\n            show_help\n            exit 0\n            ;;",
        "        h)\n            show_help\n            exit 0\n            ;;\n" +
        "        l)\n            # List wireless interfaces only\n" +
        "            find_wireless_network_interfaces\n" +
        "            exit 0\n            ;;"
    )
    
    # Update help text
    updated_content = updated_content.replace(
        "  -h               Show this help message",
        "  -h               Show this help message\n" +
        "  -l               List available wireless interfaces"
    )
    
    # Write updated script
    with open(script_path, 'w') as f:
        f.write(updated_content)


# Main entry point
if __name__ == "__main__":
    # Check if running as root
    if os.geteuid() != 0:
        print("MiracleCast GUI requires root privileges to access network interfaces.")
        print("Please run with sudo or pkexec.")
        sys.exit(1)
    
    # Add list interfaces option to universal script if needed
    try:
        add_list_interfaces_option()
    except Exception as e:
        print(f"Warning: Could not update universal script: {e}")
        
    # Ensure helper scripts are executable
    try:
        script_path = os.path.dirname(os.path.abspath(__file__))
        universal_script = os.path.join(script_path, "miraclecast-universal.sh")
        subprocess.run(['chmod', '+x', universal_script], check=True)
        
        helper_scripts = [
            "res/hardware-compatibility-fixer.sh",
            "res/network-session-manager.sh",
            "res/miracle-gst-improved",
            "res/enhanced-uibc-viewer",
            "res/miracle-utils.sh"
        ]
        
        for script in helper_scripts:
            script_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), script)
            if os.path.exists(script_path):
                subprocess.run(['chmod', '+x', script_path], check=True)
    except Exception as e:
        print(f"Warning: Could not set executable permissions: {e}")
        
    app = QApplication(sys.argv)
    window = MiracleCastGUI()
    window.show()
    sys.exit(app.exec_())