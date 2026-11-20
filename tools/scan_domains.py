import re, sys, os
root = sys.argv[1]
pat = re.compile(rb'[a-z0-9][a-z0-9.\-]{3,60}\.(?:163\.com|netease\.com|nie\.net|com|cn)')
hits = {}
for dirpath, _, files in os.walk(root):
    for f in files:
        if not f.lower().endswith(('.exe', '.dll', '.html', '.js', '.json', '.ini', '.xml')):
            continue
        p = os.path.join(dirpath, f)
        try:
            b = open(p, 'rb').read()
        except OSError:
            continue
        found = {m.group().decode('latin1') for m in pat.finditer(b)}
        found = {x for x in found if '163' in x or 'netease' in x or 'nrd' in x}
        if found:
            hits[os.path.relpath(p, root)] = sorted(found)
for k in sorted(hits):
    print(k, '->', hits[k][:12])