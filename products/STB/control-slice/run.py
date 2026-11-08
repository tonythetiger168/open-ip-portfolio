# SPDX-License-Identifier: Apache-2.0
"""Reproducible real-RTL control conformance and passive-checker sensitivity."""
import copy
import hashlib
import json
import os
from pathlib import Path
import random
import subprocess
import sys
from datetime import datetime, timezone

from scoreboard import check, read_trace

ROOT=Path(__file__).resolve().parent
OUT=ROOT/'evidence'


def linux(path):
    if os.name!='nt': return str(path.resolve())
    return '/mnt/'+str(path.resolve())[0].lower()+'/'+str(path.resolve())[3:].replace('\\','/')


def command(args, logfile):
    prefix=['wsl','-d','Ubuntu','--exec'] if os.name=='nt' else []
    result=subprocess.run(prefix+args,capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=120)
    logfile.write_text(result.stdout+result.stderr,encoding='utf-8')
    if result.returncode:
        raise RuntimeError(f'{args[0]} exit {result.returncode}: {logfile}')
    return prefix+args


def generate(seed):
    rng=random.Random(seed); rows=[]
    def emit(rst=1,sel=0,en=0,wr=0,addr=0,data=0,strb=0,prot=0):
        rows.append([rst,sel,en,wr,addr,data,strb,prot])
    def transfer(addr,wr=0,data=0,strb=15,prot=0):
        emit(sel=1,wr=wr,addr=addr,data=data,strb=strb,prot=prot)
        emit(sel=1,en=1,wr=wr,addr=addr,data=data,strb=strb,prot=prot)
    emit(rst=0);emit(rst=0);emit()
    for page in (0x10000000,0x10001000):
        for offset in (0,4,8,12,16): transfer(page+offset)
        for strobe in range(16):
            transfer(page+16,1,rng.getrandbits(32),strobe,strobe%8)
            transfer(page+16,prot=strobe%8)
        for offset in (0,4,8,12):
            transfer(page+offset,1,0xffffffff,15)
            transfer(page+offset)
        # Child register hole, unaligned access, and high-address alias attack.
        for addr in (page+20,page+1,page+2,page+3,page+0x80000000):
            transfer(addr,1,0xdeadbeef)
            transfer(page+16)
    for _ in range(120):
        page=rng.choice((0x10000000,0x10001000))
        transfer(page+16,1,rng.getrandbits(32),rng.randrange(16),rng.randrange(8))
        transfer(page+16,prot=rng.randrange(8))
        if rng.randrange(5)==0: emit()
    # Reset aborts a prepared write. No accepted write is fabricated.
    emit(sel=1,wr=1,addr=0x10000010,data=0xffffffff,strb=15)
    emit(rst=0,sel=1,en=1,wr=1,addr=0x10000010,data=0xffffffff,strb=15)
    emit(rst=0);emit()
    transfer(0x10000010);transfer(0x10001010)
    transfer(0x00000010,1,0x12345678);transfer(0x10000010)
    emit()
    return rows


