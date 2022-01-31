import zlib


class ZipFB2:
    pass


class UnzipFB2:
    def unzip_file(self, filename: str):
        unpack = zlib.decompressobj()
        with open(filename, 'rb') as fpr, open('unpack-sample.txt', 'wb') as fpw:
            while True:
                # читаем частями по 32 байта
                block = fpr.read(32)
                if block:
                    # распаковываем
                    data = unpack.decompress(block)
                    # пишем данные ф текстовый файл
                    fpw.write(data)
                else:
                    break
