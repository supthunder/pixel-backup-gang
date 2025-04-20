import sys
import os
import requests
from pathlib import Path
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler

class UploadHandler(FileSystemEventHandler):
    def __init__(self, server_url):
        self.server_url = server_url

    def upload_file(self, file_path):
        try:
            with open(file_path, 'rb') as f:
                files = {'file': (os.path.basename(file_path), f)}
                response = requests.post(f"{self.server_url}/upload/", files=files)
                if response.status_code == 200:
                    print(f"Successfully uploaded {file_path}")
                else:
                    print(f"Failed to upload {file_path}: {response.json()['message']}")
        except Exception as e:
            print(f"Error uploading {file_path}: {str(e)}")

    def on_created(self, event):
        if not event.is_directory:
            self.upload_file(event.src_path)

def main():
    if len(sys.argv) != 3:
        print("Usage: python upload.py <watch_directory> <server_url>")
        print("Example: python upload.py C:\\Photos http://localhost:8000")
        sys.exit(1)

    watch_dir = sys.argv[1]
    server_url = sys.argv[2]

    # Create watch directory if it doesn't exist
    Path(watch_dir).mkdir(parents=True, exist_ok=True)

    print(f"Watching {watch_dir} for new files...")
    print(f"Server URL: {server_url}")
    print("Drop files into the watch directory to upload them automatically")
    print("Press Ctrl+C to stop")

    event_handler = UploadHandler(server_url)
    observer = Observer()
    observer.schedule(event_handler, watch_dir, recursive=False)
    observer.start()

    try:
        while True:
            import time
            time.sleep(1)
    except KeyboardInterrupt:
        observer.stop()
    observer.join()

if __name__ == "__main__":
    main() 