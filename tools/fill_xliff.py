# Заполняет <target> в ru.xliff переводами из tools/ru.py. Использование: fill_xliff.py ru.xliff
import re, sys, html, os
sys.path.insert(0, os.path.dirname(__file__))
from ru import RU
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
missing = []
def unit(m):
    block = m.group(0)
    key = html.unescape(m.group(1))
    if key not in RU:
        if re.search(r'[A-Za-z]{3}', key) and '|==|' not in key and key not in ('CFBundleDisplayName', 'CFBundleName'): missing.append(key)
        return block
    tgt = '<target state="translated">' + html.escape(RU[key], quote=False) + '</target>'
    block = re.sub(r'<target[^>]*>.*?</target>\s*', '', block, flags=re.S)
    return block.replace('</source>', '</source>\n        ' + tgt, 1)
s = re.sub(r'<trans-unit id="(.*?)".*?</trans-unit>', unit, s, flags=re.S)
open(p, 'w', encoding='utf-8').write(s)
print('missing:', missing)
