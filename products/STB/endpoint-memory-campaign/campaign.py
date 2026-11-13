# SPDX-License-Identifier: Apache-2.0
"""Single deterministic legal memory profile; independent bytearray/passive oracle."""
from collections import Counter
INPUTS='rst sel en wr addr data strb awaddr av wd ws wv br araddr rv rr'.split()
FIELDS=['cycle']+INPUTS+'rd ready error irq core_irq awready wready bvalid bresp arready rvalid rresp rdata'.split()
def generate(with_boundary=False):
    rows=[]
    def emit(**kw):
        x=dict.fromkeys(INPUTS,0);x['rst']=1;x.update(kw);rows.append([x[k] for k in INPUTS])
    def apb(a,wr=0,data=0,strb=15):
        emit(sel=1,addr=a,wr=wr,data=data,strb=strb);emit(sel=1,en=1,addr=a,wr=wr,data=data,strb=strb)
    def write(a,data,ws=15,order=0,wait=0,csr=False):
        if order==1:
            emit(wv=1,wd=data,ws=ws);emit(wv=1,wd=data,ws=ws)
            emit(av=1,awaddr=a,wv=1,wd=data,ws=ws)
        elif order==2:emit(av=1,awaddr=a,wv=1,wd=data,ws=ws)
        else:emit(av=1,awaddr=a);emit();emit()
        emit(wv=1,wd=data,ws=ws)
        if csr:apb(16,1,data,ws);apb(16)
        else:
            for _ in range(wait):emit()
        emit(br=1);emit()
    def read(a,wait=0,csr=False):
        emit(rv=1,araddr=a)
        if csr:apb(4);apb(8)
        else:
            for _ in range(wait):emit()
        emit(rr=1);emit()
    emit(rst=0);emit(rst=0);emit();apb(0);apb(4);apb(8,1,1);apb(8)
    # Initialize all 1024 bytes, never rely on simulator initialization.
    for word in range(256):write(word*4,((word*0x01010101)^0x96a53cc3)&0xffffffff,order=word%3,wait=word%3)
    for word in range(256):read(word*4,wait=word%3)
    boundary=len(rows)
    for order in range(3):
        for ws in range(16):
            a=(0,512,1020)[order];data=(0,0xffffffff,0xaaaaaaaa,0x55555555)[ws%4]
            write(a,data,ws,order,wait=ws%3,csr=order==0);read(a,wait=(ws+1)%3)
    # Walking data at last word, followed by byte-preservation readback.
    for bit in range(32):write(1020,1<<bit,15,bit%3,wait=1);read(1020,wait=2)
    # A read remains stable while a write updates a different initialized word.
    emit(av=1,awaddr=0,rv=1,araddr=4);emit(wv=1,wd=0xaabbccdd,ws=15)
    for _ in range(4):emit()
    emit(br=1,rr=1);emit();read(0)
    # Hold a new AW behind an old pending B, including its acceptance boundary.
    emit(av=1,awaddr=8);emit(wv=1,wd=0x12345678,ws=15)
    for _ in range(3):emit(av=1,awaddr=12)
    emit(av=1,awaddr=12,br=1);emit(av=1,awaddr=12)
    emit(wv=1,wd=0xabcdef01,ws=15);emit();emit(br=1);emit();read(8);read(12)
    # Hold new AR behind old R, keeping both address and R payload stable.
    emit(rv=1,araddr=16)
    for _ in range(3):emit(rv=1,araddr=20)
    emit(rv=1,araddr=20,rr=1);emit(rv=1,araddr=20);emit();emit(rr=1);emit()
    apb(8,1,0);apb(8);apb(4);apb(16);emit()
    return (rows,boundary) if with_boundary else rows
def read_trace(path):
    ans=[]
    for line in path.read_text().splitlines():
        words=line.split();assert len(words)==len(FIELDS),'column count'
        ans.append(dict(zip(FIELDS,[int(words[0])]+[int(x,16) for x in words[1:]])))
    return ans
