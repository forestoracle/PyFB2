import xml.etree.ElementTree as ET
import os
from xml.etree.ElementTree import Element
import clargs


class FB2Parser:
    """FB2"""
    root: Element  # root element
    LastError: int  # last error code

    def __init__(self, filename):
        """ Class constructor """
        self.LastError = 0
        if os.path.isfile(filename):  #
            #
            self.LastError = 0  #
        else:
            self.LastError = 1  #
            exit(self.LastError)  #
        self.root = ET.parse(filename).getroot()
        self.cleanup()

    def cleanup(self):
        for element in self.root.iter():
                element.tag = element.tag.partition('}')[-1]

    @property
    def description(self):
        """Возвращает элемент description.
           От него отталкиваемся для получения разной информации о книге. """
        return self.root.find("./description")

    @property
    def author_first_name(self):
        """Имя автора."""
        first_name_el = self.description.find("./title-info/author/first-name")
        if first_name_el is None:
            return ""
        else:
            return first_name_el.text

    @property
    def author_last_name(self):
        """Фамилия автора."""
        last_name_el = self.description.find("./title-info/author/last-name")
        if last_name_el is None:
            return ""
        else:
            return last_name_el.text

    @property
    def author_middle_name(self):
        """Отчество автора."""
        middle_name_el = self.description.find("./title-info/author/middle-name")
        if middle_name_el is None:
            return ""
        else:
            return middle_name_el.text

    @property
    def author_home_page(self):
        """Домашняя страница автора."""
        home_page_el = self.description.find("./title-info/author/home-page")
        if home_page_el is None:
            return ""
        else:
            return home_page_el.text

    @property
    def title(self):
        """Заголовок книги."""
        return self.root.find("./description/title-info/book-title").text

if __name__ == '__main__':  #
    fb2 = FB2Parser('C:\projects\dev\python\FB2\gmn.fb2')
    if fb2.LastError == 0:
        print('File opened.')
    else:
        print('File not found!')
        exit(fb2.LastError)
    print(" Title: ", fb2.title)
    print("Author: ")
    print("  First name: ", fb2.author_first_name)
    print("   Last name: ", fb2.author_last_name)
    print(" Middle name: ", fb2.author_middle_name)
    print("   Home page: ", fb2.author_home_page)
    print(" ------------")