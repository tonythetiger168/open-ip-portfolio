# SPDX-License-Identifier: Apache-2.0
"""Independent passive APB/CSR model; no DUT source/model imports."""
from collections import Counter

FIELDS = 'cycle rst sel en wr addr data strb prot route child_en child_wr child_addr child_data child_strb child_prot rd ready error irq'.split()


def read_trace(path):
    rows=[]
    for line in path.read_text().splitlines():
        words=line.split()
        if len(words)!=len(FIELDS):
            raise AssertionError('trace column count')
        rows.append(dict(zip(FIELDS,[int(words[0])]+[int(x,16) for x in words[1:]])))
    return rows


def check(rows, overlap=False):
    scratch=[0,0]; enable=[0,0]; bins=Counter(); previous=None
    if not rows:
        raise AssertionError('empty trace')
    for cycle,x in enumerate(rows):
        if x['cycle']!=cycle:
            raise AssertionError('lost/duplicate cycle')
        # Interval lookup independent of RTL's page equality/XOR expressions.
        windows=[(0x10000000,0x10001000),(0x10000000 if overlap else 0x10001000,
                                                 0x10001000 if overlap else 0x10002000)]
        matches=[i for i,(lo,hi) in enumerate(windows) if lo<=x['addr']<hi]
        valid=len(matches)==1 and x['addr']%4==0
        route=(1<<matches[0]) if valid and x['rst'] and x['sel'] else 0
        access=bool(x['rst'] and x['sel'] and x['en'])
        expected=dict(route=route,child_en=int(bool(route) and bool(x['en'])),
            child_wr=x['wr'],
            child_addr=x['addr']%4096,child_data=x['data'],child_strb=x['strb'],child_prot=x['prot'],
            ready=int(access),rd=0,error=0,irq=0)
        if not x['rst']:
            scratch=[0,0]; enable=[0,0]; bins['reset']+=1
        elif access:
            bins['accepted']+=1
            if not valid:
                expected['error']=1
                bins['overlap' if len(matches)>1 else 'misaligned' if x['addr']%4 else 'unmapped']+=1
            else:
                i=matches[0]; offset=x['addr']-windows[i][0]
                bins[f'endpoint_{i}']+=1
                expected['error']=int(offset not in (0,4,8,12,16))
                if expected['error']:
                    bins['child_hole']+=1
                elif not x['wr']:
                    expected['rd']={0:0x414C0200,4:0,8:enable[i],12:0,16:scratch[i]}[offset]
                    bins['read_compare']+=1
                elif offset==16:
                    # Byte-array update instead of copying the RTL's bit-mask equation.
                    old=bytearray(scratch[i].to_bytes(4,'little'))
                    new=x['data'].to_bytes(4,'little')
                    for byte in range(4):
                        if x['strb'] & (1<<byte): old[byte]=new[byte]
                    scratch[i]=int.from_bytes(old,'little')
                    bins[f'strobe_{x["strb"]}']+=1
                elif offset==8 and x['strb']&1:
                    enable[i]=x['data']%2
            bins[f'prot_{x["prot"]}']+=1
        else:
            bins['setup' if x['sel'] else 'idle']+=1
        for field,value in expected.items():
            if x[field]!=value:
                raise AssertionError(f'cycle {cycle}: {field} got {x[field]:x}, expected {value:x}')
        # Legal APB setup/access controls must remain stable until completion.
        if previous and previous['rst'] and x['rst'] and previous['sel'] and not previous['en']:
            if not x['sel'] or not x['en'] or any(x[k]!=previous[k] for k in ('wr','addr','data','strb','prot')):
                raise AssertionError(f'cycle {cycle}: unstable setup/access')
        previous=x
    return dict(bins)
