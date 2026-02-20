import urllib.request
url = 'https://raw.githubusercontent.com/dhepper/font8x8/master/font8x8_basic.h'
r = urllib.request.urlopen(url)
data = r.read().decode('utf-8')
lines = data.split('\n')
out = []
out.append('pub const font8x8 = [128][8]u8{')
inside = False

# We need all 128 elements, even if missing from the C array originally.
res = ['.{ 0, 0, 0, 0, 0, 0, 0, 0 }'] * 128

for line in lines:
    if 'font8x8_basic' in line and '{' in line:
        inside = True
        continue
    if inside:
        if '}' in line and ';' in line:
            break
        # Process lines like "    { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },   // U+0020 (space)"
        if '// U+' in line:
            idx_hex = line.split('// U+')[1][:4]
            idx = int(idx_hex, 16)
            arr = line.split('{')[1].split('}')[0].strip()
            res[idx] = '.{ ' + arr + ' }'

for c in res:
    out.append('    ' + c + ',')
out.append('};')
with open('src/font.zig', 'w') as f:
    f.write('\n'.join(out))
