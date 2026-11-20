import re, sys
s = open('/vol5/@appdata/trim.hermes/workspace/uu-re/pc.html', encoding='utf-8', errors='ignore').read()
print('len', len(s))
for pat in (r'release/dl/\d+[^"\' <>]*', r'type=[a-z]+', r'https?://[^"\' <>]*\.(?:exe|dmg|zip)'):
    print('--', pat)
    print(sorted(set(re.findall(pat, s)))[:10])