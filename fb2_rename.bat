echo off
.\venv\Scripts\python.exe fb2tools.py --debug rename ^
  --file=%1% ^
  --outdir="{Al} {Af} {Am}" ^
  --template="{Al} {Af} {Am} - {Tt}" 
