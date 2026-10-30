import sys, subprocess, os
sys.path.insert(0, '.')
from pathlib import Path
from assemble51 import assemble
root = Path(r'E:/code/yuyan')
zig = root / 'zig017' / 'mcs2build' / 'zig-out' / 'bin' / 'zig.exe'
env = dict(os.environ)
env['ZIG_LIB_DIR'] = str(root / 'zig-0.17' / 'lib')
env['ZIG_GLOBAL_CACHE_DIR'] = str(root / 'zig017' / 'cbg')
env['ZIG_LOCAL_CACHE_DIR'] = str(root / 'zig017' / 'cbgl')
asm = Path('build/pe.asm')
subprocess.run([str(zig), 'build-obj', '-OReleaseSmall', '-target', 'mcs51-freestanding',
                '-femit-bin=' + str(asm), 'tests/pe.zig'], check=True, env=env)
body = asm.read_text(encoding='utf-8')
drv = Path('build/qemu_driver.asm').read_text(encoding='utf-8')
merged = Path('build/qemu_pe.asm')
merged.write_text(drv.replace('_loop_sum_to', '_pe_sum') + '\n' + body, encoding='utf-8', newline='\n')
ihx = assemble(merged, Path('build'), 'qemu_pe', dseg_base=0x30, cseg_base=0xFF0000)
print('OK', ihx)
