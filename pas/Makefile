# Сборка FreePascal-версии парсера FB2.
#
# Требуется компилятор FPC (fpc) и библиотека fcl-xml (входит в стандартную
# поставку FreePascal). Достаточно выполнить:
#
#     make            # собрать все CLI-программы
#     make parser     # только fb2parser_cli
#     make markdown   # только fb2markdown_cli
#     make writer     # только fb2writer_cli
#     make html       # только fb2html_cli
#     make index      # только fb2index_cli (нужен sqlite3.dll)
#     make splitmerge # только fb2splitmerge_cli
#     make normalize  # только fb2normalizer_cli
#     make txt        # только fb2txt_cli
#     make epub       # только fb2epub_cli
#     make fromepub   # только fb2fromepub_cli
#     make fb3        # только fb2tofb3_cli
#     make fromfb3    # только fb3tofb2_cli
#     make docx       # только fb2todocx_cli
#     make fromdocx   # только docxtofb2_cli
#     make odt        # только fb2toodt_cli
#     make fromodt    # только odttofb2_cli
#     make fromhtml   # только htmltofb2_cli
#     make mobi       # только fb2tomobi_cli
#     make frommobi   # только mobitofb2_cli
#     make frommd     # только markdowntofb2_cli
#     make clean      # удалить артефакты сборки
#
# На Windows используется fpc.exe, на Unix — fpc.

FPC ?= fpc
FPCFLAGS = -Mobjfpc -Sh -O2 -vw

PARSER_BIN = fb2parser_cli
MARKDOWN_BIN = fb2markdown_cli
WRITER_BIN = fb2writer_cli
HTML_BIN = fb2html_cli
INDEX_BIN = fb2index_cli
SPLIT_BIN = fb2splitmerge_cli
NORM_BIN = fb2normalizer_cli
TXT_BIN = fb2txt_cli
EPUB_BIN = fb2epub_cli
FROMEPUB_BIN = fb2fromepub_cli
FB3_BIN = fb2tofb3_cli
FROMFB3_BIN = fb3tofb2_cli
DOCX_BIN = fb2todocx_cli
FROMDOCX_BIN = docxtofb2_cli
ODT_BIN = fb2toodt_cli
FROMODT_BIN = odttofb2_cli
FROMHTML_BIN = htmltofb2_cli
MOBI_BIN = fb2tomobi_cli
FROMMOBI_BIN = mobitofb2_cli
FROMMD_BIN = markdowntofb2_cli

.PHONY: all parser markdown writer html index splitmerge normalize txt epub fromepub fb3 fromfb3 docx fromdocx odt fromodt fromhtml mobi frommobi frommd clean

all: parser markdown writer html index splitmerge normalize txt epub fromepub fb3 fromfb3 docx fromdocx odt fromodt fromhtml mobi frommobi frommd

parser: $(PARSER_BIN)

markdown: $(MARKDOWN_BIN)

writer: $(WRITER_BIN)

html: $(HTML_BIN)

index: $(INDEX_BIN)

splitmerge: $(SPLIT_BIN)

normalize: $(NORM_BIN)

txt: $(TXT_BIN)

epub: $(EPUB_BIN)

fromepub: $(FROMEPUB_BIN)

fb3: $(FB3_BIN)

fromfb3: $(FROMFB3_BIN)

docx: $(DOCX_BIN)

fromdocx: $(FROMDOCX_BIN)

odt: $(ODT_BIN)

fromodt: $(FROMODT_BIN)

fromhtml: $(FROMHTML_BIN)

mobi: $(MOBI_BIN)

frommobi: $(FROMMOBI_BIN)

frommd: $(FROMMD_BIN)

$(PARSER_BIN): fb2_structures.pas fb2_parser.pas fb2parser_cli.pas
	$(FPC) $(FPCFLAGS) fb2parser_cli.pas

$(MARKDOWN_BIN): fb2_structures.pas fb2_parser.pas fb2_markdown.pas fb2markdown_cli.pas
	$(FPC) $(FPCFLAGS) fb2markdown_cli.pas

$(WRITER_BIN): fb2_structures.pas fb2_parser.pas fb2_writer.pas fb2writer_cli.pas
	$(FPC) $(FPCFLAGS) fb2writer_cli.pas

$(HTML_BIN): fb2_structures.pas fb2_parser.pas fb2_html.pas fb2html_cli.pas
	$(FPC) $(FPCFLAGS) fb2html_cli.pas

$(INDEX_BIN): fb2_structures.pas fb2_parser.pas fb2_errors.pas fb2_files.pas \
		fb2_encoding_scanner.pas fb2_index.pas fb2index_cli.pas
	$(FPC) $(FPCFLAGS) fb2index_cli.pas

$(SPLIT_BIN): fb2_structures.pas fb2_parser.pas fb2_writer.pas fb2_errors.pas \
		fb2_split_merge.pas fb2splitmerge_cli.pas
	$(FPC) $(FPCFLAGS) fb2splitmerge_cli.pas

$(NORM_BIN): fb2_structures.pas fb2_errors.pas fb2_files.pas \
		fb2_transcoder.pas fb2_normalizer.pas fb2normalizer_cli.pas
	$(FPC) $(FPCFLAGS) fb2normalizer_cli.pas

$(TXT_BIN): fb2_structures.pas fb2_parser.pas fb2_errors.pas fb2_files.pas \
		fb2_to_txt.pas fb2txt_cli.pas
	$(FPC) $(FPCFLAGS) fb2txt_cli.pas

