# -*- coding: utf-8 -*-
"""Скачивание обложек и аннотаций книг и их встраивание в FB2.

Модуль — сетевой «сосед» :mod:`fb2_wiki`. Он ищет книгу в открытых
каталогах, скачивает обложку и аннотацию и записывает их прямо в
FB2-файл (``<coverpage>`` + ``<binary>`` и ``<annotation>``).

Источники (без API-ключей):

    * **Open Library** — ``search.json``, обложки ``covers.openlibrary.org``,
      описание work;
    * **Google Books** — ``books/v1/volumes`` (обложка + описание);
    * **FantLab** — ``api.fantlab.ru`` (библиография фантастики; аннотация и
      обложка из ``/work/{id}``).

Внешних зависимостей нет — используется только стандартная библиотека
(``urllib``), поэтому модуль доступен сразу после установки пакета.

Пример::

    >>> from fb2_web_metadata import Fb2MetadataFetcher
    >>> fetcher = Fb2MetadataFetcher()
    >>> matches = fetcher.search("Война и мир", author="Лев Толстой")
    >>> metadata = fetcher.enrich(matches[0])          # обложка + аннотация
    >>> fetcher.apply("book.fb2", metadata, output="book.fixed.fb2")
    WindowsPath('book.fixed.fb2')

    # Одной командой: взять метаданные книги из FB2, найти и встроить.
    >>> fetcher.apply("book.fb2")

CLI::

    python fb2_web_metadata.py book.fb2 [--list] [--out FILE]
        [--no-cover] [--no-annotation] [--provider openlibrary] [--dry-run]
"""

from __future__ import annotations

import argparse
import base64
import json
import logging
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from datetime import date
from html import unescape as html_unescape
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple, Union

from .fb2_errors import Fb2NetworkError, Fb2NotFoundError
from .fb2_images import detect_image_type
from .fb2_normalizer import ELEMENT_ORDER
from .fb2_parser import Fb2Parser
from .fb2_structures import NS_XLINK
from .fb2_xml import parse_xml

logger = logging.getLogger(__name__)

#: User-Agent: Open Library и Google Books требуют осмысленное значение.
USER_AGENT = "pyFB2-metadata-fetcher/0.1 (+https://github.com/example/pyFB2)"

#: Таймаут HTTP-запросов (секунды).
DEFAULT_TIMEOUT = 30

#: Провайдеры по умолчанию (порядок = приоритет).
DEFAULT_PROVIDERS = ("openlibrary", "google", "fantlab")

#: Адрес поиска Open Library.
OPENLIBRARY_SEARCH_URL = "https://openlibrary.org/search.json"

#: Адрес описания work в Open Library (``{key}`` — ключ вида ``/works/OL123W``).
OPENLIBRARY_WORK_URL = "https://openlibrary.org{key}.json"

#: Адрес обложки Open Library (``{cover_id}`` — числовой идентификатор).
OPENLIBRARY_COVER_URL = "https://covers.openlibrary.org/b/id/{cover_id}-L.jpg"

#: Адрес Google Books API.
GOOGLE_BOOKS_URL = "https://www.googleapis.com/books/v1/volumes"

#: Адрес поиска произведений FantLab (``q`` — поисковая фраза).
#: Ключ API не требуется; ``onlymatches=1`` возвращает сразу список карточек.
FANTLAB_SEARCH_URL = "https://api.fantlab.ru/search-works"

#: Адрес произведения FantLab (``{work_id}`` — идентификатор произведения).
FANTLAB_WORK_URL = "https://api.fantlab.ru/work/{work_id}"

#: Базовый адрес сайта FantLab (для относительных ссылок на обложки).
FANTLAB_BASE_URL = "https://fantlab.ru/"

#: Все известные провайдеры метаданных.
KNOWN_PROVIDERS = ("openlibrary", "google", "fantlab")

#: Идентификатор обложки по умолчанию (когда не удалось определить иначе).
DEFAULT_COVER_ID = "cover"

#: Коды возврата CLI.
EXIT_OK = 0
EXIT_ERRORS = 1
EXIT_USAGE = 2


