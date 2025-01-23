translate languages on language page into itself

use yaml for flatpak manifest

terminal sometimes not receiving output

show toast about potential non-translated texts

terminal deicated close button

timezone/formats updates from filter page not working

fix skipping over pages

summary language row

fix changing software/feature1


desktop fix not well configured

config: fix printing of nested variables
separate file for validation
            page for page in page_order if page_conditions.get(page, True)]

timezones prov dependent on chosen language?

formats+timezone prov locking while update?

translate format provider undefined locale name

language provider unavailable lang

choice preload check and use config instead

fallback image for desktop

disk encryption not available from summary

check summary row visibility

preloadable: check future dependency

remove suggested languages, replace with available/unavailable
merge language configs
make all languages available, independent of system and translation, show

about dialog from json

skip confirm page if no pages in configure section


custom disk partitoning
update disk page regularly
	disk_exists useful for disk page reloading
add option to skip disk selection
individual

less page image headers?
	desktop?
	summary?

dependency('libgeoclue-2.0', version: '>= 2.4')

keyboard languages in selected language, not their own

add text to no internet connection

Add Python script example

handle en_US not available?

use config for installation step

document coding stuff
	--max-line-length 100
	internal values/functions _prefix


from ctypes import cdll, CDLL, c_wchar_p

cdll.LoadLibrary("libc.so.6")
libc = CDLL("libc.so.6")
libc.rand()
c_wchar_p("de_DE.UTF-8")

libc.printf(b"Hello, %s\n", b"World!")

#struct __locale_struct
#{
#  /* Note: LC_ALL is not a valid index into this array.  */
#  struct __locale_data *__locales[13]; /* 13 = __LC_LAST. */
#
#  /* To increase the speed of this solution we add some special members.  */
#  const unsigned short int *__ctype_b;
#  const int *__ctype_tolower;
#  const int *__ctype_toupper;
#
#  /* Note: LC_ALL is not a valid index into this array.  */
#  const char *__names[13];
#};





#libc.uselocale(b'de_DE.UTF-8')


### done

fix portugese brasil - portugal
use lower case locale import in syscalls
add AdwButtonContent to hig