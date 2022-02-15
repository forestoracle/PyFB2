echo off
.\venv\Scripts\python.exe fb2tools.py --debug html ^
  --file=%1% ^
  --css=book.css ^
  --outdir="."
