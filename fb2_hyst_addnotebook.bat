:: Добавление новой записной книжки в БД Hyst
:: Русские названия должны быть записаны в кодовой странице 866
::
.\venv\Scripts\python.exe fb2tools.py --debug hyst --subaction=addnotebook ^
   --hystdb=Достоевский.hyst ^
   --notebook="Достоевский Ф. М."

.\venv\Scripts\python.exe fb2tools.py --debug hyst --subaction=addnotebook ^
   --hystdb=Достоевский.hyst ^
   --notebook="О Достоевском"

