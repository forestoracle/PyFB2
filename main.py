import xml.etree.ElementTree as ET
from xml.etree.ElementTree import Element
from PyFB2 import FB2Parser, FB2HTML, FB2Renamer, FB2GroupRenamer
import colored
# from bs4 import BeautifulSoup

# import clargs
level = 1


def print_titles(root):
    global level
    secs = fb2.get_sections(root)
    sec: Element
    for sec in secs:
        titles = fb2.get_titles(sec)
        txt = ""
        for title in titles:
            txt += title.text
        print("    " * level, txt)
        #for elem in sec.findall("section"):
        #    elem.tag = "body"
        for elem in sec.findall("./title"):
            elem.tag = "h" + str(level)

        html = ET.Element('html', attrib={"xml:lang":"ru-ru", "lang":"ru-ru"})

        head = ET.Element('head')
        ET.SubElement(head, 'meta', attrib={"http-equiv":"content-type" ,"content": "text/html; charset=utf-8"})
        ET.SubElement(head, 'title').text = txt

        body = ET.Element('body')
        html.append(head)
        html.append(body)
        body.append(sec)
        book = ET.ElementTree(html)
        book.write("./out/" + txt + ".html", encoding='utf-8')
        level += 1
        print_titles(sec)
        level -= 1


if __name__ == '__main__':  #
    cl_fg = colored.fore
    cl_bg = colored.back
    cl_info = colored.fg(2)
    cl_error = colored.fg(1)
    level = 1
    fb2 = FB2Parser("C:\projects\dev\python\pyFB2\sample\lenin.fb2")
    if fb2.LastError == 0:
        print(cl_info, 'File opened.')
    else:
        print(cl_error, 'File not found!')
        exit(fb2.LastError)
    print("      Title: ", fb2.title)
    print("       Lang: ", fb2.lang)
    print("Source Lang: ", fb2.src_lang)
    print("      Genre: ", fb2.genre)
    print(" Annotation: ", fb2.annotation)
    print("   Keywords: ", fb2.keywords)
    print("   Sequence: ", fb2.sequence_name)
    print(" Sequence #: ", fb2.sequence_number)
    print("       Date: ", fb2.title_info_date)
    authors = fb2.authors
    print("Author(s): ", fb2.authors)
    for author in authors:
        print(colored.fg("yellow"),"  First name: ", colored.fg("black"), fb2.author_first_name(author))
        print(colored.fg("yellow"),"   Last name: ", colored.fg("black"), fb2.author_last_name(author))
        print(colored.fg(200),"Middle name: ", colored.fg("black"), fb2.author_middle_name(author))
        print(colored.fg("yellow"),"   Home page: ", colored.fg("black"), fb2.author_home_page(author))
        print(colored.fg("yellow"),"    Nickname: ", colored.fg("black"), fb2.author_nickname(author))
        print(colored.fg("yellow"),"          ID: ", colored.fg("black"), fb2.author_id(author))
        print(colored.fg("yellow")," ------------")

    # print("    Binaries:", fb2.write_binaries())
    fb2html = FB2HTML("C:\projects\dev\python\pyFB2\sample\lenin.fb2")
    fb2html.write_html('out')
    bodies = fb2.bodies
    print(" Bodies:", fb2.bodies)

    ren = FB2GroupRenamer("c:/temp/fb2", "{Al} {Af} - {Tt}")
    ren.rename_all()
    # ren.rename()
    # for body in bodies:
    #     print_titles(body)
    # for cl in range(250):
    #    print(colored.fg(cl), "test", cl)

