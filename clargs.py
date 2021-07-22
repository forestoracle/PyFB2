#  Command Line ARGumentS
#  Разбор командной строки
#
import argparse
#------------------------------------------------
parser = argparse.ArgumentParser()
parser.add_argument("-v", help="show version")
parser.add_argument("-c", help="show contents")
args = parser.parse_args()