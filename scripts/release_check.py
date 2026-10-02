#!/usr/bin/env python3
"""Source-only release gate. Reports categories/paths, never matched values.

This heuristic complements manual source and image review; it is not a guarantee
against every possible secret. The manifest is intentionally maintained separately.
"""
import argparse,json,re,struct,subprocess,sys,zlib
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
GENERATED={'.git','.build','.gradle','build','bin','obj','dist','.venv','__pycache__','DerivedData'}
FORBIDDEN={'.apk','.aab','.ipa','.app','.exe','.dll','.dylib','.so','.pyc','.log','.db','.sqlite','.sqlite3','.jks','.keystore','.p12','.pfx','.pem','.key','.crt','.cer','.mobileprovision','.provisionprofile','.icns','.zip','.gz'}
PATTERNS={
    'personal home path':r'/(?:Users|home)/[^\s/]+/',
    'Windows user path':r'[A-Za-z]:\\Users\\[^\\\s]+',
    'private key':r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
    'access token':r'\b(?:gh[pousr]_[A-Za-z0-9]{25,}|github_pat_[A-Za-z0-9_]{30,}|AKIA[A-Z0-9]{16}|sk-[A-Za-z0-9_-]{24,})',
    'hardware MAC':r'(?<![\w:])(?:[A-Fa-f0-9]{2}:){5}[A-Fa-f0-9]{2}(?![\w:])',
    'hardware MAC hyphens':r'(?<![\w-])(?:[A-Fa-f0-9]{2}-){5}[A-Fa-f0-9]{2}(?![\w-])',
    'hardware UDID':r'\b0000[0-9A-Fa-f]{4}-[0-9A-Fa-f]{16}\b',
    'personal signing configuration':r'DEVELOPMENT_TEAM\s*=\s*[A-Z0-9]{10}\b',
    'fixed keystore password':r'\b(?:storePassword|keyPassword)\s*[=:]?\s*[\x27\x22][^\x27\x22]+',
    'personal remote endpoint':r'https?://[^\s/]*(?:\.ug\.link|\.ugdocker\.link)',
    'personal deployment root':r'/volume[0-9]+/',
    'local SDK path':r'\bsdk\.dir\s*=',
}

def inspect_png(data):
    if data[:8]!=b'\x89PNG\r\n\x1a\n':return False
    allowed={b'IHDR',b'PLTE',b'IDAT',b'IEND',b'tRNS',b'sRGB',b'gAMA',b'cHRM'}
    pos=8;ended=False
    while pos<len(data):
        if pos+12>len(data):return False
        n=struct.unpack('>I',data[pos:pos+4])[0];kind=data[pos+4:pos+8];end=pos+n+12
        if end>len(data) or kind not in allowed:return False
        if zlib.crc32(data[pos+4:end-4])&0xffffffff!=struct.unpack('>I',data[end-4:end])[0]:return False
        pos=end
        if kind==b'IEND':ended=True;break
    return ended and pos==len(data)

def run(check_index=False):
    names=(ROOT/'PUBLIC_FILES.txt').read_text().splitlines()
    errors=[]
    if len(names)!=len(set(names)) or 'PUBLIC_FILES.txt' not in names:errors.append(('manifest','duplicates/missing self'))
    actual={p.relative_to(ROOT).as_posix() for p in ROOT.rglob('*') if (p.is_file() or p.is_symlink()) and not any(x in GENERATED for x in p.relative_to(ROOT).parts)}
    for extra in sorted(actual-set(names)):errors.append((extra,'not allowlisted'))
    for name in names:
        p=ROOT/name;relative=Path(name)
        if relative.is_absolute() or '..' in relative.parts or any((ROOT/Path(*relative.parts[:i])).is_symlink() for i in range(1,len(relative.parts)+1)):
            errors.append((name,'unsafe path'));continue
        if not p.is_file():errors.append((name,'missing'));continue
        if p.suffix.lower() in FORBIDDEN or 'xcuserdata' in relative.parts or p.name=='.env' or (p.name.startswith('.env.') and p.name!='.env.example'):
            errors.append((name,'private/generated file'));continue
        data=p.read_bytes()
        if p.suffix=='.png':
            if not inspect_png(data):errors.append((name,'unreviewed image metadata or invalid PNG'))
            continue
        try:text=data.decode('utf-8')
        except UnicodeDecodeError:errors.append((name,'unreviewed binary'));continue
        for category,pattern in PATTERNS.items():
            if re.search(pattern,text):errors.append((name,category))
    defaults=json.loads((ROOT/'macos-signer/Defaults.json').read_text())
    if any(defaults.get(k) for k in ('project','referenceApp','team','device','automatic')):errors.append(('macos-signer/Defaults.json','must start unconfigured'))
    if check_index:
        tracked=subprocess.check_output(['git','-C',str(ROOT),'ls-files','-z']).decode().split('\0')
        for name in filter(None,tracked):
            if name not in names:errors.append((name,'index not allowlisted'))
        for name in names:
            staged=subprocess.run(['git','-C',str(ROOT),'show',':'+name],capture_output=True)
            if staged.returncode or staged.stdout!=(ROOT/name).read_bytes():errors.append((name,'index differs from reviewed file'))
    for name,reason in errors:print('FAIL',name,reason,file=sys.stderr)
    if errors:raise SystemExit(1)
    print(f'PASS {len(names)} allowlisted source files/assets; heuristic gate and index={check_index}')

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--index',action='store_true');run(p.parse_args().index)
