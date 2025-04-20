from fastapi import FastAPI, UploadFile, File
from fastapi.responses import JSONResponse, FileResponse
import uvicorn
import os
import shutil
from datetime import datetime
from typing import List

app = FastAPI(title="Pixel Backup Server")

# Directory to store uploaded files
UPLOAD_DIR = "uploads"
os.makedirs(UPLOAD_DIR, exist_ok=True)

class FileManager:
    def __init__(self):
        self.files = {}  # timestamp -> filename

    def add_file(self, filename: str):
        self.files[datetime.now().timestamp()] = filename

    def get_new_files(self, since_timestamp: float) -> List[str]:
        return [
            filename
            for ts, filename in self.files.items()
            if ts > since_timestamp
        ]

file_manager = FileManager()

@app.post("/upload/")
async def upload_file(file: UploadFile = File(...)):
    try:
        file_path = os.path.join(UPLOAD_DIR, file.filename)
        with open(file_path, "wb") as buffer:
            shutil.copyfileobj(file.file, buffer)
        file_manager.add_file(file.filename)
        return {"filename": file.filename, "status": "success"}
    except Exception as e:
        return JSONResponse(
            status_code=500,
            content={"message": f"Failed to upload file: {str(e)}"}
        )

@app.get("/check_new_files/{since_timestamp}")
async def check_new_files(since_timestamp: float):
    new_files = file_manager.get_new_files(since_timestamp)
    return {"new_files": new_files}

@app.get("/download/{filename}")
async def download_file(filename: str):
    file_path = os.path.join(UPLOAD_DIR, filename)
    if os.path.exists(file_path):
        return FileResponse(file_path)
    return JSONResponse(
        status_code=404,
        content={"message": "File not found"}
    )

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000) 