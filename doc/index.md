# Документация pyFB2

Точка входа в документацию проекта. Общие сведения (установка, быстрый старт,
примеры, CLI) — в [README](../README.md); история версий — в
[CHANGELOG](../CHANGELOG.md).

## Ядро

| Модуль | Документ |
|---|---|
| `fb2_structures.py` — dataclass-структуры по XSD | [fb2_structures.md](fb2_structures.md) |
| `fb2_errors.py` — единая иерархия исключений (`Fb2Error`) | docstring модуля |
| `fb2_parser.py` — разбор FB2, идентификаторы глав | [fb2_parser.md](fb2_parser.md) |
| `fb2_writer.py` — сериализация структур в XML (round-trip) | docstring модуля |
| `fb2_validator.py` — валидация по XSD (lxml) | docstring модуля |
| `fb2_normalizer.py` — нормализация/авто-исправление | [fb2_normalizer.md](fb2_normalizer.md) |
| `fb2_rewrite.py` — пересборка формы FB2 (структуры → XML) | [fb2_rewrite.md](fb2_rewrite.md) |
| `fb2_xml.py` — безопасный разбор XML (защита от DTD-бомб) | docstring модуля |

## Конвертеры

| Направление | Документ |
|---|---|
| FB2 → EPUB (2.0/3.0) | [fb2_to_epub.md](fb2_to_epub.md) |
| EPUB → FB2 | [epub_to_fb2.md](epub_to_fb2.md) |
| FB2 → DOCX | [fb2_to_docx.md](fb2_to_docx.md) |
| DOCX → FB2 | [docx_to_fb2.md](docx_to_fb2.md) |
| FB2 → ODT | [fb2_to_odt.md](fb2_to_odt.md) |
| ODT → FB2 | [odt_to_fb2.md](odt_to_fb2.md) |
| FB2 → MOBI (Kindle KF7) | [fb2_to_mobi.md](fb2_to_mobi.md) |
| MOBI → FB2 | [mobi_to_fb2.md](mobi_to_fb2.md) |
| FB2 → FB3 | [fb2_to_fb3.md](fb2_to_fb3.md) |
| FB3 → FB2 | [fb3_to_fb2.md](fb3_to_fb2.md) |
| FB2 → HTML (с двусторонними сносками) | [fb2_to_html.md](fb2_to_html.md) |
| HTML → FB2 | [html_to_fb2.md](html_to_fb2.md) |
| FB2 → Markdown | docstring `fb2_to_markdown.py` |
| Markdown → FB2 | [markdown_to_fb2.md](markdown_to_fb2.md) |
| FB2 → TXT | [fb2_to_txt.md](fb2_to_txt.md) |
| FB2 → PDF (extra `[pdf]`) | docstring `fb2_to_pdf.py` |
| PDF → FB2 (эвристически) | [pdf_to_fb2.md](pdf_to_fb2.md) |

## Утилиты, библиотека, сеть

| Модуль | Документ |
|---|---|
| `fb2_split_merge.py` — разбиение и слияние книг | [fb2_split_merge.md](fb2_split_merge.md) |
| `fb2_web_metadata.py` — обложки/аннотации из Open Library, Google Books и FantLab | [fb2_web_metadata.md](fb2_web_metadata.md) |
| `fb2_index.py` — SQLite-индекс библиотеки, поиск по метаданным и полнотекстовый (FTS5) | [fb2_index.md](fb2_index.md) |
| `fb2_transcoder.py` — перекодировка в UTF-8 | docstring модуля |
| `fb2_zip.py`, `fb2_unzip.py` — упаковка в `.fb2.zip` и распаковка архивов | docstring модулей |
| `fb2_renamer.py`, `fb2_group_renamer.py` — переименование | docstring модулей |
| `fb2_author_scanner.py`, `fb2_encoding_scanner.py` — сканеры | docstring модулей |
| `fb2_wiki.py` — статья об авторе (extra `[wiki]`) | docstring модуля |

## Командная строка

- [fb2tools.md](fb2tools.md) — единая команда `pyfb2` (16 подкоманд) и узкие
  console-scripts.

## Прочее

- [htmlview.md](htmlview.md) — заметки по HTML-представлению книги.
- [fb2_viewer.md](fb2_viewer.md) — просмотрщик FB2 на `THtmlViewer` (FreePascal).
- [plan.md](plan.md) — исходный план развития библиотеки (что сделано и что нет).

## Порт на FreePascal

- [pas/README_PASCAL.md](../pas/README_PASCAL.md) — статус порта, состав,
  сборка и отличия от Python-версии.
- [fb2_viewer.md](fb2_viewer.md) — опциональные GUI-компоненты: `pas/fb2viewer.pas`
  (просмотр FB2 на `THtmlViewer` из BerndGabriel/HtmlViewer) и
  `pas/fb2outline.pas` (дерево заголовков на `TTreeView` с навигацией).
