import sys
sys.path.insert(0, '.')
from pathlib import Path
from assemble51 import assemble
body = Path('build/uart_demo.asm').read_text(encoding='utf-8')
drv = Path('build/uart_entry.asm').read_text(encoding='utf-8')
merged = Path('build/uart_full.asm')
merged.write_text(drv + '\n' + body, encoding='utf-8', newline='\n')
ihx = assemble(merged, Path('build'), 'uart_full', dseg_base=0x30, cseg_base=0x0000)
print('OK', ihx)