def check(rows,require_complete=True):
    # Independent byte storage/defined mask, not a copy of DUT word-array FSM.
    mem=bytearray(1024);defined=bytearray(1024);aw=None;read=None;bcredit=0
    bins=Counter();previous=None;ante=Counter();done=Counter();awfirst=None;wfirst=None
    pending=enable=source=scratch=0
    rules={'aw_hold':('av','awready',('awaddr',)), 'w_hold':('wv','wready',('wd','ws')),
           'ar_hold':('rv','arready',('araddr',)), 'b_hold':('bvalid','br',('bresp',)),
           'r_hold':('rvalid','rr',('rresp','rdata'))}
    for cycle,x in enumerate(rows):
        assert x['cycle']==cycle,'lost/duplicate trace cycle'
        if previous and previous['rst'] and x['rst']:
            for name,(valid,ready,payload) in rules.items():
                if previous[valid] and not previous[ready]:
                    assert x[valid] and all(x[k]==previous[k] for k in payload),name+' stability'
                    done[name]+=1
            if previous['wv'] and previous['wready']:assert x['bvalid'],'W->B';done['w_to_b']+=1
            if previous['rv'] and previous['arready']:assert x['rvalid'],'AR->R';done['ar_to_r']+=1
        previous=x
        if not x['rst']:
            aw=read=None;bcredit=0;awfirst=wfirst=None;pending=enable=source=scratch=0;continue
        for name,(valid,ready,_) in rules.items():ante[name]+=int(bool(x[valid] and not x[ready]))
        ante['w_to_b']+=int(bool(x['wv'] and x['wready']));ante['ar_to_r']+=int(bool(x['rv'] and x['arready']))
        assert x['ready']==int(bool(x['sel'] and x['en'])),'APB zero-wait'
        assert x['irq']==(pending&enable) and x['core_irq']==source,'IRQ'
        access=x['sel'] and x['en'];valid=x['addr'] in (0,4,8,12,16)
        if access:
            ante['apb_ready']+=1;done['apb_ready']+=int(bool(x['ready']))
            assert x['error']==int(not valid),'APB error'
            if not x['wr'] and valid:
                assert x['rd']=={0:0x414c0200,4:pending,8:enable,12:0,16:scratch}[x['addr']],'CSR read'
            if x['wr'] and valid:
                if x['addr']==8 and x['strb']&1:enable=x['data']&1
                if x['addr']==16:
                    b=bytearray(scratch.to_bytes(4,'little'));new=x['data'].to_bytes(4,'little')
                    for lane in range(4):
                        if x['strb']>>lane&1:b[lane]=new[lane]
                    scratch=int.from_bytes(b,'little');bins['csr_strobe_'+str(x['strb'])]+=1
            bins['csr_'+str(x['addr'])]+=1
        if x['bvalid']:
            assert bcredit==1 and x['bresp']==0,'unexpected/error B response'
            if x['br']:bcredit=0;bins['b_complete']+=1
            else:bins['b_stall']+=1
        if x['rvalid']:
            assert read is not None and x['rresp']==0,'unexpected/error R response'
            a,expected=read;assert x['rdata']==expected,f'bytearray read mismatch at {a:#x}'
            if x['rr']:read=None;bins['r_complete']+=1
            else:bins['r_stall']+=1
        if x['av'] and awfirst is None:awfirst=cycle
        if x['wv'] and wfirst is None:wfirst=cycle
        if x['av'] and x['awready']:
            assert aw is None and bcredit==0,'AW outstanding limit';a=x['awaddr']
            assert a%4==0 and 0<=a<=1020,'profile address';aw=a;bins['word_'+str(a//4)]+=1
        if x['wv'] and x['wready']:
            assert aw is not None,'W accepted without AW';assert read is None or read[0]!=aw,'same-address overwrite excluded'
            old=mem[aw:aw+4];data=x['wd'].to_bytes(4,'little')
            for lane in range(4):
                if x['ws']>>lane&1:mem[aw+lane]=data[lane];defined[aw+lane]=1
            assert all(mem[aw+i]==old[i] for i in range(4) if not x['ws']>>i&1),'byte preservation'
            order=0 if awfirst<wfirst else 1 if wfirst<awfirst else 2
            bins[f'order_{order}_strobe_{x["ws"]}']+=1;bins['write']+=1
            aw=None;bcredit=1;awfirst=wfirst=None
        if x['rv'] and x['arready']:
            a=x['araddr'];assert read is None and a%4==0 and 0<=a<=1020,'AR profile'
            assert all(defined[a:a+4]),'uninitialized read forbidden'
            read=(a,int.from_bytes(mem[a:a+4],'little'));bins['read']+=1
    assert aw is None and read is None and bcredit==0,'undrained ledger'
    assert all(defined),'not all memory bytes initialized'
    assert all(bins[f'word_{i}'] for i in range(256))
    if require_complete:
        assert all(bins[f'order_{o}_strobe_{s}'] for o in range(3) for s in range(16))
        assert all(ante[k]>0 and ante[k]==done[k] for k in list(rules)+['w_to_b','ar_to_r','apb_ready']),dict(ante)
    else:assert all(ante[k]==done[k] for k in ante),'prefix incomplete witness'
    return dict(bytearray_bytes=1024,initialized_bytes=sum(defined),transactions=dict(bins),
                passive_sva_witnesses={k:dict(antecedent=ante[k],completed=done[k]) for k in ante})
