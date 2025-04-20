import sys
import os
import threading
import uvicorn
from PyQt6.QtWidgets import (QApplication, QMainWindow, QWidget, QVBoxLayout, 
                            QPushButton, QLabel, QFileDialog, QTextEdit, 
                            QLineEdit, QMessageBox)
from PyQt6.QtCore import Qt, pyqtSignal, QObject
from pathlib import Path

# Import our existing server app
from server import app
from upload import UploadHandler
from watchdog.observers import Observer

class LogSignals(QObject):
    new_log = pyqtSignal(str)

class ServerThread(threading.Thread):
    def __init__(self, port):
        super().__init__()
        self.port = port
        self.daemon = True  # Thread will close when main program exits
        
    def run(self):
        uvicorn.run(app, host="0.0.0.0", port=self.port)

class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("Pixel Backup Manager")
        self.setMinimumSize(600, 400)
        
        # Create main widget and layout
        main_widget = QWidget()
        self.setCentralWidget(main_widget)
        layout = QVBoxLayout(main_widget)
        
        # Server controls
        self.port_label = QLabel("Server Port:")
        self.port_input = QLineEdit("8000")
        self.server_status = QLabel("Server Status: Not Running")
        self.start_server_btn = QPushButton("Start Server")
        self.start_server_btn.clicked.connect(self.toggle_server)
        
        # Watch folder controls
        self.folder_label = QLabel("Watch Folder: Not Selected")
        self.select_folder_btn = QPushButton("Select Folder")
        self.select_folder_btn.clicked.connect(self.select_folder)
        
        # IP Address display
        import socket
        ip = socket.gethostbyname(socket.gethostname())
        self.ip_label = QLabel(f"Server IP: {ip}")
        
        # Log display
        self.log_display = QTextEdit()
        self.log_display.setReadOnly(True)
        
        # Add widgets to layout
        layout.addWidget(self.port_label)
        layout.addWidget(self.port_input)
        layout.addWidget(self.server_status)
        layout.addWidget(self.start_server_btn)
        layout.addWidget(self.ip_label)
        layout.addWidget(self.folder_label)
        layout.addWidget(self.select_folder_btn)
        layout.addWidget(QLabel("Log:"))
        layout.addWidget(self.log_display)
        
        # Initialize variables
        self.server_thread = None
        self.observer = None
        self.watch_dir = None
        self.server_running = False
        
        # Set up log signals
        self.log_signals = LogSignals()
        self.log_signals.new_log.connect(self.append_log)
        
        # Custom upload handler that logs to GUI
        class GUIUploadHandler(UploadHandler):
            def __init__(self, server_url, log_signals):
                super().__init__(server_url)
                self.log_signals = log_signals
                
            def upload_file(self, file_path):
                try:
                    with open(file_path, 'rb') as f:
                        files = {'file': (os.path.basename(file_path), f)}
                        response = requests.post(f"{self.server_url}/upload/", files=files)
                        if response.status_code == 200:
                            self.log_signals.new_log.emit(f"Successfully uploaded {file_path}")
                        else:
                            self.log_signals.new_log.emit(
                                f"Failed to upload {file_path}: {response.json()['message']}")
                except Exception as e:
                    self.log_signals.new_log.emit(f"Error uploading {file_path}: {str(e)}")
        
        self.UploadHandler = GUIUploadHandler
        
        # Show instructions
        self.show_instructions()
    
    def show_instructions(self):
        instructions = """
Instructions:
1. Enter the port number (default: 8000)
2. Click 'Start Server' to start the backup server
3. Select a folder to watch for new files
4. On your Pixel phone, run:
   ./sync_service.sh http://<your-pc-ip>:8000

Any files you add to the watch folder will automatically
be sent to your phone and appear as internal storage.
        """
        QMessageBox.information(self, "How to Use", instructions)
    
    def append_log(self, message):
        self.log_display.append(message)
    
    def toggle_server(self):
        if not self.server_running:
            try:
                port = int(self.port_input.text())
                self.server_thread = ServerThread(port)
                self.server_thread.start()
                self.server_running = True
                self.server_status.setText("Server Status: Running")
                self.start_server_btn.setText("Stop Server")
                self.port_input.setEnabled(False)
                self.append_log(f"Server started on port {port}")
            except Exception as e:
                self.append_log(f"Error starting server: {str(e)}")
                QMessageBox.critical(self, "Error", f"Failed to start server: {str(e)}")
        else:
            # Note: Currently, we don't have a clean way to stop uvicorn
            # This will just disable the controls
            self.server_running = False
            self.server_status.setText("Server Status: Not Running")
            self.start_server_btn.setText("Start Server")
            self.port_input.setEnabled(True)
            self.append_log("Server stopped")
            QMessageBox.information(self, "Restart Required", 
                                  "Please close and restart the application to start the server again")
    
    def select_folder(self):
        folder = QFileDialog.getExistingDirectory(self, "Select Folder to Watch")
        if folder:
            self.watch_dir = folder
            self.folder_label.setText(f"Watch Folder: {folder}")
            
            # Stop existing observer if any
            if self.observer:
                self.observer.stop()
                self.observer.join()
            
            # Start new observer
            try:
                server_url = f"http://localhost:{self.port_input.text()}"
                event_handler = self.UploadHandler(server_url, self.log_signals)
                self.observer = Observer()
                self.observer.schedule(event_handler, folder, recursive=False)
                self.observer.start()
                self.append_log(f"Now watching folder: {folder}")
            except Exception as e:
                self.append_log(f"Error setting up folder watch: {str(e)}")
                QMessageBox.critical(self, "Error", f"Failed to watch folder: {str(e)}")

if __name__ == '__main__':
    app = QApplication(sys.argv)
    window = MainWindow()
    window.show()
    sys.exit(app.exec()) 