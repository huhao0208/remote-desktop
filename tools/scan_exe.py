import sys
p = sys.argv[1]
b = open(p, 'rb').read()
print('size', len(b))
marks = [b'Nullsoft', b'Inno Setup', b'Electron', b'app.asar', b'node_modules', b'V8 version',
         b'7z\xbc\xaf\x27\x1c', b'PK\x03\x04', b'Chrome', b'NSIS', b'cef', b'CEF', b'libcef',
         b'UURemote', b'nrd', b'api.nrd.nie.163.com']
for m in marks:
    idx = b.find(m)
    print(f'{m!r:40} -> {idx}')
# 统计 zip 头个数（可能内嵌压缩包）
print('PK\\x03\\x04 count', b.count(b'PK\x03\x04'))
print('7z sig count', b.count(b'7z\xbc\xaf\x27\x1c'))