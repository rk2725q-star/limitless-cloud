@echo off
echo ========================================
echo  Limitless Cloud - Backend Server
echo ========================================
echo.
echo Installing Python dependencies...
pip install -r requirements.txt
echo.
echo Starting server on http://localhost:8000
echo Press Ctrl+C to stop.
echo.
python main.py
