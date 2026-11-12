# SPDX-License-Identifier: Apache-2.0
"""Fixed 5.052 image entry point: one real endpoint, one new stimulus/profile."""
from pathlib import Path
import json,hashlib,subprocess,shutil,sys,resource,copy,os
from campaign import generate,read_trace,check,INPUTS
ROOT=Path(__file__).resolve().parent
OUT=Path(os.environ.get('STB_CAMPAIGN_OUT',ROOT/'evidence'))
BUILD=Path('/tmp/stb-memory-campaign')
COMMANDS=[]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def run(args,name,allowed=False):
    p=subprocess.run(list(map(str,args)),capture_output=True,text=True,timeout=300,
        preexec_fn=lambda:resource.setrlimit(resource.RLIMIT_CORE,(0,0)))
    (OUT/(name+'.log')).write_text(p.stdout+p.stderr)
    COMMANDS.append(dict(argv=list(map(str,args)),exit_code=p.returncode,log=name+'.log'))
    if not allowed:assert p.returncode==0,name
    return p
def points(p):
    ans=[]
    for line in p.read_text().splitlines():
        if not line.startswith("C '"):continue
        key,count=line[3:].rsplit("' ",1);f={}
        for x in key.split('\x01'):
            if '\x02' in x:k,v=x.split('\x02',1);f[k]=v
        ans.append(dict(id=hashlib.sha256(key.encode()).hexdigest(),fields=f,hits=int(count)))
    return ans
