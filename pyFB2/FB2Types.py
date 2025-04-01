class Author:
    def __init__(self, firstname: str, middlename: str, lastname: str, nickname: str, homepage: str, email: str):
        self.firstName = firstname
        self.middleName = middlename
        self.lastName = lastname
        self.nickName = nickname
        self.homePage = homepage
        self.email = email

    def __dict__(self):
        return {
            "firstName": self.firstName,
            "middleName": self.middleName,
            "lastName": self.lastName,
            "nickName": self.nickName,
            "homePage": self.homePage,
            "email": self.email
        }


class Authors:
    """Список авторов"""

    def __init__(self):
        """
        Конструктор класса
        """
        self.authors = list[Author]

    def append(self, author: Author):
        """
        Добавление автора в список авторов
        :param author: Добавляемый автор
        :type author: Author
        """
        self.authors.append(author)

    def __dict__(self):
        d = []
        for n in list(self.authors):
            d.append(n.__dict__())
        return d

class DocumentInfo:
    def __init__(self, author: str = None, program_used: str = None, date: str = None, src_url: str = None,
                 src_ocr: str = None, id: str = None, version: str = None, history: str = None, publisher: str = None):
        self.author = author
        self.program_used = program_used
        self.date = date
        self.src_url = src_url
        self.src_ocr = src_ocr
        self.id = id
        self.version = version
        self.history = history
        self.publisher = publisher

    def __dict__(self):
        return {"author": self.author,
                "program-used": self.program_used,
                "date": self.date,
                "src-url": self.src_url,
                "src-ocr": self.src_ocr,
                "id": self.id,
                "version": self.version,
                "history": self.history,
                "publisher": self.publisher}

class PublishInfo:
    pass