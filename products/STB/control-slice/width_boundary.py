# SPDX-License-Identifier: Apache-2.0
"""Exhaustive guarded-address equivalence and real endpoint negative tests."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
from irq_wait_scoreboard import INPUTS, read_trace, check

ROOT=Path(__file__).resolve().parent
OUT=ROOT/'width-evidence'

def main():
    if not __debug__: raise RuntimeError('optimized Python rejected')
    OUT.mkdir(exist_ok=True)
    baseline=Path(sys.argv[1]).resolve()
    rows=[]
    def emit(**kw):
        x=dict.fromkeys(INPUTS,0);x['rst']=1;x.update(kw)
        rows.append([x[k] for k in INPUTS])
    def apb(a,wr=0,data=0,strb=15):
        emit(sel=1,addr=a,wr=wr,data=data,strb=strb)
        emit(sel=1,en=1,addr=a,wr=wr,data=data,strb=strb)
    emit(rst=0);emit(rst=0);emit()
    # Every 12-bit value: includes offsets 17..31 and all high-bit aliases.
    for a in range(4096):
        apb(16,1,0x12345678)
        apb(a,1,0xa5a5a5a5)
        apb(a)
        apb(16)
    for strobe in range(16):
        for data in (0,0xffffffff,0x80000000,0x7fffffff):
            apb(16,1,data,strobe);apb(16)
    emit()
    stim=OUT/'boundary.stim'
    stim.write_text('\n'.join(' '.join(f'{v:x}' for v in r) for r in rows)+'\n')
    # Test actual SystemVerilog decode and signed integer truth conversion.
    probe=OUT/'width_probe.sv'
    probe.write_text('''module width_probe;
      reg [11:0] a; reg [4:0] old_hit,new_hit,bad_hit;
      integer i,j,fd; integer aliases;
      initial begin
        aliases=0;
        for(i=0;i<4096;i=i+1) begin
          a=12'(i);old_hit=0;new_hit=0;bad_hit=0;
          if(a[1:0]==0 && a[11:2]<10'd5) old_hit[a[11:2]]=1;
          if(a[1:0]==0 && a[11:2]<10'd5) new_hit[a[4:2]]=1;
          if(a[1:0]==0 && a[4:2]<3'd5) bad_hit[a[4:2]]=1;
          if(old_hit!==new_hit) $fatal(1,"decode mismatch %h",a);
          if(old_hit!==bad_hit) aliases=aliases+1;
        end
        for(j=0;j<8;j=j+1) begin
          case(j)
            0:fd=0;1:fd=1;2:fd=-1;3:fd=32'h80000000;
            4:fd=32'h7fffffff;5:fd=32'h80000001;
            6:fd=32'h00010000;7:fd=32'hfffffffe;
          endcase
          if((!fd)!==(fd==0)) $fatal(1,"file handle mismatch");
        end
        if(aliases!=635) $fatal(1,"alias negative mutation missed");
        $display("PASS 4096 addresses, 8 signed handles, 635 alias negatives");
      end
    endmodule
''')
    commands=[]
    def run(args,log):
        p=subprocess.run(list(map(str,args)),capture_output=True,text=True,timeout=180)
        (OUT/log).write_text(p.stdout+p.stderr)
        commands.append(dict(argv=list(map(str,args)),exit_code=p.returncode,log=log))
        assert p.returncode==0,log
    run(['iverilog','-g2012','-s','width_probe','-o',OUT/'probe.vvp',probe],'probe-build.log')
    run(['vvp',OUT/'probe.vvp'],'probe-run.log')
    traces=[]
    for name,source in [('original',baseline),('proposed',ROOT)]:
        exe=OUT/(name+'.vvp');trace=OUT/(name+'.trace')
        run(['iverilog','-g2012','-s','irq_wait_tb','-o',exe,
             source/'rtl/AXI4_Lite_top.sv',source/'rtl/AXI4_Lite_apb.sv',source/'irq_wait_tb.sv'],name+'-build.log')
        run(['vvp',exe,'+stim='+str(stim),'+trace='+str(trace)],name+'-run.log')
        observed=read_trace(trace)
        assert len(observed)==len(rows)
        assert all([x[k] for k in INPUTS]==row for x,row in zip(observed,rows))
        check(observed);traces.append(observed)
    assert traces[0]==traces[1], 'wire-level regression'
    hashes={str(p.relative_to(OUT)):hashlib.sha256(p.read_bytes()).hexdigest()
            for p in OUT.iterdir() if p.is_file() and p.name!='result.json'}
    sources={name:{str(p.relative_to(source)):hashlib.sha256(p.read_bytes()).hexdigest()
             for p in [source/'rtl/AXI4_Lite_top.sv',source/'rtl/AXI4_Lite_apb.sv',source/'irq_wait_tb.sv']}
             for name,source in [('original',baseline),('proposed',ROOT)]}
    report=dict(status='PASS',cycles=len(rows),addresses=4096,signed_handles=8,
        rejected_alias_mutations=635,wire_trace_equal=True,independent_oracle='PASS',
        source_sha256=sources,artifacts=hashes,commands=commands,native_coverage='NOT_MEASURED')
    (OUT/'result.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k not in ('artifacts','commands','source_sha256')}))

if __name__=='__main__':main()