def absolute_image_url(url: str, base: str = FANTLAB_BASE_URL) -> str:
    """Привести ссылку на картинку к абсолютному виду.

    FantLab отдаёт ссылки «обычно без протокола» (``//fantlab.ru/...`` или
    ``/images/...``), поэтому их нужно дополнить.

    :param url: исходная ссылка.
    :param base: базовый адрес сайта для относительных ссылок.
    :return: абсолютный URL (пустая строка, если ссылки не было).
    """
    url = (url or "").strip()
    if not url:
        return ""
    if url.startswith("//"):
        return "https:" + url
    if url.startswith(("http://", "https://")):
        return url
    return base + url.lstrip("/")


def strip_html(text: str) -> str:
    """Убрать HTML-теги и раскрыть сущности (для описаний из веба)."""
    without_tags = re.sub(r"<[^>]+>", " ", text or "")
    unescaped = html_unescape(without_tags)
    return re.sub(r"\s+", " ", unescaped).strip()


def split_paragraphs(text: str) -> List[str]:
    """Разбить текст на абзацы (по пустым строкам или переводам строк)."""
    cleaned = (text or "").replace("\r\n", "\n").replace("\r", "\n").strip()
    if not cleaned:
        return []
    blocks = re.split(r"\n\s*\n", cleaned)
    if len(blocks) == 1:
        blocks = cleaned.split("\n")
    return [block.strip() for block in blocks if block.strip()]


@dataclass
class BookMetadata:
    """Найденные сведения о книге.

    :param title: название.
    :param authors: авторы.
    :param provider: источник (``openlibrary`` / ``google``).
    :param identifier: идентификатор записи у провайдера.
    :param year: год издания.
    :param language: язык (код или название).
    :param isbn: ISBN (если есть).
    :param cover_url: ссылка на обложку.
    :param cover_data: скачанные байты обложки (после :meth:`enrich`).
    :param annotation: аннотация (после :meth:`enrich`).
    """

    title: str = ""
    authors: List[str] = field(default_factory=list)
    provider: str = ""
    identifier: str = ""
    year: str = ""
    language: str = ""
    isbn: str = ""
    cover_url: Optional[str] = None
    cover_data: Optional[bytes] = None
    annotation: Optional[str] = None

    def __str__(self) -> str:
        authors = ", ".join(self.authors) or "—"
        year = f", {self.year}" if self.year else ""
        return f"{self.title} — {authors} [{self.provider}{year}]"


