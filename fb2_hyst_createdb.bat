:: Создание новой БД Hyst
:: Русские названия должны быть записаны в кодовой странице 866
::
set DBNAME=Достоевский
.\venv\Scripts\python.exe fb2tools.py --debug hyst --subaction=createdb --hystdb=%DBNAME%.hyst