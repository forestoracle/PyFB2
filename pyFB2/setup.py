"""Совместимость со сборкой: метаданные описаны в pyproject.toml.

Оставлен как shim для инструментов, ожидающих setup.py. Все метаданные,
зависимости, точки входа (console_scripts) и данные пакета заданы в
``pyproject.toml`` (PEP 621).
"""

from setuptools import setup

setup()

