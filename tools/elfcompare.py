# Compara dos ELF de PS2: cabecera, segmentos y secciones. Uso: python elfcompare.py A B
import sys, hashlib
from elftools.elf.elffile import ELFFile
def info(p):
    f = open(p, 'rb'); e = ELFFile(f); d = open(p, 'rb').read()
    segs = [(s['p_type'], hex(s['p_vaddr']), s['p_filesz'], s['p_memsz']) for s in e.iter_segments()]
    secs = [(s.name, hex(s['sh_addr']), s['sh_size']) for s in e.iter_sections()]
    return dict(entry=hex(e.header['e_entry']), machine=e.header['e_machine'], flags=hex(e.header['e_flags']), size=len(d), sha1=hashlib.sha1(d).hexdigest(), segs=segs, secs=secs, sym=e.get_section_by_name('.symtab') is not None)
a, b = sys.argv[1:3]
A, B = info(a), info(b)
for k in ['size', 'sha1', 'entry', 'machine', 'flags', 'sym']: print(f"{k:8} {A[k]!s:45} {B[k]}")
print("segmentos A:", A['segs']); print("segmentos B:", B['segs'])
print("secciones A:", A['secs'][:30]); print("secciones B:", B['secs'][:30])