$(EPUB_BIN): fb2_structures.pas fb2_parser.pas fb2_errors.pas fb2_files.pas \
		fb2_to_epub.pas fb2epub_cli.pas
	$(FPC) $(FPCFLAGS) fb2epub_cli.pas

$(FROMEPUB_BIN): fb2_structures.pas fb2_parser.pas fb2_errors.pas fb2_files.pas \
		fb2_writer.pas fb2_archive.pas fb2_genres.pas epub_to_fb2.pas \
		fb2fromepub_cli.pas
	$(FPC) $(FPCFLAGS) fb2fromepub_cli.pas

$(FB3_BIN): fb2_structures.pas fb2_parser.pas fb2_errors.pas fb2_files.pas \
		fb2_images.pas fb2_to_fb3.pas fb2tofb3_cli.pas
	$(FPC) $(FPCFLAGS) fb2tofb3_cli.pas

$(FROMFB3_BIN): fb2_structures.pas fb2_parser.pas fb2_errors.pas fb2_files.pas \
		fb2_writer.pas fb2_images.pas fb2_archive.pas fb3_to_fb2.pas \
		fb3tofb2_cli.pas
	$(FPC) $(FPCFLAGS) fb3tofb2_cli.pas

$(DOCX_BIN): fb2_structures.pas fb2_parser.pas fb2_errors.pas fb2_files.pas \
		fb2_images.pas fb2_to_docx.pas fb2todocx_cli.pas
	$(FPC) $(FPCFLAGS) fb2todocx_cli.pas

$(FROMDOCX_BIN): fb2_structures.pas fb2_parser.pas fb2_errors.pas fb2_files.pas \
		fb2_writer.pas fb2_archive.pas fb2_genres.pas docx_to_fb2.pas \
		docxtofb2_cli.pas
	$(FPC) $(FPCFLAGS) docxtofb2_cli.pas

$(ODT_BIN): fb2_structures.pas fb2_parser.pas fb2_errors.pas fb2_files.pas \
		fb2_images.pas fb2_to_odt.pas fb2toodt_cli.pas
	$(FPC) $(FPCFLAGS) fb2toodt_cli.pas

$(FROMODT_BIN): fb2_structures.pas fb2_parser.pas fb2_errors.pas fb2_files.pas \
		fb2_writer.pas fb2_images.pas fb2_archive.pas odt_to_fb2.pas \
		odttofb2_cli.pas
	$(FPC) $(FPCFLAGS) odttofb2_cli.pas

$(FROMHTML_BIN): fb2_structures.pas fb2_parser.pas fb2_errors.pas fb2_files.pas \
		fb2_writer.pas fb2_genres.pas html_to_fb2.pas htmltofb2_cli.pas
	$(FPC) $(FPCFLAGS) htmltofb2_cli.pas

$(MOBI_BIN): fb2_structures.pas fb2_parser.pas fb2_errors.pas fb2_files.pas \
		fb2_images.pas fb2_to_mobi.pas fb2tomobi_cli.pas
	$(FPC) $(FPCFLAGS) fb2tomobi_cli.pas

$(FROMMOBI_BIN): fb2_structures.pas fb2_parser.pas fb2_errors.pas fb2_files.pas \
		fb2_writer.pas fb2_images.pas fb2_genres.pas html_to_fb2.pas \
		mobi_to_fb2.pas mobitofb2_cli.pas
	$(FPC) $(FPCFLAGS) mobitofb2_cli.pas

$(FROMMD_BIN): fb2_structures.pas fb2_errors.pas fb2_files.pas \
		fb2_writer.pas fb2_genres.pas markdown_to_fb2.pas \
		markdowntofb2_cli.pas
	$(FPC) $(FPCFLAGS) markdowntofb2_cli.pas

clean:
	-rm -f *.o *.ppu *.a
	-rm -f $(PARSER_BIN) $(PARSER_BIN).exe
	-rm -f $(MARKDOWN_BIN) $(MARKDOWN_BIN).exe
	-rm -f $(WRITER_BIN) $(WRITER_BIN).exe
	-rm -f $(HTML_BIN) $(HTML_BIN).exe
	-rm -f $(INDEX_BIN) $(INDEX_BIN).exe
	-rm -f $(SPLIT_BIN) $(SPLIT_BIN).exe
	-rm -f $(NORM_BIN) $(NORM_BIN).exe
	-rm -f $(TXT_BIN) $(TXT_BIN).exe
	-rm -f $(EPUB_BIN) $(EPUB_BIN).exe
	-rm -f $(FROMEPUB_BIN) $(FROMEPUB_BIN).exe
	-rm -f $(FB3_BIN) $(FB3_BIN).exe
	-rm -f $(FROMFB3_BIN) $(FROMFB3_BIN).exe
	-rm -f $(DOCX_BIN) $(DOCX_BIN).exe
	-rm -f $(FROMDOCX_BIN) $(FROMDOCX_BIN).exe
	-rm -f $(ODT_BIN) $(ODT_BIN).exe
	-rm -f $(FROMODT_BIN) $(FROMODT_BIN).exe
	-rm -f $(FROMHTML_BIN) $(FROMHTML_BIN).exe
	-rm -f $(MOBI_BIN) $(MOBI_BIN).exe
	-rm -f $(FROMMOBI_BIN) $(FROMMOBI_BIN).exe
	-rm -f $(FROMMD_BIN) $(FROMMD_BIN).exe
