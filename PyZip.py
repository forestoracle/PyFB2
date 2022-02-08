import os
import zipfile


class ZipFB2:
    def zip(self, filename: str):
        pass


class UnzipFB2:
    def __init__(self, startdir: str = '.', removezip: bool = False, debug: bool = False) -> object:
        self.startDir = startdir
        self.removezip = removezip
        self.debug = debug

    def unzipFile(self, filename: str):
        path = os.path.split(os.path.abspath(filename))[0]  # получить полный путь к файлу
        unzip = zipfile.ZipFile(filename)
        unzip.extractall(path = path)  # извлечь все файлы из архива
        unzip.close()
        if self.removezip:
            os.unlink(filename)  # удаление файла ZIP

    def unzipAll(self):
        for folderName, subfolders, filenames in os.walk(self.startDir):
            for filename in filenames:
                filename = os.path.join(folderName, filename)
                if zipfile.is_zipfile(filename):
                    print('  Unzip: {}'.format(filename))
                    self.unzipFile(filename = filename)
