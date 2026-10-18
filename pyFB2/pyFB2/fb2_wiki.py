# -*- coding: utf-8 -*-
"""Поиск статьи об авторе книги в Википедии и экспорт её в Markdown.

Модуль умеет:
    * брать имя автора из FB2-файла (через :class:`Fb2Parser`);
    * искать соответствующую статью в Википедии (MediaWiki API);
    * скачивать HTML статьи и преобразовывать его в Markdown.

Пример:
    >>> from fb2_wiki import WikipediaAuthor
    >>> wiki = WikipediaAuthor(lang="ru")
    >>> markdown = wiki.article_markdown("Лев Толстой")
    >>> wiki.save(markdown, "tolstoy.md")
    PosixPath('tolstoy.md')

CLI:
    python fb2_wiki.py <автор|файл.fb2> [--lang ru] [--out FILE] [--list]
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Dict, List, Optional, Union

import requests
from bs4 import BeautifulSoup
from markdownify import markdownify as html_to_md

from .fb2_errors import Fb2NetworkError, Fb2NotFoundError
from .fb2_parser import Fb2Parser
from .fb2_structures import Author

#: Википедия требует осмысленный User-Agent.
USER_AGENT = "FB2Wiki/1.0 (fb2 author to markdown; contact: local-user)"

#: Язык Википедии по умолчанию.
DEFAULT_LANG = "ru"

#: Таймаут HTTP-запросов (секунды).
DEFAULT_TIMEOUT = 30

#: Служебные элементы разметки Википедии, не несущие полезного текста.
DROP_SELECTORS = (
    "style",
    "script",
    ".mw-editsection",
    ".mw-empty-elt",
    ".navbox",
    ".navbox-styles",
    ".vertical-navbox",
    ".metadata",
    ".ambox",
    ".hatnote",
    ".noprint",
    ".toc",
    "#toc",
    ".mw-jump-link",
    ".mw-indicators",
    ".printfooter",
    ".catlinks",
    ".mw-references-columns ~ .mw-cite-backlink",
)


def format_author(author: Author) -> str:
    """Собрать имя автора из полей authorType.

    Приоритет: ``first-name middle-name last-name``; при их отсутствии —
    ``nickname``.

    :param author: структура :class:`Author`.
    :return: имя автора ("" если данных нет).
    """
    parts = [author.first_name, author.middle_name, author.last_name]
    name = " ".join(p.strip() for p in parts if p and p.strip())
    if name:
        return name
    return (author.nickname or "").strip()


class WikipediaAuthor:
    """Клиент Википедии: поиск статьи об авторе и экспорт в Markdown.

    :param lang: код языка Википедии (``ru``, ``en`` и т. п.).
    :param timeout: таймаут HTTP-запросов в секундах.
    """

    def __init__(self, lang: str = DEFAULT_LANG, timeout: int = DEFAULT_TIMEOUT) -> None:
        self.lang = lang
        self.timeout = timeout
        self.base_url = f"https://{lang}.wikipedia.org"
        self.api_url = f"{self.base_url}/w/api.php"
        self.session = requests.Session()
        self.session.headers.update({"User-Agent": USER_AGENT})

    # --- Низкоуровневые запросы -------------------------------------------
    def _api(self, params: Dict[str, Union[str, int]]) -> dict:
        """Выполнить запрос к MediaWiki API и вернуть JSON.

        :param params: параметры запроса (``action`` и т. д.).
        :raises RuntimeError: при сетевой ошибке или некорректном ответе.
        """
        query: Dict[str, Union[str, int]] = {"format": "json", "formatversion": 2}
        query.update(params)
        try:
            response = self.session.get(
                self.api_url, params=query, timeout=self.timeout
            )
            response.raise_for_status()
            return response.json()
        except requests.RequestException as exc:
            raise Fb2NetworkError(f"Ошибка запроса к Википедии: {exc}") from exc

    def search(self, query: str, limit: int = 10) -> List[str]:
        """Найти названия статей по запросу.

        :param query: поисковый запрос (имя автора).
        :param limit: максимальное число результатов.
        :return: список названий статей (может быть пустым).
        """
        data = self._api(
            {
                "action": "query",
                "list": "search",
                "srsearch": query,
                "srlimit": limit,
            }
        )
        return [item["title"] for item in data.get("query", {}).get("search", [])]

    def page_html(self, title: str) -> Optional[str]:
        """Получить HTML-содержимое статьи.

        :param title: точное название статьи.
        :return: HTML-фрагмент статьи или None, если статьи нет.
        """
        data = self._api(
            {
                "action": "parse",
                "page": title,
                "prop": "text",
                "redirects": 1,
            }
        )
        if "error" in data:
            return None
        return data.get("parse", {}).get("text")

    def page_url(self, title: str) -> str:
        """Канонический URL статьи (для указания источника)."""
        return f"{self.base_url}/wiki/{title.replace(' ', '_')}"

    # --- Преобразование HTML -> Markdown ----------------------------------
    def _absolutize(self, soup: BeautifulSoup) -> None:
        """Сделать ссылки и картинки абсолютными URL.

        Википедия в HTML отдаёт ссылки вида ``/wiki/...`` и ``//upload...``;
        без преобразования они не работают вне сайта.

        :param soup: разобранный документ (изменяется на месте).
        """
        for tag in soup.find_all(href=True):
            href = str(tag["href"])
            if href.startswith("//"):
                tag["href"] = "https:" + href
            elif href.startswith("/"):
                tag["href"] = self.base_url + href
        for tag in soup.find_all(src=True):
            src = str(tag["src"])
            if src.startswith("//"):
                tag["src"] = "https:" + src
            elif src.startswith("/"):
                tag["src"] = self.base_url + src

    def clean_html(self, html: str) -> str:
        """Удалить служебные элементы и сделать URL абсолютными.

        :param html: исходный HTML статьи.
        :return: очищенный HTML.
        """
        soup = BeautifulSoup(html, "lxml")
        for selector in DROP_SELECTORS:
            for element in soup.select(selector):
                element.decompose()
        self._absolutize(soup)
        return str(soup)

    @staticmethod
    def html_to_markdown(html: str) -> str:
        """Преобразовать HTML статьи в Markdown.

        :param html: HTML статьи.
        :return: Markdown-текст.
        """
        markdown = html_to_md(
            html,
            heading_style="ATX",
            bullets="-",
            strip=["script", "style"],
        )
        return WikipediaAuthor._tidy(markdown)

    @staticmethod
    def _tidy(markdown: str) -> str:
        """Убрать лишние пробелы и пустые строки в Markdown."""
        lines = [line.rstrip() for line in markdown.splitlines()]
        out: List[str] = []
        blank = 0
        for line in lines:
            if line:
                blank = 0
            else:
                blank += 1
                if blank > 1:
                    continue
            out.append(line)
        while out and not out[0].strip():
            out.pop(0)
        while out and not out[-1].strip():
            out.pop()
        return "\n".join(out)

    # --- Высокоуровневый API ----------------------------------------------
    def article_markdown(self, title: str, with_source: bool = True) -> str:
        """Получить Markdown статьи по её названию.

        :param title: название статьи в Википедии.
        :param with_source: добавлять ли ссылку на источник и заголовок.
        :return: Markdown-текст статьи.
        :raises RuntimeError: если статья не найдена.
        """
        html = self.page_html(title)
        if not html:
            raise Fb2NotFoundError(f"Статья не найдена: {title}")

        body = self.html_to_markdown(self.clean_html(html))
        if not with_source:
            return body + "\n"

        header = [f"# {title}", "", f"Источник: {self.page_url(title)}", ""]
        return "\n".join(header) + body + "\n"

    def author_markdown(self, author_name: str) -> str:
        """Найти статью об авторе и вернуть её Markdown.

        Берётся первый результат поиска по имени автора.

        :param author_name: имя автора.
        :return: Markdown-текст статьи.
        :raises RuntimeError: если ничего не найдено.
        """
        candidates = self.search(author_name)
        if not candidates:
            raise Fb2NotFoundError(f"В Википедии ничего не найдено: {author_name}")
        return self.article_markdown(candidates[0])

    @staticmethod
    def save(markdown: str, path: Union[str, Path], encoding: str = "utf-8") -> Path:
        """Сохранить Markdown в файл.

        :param markdown: текст статьи.
        :param path: путь к файлу.
        :param encoding: кодировка файла.
        :return: путь к записанному файлу.
        """
        target = Path(path)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(markdown, encoding=encoding)
        return target

    @staticmethod
    def author_from_fb2(path: Union[str, Path]) -> str:
        """Извлечь имя автора из FB2-файла.

        :param path: путь к FB2-файлу.
        :return: имя первого автора.
        :raises RuntimeError: если автор не указан.
        """
        description = Fb2Parser(source=str(path)).parse()
        title_info = description.title_info
        if title_info is not None:
            for author in title_info.authors:
                name = format_author(author)
                if name:
                    return name
        raise Fb2NotFoundError(f"В файле не найден автор: {path}")


def _safe_filename(name: str) -> str:
    """Преобразовать имя в безопасное имя файла."""
    cleaned = re.sub(r'[\\/:*?"<>|]', "", name).strip()
    cleaned = re.sub(r"\s+", "_", cleaned)
    return cleaned or "article"


def main(argv: Optional[List[str]] = None) -> int:
    """Точка входа CLI.

    :param argv: аргументы командной строки (по умолчанию ``sys.argv[1:]``).
    :return: код возврата.
    """
    parser = argparse.ArgumentParser(
        description="Найти статью об авторе книги в Википедии и сохранить в Markdown.",
    )
    parser.add_argument(
        "source",
        help="имя автора или путь к FB2-файлу (тогда автор берётся из книги)",
    )
    parser.add_argument("--lang", default=DEFAULT_LANG, help="код языка Википедии")
    parser.add_argument("--out", default=None, help="файл для сохранения Markdown")
    parser.add_argument(
        "--list",
        action="store_true",
        help="только показать найденные статьи, без сохранения",
    )
    parser.add_argument(
        "--title",
        default=None,
        help="точное название статьи (пропустить поиск)",
    )
    args = parser.parse_args(argv)

    wiki = WikipediaAuthor(lang=args.lang)

    # Определяем имя автора: из FB2-файла или из аргумента.
    source_path = Path(args.source)
    if source_path.is_file() and source_path.suffix.lower() == ".fb2":
        try:
            author_name = wiki.author_from_fb2(source_path)
        except (RuntimeError, ValueError) as exc:
            print(f"Ошибка: {exc}", file=sys.stderr)
            return 1
        print(f"Автор книги: {author_name}")
    else:
        author_name = args.source

    if args.list:
        candidates = wiki.search(author_name)
        if not candidates:
            print("Ничего не найдено.", file=sys.stderr)
            return 1
        for candidate in candidates:
            print(candidate)
        return 0

    try:
        if args.title:
            markdown = wiki.article_markdown(args.title)
            used_title = args.title
        else:
            candidates = wiki.search(author_name)
            if not candidates:
                print(f"Ничего не найдено: {author_name}", file=sys.stderr)
                return 1
            used_title = candidates[0]
            markdown = wiki.article_markdown(used_title)
    except RuntimeError as exc:
        print(f"Ошибка: {exc}", file=sys.stderr)
        return 1

    out_path = args.out or f"{_safe_filename(used_title)}.md"
    saved = wiki.save(markdown, out_path)
    print(f"Статья: {used_title}")
    print(f"Сохранено: {saved}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())