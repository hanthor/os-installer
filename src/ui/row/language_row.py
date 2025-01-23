# SPDX-License-Identifier: GPL-3.0-or-later

import locale

from gi.repository import Adw, Gtk


@Gtk.Template(resource_path='/com/github/p3732/os-installer/ui/row/language_row.ui')
class LanguageRow(Adw.ActionRow):
    __gtype_name__ = __qualname__

    def __init__(self, info, **kwargs):
        self.info = info

        print(f'trying set {info.locale}')
        try:
            locale.setlocale(locale.LC_ALL, info.locale)
            print('  yes translating')
        except locale.Error:
            print('  no')
        super().__init__(**kwargs)
