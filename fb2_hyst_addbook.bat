:: Добавление новой книги в БД Hyst
:: Русские названия должны быть записаны в кодовой странице 866
::
.\venv\Scripts\python.exe fb2tools.py --debug hyst --subaction=addbook ^
   --hystdb="C:\projects\dev\FreePascal\Hyst\data\Достоевский.hyst"  ^
   --notebook="Достоевский Ф. М." ^
   --file="Z:\Книги\Художественная литература\Достоевский Федор Михайлович\Двойник.fb2" 
   > addbook.log


