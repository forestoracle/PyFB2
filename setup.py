from setuptools import setup, find_packages
import sys
import os
import glob


def list_recursive(package, subdirectory, extension="*"):
    __start_directory = str(os.path.join(package, subdirectory))

    __found = [result for (__cur_dir, __subdirs, __files) in os.walk(__start_directory)
               for result in glob.glob(os.path.join(__cur_dir, '*.' + extension))]

    __relative_found = list(map(lambda __x: os.path.relpath(__x, package), __found))
    return __relative_found

__version = "0.1.2"

spec = {
    "name": "pyFB2",
    "version": __version,
    "license": "Apache2",
    "description": "Package for processing FB2 books",
    "long_description": "Package for processing FB2 books",
    "long_description_content_type": "text/plain",
    "packages": ["pyFB2"],
    "install_requires": ["xmlschema >= 3.0.2"],
    "python_requires": ">=3.11",
    "package_data": {"": list_recursive("pyFB2", "resources")}
}

setup(**spec)
