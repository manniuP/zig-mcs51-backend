; 纯 Zig 程序的复位启动（供 sdcc 链接用）。
; AI8051U 复位 PC = FF:0000，代码由 --code-loc 0xff0000 放在此。此文件在 HOME 区，
; 第一条即 `ejmp __start`；随后设 SPX 并 ECALL Zig 导出的 _main。
;
; 空声明 PSEG/ISEG/BSEG：sdcc 生成的 .lk 会对这些区发 `-b`，缺一个就报
; "No definition of area ..."。这里声明成空区即可满足。

	.module crt0
	.area PSEG    (PAG,XDATA)
	.area DSEG    (DATA)
	.area ISEG    (DATA)
	.area BSEG    (BIT)
	.area HOME    (CODE)

	.globl _main

	ejmp __start

__start:
	mov  spx,#0x0100
	ecall _main
	sjmp .
