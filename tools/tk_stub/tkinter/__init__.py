"""Заглушка модуля tkinter для запуска inp2rad.py без графического интерфейса.

inp2rad.py импортирует tkinter в первых строках, хотя в пакетном режиме окна не
открывает. В образе OpenCourant модуля tkinter нет, поэтому подкладываем пустой.
Если код всё же попытается открыть окно — получим понятную ошибку.
"""


class _NoGui:
    def __getattr__(self, name):
        raise RuntimeError("tkinter недоступен: inp2rad запущен в пакетном режиме без GUI")


Tk = _NoGui
filedialog = _NoGui()
messagebox = _NoGui()
