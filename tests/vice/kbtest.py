#!/usr/bin/env python3
"""Unit test for scan_keyboard in the py65 6502 simulator (no VICE needed).

A fake CIA1 returns matrix rows for the column selected in $DC00.  Checks the
KERNAL matrix code, SHIFT detection, the $CB mirror and the cycle cost.

usage: kbtest.py <labels.txt> <scroll.prg>     (needs: pip install py65)
Exit code 0 = pass.
"""
import sys
from mon import load_labels
from py65.devices.mpu6502 import MPU
from py65.memory import ObservableMemory
lab=load_labels(sys.argv[1])
prg=open(sys.argv[2],'rb').read(); load=prg[0]|prg[1]<<8; body=prg[2:]
def run(pressed):           # pressed: set of KERNAL matrix codes (col*8+row)
    mem=ObservableMemory()
    for i,b in enumerate(body): mem[load+i]=b
    st={'dc00':0xff}
    def w(addr,val): st['dc00']=val
    def r(addr):
        v=0xff
        for code in pressed:
            col,row=code>>3,code&7
            if not (st['dc00']>>col)&1: v&=~(1<<row)
        return v&0xff
    mem.subscribe_to_write([0xdc00],w); mem.subscribe_to_read([0xdc01],r)
    cpu=MPU(memory=mem); cpu.sp=0xff
    mem[0x0300]=0x20; mem[0x0301]=lab['scan_keyboard']&255; mem[0x0302]=lab['scan_keyboard']>>8
    cpu.pc=0x0300; n=0
    while cpu.pc!=0x0303: cpu.step(); n+=1
    return mem[lab['kb_code']],mem[lab['kb_shift']],cpu.processorCycles,mem[0xcb]
LSH,RSH,CTRL,CBM=0x0F,0x34,0x3A,0x3D
cases=[("none",set(),0x40,0),("L-SHIFT",{LSH},0x40,1),("R-SHIFT",{RSH},0x40,1),
 ("1",{0x38},0x38,0),("0",{0x23},0x23,0),("5",{0x10},0x10,0),("9",{0x20},0x20,0),
 ("F1",{0x04},0x04,0),("F3",{0x05},0x05,0),("T",{0x16},0x16,0),(",",{0x2F},0x2F,0),(".",{0x2C},0x2C,0),
 ("SHIFT+7",{LSH,0x18},0x18,1),("RSHIFT+2",{RSH,0x3B},0x3B,1),("CTRL",{CTRL},0x40,0),("C=",{CBM},0x40,0),
 ("SHIFT+CTRL+8",{LSH,CTRL,0x1B},0x1B,1)]
ok=True; cyc=[]
for name,keys,ecode,eshift in cases:
    code,sh,c,cb=run(keys); cyc.append(c)
    good = code==ecode and bool(sh)==bool(eshift) and cb==code
    ok&=good
    print("%-14s code $%02X shift %d  cycles %4d  %s"%(name,code,sh!=0,c,"ok" if good else "FAIL (want $%02X/%d)"%(ecode,eshift)))
print("PASS" if ok else "FAIL", " max cycles",max(cyc))
sys.exit(0 if ok else 1)