def main():
    if not __debug__:raise RuntimeError('optimized Python rejected')
    OUT.mkdir(exist_ok=True);BUILD.mkdir(parents=True,exist_ok=True)
    report=dict(status='INCOMPLETE',profile='STB-ENDPOINT-MEMORY-01',scope='UNADOPTED_PR29_SINGLE_ENDPOINT_NEW_CONFIG',
        native_closure='NOT_CLOSED',exclusions=[],warnings_disabled=False)
    try:
        manifest=json.loads((ROOT/'profile.json').read_text())
        for path,expected in manifest['source_sha256'].items():assert sha(ROOT/path)==expected,path
        report['profile']=manifest
        report['checkout_sha']=os.environ.get('GITHUB_SHA','LOCAL_FIXED_SOURCE')
        report['ci_run_id']=os.environ.get('GITHUB_RUN_ID')
        dependency=ROOT.parent/'control-slice'
        if dependency.exists():
            for name in ['rtl/AXI4_Lite_top.sv','rtl/AXI4_Lite_apb.sv']:
                assert (dependency/name).read_bytes().replace(b'\r\n',b'\n')==(ROOT/name).read_bytes(),'proposal dependency drift'
        for p in ROOT.rglob('*'):
            if p.is_file() and p.suffix in ('.sv','.cpp','.py','.json') and 'evidence' not in p.parts:
                dest=BUILD/p.relative_to(ROOT);dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(p,dest)
        version=run(['verilator','--version'],'version').stdout.strip();assert version.startswith('Verilator 5.052 ')
        report['tool']=version
        rows,boundary=generate(with_boundary=True);stim=OUT/'campaign.stim'
        stim.write_text('\n'.join(' '.join(f'{v:x}' for v in row) for row in rows)+'\n')
        before_stim=OUT/'before.stim'
        before_stim.write_text('\n'.join(' '.join(f'{v:x}' for v in row) for row in rows[:boundary])+'\n')
        report['stimulus_sha256']=sha(stim);report['cycles']=len(rows)
        rtl=[BUILD/'rtl/AXI4_Lite_top.sv',BUILD/'rtl/AXI4_Lite_apb.sv'];tb=BUILD/'endpoint_memory_tb.sv'
        obj=BUILD/'obj'
        args=['verilator','--cc','--exe','--build','--timing','--assert','--coverage','--coverage-per-instance',
            '--coverage-max-width','8192','--timescale-override','1ns/1ps','--trace','--trace-depth','4','-j','2',
            '+define+STB_MEMORY_NATIVE','--top-module','endpoint_memory_tb','--prefix','Vnative_top','--Mdir',obj,
            '-o','native_sim',*rtl,tb,BUILD/'memory_contract.sv',BUILD/'sim_main.cpp']
        run(args,'native-build');binary=obj/'native_sim';report['binary_sha256']=sha(binary)
        run([binary,'+stim='+str(before_stim),'+trace='+str(OUT/'before.trace'),
             '+cov='+str(OUT/'before.dat'),'+wave='+str(OUT/'before.vcd'),'+verilator+seed+1'],'before-run')
        before_rows=read_trace(OUT/'before.trace');assert len(before_rows)==boundary
        assert all([x[k] for k in INPUTS]==row for x,row in zip(before_rows,rows[:boundary]))
        check(before_rows,require_complete=False)
        report['before']=dict(cycles=boundary,status='PASS_COMPLETE_MEMORY_INIT_READ_PREFIX',stimulus_sha256=sha(before_stim))
        for name in ['native','replay']:
            run([binary,'+stim='+str(stim),'+trace='+str(OUT/(name+'.trace')),
                 '+cov='+str(OUT/(name+'.dat')),'+wave='+str(OUT/(name+'.vcd')),'+verilator+seed+1'],name+'-run')
            observed=read_trace(OUT/(name+'.trace'))
            assert len(observed)==len(rows)
            assert all([x[k] for k in INPUTS]==row for x,row in zip(observed,rows)),'input echo'
            oracle=check(observed)
            sys.path.insert(0,str(BUILD));from irq_wait_scoreboard import check as prior_check
            prior_check(observed)
            report[name]=dict(oracle='PASS',prior_oracle='PASS',ledger=oracle)
        assert read_trace(OUT/'native.trace')==read_trace(OUT/'replay.trace'),'replay wire mismatch'
        assert {p['id']:p['hits'] for p in points(OUT/'native.dat')}=={p['id']:p['hits'] for p in points(OUT/'replay.dat')},'replay native mismatch'
        run(['verilator_coverage','--annotate',OUT/'annotated','--annotate-all',OUT/'native.dat'],'annotate')
        ps=points(OUT/'native.dat');metrics={};hier=set()
        before_points=points(OUT/'before.dat')
        a={p['id']:p for p in before_points};b={p['id']:p for p in ps}
        assert a.keys()==b.keys(),'native before/after ID drift'
        meaningful=lambda p:Path(p['fields'].get('f','')).name in ('AXI4_Lite_top.sv','AXI4_Lite_apb.sv','memory_contract.sv')
        assert all(b[k]['hits']>=v['hits'] for k,v in a.items() if meaningful(v)),'lost native hit/event count'
        new=[dict(id=k,fields=b[k]['fields'],before=v['hits'],after=b[k]['hits']) for k,v in a.items()
             if meaningful(v) and v['hits']==0 and b[k]['hits']>0]
        delta=dict(status='PASS_IDENTICAL_BUILD_IDS_NO_MERGE',before_sha256=sha(OUT/'before.dat'),
            after_sha256=sha(OUT/'native.dat'),binary_sha256=sha(binary),raw_ids=len(a),
            ids_identical=True,exclusions=[],new_points=new)
        (OUT/'before-after-identity.json').write_text(json.dumps(delta,indent=2)+'\n')
        (OUT/'before-native-points.json').write_text(json.dumps(before_points,indent=2)+'\n')
        report['before_after']=dict(ids_identical=True,raw_ids=len(a),new_points=len(new),denominator_unchanged=True,merged=False)
        for p in ps:
            f=p['fields']
            if Path(f.get('f','')).name not in ('AXI4_Lite_top.sv','AXI4_Lite_apb.sv'):continue
            kind=f.get('t');hier.add(f.get('h'))
            if kind=='toggle':kind='toggle_01' if f['o'].endswith('0->1') else 'toggle_10' if f['o'].endswith('1->0') else 'toggle_unknown'
            s=metrics.setdefault(kind,dict(raw_hit=0,raw_total=0,exclusions=[]));s['raw_total']+=1;s['raw_hit']+=int(p['hits']>0)
        report['dut_native_metrics']=metrics;report['dut_native_hierarchy']=sorted(hier)
        report['instance_status']='EXACT_SINGLE_ENDPOINT' if not any('*' in x for x in hier) else 'BLOCKED_INSTANCE_UNION'
        report['fsm_states']=report['fsm_arcs']=dict(status='NOT_MEASURED_NO_NATIVE_RECORDS',raw_total=None)
        assert not any(p['fields'].get('t','').startswith('fsm') for p in ps)
        functional=[p for p in ps if p['fields'].get('t')=='covergroup' and p['fields'].get('f','').endswith('memory_contract.sv')]
        report['functional']=dict(raw_hit=sum(p['hits']>0 for p in functional),raw_total=len(functional),exclusions=[],
            status='PROPOSED_PROFILE_REQUIREMENTS_ONLY',inventory='functional-inventory.json')
        (OUT/'functional-inventory.json').write_text(json.dumps(functional,indent=2)+'\n')
        assert len(functional)==355,len(functional)
        assert all(p['hits']>0 for p in functional),[(p['fields'],p['hits']) for p in functional if not p['hits']]
        covers={p['fields']['o']:p['hits'] for p in ps if p['fields'].get('t')=='user' and p['fields'].get('f','').endswith('memory_contract.sv')}
        witnesses={}
        for name,sw in oracle['passive_sva_witnesses'].items():
            assert covers[name+'_ante']==sw['antecedent'] and covers[name+'_done']==sw['completed'],(name,covers,sw)
            witnesses[name]=dict(native_antecedent=covers[name+'_ante'],native_completed=covers[name+'_done'],
                passive_antecedent=sw['antecedent'],passive_completed=sw['completed'])
        assert len(covers)==16 and len(witnesses)==8
        report['sva_witnesses']=dict(declared_properties=8,native_user_witness_points=dict(raw_hit=16,raw_total=16),
            properties=witnesses,full_native_assertion_inventory=dict(status='NOT_MEASURED',raw_total=None))
        (OUT/'native-points.json').write_text(json.dumps(ps,indent=2)+'\n')
        # Actual source mutations remain qualification runs, never native coverage inputs.
        core=(rtl[0]).read_text();cases=[('ignore_strobes','if (wstrb[b])',"if (1'b1)"),
            ('bvalid_needs_ready','bvalid  = (wstate == W_RESP);','bvalid  = (wstate == W_RESP) && bready;'),
            ('corrupt_read','rdata   = rdata_mux;',"rdata   = rdata_mux ^ 32'h1;")]
        mutants=[]
        # Image has no Icarus: run each tiny compiled mutant in the same native build policy.
        # Use no extra assertions/coverage here: independent passive oracle must detect it.
        for name,old,new in cases:
            assert core.count(old)==1,name
            f=BUILD/(name+'.sv');f.write_text(core.replace(old,new));mobj=BUILD/name
            cmd=['verilator','--cc','--exe','--build','--timing','--timescale-override','1ns/1ps','--trace',
                 '--trace-depth','4','-j','2','--top-module','endpoint_memory_tb','--prefix','Vnative_top',
                 '--Mdir',mobj,'-o','native_sim',f,rtl[1],tb,BUILD/'sim_main.cpp']
            # C++ coverage writer requires native coverage support; same instrumentation, no helper contract.
            cmd.insert(1,'--coverage')
            run(cmd,name+'-build')
            run([mobj/'native_sim','+stim='+str(stim),'+trace='+str(OUT/(name+'.trace')),
                 '+cov='+str(OUT/(name+'.dat')),'+wave='+str(OUT/(name+'.vcd')),'+verilator+seed+1'],name+'-run')
            try:check(read_trace(OUT/(name+'.trace')))
            except AssertionError as e:mutants.append(dict(name=name,status='DETECTED',kind='actual compiled RTL mutant',witness=str(e)))
            else:raise AssertionError('missed mutant '+name)
        report['mutants']=mutants;report['status']='PASS_CAMPAIGN_NOT_SIX_METRIC_CLOSURE'
        print(json.dumps(dict(status=report['status'],cycles=report['cycles'],metrics=metrics,functional=report['functional'],witnesses=witnesses,mutants=mutants)),flush=True)
    finally:
        report['commands']=COMMANDS
        source=OUT/'frozen-profile';source.mkdir(exist_ok=True)
        for name in list(report.get('profile',{}).get('source_sha256',{}))+['profile.json','analyze_campaign.py']:
            if (ROOT/name).exists():
                dest=source/name;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(ROOT/name,dest)
        (OUT/'result.json').write_text(json.dumps(report,indent=2)+'\n')
        index={str(p.relative_to(OUT)):sha(p) for p in OUT.rglob('*') if p.is_file() and p.name!='artifact-index.json'}
        (OUT/'artifact-index.json').write_text(json.dumps(index,indent=2)+'\n')
if __name__=='__main__':main()