class Fb2MetadataFetcher:
    """Поиск обложек и аннотаций в открытых каталогах и запись их в FB2.

    :param providers: источники в порядке приоритета (``openlibrary``, ``google``).
    :param timeout: таймаут HTTP-запросов в секундах.
    :param language: предпочтительный язык книги (для Google Books).
    :param user_agent: значение заголовка ``User-Agent``.
    """

    def __init__(
        self,
        providers: Sequence[str] = DEFAULT_PROVIDERS,
        timeout: int = DEFAULT_TIMEOUT,
        language: str = "ru",
        user_agent: str = USER_AGENT,
    ) -> None:
        unknown = [
            name for name in providers if name not in KNOWN_PROVIDERS
        ]
        if unknown:
            raise ValueError(f"Неизвестный провайдер: {', '.join(unknown)}")
        self.providers = tuple(providers) or DEFAULT_PROVIDERS
        self.timeout = timeout
        self.language = language
        self.user_agent = user_agent

    # --- HTTP -------------------------------------------------------------
    def _request(self, url: str, params: Optional[Dict[str, str]] = None) -> bytes:
        """Выполнить GET-запрос и вернуть тело ответа.

        :param url: адрес запроса.
        :param params: параметры строки запроса.
        :raises RuntimeError: при сетевой ошибке или HTTP-ошибке.
        """
        if params:
            url = f"{url}?{urllib.parse.urlencode(params)}"
        request = urllib.request.Request(url, headers={"User-Agent": self.user_agent})
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                return response.read()
        except urllib.error.HTTPError as exc:
            raise Fb2NetworkError(f"HTTP {exc.code} для {url}") from exc
        except (urllib.error.URLError, OSError) as exc:
            raise Fb2NetworkError(f"Ошибка сети: {exc}") from exc

    def _get_json(self, url: str, params: Optional[Dict[str, str]] = None) -> dict:
        """GET-запрос, возвращающий JSON.

        :raises RuntimeError: при сетевой ошибке или некорректном JSON.
        """
        raw = self._request(url, params)
        try:
            return json.loads(raw.decode("utf-8", "replace"))
        except json.JSONDecodeError as exc:
            raise Fb2NetworkError(f"Некорректный JSON от {url}: {exc}") from exc

    def _get_bytes(self, url: str) -> Optional[bytes]:
        """GET-запрос изображения (None, если скачать не удалось)."""
        try:
            return self._request(url)
        except RuntimeError:
            return None

    # --- Поиск ------------------------------------------------------------
    def search(
        self, title: str, author: Optional[str] = None, limit: int = 5
    ) -> List[BookMetadata]:
        """Найти книгу во всех настроенных источниках.

        :param title: название книги.
        :param author: автор (необязательно).
        :param limit: максимум результатов на источник.
        :return: список совпадений в порядке провайдеров.
        """
        results: List[BookMetadata] = []
        for provider in self.providers:
            try:
                if provider == "openlibrary":
                    results.extend(self._search_openlibrary(title, author, limit))
                elif provider == "google":
                    results.extend(self._search_google(title, author, limit))
                elif provider == "fantlab":
                    results.extend(self._search_fantlab(title, author, limit))
            except RuntimeError as exc:
                logger.warning("провайдер %s недоступен: %s", provider, exc)
        return results

    def _search_openlibrary(
        self, title: str, author: Optional[str], limit: int
    ) -> List[BookMetadata]:
        """Поиск в Open Library."""
        params = {"title": title, "limit": str(limit)}
        if author:
            params["author"] = author
        data = self._get_json(OPENLIBRARY_SEARCH_URL, params)

        results: List[BookMetadata] = []
        for doc in data.get("docs", [])[:limit]:
            cover_id = doc.get("cover_i")
            cover_url = (
                OPENLIBRARY_COVER_URL.format(cover_id=cover_id) if cover_id else None
            )
            isbns = doc.get("isbn") or []
            languages = doc.get("language") or []
            results.append(
                BookMetadata(
                    title=doc.get("title", "") or "",
                    authors=list(doc.get("author_name") or []),
                    provider="openlibrary",
                    identifier=doc.get("key", "") or "",
                    year=str(doc.get("first_publish_year") or ""),
                    language=languages[0] if languages else "",
                    isbn=isbns[0] if isbns else "",
                    cover_url=cover_url,
                )
            )
        return results

    def _search_google(
        self, title: str, author: Optional[str], limit: int
    ) -> List[BookMetadata]:
        """Поиск в Google Books."""
        query = f'intitle:"{title}"'
        if author:
            query += f' inauthor:"{author}"'
        params = {"q": query, "maxResults": str(limit)}
        if self.language:
            params["langRestrict"] = self.language
        data = self._get_json(GOOGLE_BOOKS_URL, params)

        results: List[BookMetadata] = []
        for item in (data.get("items") or [])[:limit]:
            info = item.get("volumeInfo", {})
            links = info.get("imageLinks") or {}
            cover_url = links.get("thumbnail") or links.get("smallThumbnail")
            if cover_url:
                cover_url = cover_url.replace("http://", "https://")

            isbn = ""
            for identifier in info.get("industryIdentifiers") or []:
                if identifier.get("type") in ("ISBN_13", "ISBN_10"):
                    isbn = identifier.get("identifier", "")
                    break

            description = info.get("description")
            results.append(
                BookMetadata(
                    title=info.get("title", "") or "",
                    authors=list(info.get("authors") or []),
                    provider="google",
                    identifier=item.get("id", "") or "",
                    year=(info.get("publishedDate") or "")[:4],
                    language=info.get("language", "") or "",
                    isbn=isbn,
                    cover_url=cover_url,
                    annotation=strip_html(description) if description else None,
                )
            )
        return results

    def _search_fantlab(
        self, title: str, author: Optional[str], limit: int
    ) -> List[BookMetadata]:
        """Поиск в FantLab (библиография фантастики; ключ API не нужен).

        Используется ``search-works`` с ``onlymatches=1``: ответ — список
        мини-карточек произведений. Аннотация и обложка подтягиваются позже,
        в :meth:`enrich`, через ``/work/{id}``.

        :param title: название книги.
        :param author: автор (необязательно; используется для фильтрации).
        :param limit: максимум результатов.
        :return: список совпадений.
        """
        query = f"{author} {title}".strip() if author else title
        data = self._get_json(
            FANTLAB_SEARCH_URL, {"q": query, "onlymatches": "1"}
        )

        if isinstance(data, list):
            items = data
        else:
            items = list(data.get("matches") or [])

        matched = [
            meta
            for item in items
            if self._fantlab_matches_author(item, author)
            for meta in [self._fantlab_meta(item)]
            if meta is not None
        ]
        if not matched and author:
            # Фильтр по автору мог отсечь всё — показываем сырые результаты.
            matched = [
                meta
                for item in items
                for meta in [self._fantlab_meta(item)]
                if meta is not None
            ]
        return matched[:limit]

    @staticmethod
    def _fantlab_meta(item: dict) -> Optional[BookMetadata]:
        """Преобразовать мини-карточку FantLab в :class:`BookMetadata`."""
        work_id = item.get("work_id")
        if not work_id:
            return None
        name = (item.get("rusname") or item.get("name") or "").strip()
        author_name = (
            item.get("all_autor_rusname") or item.get("autor_rusname") or ""
        ).strip()
        year = item.get("year")
        return BookMetadata(
            title=name,
            authors=[author_name] if author_name else [],
            provider="fantlab",
            identifier=str(work_id),
            year=str(year) if year else "",
            language="",
        )

    @staticmethod
    def _fantlab_matches_author(item: dict, author: Optional[str]) -> bool:
        """Проверить, что карточка FantLab относится к нужному автору.

        Сравнение идёт по значимым словам имени (длиной от 3 символов),
        чтобы инициалы и служебные слова не мешали.
        """
        if not author:
            return True
        haystack = " ".join(
            str(item.get(key) or "")
            for key in ("all_autor_rusname", "all_autor_name", "autor_rusname")
        ).casefold()
        words = [word for word in re.split(r"[^\w]+", author.casefold()) if len(word) >= 3]
        if not words:
            return True
        return any(word in haystack for word in words)

    def _fantlab_details(self, work_id: str) -> Optional[dict]:
        """Сведения о произведении FantLab (``/work/{id}``).

        :param work_id: идентификатор произведения.
        :return: словарь с полями ``description``/``image``/``year``/``title``
            или None при ошибке.
        """
        try:
            data = self._get_json(FANTLAB_WORK_URL.format(work_id=work_id))
        except RuntimeError:
            return None
        if not isinstance(data, dict):
            return None

        description = data.get("work_description")
        image = data.get("image") or data.get("image_preview")
        authors = [
            entry.get("name")
            for entry in (data.get("authors") or [])
            if isinstance(entry, dict) and entry.get("name")
        ]
        return {
            "title": str(data.get("work_name") or ""),
            "description": strip_html(str(description)) if description else None,
            "image": absolute_image_url(str(image)) if image else None,
            "year": str(data["work_year"]) if data.get("work_year") else "",
            "authors": authors,
        }


    # --- Обогащение (скачивание обложки/аннотации) ------------------------
    def enrich(self, meta: BookMetadata) -> BookMetadata:
        """Дополнить сведения: скачать обложку и аннотацию.

        :param meta: результат :meth:`search` (или созданный вручную).
        :return: тот же объект с заполненными ``cover_data``/``annotation``.
        """
        if meta.provider == "fantlab" and meta.identifier:
            details = self._fantlab_details(meta.identifier)
            if details:
                if details["description"] and not meta.annotation:
                    meta.annotation = details["description"]
                if details["image"] and not meta.cover_url:
                    meta.cover_url = details["image"]
                if not meta.title:
                    meta.title = details["title"]
                if not meta.year:
                    meta.year = details["year"]
                if not meta.authors:
                    meta.authors = details["authors"]

        if meta.cover_data is None and meta.cover_url:
            data = self._get_bytes(meta.cover_url)
            if data:
                meta.cover_data = data

        if not meta.annotation and meta.provider == "openlibrary" and meta.identifier:
            meta.annotation = self._openlibrary_annotation(meta.identifier)
        return meta

    def _openlibrary_annotation(self, key: str) -> Optional[str]:
        """Описание книги из Open Library (``/works/OL...W.json``)."""
        try:
            data = self._get_json(OPENLIBRARY_WORK_URL.format(key=key))
        except RuntimeError:
            return None
        description = data.get("description")
        if isinstance(description, dict):
            description = description.get("value")
        if not description:
            return None
        return strip_html(description)

    def fetch(
        self, title: str, author: Optional[str] = None, limit: int = 5
    ) -> Optional[BookMetadata]:
        """Найти книгу и сразу скачать обложку и аннотацию.

        :return: лучший результат (первый найденный) или None.
        """
        matches = self.search(title, author, limit=limit)
        if not matches:
            return None
        return self.enrich(matches[0])

    def fetch_from_fb2(self, path, limit: int = 5) -> Optional[BookMetadata]:
        """Определить название и автора из FB2 и найти книгу."""
        title, author = self.book_query(path)
        if not title:
            raise Fb2NotFoundError(f"В файле не найдено название книги: {path}")
        return self.fetch(title, author, limit=limit)

    @staticmethod
    def book_query(path) -> Tuple[str, Optional[str]]:
        """Извлечь название книги и имя автора из FB2."""
        description = Fb2Parser(source=path).parse()
        title_info = description.title_info
        if title_info is None:
            return "", None

        title = title_info.book_title.value if title_info.book_title else ""
        author = ""
        for item in title_info.authors:
            parts = [item.first_name, item.middle_name, item.last_name]
            author = " ".join(part for part in parts if part) or (item.nickname or "")
            if author:
                break
        return title or "", author or None

    def save_cover(self, meta: BookMetadata, path: Union[str, Path]) -> Path:
        """Сохранить обложку в отдельный файл.

        :param meta: сведения с заполненным ``cover_data``.
        :param path: файл назначения или каталог.
        :raises RuntimeError: если обложка не скачана.
        """
        if not meta.cover_data:
            raise Fb2NotFoundError("Обложка не скачана (вызовите enrich)")
        target = Path(path)
        if target.is_dir() or not target.suffix:
            _, extension = detect_image_type(meta.cover_data)
            target = target / f"{DEFAULT_COVER_ID}{extension}"
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(meta.cover_data)
        return target

    # --- Запись в FB2 -----------------------------------------------------
    def apply(
        self,
        path: Union[str, Path],
        meta: Optional[BookMetadata] = None,
        output: Optional[Union[str, Path]] = None,
        set_cover: bool = True,
        set_annotation: bool = True,
        update_version: bool = True,
        dry_run: bool = False,
    ) -> Path:
        """Встроить обложку и/или аннотацию в FB2-файл.

        :param path: исходный FB2.
        :param meta: готовые сведения; если None — ищутся в вебе по названию
            и автору книги.
        :param output: файл результата (по умолчанию — перезапись исходного).
        :param set_cover: записывать обложку.
        :param set_annotation: записывать аннотацию.
        :param update_version: увеличить ``<version>`` и обновить ``<date>``.
        :param dry_run: не записывать файл.
        :raises RuntimeError: если сведения не найдены или записывать нечего.
        """
        source = Path(path)
        if meta is None:
            meta = self.fetch_from_fb2(source)
            if meta is None:
                raise Fb2NotFoundError("Книга не найдена в открытых каталогах")

        root = parse_xml(source)
        namespace = self._namespace(root)
        applied: List[str] = []

        if set_cover and meta.cover_data:
            cover_id = self._apply_cover(root, namespace, meta.cover_data)
            applied.append(f"обложка #{cover_id}")
        if set_annotation and meta.annotation:
            if self._apply_annotation(root, namespace, meta.annotation):
                applied.append("аннотация")
        if update_version:
            self._bump_version(root, namespace)

        if not applied:
            raise Fb2NotFoundError("Нечего записывать: нет ни обложки, ни аннотации")

        target = Path(output) if output else source
        if not dry_run:
            ET.indent(root, space="  ")
            xml = (
                '<?xml version="1.0" encoding="utf-8"?>\n'
                + ET.tostring(root, encoding="unicode")
            )
            target.write_text(xml, encoding="utf-8")
        return target

    # --- Вспомогательные методы для XML -----------------------------------
    @staticmethod
    def _namespace(root: ET.Element) -> str:
        """URI пространства имён корневого элемента ("" — нет)."""
        tag = root.tag
        if isinstance(tag, str) and tag.startswith("{"):
            return tag[1:].split("}", 1)[0]
        return ""

    @staticmethod
    def _q(namespace: str, name: str) -> str:
        """Полное имя элемента с учётом пространства имён."""
        return f"{{{namespace}}}{name}" if namespace else name

    def _find(self, parent: Optional[ET.Element], namespace: str, name: str):
        """Первый дочерний элемент с указанным локальным именем."""
        if parent is None:
            return None
        return parent.find(self._q(namespace, name))

    @staticmethod
    def _insert_ordered(
        parent: ET.Element, child: ET.Element, parent_name: str
    ) -> None:
        """Вставить элемент в позицию, соответствующую порядку по XSD."""
        order = ELEMENT_ORDER.get(parent_name)
        if not order:
            parent.append(child)
            return

        def localname(element) -> str:
            tag = element.tag
            return tag.rsplit("}", 1)[-1] if isinstance(tag, str) else ""

        index = {name: position for position, name in enumerate(order)}
        child_key = index.get(localname(child), len(order))
        position = len(parent)
        for offset, element in enumerate(parent):
            if index.get(localname(element), len(order)) > child_key:
                position = offset
                break
        parent.insert(position, child)

    def _apply_cover(self, root: ET.Element, namespace: str, data: bytes) -> str:
        """Добавить ``<binary>`` с обложкой и ``<coverpage>`` в ``<title-info>``."""
        content_type, extension = detect_image_type(data)
        description = self._find(root, namespace, "description")
        if description is None:
            raise Fb2NotFoundError("В документе нет <description>")
        title_info = self._find(description, namespace, "title-info")
        if title_info is None:
            raise Fb2NotFoundError("В документе нет <title-info>")

        existing = {
            element.get("id")
            for element in root.iter(self._q(namespace, "binary"))
        }
        cover_id = f"{DEFAULT_COVER_ID}{extension}"
        counter = 2
        while cover_id in existing:
            cover_id = f"{DEFAULT_COVER_ID}{counter}{extension}"
            counter += 1

        # Старая <coverpage> (если была) заменяется, а её <binary> может
        # стать ненужным — соберём ссылки, чтобы затем почистить.
        old_hrefs: List[str] = []
        existing_coverpage = self._find(title_info, namespace, "coverpage")
        if existing_coverpage is not None:
            for element in existing_coverpage.iter(self._q(namespace, "image")):
                old_hrefs.append(element.get(f"{{{NS_XLINK}}}href") or "")
            title_info.remove(existing_coverpage)

        binary = ET.SubElement(root, self._q(namespace, "binary"))
        binary.set("id", cover_id)
        binary.set("content-type", content_type)
        binary.text = "\n" + base64.b64encode(data).decode("ascii") + "\n"

        coverpage = ET.Element(self._q(namespace, "coverpage"))
        image = ET.SubElement(coverpage, self._q(namespace, "image"))
        image.set(f"{{{NS_XLINK}}}href", f"#{cover_id}")
        self._insert_ordered(title_info, coverpage, "title-info")

        self._drop_unused_binaries(root, namespace, old_hrefs)
        return cover_id

    def _drop_unused_binaries(
        self, root: ET.Element, namespace: str, candidates: Sequence[str]
    ) -> None:
        """Удалить ``<binary>`` из ``candidates``, на которые больше нет ссылок."""
        wanted = {href.lstrip("#") for href in candidates if href}
        if not wanted:
            return

        used: set = set()
        for element in root.iter():
            href = element.get(f"{{{NS_XLINK}}}href")
            if href and href.startswith("#"):
                used.add(href[1:])

        for binary in list(root.iter(self._q(namespace, "binary"))):
            binary_id = binary.get("id")
            if binary_id in wanted and binary_id not in used:
                root.remove(binary)

    def _apply_annotation(self, root: ET.Element, namespace: str, text: str) -> bool:
        """Записать ``<annotation>`` в ``<title-info>``."""
        description = self._find(root, namespace, "description")
        title_info = self._find(description, namespace, "title-info")
        if title_info is None:
            return False

        annotation = ET.Element(self._q(namespace, "annotation"))
        for block in split_paragraphs(text):
            paragraph = ET.SubElement(annotation, self._q(namespace, "p"))
            paragraph.text = block

        existing = self._find(title_info, namespace, "annotation")
        if existing is not None:
            title_info.remove(existing)
        self._insert_ordered(title_info, annotation, "title-info")
        return True

    def _bump_version(self, root: ET.Element, namespace: str) -> None:
        """Увеличить ``<version>`` и обновить ``<date>`` в ``<document-info>``."""
        description = self._find(root, namespace, "description")
        document_info = self._find(description, namespace, "document-info")
        if document_info is None:
            return

        version = self._find(document_info, namespace, "version")
        if version is not None:
            try:
                current = float(version.text or "1.0")
            except ValueError:
                current = 1.0
            version.text = f"{current + 0.1:.1f}"

        today = date.today().isoformat()
        date_element = self._find(document_info, namespace, "date")
        if date_element is not None:
            date_element.text = today
            date_element.set("value", today)


