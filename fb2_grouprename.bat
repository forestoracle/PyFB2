echo off
.\venv\Scripts\python.exe fb2tools.py --debug grouprename ^
  --indir="C:\temp\books\corpus"  ^
  --outdir="{Al} {Af} {Am}" ^
  --template="{Al} {Af} {Am} - {Tt}" 
