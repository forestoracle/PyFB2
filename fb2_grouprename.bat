echo off
.\venv\Scripts\python.exe fb2tools.py --debug grouprename ^
  --indir=%1    ^
  --outdir="" ^
  --template="{Al} {Af} {Am} - {Tt}" 