__all__ = [
    "BookMetadata",
    "Fb2MetadataFetcher",
    "detect_image_type",
    "split_paragraphs",
    "strip_html",
]


def main(argv: Optional[List[str]] = None) -> int:
    """Точка входа CLI.

    :param argv: аргументы командной строки (по умолчанию ``sys.argv[1:]``).
    :return: код возврата.
    """
    parser = argparse.ArgumentParser(
        description="Скачать обложку и/или аннотацию книги и встроить их в FB2.",
    )
    parser.add_argument("source", help="путь к FB2-файлу")
    parser.add_argument(
        "--out", default=None, help="файл результата (по умолчанию — перезапись)"
    )
    parser.add_argument(
        "--provider",
        action="append",
        choices=list(KNOWN_PROVIDERS),
        default=None,
        help="источник (можно указать несколько раз)",
    )
    parser.add_argument("--lang", default="ru", help="предпочитаемый язык книги")
    parser.add_argument(
        "--limit", type=int, default=5, help="сколько результатов запрашивать"
    )
    parser.add_argument("--no-cover", action="store_true", help="не записывать обложку")
    parser.add_argument(
        "--no-annotation", action="store_true", help="не записывать аннотацию"
    )
    parser.add_argument(
        "--no-version", action="store_true", help="не увеличивать <version>"
    )
    parser.add_argument(
        "--list", action="store_true", help="только показать найденные варианты"
    )
    parser.add_argument(
        "--cover-out", default=None, help="сохранить обложку отдельным файлом"
    )
    parser.add_argument("--dry-run", action="store_true", help="не записывать результат")
    args = parser.parse_args(argv)

    fetcher = Fb2MetadataFetcher(
        providers=tuple(args.provider) if args.provider else DEFAULT_PROVIDERS,
        language=args.lang,
    )

    try:
        title, author = fetcher.book_query(args.source)
    except (OSError, ET.ParseError, ValueError) as exc:
        print(f"Ошибка чтения FB2: {exc}", file=sys.stderr)
        return EXIT_ERRORS

    if not title:
        print("В файле не найдено название книги.", file=sys.stderr)
        return EXIT_ERRORS
    print(f"Книга: {title}" + (f" — {author}" if author else ""))

    try:
        matches = fetcher.search(title, author, limit=args.limit)
    except RuntimeError as exc:
        print(f"Ошибка поиска: {exc}", file=sys.stderr)
        return EXIT_ERRORS

    if not matches:
        print("Ничего не найдено.", file=sys.stderr)
        return EXIT_ERRORS

    if args.list:
        for index, match in enumerate(matches, 1):
            print(f"{index}. {match}")
        return EXIT_OK

    # Предпочитаем запись с обложкой.
    best = next((match for match in matches if match.cover_url), matches[0])
    meta = fetcher.enrich(best)
    print(f"Источник: {meta}")
    if meta.cover_data:
        print(f"Обложка: {len(meta.cover_data)} байт")
    if meta.annotation:
        print(f"Аннотация: {meta.annotation[:80]}…")

    if args.cover_out:
        saved = fetcher.save_cover(meta, args.cover_out)
        print(f"Обложка сохранена: {saved}")

    try:
        target = fetcher.apply(
            args.source,
            meta=meta,
            output=args.out,
            set_cover=not args.no_cover,
            set_annotation=not args.no_annotation,
            update_version=not args.no_version,
            dry_run=args.dry_run,
        )
    except RuntimeError as exc:
        print(f"Ошибка: {exc}", file=sys.stderr)
        return EXIT_ERRORS

    if args.dry_run:
        print("(dry-run: файл не изменён)")
    else:
        print(f"Записано: {target}")
    return EXIT_OK


if __name__ == "__main__":
    raise SystemExit(main())
