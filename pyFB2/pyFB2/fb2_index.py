# -*- coding: utf-8 -*-
"""SQLite-индекс библиотеки FB2 — ядро для упорядочивания коллекции.

Модуль один раз обходит дерево каталогов, читает метаданные FB2 через
:class:`fb2_parser.Fb2Parser` и складывает результат в базу SQLite. Все
остальные инструменты (раскладка по папкам, каталог, дедупликация) работают
с базой, а не заново парсят файлы.

Схема базы::

    books        — по строке на файл (путь, размер, mtime, sha1, кодировка, статус)
    authors      — авторы книги (last/first/middle/nickname)
    titles       — название, серия, номер серии, язык, год
    genres       — жанры книги (код + match)
    author_facts — внешние сведения об авторе (страна, годы жизни) + кэш
    book_text    — FTS5-индекс текста книг (полнотекстовый поиск)

Обновление инкрементальное: файлы с неизменившимися ``size``/``mtime``
пропускаются (``--force`` пересобирает всё).

Поиск:

* :meth:`Fb2Index.search_books` — по метаданным (автор, название, серия,
  жанр, год), регистро- и ё-независимо;
* :meth:`Fb2Index.search_text` — полнотекстовый по содержимому книг (FTS5),
  с сниппетом и ранжированием BM25.

Использование::

    python fb2_index.py build <каталог> [--db library.db] [-r] [--force]
    python fb2_index.py search "толстой" [--by author|title|series|genre|year]
    python fb2_index.py find "красная шапка" [-n 20]
    python fb2_index.py stats [--db library.db]

Пример::

    >>> from fb2_index import Fb2Index
    >>> idx = Fb2Index("library.db")
    >>> idx.build("C:/Books", recursive=True)
    >>> idx.search_books("Петров", by="author")
    >>> idx.search_text("ёжик")
"""

from __future__ import annotations

import argparse
import hashlib
import logging
import re
import sqlite3
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, List, Optional, Sequence, Tuple

from .fb2_encoding_scanner import detect_encoding
from .fb2_errors import Fb2OperationError
from .fb2_parser import TEXT_NODE, Fb2Parser
from .fb2_structures import (
    Annotation,
    Cite,
    Epigraph,
    Paragraph,
    Poem,
    Stanza,
    Subtitle,
    Table,
    Title,
)
from .fb2_xml import parse_xml

DEFAULT_DB = "fb2_index.db"

#: Сколько символов текста книги хранить в FTS-индексе (защита от гигантов).
DEFAULT_TEXT_LIMIT = 200_000

#: Имя FTS-таблицы и её токенизатор.
FTS_TABLE = "book_text"
FTS_TOKENIZER = "unicode61 remove_diacritics 2"

#: Операторы FTS5, которые не нормализуются и не получают ``*``.
FTS_OPERATORS = frozenset({"AND", "OR", "NOT", "NEAR"})

#: Минимальная длина слова, к которому добавляется префиксный ``*``.
MIN_PREFIX_LENGTH = 3

#: Поля, по которым ищет :meth:`Fb2Index.search_books`.
SEARCH_FIELDS = ("any", "author", "title", "series", "genre", "year")

logger = logging.getLogger(__name__)


SCHEMA = """
CREATE TABLE IF NOT EXISTS books (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    path      TEXT    NOT NULL UNIQUE,
    dir       TEXT    NOT NULL,
    filename  TEXT    NOT NULL,
    size      INTEGER NOT NULL,
    mtime     REAL    NOT NULL,
    sha1      TEXT,
    encoding  TEXT,
    is_valid  INTEGER NOT NULL DEFAULT 1,
    error     TEXT,
    scanned_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS authors (
    book_id   INTEGER NOT NULL REFERENCES books(id) ON DELETE CASCADE,
    ord       INTEGER NOT NULL,
    last_name TEXT,
    first_name TEXT,
    middle_name TEXT,
    nickname  TEXT,
    full_name TEXT
);
CREATE TABLE IF NOT EXISTS titles (
    book_id   INTEGER PRIMARY KEY REFERENCES books(id) ON DELETE CASCADE,
    title     TEXT,
    series    TEXT,
    series_num INTEGER,
    lang      TEXT,
    src_lang  TEXT,
    year      TEXT,
    book_id_fb2 TEXT
);
CREATE TABLE IF NOT EXISTS genres (
    book_id INTEGER NOT NULL REFERENCES books(id) ON DELETE CASCADE,
    code    TEXT NOT NULL,
    match   INTEGER
);
CREATE TABLE IF NOT EXISTS author_facts (
    name_norm  TEXT PRIMARY KEY,
    country    TEXT,
    birth_year INTEGER,
    death_year INTEGER,
    century    INTEGER,
    source     TEXT,
    fetched_at REAL
);
CREATE INDEX IF NOT EXISTS idx_books_dir      ON books(dir);
CREATE INDEX IF NOT EXISTS idx_books_sha1     ON books(sha1);
CREATE INDEX IF NOT EXISTS idx_authors_book   ON authors(book_id);
CREATE INDEX IF NOT EXISTS idx_authors_name   ON authors(full_name);
CREATE INDEX IF NOT EXISTS idx_genres_book    ON genres(book_id);
CREATE INDEX IF NOT EXISTS idx_genres_code    ON genres(code);
"""

