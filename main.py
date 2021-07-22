import xml.etree.ElementTree as ET
import os
from xml.etree.ElementTree import Element
import clargs

class FB2Parser:
    """Разбор документа FB2"""
    root: Element                     # корневой элемент
    LastError: int                    # код последней ошибки
    def __init__(self, filename):
        """Конструктор"""
        self.LastError = 0
        if os.path.isfile(filename):  # если переданная строка - имя существующего файла
                                      # а что, если это линк?
            self.LastError = 0        #
        else:
            self.LastError = 1        # код последней ошибки 1 - файл не найден
            exit(self.LastError)      # выходим с ошибкой 1
        self.root = ET.parse(filename).getroot()

if __name__ == '__main__': # если файл был запущен напрямую, а не импортирован, то будет выполнен нижеследующий код
    fb2 = FB2Parser('C:\projects\dev\python\FB2\gmn.fb2')
    if fb2.LastError == 0:
        print('File opened.')
    else:
        print('File not found!')
        exit(fb2.LastError)
