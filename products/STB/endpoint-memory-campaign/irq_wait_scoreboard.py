# SPDX-License-Identifier: Apache-2.0
"""Independent accepted-transaction ledger and IRQ/CSR predictor."""
from collections import Counter

INPUTS='rst sel en wr addr data strb awaddr av wd ws wv br araddr rv rr'.split()
FIELDS=['cycle']+INPUTS+'rd ready error irq core_irq awready wready bvalid bresp arready rvalid rresp rdata'.split()


def read_trace(path):
    rows=[]
    for line in path.read_text().splitlines():
        w=line.split()
        if len(w)!=len(FIELDS): raise AssertionError('IRQ trace column count')
        rows.append(dict(zip(FIELDS,[int(w[0])]+[int(x,16) for x in w[1:]])))
    return rows


def check(rows):
    memory={}; address=None; response=None; read=None
    pending=enable=source=scratch=0; bins=Counter(); previous=None
    for cycle,x in enumerate(rows):
        if x['cycle']!=cycle: raise AssertionError('IRQ lost/duplicate cycle')
        if not x['rst']:
            if source or pending: bins['reset_pending_irq']+=1
            if response is not None: bins['reset_pending_b']+=1
            if read is not None: bins['reset_pending_r']+=1
            address=response=read=None;pending=enable=source=scratch=0
        expected=dict(ready=int(bool(x['sel'] and x['en'])),error=0,rd=0,
            irq=int(bool(pending and enable)),core_irq=source,
            awready=int(address is None and response is None),wready=int(address is not None),
            bvalid=int(response is not None),arready=int(read is None),rvalid=int(read is not None))
        access=bool(x['rst'] and x['sel'] and x['en'])
        valid=x['addr'] in (0,4,8,12,16)
        if access:
            expected['error']=int(not valid)
            if valid and not x['wr']:
                expected['rd']={0:0x414c0200,4:pending,8:enable,12:0,16:scratch}[x['addr']]
                bins['csr_read_compare']+=1
        if response is not None: expected['bresp']=response
        if read is not None: expected['rresp'],expected['rdata']=read
        for field,value in expected.items():
            if x[field]!=value: raise AssertionError(f'IRQ cycle{cycle}: {field} got{x[field]:x}, expected{value:x}')
        if previous and previous['rst'] and x['rst'] and previous['sel'] and not previous['en']:
            if not x['sel'] or not x['en'] or any(x[k]!=previous[k] for k in ('wr','addr','data','strb')):
                raise AssertionError('IRQ APB setup unstable')
        previous=x
        if not x['rst']: continue
        if source and not enable: bins['irq_masked']+=1
        if pending and enable: bins['irq_unmasked']+=1
        if response is not None and not x['br']: bins['b_wait']+=1
        if read is not None and not x['rr']: bins['r_wait']+=1
        if response==2: bins['b_error']+=1
        if read is not None and read[0]==2: bins['r_error']+=1
        # Wrapper captures the previous cycle's sticky source. Set wins W1C.
        clear=int(access and valid and x['wr'] and x['addr']==4 and x['strb']&1 and x['data']&1)
        if clear and source: bins['w1c_set_wins']+=1
        pending=(pending & (1-clear)) | source
        if access and valid and x['wr']:
            if x['addr']==8 and x['strb']&1: enable=x['data']&1
            if x['addr']==16:
                old=bytearray(scratch.to_bytes(4,'little')); new=x['data'].to_bytes(4,'little')
                for i in range(4):
                    if x['strb']&(1<<i): old[i]=new[i]
                scratch=int.from_bytes(old,'little')
        # Consume old responses before admitting newly accepted requests.
        if response is not None and x['br']: response=None;bins['b_complete']+=1
        if read is not None and x['rr']: read=None;bins['r_complete']+=1
        aw=bool(x['av'] and x['awready']); wd=bool(x['wv'] and x['wready']); ar=bool(x['rv'] and x['arready'])
        if aw:
            ok=x['awaddr']%4==0 and x['awaddr']<1024
            address=(x['awaddr'],ok);source|=int(not ok);bins['aw_accept']+=1
        if wd:
            a,ok=address
            if ok:
                if a not in memory and x['ws']!=15: raise AssertionError('first write must initialize all bytes')
                old=bytearray(memory.get(a,0).to_bytes(4,'little'));new=x['wd'].to_bytes(4,'little')
                for i in range(4):
                    if x['ws']&(1<<i): old[i]=new[i]
                memory[a]=int.from_bytes(old,'little')
            response=0 if ok else 2;address=None
        if ar:
            a=x['araddr'];ok=a%4==0 and a<1024
            if ok and a not in memory: raise AssertionError('uninitialized memory read in campaign')
            read=(0,memory[a]) if ok else (2,0);source|=int(not ok);bins['ar_accept']+=1
    if address is not None or response is not None or read is not None: raise AssertionError('outstanding endpoint traffic at end')
    return dict(bins)