#: Схема FTS5-таблицы полнотекстового поиска (создаётся отдельно: SQLite
#: может быть собран без FTS5 — тогда текстовый поиск отключается).
SCHEMA_TEXT = f"""
CREATE VIRTUAL TABLE IF NOT EXISTS {FTS_TABLE} USING fts5(
    path   UNINDEXED,
    title  UNINDEXED,
    body   UNINDEXED,
    folded,
    tokenize = '{FTS_TOKENIZER}'
);
"""


def normalize_name(value: Optional[str]) -> str:
    """Нормализует имя для сопоставления: нижний регистр, без лишних пробелов."""
    if not value:
        return ""
    value = value.lower().replace("ё", "е")
    value = re.sub(r"[^\w\s]", " ", value, flags=re.UNICODE)
    return re.sub(r"\s+", " ", value).strip()


def author_full_name(author) -> str:
    """Собирает полное имя автора: 'Фамилия Имя Отчество' или никнейм."""
    parts = [author.last_name, author.first_name, author.middle_name]
    full = " ".join(p.strip() for p in parts if p and p.strip())
    if not full and author.nickname:
        full = author.nickname.strip()
    return full


def sha1_of_file(path: Path, chunk_size: int = 1 << 20) -> str:
    """SHA-1 содержимого файла (для поиска дублей)."""
    h = hashlib.sha1()
    with open(path, "rb") as fh:
        while True:
            chunk = fh.read(chunk_size)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def century_of(year: Optional[int]) -> Optional[int]:
    """Век по году: 1799 -> 18, 1801 -> 19."""
    if year is None:
        return None
    if year <= 0:
        return None
    return (year - 1) // 100 + 1


def year_from_date(value: Optional[str]) -> Optional[str]:
    """Извлекает год (4 цифры) из строки даты 'YYYY-MM-DD' / 'YYYY'."""
    if not value:
        return None
    m = re.search(r"(\d{4})", value)
    return m.group(1) if m else None


# ---------------------------------------------------------------------------
# Текстовый поиск: нормализация, FTS-запрос, сниппет
def fold_text(value: Optional[str]) -> str:
    """Нормализует текст для поиска: нижний регистр и ``ё`` -> ``е``.

    Замена посимвольная, поэтому позиции в исходном и нормализованном тексте
    совпадают (это используется при подсветке сниппета).
    """
    if not value:
        return ""
    return value.replace("Ё", "Е").replace("ё", "е").lower()


def _is_simple_word(token: str) -> bool:
    """Слово без FTS-синтаксиса (кавычек, звёздочек, скобок, двоеточий)."""
    return not any(char in token for char in '"*():^')


def build_fts_query(query: str, prefix: bool = True) -> str:
    """Собирает запрос для FTS5: ``ё`` -> ``е``, регистр вниз, префиксы.

    Операторы (``AND``/``OR``/``NOT``/``NEAR``) сохраняются; слова с
    FTS-синтаксисом и слова короче ``MIN_PREFIX_LENGTH`` не усекаются.
    Префиксный ``*`` компенсирует отсутствие стеммера для русского языка:
    запрос «ежик» найдёт «ежика», «ежиков».

    :param query: пользовательский запрос;
    :param prefix: добавлять ``*`` к простым словам.
    """
    parts: List[str] = []
    for token in re.split(r"(\s+)", query.strip()):
        if not token.strip():
            parts.append(token)
            continue
        if token.strip().upper() in FTS_OPERATORS:
            parts.append(token.strip().upper())
            continue
        folded = fold_text(token)
        if prefix and _is_simple_word(token) and len(folded) >= MIN_PREFIX_LENGTH:
            folded += "*"
        parts.append(folded)
    return "".join(parts).strip()


