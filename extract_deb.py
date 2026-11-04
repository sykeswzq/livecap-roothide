import tarfile
import io
import os
import lzma

deb_path = r'C:\Users\Administrator\WorkBuddy\ZDFY\livecap-roothide\com.sykes.livecap_1.0.77_iphoneos-arm64e.deb'
extract_dir = r'C:\Users\Administrator\WorkBuddy\ZDFY\livecap-roothide\livecap_extracted'
os.makedirs(extract_dir, exist_ok=True)

with open(deb_path, 'rb') as f:
    data = f.read()

print(f'File size: {len(data)} bytes')

# New ar format has extended header at start
# Format: <size>\n<content> where size is decimal
pos = 8  # Skip !<arch>\n
if data[pos:pos+1] == b'/':
    # Extended header
    end = data.find(b'\n', pos)
    ext_header_size = int(data[pos+1:end].decode())
    ext_header = data[end+1:end+1+ext_header_size]
    print(f'Extended header: {ext_header_size} bytes')
    pos = end + 1 + ext_header_size
    # Align to 2 bytes
    if pos % 2 != 0:
        pos += 1

# Now parse regular ar entries
files = {}
while pos < len(data):
    # Check for global header marker
    if data[pos:pos+2] == b'//':
        pos += 2
        continue
    if data[pos:pos+1] == b'\n':
        pos += 1
        continue
    
    # Ar header: 16 bytes name, 12 bytes date, 12 bytes uid, 12 bytes gid, 8 bytes mode, 10 bytes size, 2 bytes magic
    if pos + 60 > len(data):
        break
    
    header = data[pos:pos+60]
    magic = header[58:60]
    
    # Check for old-style magic (backtick + newline)
    if magic != b'`\n':
        print(f'End of archive at pos {pos}, magic: {magic}')
        break
    
    name = header[0:16].decode('ascii', errors='replace').strip()
    size = int(header[48:58].decode('ascii').strip())
    
    # Align to even boundary
    if size % 2 != 0:
        size += 1
    
    content_start = pos + 60
    content = data[content_start:content_start+size]
    
    files[name] = content
    print(f'  {name}: {size} bytes')
    
    pos = content_start + size

print(f'\nFound {len(files)} files in archive')

# Extract control.tar.xz
if 'control.tar.xz' in files:
    print('\nExtracting control.tar.xz...')
    control_data = lzma.decompress(files['control.tar.xz'])
    with tarfile.open(fileobj=io.BytesIO(control_data), mode='r') as tar:
        tar.extractall(path=extract_dir)
        for m in tar.getmembers():
            print(f'  {m.name}')

# Extract data.tar.xz
if 'data.tar.xz' in files:
    print('\nExtracting data.tar.xz...')
    data_data = lzma.decompress(files['data.tar.xz'])
    with tarfile.open(fileobj=io.BytesIO(data_data), mode='r') as tar:
        tar.extractall(path=extract_dir)
        for m in tar.getmembers():
            print(f'  {m.name}')

print('\nDone!')
