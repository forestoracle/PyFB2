#  Command Line ARGumentS
#  Разбор командной строки
#
import argparse
# ------------------------------------------------
parser = argparse.ArgumentParser()

parser.add_argument("-v", help="show version")
parser.add_argument("-c", help="show contents tree")
parser.add_argument("-a", help="show Author(s) info")
args = parser.parse_args()