def query_terms(query: str) -> List[str]:
    """Слова запроса (нормализованные) — для подсветки в сниппете."""
    terms: List[str] = []
    for token in re.split(r"[^\w]+", fold_text(query), flags=re.UNICODE):
        if len(token) >= 2 and token.upper() not in FTS_OPERATORS:
            terms.append(token)
    return terms


def make_snippet(
    body: str,
    folded: str,
    terms: Sequence[str],
    length: int = 200,
) -> str:
    """Вырезает фрагмент текста вокруг первого совпадения и подсвечивает его.

    :param body: исходный текст книги (то, что показываем);
    :param folded: нормализованный текст той же книги (по нему ищем);
    :param terms: слова запроса;
    :param length: желаемая длина фрагмента в символах.
    """
    if not body:
        return ""
    haystack = folded if len(folded) == len(body) else fold_text(body)
    position, matched = -1, ""
    for term in terms:
        index = haystack.find(term)
        if index != -1 and (position == -1 or index < position):
            position, matched = index, term

    if position == -1:
        head = body[:length]
        return head + ("…" if len(body) > length else "")

    start = max(0, position - length // 3)
    end = min(len(body), start + length)
    fragment = body[start:end]
    if matched and len(haystack) == len(body):
        rel = position - start
        fragment = (
            fragment[:rel]
            + "["
            + fragment[rel:rel + len(matched)]
            + "]"
            + fragment[rel + len(matched):]
        )
    prefix = "…" if start > 0 else ""
    suffix = "…" if end < len(body) else ""
    return f"{prefix}{fragment}{suffix}"


def _markup_text(nodes: Sequence) -> str:
    """Простой текст из узлов разметки FB2 (рекурсивно)."""
    parts: List[str] = []
    for node in nodes:
        if getattr(node, "tag", None) == TEXT_NODE:
            parts.append(node.text or "")
        else:
            parts.append(_markup_text(getattr(node, "children", [])))
    return "".join(parts)


def _block_text(block) -> str:
    """Текст одного блочного элемента FB2 (абзац, стихи, цитата, таблица)."""
    if isinstance(block, (Paragraph, Subtitle)):
        return _markup_text(block.content)
    if isinstance(block, (Title, Annotation)):
        return "\n".join(_block_text(item) for item in block.items)
    if isinstance(block, (Epigraph, Cite, Poem)):
        parts = [_block_text(item) for item in block.items]
        parts.extend(_markup_text(author.content) for author in block.text_author)
        return "\n".join(part for part in parts if part)
    if isinstance(block, Stanza):
        verse_parts: List[str] = []
        if block.subtitle is not None:
            verse_parts.append(_block_text(block.subtitle))
        verse_parts.extend(_markup_text(verse.content) for verse in block.verses)
        return "\n".join(part for part in verse_parts if part)
    if isinstance(block, Table):
        return "\n".join(
            _markup_text(cell.children)
            for row in block.rows
            for cell in row.cells
        )
    return ""


def _section_text(section) -> str:
    """Текст секции (заголовок, эпиграфы, аннотация, содержимое, подсекции)."""
    parts: List[str] = []
    if section.title is not None:
        parts.append(_block_text(section.title))
    parts.extend(_block_text(item) for item in section.epigraphs)
    if section.annotation is not None:
        parts.append(_block_text(section.annotation))
    parts.extend(_block_text(block) for block in section.content)
    for child in section.sections:
        parts.append(_section_text(child))
    return "\n".join(part for part in parts if part)


def book_text(bodies: Sequence, limit: int = DEFAULT_TEXT_LIMIT) -> str:
    """Собирает plain text книги из тел FB2 (для полнотекстового индекса).

    :param bodies: список тел из :meth:`fb2_parser.Fb2Parser.parse_bodies`;
    :param limit: максимальная длина результата в символах.
    """
    parts: List[str] = []
    for body in bodies:
        if body.title is not None:
            parts.append(_block_text(body.title))
        parts.extend(_block_text(item) for item in body.epigraphs)
        for section in body.sections:
            parts.append(_section_text(section))
    text = "\n".join(part for part in parts if part)
    return text[:limit]


@dataclass
class BookHit:
    """Результат поиска по метаданным (:meth:`Fb2Index.search_books`)."""

    path: str
    title: str
    authors: str = ""
    series: Optional[str] = None
    year: Optional[str] = None


@dataclass
class TextHit:
    """Результат полнотекстового поиска (:meth:`Fb2Index.search_text`)."""

    path: str
    title: str
    snippet: str
    rank: float


class Fb2Index:
    """Индекс библиотеки FB2 в базе SQLite.

    :param db_path: путь к файлу базы (создаётся автоматически);
    :param debug: печатать отладочные сообщения;
    :param index_text: индексировать текст книг (полнотекстовый поиск);
    :param text_limit: сколько символов текста книги хранить в FTS-индексе.
    """

    def __init__(
        self,
        db_path: str = DEFAULT_DB,
        debug: bool = False,
        index_text: bool = True,
        text_limit: int = DEFAULT_TEXT_LIMIT,
    ) -> None:
        self.dbPath = Path(db_path)
        self.debug = debug
        self.index_text = index_text
        self.text_limit = text_limit
        self.conn = sqlite3.connect(str(self.dbPath))
        self.conn.execute("PRAGMA foreign_keys = ON")
        # Регистро- и ё-независимое сравнение строк в SQL (для search_books).
        self.conn.create_function(
            "fb2_norm", 1, normalize_name, deterministic=True
        )
        self.conn.executescript(SCHEMA)
        self.text_search = self._ensure_text_table()
        self.conn.commit()

    def _ensure_text_table(self) -> bool:
        """Создаёт FTS5-таблицу; False, если SQLite собран без FTS5."""
        try:
            self.conn.executescript(SCHEMA_TEXT)
        except sqlite3.OperationalError as exc:  # pragma: no cover - редкий сборка
            logger.warning("полнотекстовый поиск недоступен (нет FTS5): %s", exc)
            return False
        return True


    # --- контекстный менеджер ------------------------------------------------
    def __enter__(self) -> "Fb2Index":
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.close()

    def close(self) -> None:
        self.conn.close()

    # --- обход файлов --------------------------------------------------------
    @staticmethod
    def iter_files(root: Path, recursive: bool = True) -> Iterable[Path]:
        """Возвращает пути к FB2-файлам (без учёта регистра расширения)."""
        mask = "**/*" if recursive else "*"
        for item in root.glob(mask):
            if item.is_file() and item.suffix.lower() == ".fb2":
                yield item

    # --- низкоуровневые операции с БД ---------------------------------------
    def _book_row(self, path: str):
        cur = self.conn.execute(
            "SELECT id, size, mtime FROM books WHERE path = ?", (path,))
        return cur.fetchone()

    def _delete_book(self, path: str) -> None:
        row = self.conn.execute(
            "SELECT id FROM books WHERE path = ?", (path,)).fetchone()
        if row is not None:
            self._delete_text(row[0])
        self.conn.execute("DELETE FROM books WHERE path = ?", (path,))

    def _delete_text(self, book_id: int) -> None:
        """Удаляет текст книги из FTS-индекса (``rowid`` = id книги)."""
        if not self.text_search:
            return
        self.conn.execute(f"DELETE FROM {FTS_TABLE} WHERE rowid = ?", (book_id,))

    def _has_text(self, book_id: int) -> bool:
        """Есть ли у книги строка в FTS-индексе."""
        if not self.text_search:
            return True
        row = self.conn.execute(
            f"SELECT 1 FROM {FTS_TABLE} WHERE rowid = ? LIMIT 1", (book_id,)
        ).fetchone()
        return row is not None

    def _store(self, path: Path, description, encoding: Optional[str],
               sha1: Optional[str], text: Optional[str] = None) -> None:
        """Записывает метаданные одной книги (перезапись при повторе)."""
        st = path.stat()
        self._delete_book(str(path))
        cur = self.conn.execute(
            "INSERT INTO books(path, dir, filename, size, mtime, sha1, encoding,"
            " is_valid, error, scanned_at) VALUES (?,?,?,?,?,?,?,?,?,?)",
            (str(path), str(path.parent), path.name, st.st_size, st.st_mtime,
             sha1, encoding, 1, None, time.time()))
        book_id = cur.lastrowid

        ti = getattr(description, "title_info", None)
        di = getattr(description, "document_info", None)
        pi = getattr(description, "publish_info", None)

        # --- авторы ---
        authors = list(ti.authors) if ti else []
        for i, a in enumerate(authors):
            self.conn.execute(
                "INSERT INTO authors(book_id, ord, last_name, first_name,"
                " middle_name, nickname, full_name) VALUES (?,?,?,?,?,?,?)",
                (book_id, i, a.last_name, a.first_name, a.middle_name,
                 a.nickname, author_full_name(a)))

        # --- название / серия / язык / год ---
        title = ti.book_title.value if (ti and ti.book_title) else None
        series, series_num = None, None
        if ti and ti.sequences:
            series = ti.sequences[0].name
            series_num = ti.sequences[0].number
        lang = ti.lang if ti else None
        src_lang = getattr(ti, "src_lang", None) if ti else None
        year = None
        if pi and pi.year:
            year = year_from_date(pi.year)
        if not year and di and di.date:
            year = year_from_date(di.date.date_value or di.date.value)
        if not year and ti and ti.date:
            year = year_from_date(ti.date.date_value or ti.date.value)
        book_id_fb2 = di.id if di else None
        self.conn.execute(
            "INSERT INTO titles(book_id, title, series, series_num, lang,"
            " src_lang, year, book_id_fb2) VALUES (?,?,?,?,?,?,?,?)",
            (book_id, title, series, series_num, lang, src_lang, year,
             book_id_fb2))

        # --- жанры ---
        if ti:
            for g in ti.genres:
                self.conn.execute(
                    "INSERT INTO genres(book_id, code, match) VALUES (?,?,?)",
                    (book_id, g.value, g.match))

        # --- текст книги (полнотекстовый поиск) ---
        if self.text_search and text is not None:
            title_text = title or ""
            body = f"{title_text}\n\n{text}" if title_text else text
            self.conn.execute(
                f"INSERT INTO {FTS_TABLE}(rowid, path, title, body, folded)"
                " VALUES (?,?,?,?,?)",
                (book_id, str(path), title_text, body, fold_text(body)))

    def _mark_error(self, path: Path, message: str) -> None:
        st = path.stat()
        self._delete_book(str(path))
        self.conn.execute(
            "INSERT INTO books(path, dir, filename, size, mtime, is_valid,"
            " error, scanned_at) VALUES (?,?,?,?,?,?,?,?)",
            (str(path), str(path.parent), path.name, st.st_size, st.st_mtime,
             0, message[:500], time.time()))

    # --- индексация ----------------------------------------------------------
    def index_file(self, path: Path, force: bool = False,
                   compute_hash: bool = False,
                   index_text: Optional[bool] = None) -> str:
        """Индексирует один файл.

        :param index_text: сохранять текст книги (по умолчанию — значение из
            конструктора); если текст ещё не сохранён, файл переиндексируется
            даже при неизменившихся метаданных.
        :returns: 'added', 'updated', 'skipped' или 'error'.
        """
        want_text = self.index_text if index_text is None else index_text
        st = path.stat()
        row = self._book_row(str(path))
        if row and not force:
            unchanged = row[1] == st.st_size and abs(row[2] - st.st_mtime) < 1e-6
            if unchanged and (not want_text or self._has_text(row[0])):
                return "skipped"
        try:
            encoding = detect_encoding(path)
        except Exception:
            encoding = None
        try:
            parser = Fb2Parser(source=str(path))
            root = parse_xml(path)
            description = parser.parse(root)
            text = (
                book_text(parser.parse_bodies(root), limit=self.text_limit)
                if want_text and self.text_search
                else None
            )
        except Exception as exc:  # noqa: BLE001
            self._mark_error(path, f"{type(exc).__name__}: {exc}")
            logger.warning("не удалось проиндексировать %s: %s", path, exc)
            return "error"
        sha1 = sha1_of_file(path) if compute_hash else None
        self._store(path, description, encoding, sha1, text)
        return "updated" if row else "added"

    def build(self, root: str, recursive: bool = True, force: bool = False,
              compute_hash: bool = False,
              index_text: Optional[bool] = None) -> dict:
        """Обходит каталог и обновляет индекс.

        :returns: словарь со счётчиками added/updated/skipped/error.
        """
        base = Path(root)
        if not base.is_dir():
            raise NotADirectoryError(f"Каталог не существует: {base}")
        stats = {"added": 0, "updated": 0, "skipped": 0, "error": 0}
        for path in self.iter_files(base, recursive):
            result = self.index_file(path, force=force,
                                     compute_hash=compute_hash,
                                     index_text=index_text)
            stats[result] += 1
            logger.debug("[%s] %s", result, path)
        self.conn.commit()
        return stats

    # --- запросы -------------------------------------------------------------
    def stats(self) -> dict:
        """Сводная статистика по индексу."""
        c = self.conn
        total = c.execute("SELECT COUNT(*) FROM books").fetchone()[0]
        valid = c.execute(
            "SELECT COUNT(*) FROM books WHERE is_valid = 1").fetchone()[0]
        broken = total - valid
        authors = c.execute(
            "SELECT COUNT(DISTINCT full_name) FROM authors"
            " WHERE full_name IS NOT NULL AND full_name <> ''").fetchone()[0]
        genres = c.execute(
            "SELECT COUNT(DISTINCT code) FROM genres").fetchone()[0]
        encodings = dict(c.execute(
            "SELECT COALESCE(encoding, '?'), COUNT(*) FROM books"
            " GROUP BY encoding ORDER BY 2 DESC").fetchall())
        langs = dict(c.execute(
            "SELECT COALESCE(lang, '?'), COUNT(*) FROM titles"
            " GROUP BY lang ORDER BY 2 DESC").fetchall())
        with_text = 0
        if self.text_search:
            with_text = c.execute(
                f"SELECT COUNT(*) FROM {FTS_TABLE}").fetchone()[0]
        return {
            "books": total,
            "valid": valid,
            "broken": broken,
            "authors": authors,
            "genres": genres,
            "encodings": encodings,
            "langs": langs,
            "text": with_text,
        }

    def top_authors(self, limit: int = 50) -> List[Tuple[str, int]]:
        """Авторы с наибольшим числом книг."""
        cur = self.conn.execute(
            "SELECT full_name, COUNT(DISTINCT book_id) AS n FROM authors"
            " WHERE full_name IS NOT NULL AND full_name <> ''"
            " GROUP BY full_name ORDER BY n DESC, full_name LIMIT ?",
            (limit,))
        return [(row[0], row[1]) for row in cur.fetchall()]

    def genre_counts(self) -> List[Tuple[str, int]]:
        """Число книг по каждому жанровому коду."""
        cur = self.conn.execute(
            "SELECT code, COUNT(DISTINCT book_id) AS n FROM genres"
            " GROUP BY code ORDER BY n DESC, code")
        return [(row[0], row[1]) for row in cur.fetchall()]

    def duplicate_hashes(self, limit: int = 100) -> List[Tuple[str, int]]:
        """Хеши, встречающиеся более одного раза (требует --hash)."""
        cur = self.conn.execute(
            "SELECT sha1, COUNT(*) AS n FROM books WHERE sha1 IS NOT NULL"
            " GROUP BY sha1 HAVING n > 1 ORDER BY n DESC LIMIT ?", (limit,))
        return [(row[0], row[1]) for row in cur.fetchall()]

    def books_by_author(self, name: str) -> List[Tuple[str, str]]:
        """Книги автора (по подстроке полного имени)."""
        cur = self.conn.execute(
            "SELECT t.title, b.path FROM books b"
            " JOIN authors a ON a.book_id = b.id"
            " LEFT JOIN titles t ON t.book_id = b.id"
            " WHERE a.full_name LIKE ? ORDER BY t.title",
            (f"%{name}%",))
        return [(row[0] or "", row[1]) for row in cur.fetchall()]

    def search_books(self, query: str, by: str = "any",
                     limit: int = 50) -> List[BookHit]:
        """Ищет книги по метаданным (регистро- и ё-независимо).

        :param query: подстрока для поиска;
        :param by: поле поиска — ``author``, ``title``, ``series``, ``genre``,
            ``year`` или ``any`` (все поля сразу);
        :param limit: максимум результатов.
        :raises ValueError: если поле поиска неизвестно.
        """
        if by not in SEARCH_FIELDS:
            raise ValueError(
                f"неизвестное поле поиска: {by!r} "
                f"(доступно: {', '.join(SEARCH_FIELDS)})"
            )
        pattern = f"%{normalize_name(query)}%"
        if pattern == "%%":
            return []
        conditions: List[str] = []
        if by in ("any", "author"):
            conditions.append(
                "EXISTS (SELECT 1 FROM authors a WHERE a.book_id = b.id"
                " AND fb2_norm(a.full_name) LIKE ?)"
            )
        if by in ("any", "title"):
            conditions.append("fb2_norm(t.title) LIKE ?")
        if by in ("any", "series"):
            conditions.append("fb2_norm(t.series) LIKE ?")
        if by in ("any", "genre"):
            conditions.append(
                "EXISTS (SELECT 1 FROM genres g WHERE g.book_id = b.id"
                " AND fb2_norm(g.code) LIKE ?)"
            )
        if by in ("any", "year"):
            conditions.append("t.year LIKE ?")
        sql = (
            "SELECT b.path, COALESCE(t.title, ''),"
            " COALESCE((SELECT GROUP_CONCAT(full_name, ', ')"
            "           FROM authors WHERE book_id = b.id), ''),"
            " t.series, t.year"
            " FROM books b LEFT JOIN titles t ON t.book_id = b.id"
            f" WHERE {' OR '.join(conditions)}"
            " ORDER BY t.title, b.path LIMIT ?"
        )
        params: List[object] = [pattern] * len(conditions) + [limit]
        cur = self.conn.execute(sql, params)
        return [
            BookHit(path=row[0], title=row[1], authors=row[2],
                    series=row[3], year=row[4])
            for row in cur.fetchall()
        ]

    def search_text(self, query: str, limit: int = 50,
                    snippet_length: int = 200,
                    prefix: bool = True) -> List[TextHit]:
        """Полнотекстовый поиск по содержимому книг (FTS5).

        :param query: запрос в синтаксисе FTS5 (``AND``/``OR``/``NOT``/
            ``NEAR``, ``"точная фраза"``, ``слово*``); простые слова ищутся
            как префиксы, ``ё`` и ``е`` не различаются;
        :param limit: максимум результатов;
        :param snippet_length: длина фрагмента текста в результате;
        :param prefix: добавлять ``*`` к простым словам (компенсация
            отсутствия стеммера для русского языка).
        :returns: результаты, упорядоченные по релевантности (BM25).
        :raises Fb2OperationError: если FTS5 недоступен или запрос некорректен.
        """
        if not self.text_search:
            raise Fb2OperationError(
                "полнотекстовый поиск недоступен: SQLite без FTS5")
        fts_query = build_fts_query(query, prefix=prefix)
        if not fts_query:
            return []
        terms = query_terms(query)
        sql = (
            f"SELECT path, title, body, folded, bm25({FTS_TABLE}) AS rank"
            f" FROM {FTS_TABLE} WHERE {FTS_TABLE} MATCH ?"
            " ORDER BY rank LIMIT ?"
        )
        try:
            rows = self.conn.execute(sql, (fts_query, limit)).fetchall()
        except sqlite3.OperationalError as exc:
            raise Fb2OperationError(
                f"некорректный поисковый запрос {query!r}: {exc}"
            ) from exc
        return [
            TextHit(
                path=row[0],
                title=row[1],
                snippet=make_snippet(row[2], row[3], terms, snippet_length),
                rank=float(row[4]),
            )
            for row in rows
        ]


def _print_stats(idx: Fb2Index) -> None:
    s = idx.stats()
    print(f"книг: {s['books']} (валидных: {s['valid']}, "
          f"с ошибками: {s['broken']})")
    print(f"авторов: {s['authors']} | жанров: {s['genres']}")
    print(f"с текстом в индексе: {s['text']}")
    print("кодировки:")
    for enc, n in s["encodings"].items():
        print(f"  {enc}: {n}")
    print("языки:")
    for lang, n in s["langs"].items():
        print(f"  {lang}: {n}")


def main(argv: List[str] | None = None) -> int:
    if argv is None:
        argv = sys.argv
    parser = argparse.ArgumentParser(
        description="SQLite-индекс библиотеки FB2")
    parser.add_argument("--db", default=DEFAULT_DB, help="файл базы")
    sub = parser.add_subparsers(dest="command", required=True)

    p_build = sub.add_parser("build", help="построить/обновить индекс")
    p_build.add_argument("root", help="корневой каталог с FB2")
    p_build.add_argument("-r", "--recursive", action="store_true",
                         help="обходить подкаталоги")
    p_build.add_argument("--force", action="store_true",
                         help="переиндексировать всё")
    p_build.add_argument("--hash", action="store_true",
                         help="считать SHA-1 (для поиска дублей)")
    p_build.add_argument("--no-text", action="store_true",
                         help="не индексировать текст книг (только метаданные)")
    p_build.add_argument("--text-limit", type=int, default=DEFAULT_TEXT_LIMIT,
                         help="сколько символов текста хранить на книгу")
    p_build.add_argument("-v", "--verbose", action="store_true")

    sub.add_parser("stats", help="сводная статистика")
    p_auth = sub.add_parser("authors", help="авторы по числу книг")
    p_auth.add_argument("-n", type=int, default=50, help="сколько показать")
    p_books = sub.add_parser("books", help="книги автора")
    p_books.add_argument("name", help="часть имени автора")
    p_search = sub.add_parser("search", help="поиск по метаданным")
    p_search.add_argument("query", help="подстрока (автор, название, серия…)")
    p_search.add_argument("--by", default="any", choices=SEARCH_FIELDS,
                          help="поле поиска (any — все поля)")
    p_search.add_argument("-n", "--limit", type=int, default=50)
    p_find = sub.add_parser("find", help="полнотекстовый поиск по тексту книг")
    p_find.add_argument("query", help="запрос (FTS5: AND/OR/NOT, \"фраза\", слово*)")
    p_find.add_argument("-n", "--limit", type=int, default=20)
    p_find.add_argument("--snippet-length", type=int, default=200,
                        help="длина фрагмента текста")
    p_find.add_argument("--no-prefix", action="store_true",
                        help="не искать слова как префиксы")
    p_dups = sub.add_parser("dups", help="дубли по SHA-1 (нужен build --hash)")
    p_dups.add_argument("-n", type=int, default=100)

    args = parser.parse_args(argv[1:])
    if getattr(args, "verbose", False):
        # -v: подробный вывод библиотеки идёт через logging (в stderr).
        # basicConfig не переопределяет уже настроенное логирование.
        logging.basicConfig(level=logging.DEBUG, format="%(message)s")
    with Fb2Index(args.db, debug=getattr(args, "verbose", False),
                  index_text=not getattr(args, "no_text", False),
                  text_limit=getattr(args, "text_limit", DEFAULT_TEXT_LIMIT)) as idx:
        if args.command == "build":
            res = idx.build(args.root, recursive=args.recursive,
                            force=args.force, compute_hash=args.hash,
                            index_text=not args.no_text)
            print(f"добавлено: {res['added']}, обновлено: {res['updated']}, "
                  f"пропущено: {res['skipped']}, ошибок: {res['error']}")
        elif args.command == "stats":
            _print_stats(idx)
        elif args.command == "authors":
            for name, n in idx.top_authors(args.n):
                print(f"{n:6d}  {name}")
        elif args.command == "books":
            for title, path in idx.books_by_author(args.name):
                print(f"{title} | {path}")
        elif args.command == "search":
            hits = idx.search_books(args.query, by=args.by, limit=args.limit)
            if not hits:
                print("Ничего не найдено.")
            for hit in hits:
                extra = ", ".join(
                    part for part in (hit.authors, hit.series, hit.year) if part)
                print(f"{hit.title} — {extra} | {hit.path}" if extra
                      else f"{hit.title} | {hit.path}")
        elif args.command == "find":
            try:
                text_hits = idx.search_text(
                    args.query, limit=args.limit,
                    snippet_length=args.snippet_length,
                    prefix=not args.no_prefix)
            except Fb2OperationError as exc:
                print(f"Ошибка: {exc}", file=sys.stderr)
                return 1
            if not text_hits:
                print("Ничего не найдено.")
            for text_hit in text_hits:
                print(f"{text_hit.title} | {text_hit.path}")
                print(f"  {text_hit.snippet}")
        elif args.command == "dups":
            dups = idx.duplicate_hashes(args.n)
            if not dups:
                print("дублей не найдено (соберите индекс с --hash)")
            for sha1, n in dups:
                print(f"{n:4d}  {sha1}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
