"""Extract unmodified ASAP7 libraries and check native LEF area/provenance.

Libarchive handles decompression. The small reader below extracts cell areas
for validation; Yosys parses the libraries for synthesis and reports logic area.
"""
import ctypes as c
import hashlib
import json
from pathlib import Path
import re
import subprocess

DEFAULT_PDK = Path('/home/ubuntu/asap7_pdk')

def liberty_cells(text):
    # Partition at cell headers; areas occur in cell scope before pin blocks.
    starts=list(re.finditer(r'\bcell\s*\(\s*"?([^\s"()]+)"?\s*\)\s*\{',text))
    cells={}
    for i,m in enumerate(starts):
        body=text[m.end():starts[i+1].start() if i+1<len(starts) else len(text)]
        area=re.search(r'\barea\s*:\s*([0-9.eE+-]+)',body)
        if area:cells[m[1]]=float(area[1])
    return cells

def git(path,*args):
    return subprocess.check_output(['git','-C',str(path),*args],text=True).strip()

def verify_pdk(root):
    result={}
    for name in ('asap7sc7p5t_28',):
        directory=root/name
        remote=git(directory,'remote','get-url','origin')
        if not remote.removesuffix('.git').endswith('The-OpenROAD-Project/'+name):
            raise ValueError(f'Unexpected upstream for {name}: {remote}')
        if git(directory,'status','--porcelain'):
            raise ValueError(f'{directory} is modified; keep the upstream checkout untouched')
        result[name]=dict(path=str(directory),remote=remote,commit=git(directory,'rev-parse','HEAD'))
    return result

def extract_7z(archive,destination):
    # libarchive is present on this host; no modifications/installations in PDK.
    lib=c.CDLL('libarchive.so.13')
    lib.archive_read_new.restype=c.c_void_p
    for fn in ('archive_read_support_filter_all','archive_read_support_format_all','archive_read_free'):
        getattr(lib,fn).argtypes=[c.c_void_p]
    lib.archive_read_open_filename.argtypes=[c.c_void_p,c.c_char_p,c.c_size_t]
    lib.archive_read_next_header.argtypes=[c.c_void_p,c.POINTER(c.c_void_p)]
    lib.archive_entry_pathname.argtypes=[c.c_void_p];lib.archive_entry_pathname.restype=c.c_char_p
    lib.archive_read_data.argtypes=[c.c_void_p,c.c_void_p,c.c_size_t];lib.archive_read_data.restype=c.c_ssize_t
    handle=lib.archive_read_new()
    try:
        lib.archive_read_support_filter_all(handle);lib.archive_read_support_format_all(handle)
        if lib.archive_read_open_filename(handle,str(archive).encode(),10240)!=0:
            raise ValueError(f'Cannot open {archive}')
        entry=c.c_void_p();outputs=[]
        while True:
            status=lib.archive_read_next_header(handle,c.byref(entry))
            if status==1:break
            if status!=0:raise ValueError(f'Archive header failure: {archive}')
            name=Path(lib.archive_entry_pathname(entry).decode()).name
            if not name.endswith('.lib'):raise ValueError(f'Unexpected archive entry: {name}')
            target=destination/name;buf=c.create_string_buffer(65536)
            with target.open('wb') as f:
                while True:
                    size=lib.archive_read_data(handle,buf,len(buf))
                    if size==0:break
                    if size<0:raise ValueError(f'Archive read failure: {archive}')
                    f.write(buf.raw[:size])
            outputs.append(target)
        return outputs
    finally:lib.archive_read_free(handle)

def verify_area_units(root,libraries):
    text=(root/'asap7sc7p5t_28/LEF/asap7sc7p5t_28_R_1x_220121a.lef').read_text()
    lef={n:float(w)*float(h) for n,w,h in re.findall(
        r'MACRO\s+(\S+).*?SIZE\s+([\d.]+)\s+BY\s+([\d.]+)',text,re.S)}
    count=0
    for path in libraries:
        for name,area in liberty_cells(path.read_text()).items():
            if name not in lef or abs(area-lef[name])>1e-7:
                raise ValueError(f'Standard-cell area/1x LEF mismatch: {name}')
            count+=1
    return dict(stdcell_areas_checked=count,matches_1x_lef=True)

def prepare_libraries(root, out):
    provenance = verify_pdk(root)
    derived = out / 'derived_libraries'
    derived.mkdir(exist_ok=True)
    libdir = root / 'asap7sc7p5t_28/LIB/NLDM'
    libraries, archives = [], []
    for group in ('INVBUF', 'SIMPLE', 'AO', 'OA', 'SEQ'):
        candidates = sorted(libdir.glob(f'asap7sc7p5t_{group}_RVT_TT_nldm_*.lib.7z'))
        if len(candidates) != 1:
            raise ValueError(f'Expected one {group} RVT TT archive, found {candidates}')
        archive = candidates[0]
        libraries.extend(extract_7z(archive, derived))
        archives.append(dict(path=str(archive), sha256=hashlib.sha256(archive.read_bytes()).hexdigest()))
    units = verify_area_units(root, libraries)
    (out / 'pdk_provenance.json').write_text(json.dumps(dict(
        repositories=provenance, archives=archives, libraries=[str(p) for p in libraries], corner='RVT TT',
        stdcell_area_units='um^2 (native 1x library areas)', area_verification=units), indent=2)+'\n')
    if verify_pdk(root) != provenance:
        raise ValueError('Upstream checkout changed during library preparation')
    return libraries