def main():
    OUT.mkdir(exist_ok=True)
    (OUT/'result.json').write_text('{"status":"INCOMPLETE"}\n',encoding='utf-8')
    if not __debug__: raise RuntimeError('optimized Python disables checker assertions')
    commands=[]
    pins=json.loads((ROOT/'sources.json').read_text(encoding='utf-8'))
    for pin in pins:
        data=(ROOT/pin['path']).read_bytes()
        assert hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()==pin['git_blob']
    command(['/usr/bin/iverilog','-V'],OUT/'tool-version.log')
    assert 'Icarus Verilog version 12.0' in (OUT/'tool-version.log').read_text(), 'unqualified tool version'
    results=[]; normal_rows=None
    for configuration in ('normal','overlap'):
        exe=OUT/(configuration+'.vvp')
        args=['/usr/bin/iverilog','-g2012','-Wall','-s','control_slice_tb']
        if configuration=='overlap': args+=['-DOVERLAP']
        args+=['-o',linux(exe)]+[linux(ROOT/p['path']) for p in pins]+[linux(ROOT/'control_slice_tb.sv')]
        commands.append(command(args,OUT/(configuration+'-build.log')))
        for seed in (1,17,20261102):
            name=f'{configuration}-{seed}'
            stim=OUT/(name+'.stim'); trace=OUT/(name+'.trace')
            stimulus=generate(seed)
            stim.write_text('\n'.join(' '.join(f'{v:x}' for v in row) for row in stimulus)+'\n')
            commands.append(command(['/usr/bin/vvp',linux(exe),'+stim='+linux(stim),'+trace='+linux(trace)],OUT/(name+'-run.log')))
            observed=read_trace(trace)
            assert len(observed)==len(stimulus), 'monitor lost cycles'
            # Separately establish that the driver consumed every intended cycle.
            for row,values in zip(observed,stimulus):
                assert [row[k] for k in ('rst','sel','en','wr','addr','data','strb','prot')]==values
            bins=check(observed,configuration=='overlap')
            if configuration=='normal':
                required=['reset','setup','idle','misaligned','unmapped','child_hole','read_compare','endpoint_0','endpoint_1']
                required += [f'strobe_{i}' for i in range(16)]+[f'prot_{i}' for i in range(8)]
                assert all(bins.get(k,0)>0 for k in required), bins
                normal_rows=observed
            else:
                assert bins.get('overlap',0)>0
            results.append(dict(configuration=configuration,seed=seed,cycles=len(observed),bins=bins,status='PASS'))
    mutations=[]
    selectors={
        'wrong_route':('route',lambda x:x['route']>0,3),
        'wrong_read_byte':('rd',lambda x:x['sel'] and x['en'] and not x['wr'] and x['addr']==0x10000010,1),
        'reset_ready':('ready',lambda x:not x['rst'],1),
        'wrong_strobe_forward':('child_strb',lambda x:x['route']>0,1),
        'wrong_write_forward':('child_wr',lambda x:x['route']>0,1),
        'wrong_protection_forward':('child_prot',lambda x:x['route']>0,1),
    }
    for name,(field,predicate,mask) in selectors.items():
        rows=copy.deepcopy(normal_rows)
        row=next(x for x in rows if predicate(x)); row[field]^=mask
        try: check(rows)
        except AssertionError as error: mutations.append(dict(name=name,status='DETECTED',witness=str(error)))
        else: raise AssertionError('checker missed '+name)
    rows=copy.deepcopy(normal_rows);del rows[3]
    try: check(rows)
    except AssertionError as error: mutations.append(dict(name='lost_cycle',status='DETECTED',witness=str(error)))
    else: raise AssertionError('checker missed lost cycle')
    # Fault the actual compiled router, rather than only altering a trace.
    source=(ROOT/'rtl/apb_window_router.sv').read_text()
    for name,old,new in (
        ('high_address_alias','paddr[31:12] ==','{1\'b0,paddr[30:12]} =='),
        ('unaligned_forward'," && paddr[1:0] == 2'b00",'')):
        assert old in source
        mutant=OUT/(name+'.sv'); mutant.write_text(source.replace(old,new))
        exe=OUT/(name+'.vvp');trace=OUT/(name+'.trace')
        args=['/usr/bin/iverilog','-g2012','-Wall','-s','control_slice_tb','-o',linux(exe),linux(mutant)]
        args += [linux(ROOT/p['path']) for p in pins if 'apb_window_router' not in p['path']]+[linux(ROOT/'control_slice_tb.sv')]
        commands.append(command(args,OUT/(name+'-build.log')))
        commands.append(command(['/usr/bin/vvp',linux(exe),'+stim='+linux(OUT/'normal-1.stim'),'+trace='+linux(trace)],OUT/(name+'-run.log')))
        try: check(read_trace(trace))
        except AssertionError as error: mutations.append(dict(name=name,status='DETECTED',witness=str(error),kind='actual RTL mutant'))
        else: raise AssertionError('checker missed RTL mutant '+name)
    evidence=[]
    from irq_wait import run as run_endpoint
    endpoint=run_endpoint(ROOT,OUT/'irq-wait',command,linux)
    results.extend(endpoint['runs']);mutations.extend(endpoint['mutations']);commands.extend(endpoint['commands'])
    for p in sorted(OUT.rglob('*')):
        if p.is_file() and p!=OUT/'result.json':
            evidence.append(dict(path=p.relative_to(OUT).as_posix(),sha256=hashlib.sha256(p.read_bytes()).hexdigest(),bytes=p.stat().st_size))
    own_hashes={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in
        (ROOT/'run.py',ROOT/'scoreboard.py',ROOT/'control_slice_tb.sv',ROOT/'sources.json',ROOT/'ci-workflow.yml',
         ROOT/'irq_wait.py',ROOT/'irq_wait_scoreboard.py',ROOT/'irq_wait_tb.sv')}
    report=dict(status='PASS',date='2026-11-02',scope='real-RTL APB control slice; not SoC/UVM/native coverage',
        executed_at_utc=datetime.now(timezone.utc).isoformat(),python_version=sys.version,host_platform=sys.platform,
        top='control_slice_tb',hierarchy=['u_router','u_reg0','u_reg0.u_core','u_reg1','u_reg1.u_core'],
        endpoint_top='irq_wait_tb',endpoint_hierarchy=['u_ep','u_ep.u_core'],
        endpoint_filelist=['rtl/AXI4_Lite_top.sv','rtl/AXI4_Lite_apb.sv','irq_wait_tb.sv'],
        filelist=[p['path'] for p in pins]+['control_slice_tb.sv'],
        parameters={'PAGE0':'0x10000','normal_PAGE1':'0x10001','overlap_PAGE1':'0x10000','DW':32,'AW':32},
        clock_reset='single 10ns bench clock; async active-low reset driven at negative edges; not SKU timing',
        ownership='routing fixture AXI idle; separate real endpoint AXI error/response-wait ledger',
        requirements=['STB-001 routing fixture','STB-002 APB strobes and bounded AXI response waits',
                      'STB-003 CSR/error IRQ/mask/set-wins/reset subset; not full codec RAL',
                      'STB-014 local reset only; no fabric drain','STB-022 checker sensitivity'],
        source_pins=pins,harness_sha256=own_hashes,commands=commands,runs=results,mutations=mutations,
        artifacts=evidence,native_coverage=None,
        native_metrics={m:dict(status='NOT_MEASURED',raw_hit=None,raw_total=None,exclusions=[]) for m in
            ('line','fsm_states','fsm_arcs','toggle_01','toggle_10','branch_true','branch_false','sva','functional')},
        physical='NOT_RUN')
    (OUT/'result.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(dict(runs=len(results),cycles=sum(r['cycles'] for r in results),
        checker_mutations=len(mutations),status='PASS',native_coverage='NOT_MEASURED'),indent=2))


if __name__=='__main__': main()
