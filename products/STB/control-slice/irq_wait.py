# SPDX-License-Identifier: Apache-2.0
"""Actual endpoint error-IRQ and AXI response-backpressure campaigns."""
import copy
import hashlib
import json
import random

from irq_wait_scoreboard import INPUTS, check, read_trace


def stimulus(seed):
    rng=random.Random(seed); rows=[]
    def emit(**values):
        x=dict.fromkeys(INPUTS,0);x['rst']=1;x.update(values);rows.append([x[k] for k in INPUTS])
    def apb(a,wr=0,data=0,strb=15):
        emit(sel=1,addr=a,wr=wr,data=data,strb=strb)
        emit(sel=1,en=1,addr=a,wr=wr,data=data,strb=strb)
    def wait():
        for _ in range(rng.randint(2,5)):emit()
    emit(rst=0);emit(rst=0);emit()
    # Initialize actual memory before any valid read; hold successful B/R.
    value=rng.getrandbits(32)
    emit(av=1,awaddr=0);emit(wv=1,wd=value,ws=15);wait();emit(br=1);emit()
    emit(rv=1,araddr=0);wait();emit(rr=1);emit()
    # Real accepted erroneous AW produces sticky core IRQ and SLVERR B.
    emit(av=1,awaddr=rng.choice((1024,1)));emit(wv=1,wd=0xdeadbeef,ws=15);wait()
    apb(4);apb(8,1,1);apb(4);apb(4,1,1);apb(4)
    apb(8,1,0);apb(8,1,1,0);apb(8);apb(8,1,1);apb(4)
    # Local reset clears source/pending and aborts the pending response.
    # This does not assert SoC fabric drain or security zeroization.
    emit(rst=0);emit(rst=0);emit();apb(4);apb(8)
    # Memory is not reset by this core. Verify known retained data.
    emit(rv=1,araddr=0);wait();emit(rr=1);emit()
    # Real erroneous AR; hold its response while servicing IRQ through APB.
    emit(rv=1,araddr=rng.choice((1024,2)));wait();apb(4);apb(8,1,1);apb(4,1,1);apb(4)
    emit(rst=0);emit(rst=0);emit();apb(4);apb(8);emit()
    return rows


def run(root,out,command,linux):
    out.mkdir(parents=True,exist_ok=True)
    (out/'result.json').write_text('{"status":"INCOMPLETE"}\n')
    if not __debug__:raise RuntimeError('optimized Python disables checker assertions')
    wrapper=root/'rtl/AXI4_Lite_apb.sv';core=root/'rtl/AXI4_Lite_top.sv';tb=root/'irq_wait_tb.sv'
    exe=out/'endpoint.vvp'
    commands=[command(['/usr/bin/iverilog','-g2012','-Wall','-s','irq_wait_tb','-o',linux(exe),linux(core),linux(wrapper),linux(tb)],out/'build.log')]
    runs=[];sample=None
    for seed in (1,17,20261102):
        stim=out/f'{seed}.stim';trace=out/f'{seed}.trace'; values=stimulus(seed)
        stim.write_text('\n'.join(' '.join(f'{v:x}' for v in row) for row in values)+'\n')
        commands.append(command(['/usr/bin/vvp',linux(exe),'+stim='+linux(stim),'+trace='+linux(trace)],out/f'{seed}-run.log'))
        rows=read_trace(trace);assert len(rows)==len(values)
        assert all([x[k] for k in INPUTS]==v for x,v in zip(rows,values))
        bins=check(rows)
        required=('b_wait','r_wait','b_error','r_error','irq_masked','irq_unmasked','w1c_set_wins',
                  'reset_pending_irq','reset_pending_b','reset_pending_r','b_complete','r_complete','csr_read_compare')
        assert all(bins.get(k,0)>0 for k in required),bins
        runs.append(dict(configuration='real-endpoint-irq-axi-wait',seed=seed,cycles=len(rows),bins=bins,status='PASS'))
        if seed==1:sample=rows
    mutants=[]
    for name,field,predicate in (
        ('lost_irq','irq',lambda x:x['irq']==1),
        ('wrong_bresp','bresp',lambda x:x['bvalid'] and not x['br']),
        ('changed_stalled_rdata','rdata',lambda x:x['rvalid'] and not x['rr'])):
        rows=copy.deepcopy(sample);next(x for x in rows if predicate(x))[field]^=1
        try:check(rows)
        except AssertionError as error:mutants.append(dict(name=name,status='DETECTED',witness=str(error),kind='observation mutation'))
        else:raise AssertionError('missed endpoint observation mutant '+name)
    cases=(
        ('irq_mask_bypass',wrapper,'assign irq = |(irq_status & irq_enable);','assign irq = |irq_status;'),
        ('w1c_clear_wins',wrapper,"irq_status <= (irq_status & ~((wr && hit[1]) ? PWDATA[0:0] & wmask[0:0] : '0)) | irq_set;",
         "irq_status <= (irq_status | irq_set) & ~((wr && hit[1]) ? PWDATA[0:0] & wmask[0:0] : '0);"),
        ('bvalid_requires_ready',core,'bvalid  = (wstate == W_RESP);','bvalid  = (wstate == W_RESP) && bready;'),
        ('rvalid_requires_ready',core,'rvalid  = (rstate == R_DATA);','rvalid  = (rstate == R_DATA) && rready;'))
    for name,path,old,new in cases:
        source=path.read_text();assert source.count(old)==1,name
        mutant=out/(name+'.sv');mutant.write_text(source.replace(old,new))
        files=[mutant if path==core else core,mutant if path==wrapper else wrapper,tb]
        binary=out/(name+'.vvp');trace=out/(name+'.trace')
        commands.append(command(['/usr/bin/iverilog','-g2012','-Wall','-s','irq_wait_tb','-o',linux(binary)]+[linux(p) for p in files],out/(name+'-build.log')))
        commands.append(command(['/usr/bin/vvp',linux(binary),'+stim='+linux(out/'1.stim'),'+trace='+linux(trace)],out/(name+'-run.log')))
        try:check(read_trace(trace))
        except AssertionError as error:mutants.append(dict(name=name,status='DETECTED',witness=str(error),kind='actual RTL mutant'))
        else:raise AssertionError('missed actual endpoint RTL mutant '+name)
    artifacts=[dict(path=p.name,sha256=hashlib.sha256(p.read_bytes()).hexdigest(),bytes=p.stat().st_size)
               for p in sorted(out.iterdir()) if p.is_file() and p.name!='result.json']
    report=dict(status='PASS',scope='pinned real AXI4_Lite_apb/core; APB stays zero-wait',runs=runs,mutations=mutants,
                commands=commands,artifacts=artifacts,native_coverage='NOT_MEASURED',
                contract_limits='isolated AXI read/write responses; no concurrent same-address overwrite, APB wait insertion, CDC, fabric drain or zeroization claim')
    (out/'result.json').write_text(json.dumps(report,indent=2)+'\n')
    return report


if __name__=='__main__':
    from run import ROOT, OUT, command, linux
    print(json.dumps(run(ROOT,OUT/'irq-wait',command,linux),indent=2))
