# SPDX-License-Identifier: Apache-2.0
"""Require exact native/profile bin domains and passive event-count agreement."""
from pathlib import Path
from collections import Counter
import json,hashlib,re,os
from campaign import read_trace,check
ROOT=Path(__file__).resolve().parent;OUT=Path(os.environ.get('STB_CAMPAIGN_OUT',ROOT/'evidence'))
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    profile=json.loads((ROOT/'profile.json').read_text());result=json.loads((OUT/'result.json').read_text())
    assert result['status']=='PASS_CAMPAIGN_NOT_SIX_METRIC_CLOSURE'
    assert all(sha(ROOT/k)==v for k,v in profile['source_sha256'].items())
    rows=read_trace(OUT/'native.trace');oracle=check(rows)
    assert rows==read_trace(OUT/'replay.trace')
    identity=json.loads((OUT/'before-after-identity.json').read_text())
    assert identity['ids_identical'] and identity['status']=='PASS_IDENTICAL_BUILD_IDS_NO_MERGE'
    points=json.loads((OUT/'native-points.json').read_text())
    assert not any(x['fields'].get('t','').startswith('fsm') for x in points)
    functional=json.loads((OUT/'functional-inventory.json').read_text())
    orders=['aw_first','w_first','simultaneous']
    domains=dict(word_index=[f'word_bin[{i}]' for i in range(256)],order_cp=orders,
        strobe_cp=[f'lanes[{i}]' for i in range(16)],data_cp=['zero','ones','alternating','other'],
        bstall_cp=['none','one','multiple'],rstall_cp=['none','one','multiple'],
        bresp_cp=['okay'],rresp_cp=['okay'],csr_cp=['id','status','enable','scratch'],
        csr_strobe_cp=[f'lanes[{i}]' for i in range(16)],
        order_strobe=[f'{o}_x_lanes[{i}]' for o in orders for i in range(16)])
    explanations=dict(word_index='Every aligned memory target word has an accepted AW',
        order_cp='AW-first, W-first or same-cycle VALID presentation; W acceptance remains after AW',
        strobe_cp='All four-byte WSTRB masks, including no-op mask0',
        data_cp='Zero, allones, alternating or other accepted write payload',
        bstall_cp='B response with zero, one or multiple stalled cycles before completion',
        rstall_cp='R response with zero, one or multiple stalled cycles before completion',
        bresp_cp='Successful B response completion',rresp_cp='Successful R response completion',
        csr_cp='APB ID/status/enable/scratch access while preserving zero-wait contract',
        csr_strobe_cp='All APB scratch byte masks',order_strobe='Every presentation order x WSTRB pair')
    expected={k:Counter() for k in domains};bstall=rstall=0
    for x in rows:
        if not x['rst']:bstall=rstall=0;continue
        if x['av'] and x['awready']:expected['word_index'][f'word_bin[{x["awaddr"]//4}]']+=1
        if x['wv'] and x['wready']:
            expected['strobe_cp'][f'lanes[{x["ws"]}]']+=1
            data=x['wd'];kind='zero' if data==0 else 'ones' if data==0xffffffff else 'alternating' if data in (0xaaaaaaaa,0x55555555) else 'other'
            expected['data_cp'][kind]+=1
        for channel,count in [('b',bstall),('r',rstall)]:
            if x[channel+'valid'] and x['br' if channel=='b' else 'rr']:
                expected[channel+'stall_cp'][('none','one','multiple')[min(count,2)]]+=1
                expected[channel+'resp_cp']['okay']+=1
        if x['bvalid']:bstall=bstall+1 if not x['br'] else 0
        if x['rvalid']:rstall=rstall+1 if not x['rr'] else 0
        if x['sel'] and x['en']:
            expected['csr_cp'][{0:'id',4:'status',8:'enable',16:'scratch'}[x['addr']]]+=1
            if x['wr'] and x['addr']==16:expected['csr_strobe_cp'][f'lanes[{x["strb"]}]']+=1
    for o,name in enumerate(orders):
        for s in range(16):
            n=oracle['transactions'][f'order_{o}_strobe_{s}'];expected['order_strobe'][f'{name}_x_lanes[{s}]']=n
            expected['order_cp'][name]+=n
    requirements=[]
    for i,(group,domain) in enumerate(domains.items(),1):
        native=[p for p in functional if p['fields']['h'].split('.')[1]==group]
        assert {p['fields']['bin'] for p in native}==set(domain),(group,'domain mismatch')
        assert {p['fields']['bin']:p['hits'] for p in native}==dict(expected[group]),(group,'native/passive event mismatch')
        requirements.append(dict(id=f'STB-MEM-FUNC-{i:02d}',requirement=explanations[group],native_group=group,
            raw_hit=sum(p['hits']>0 for p in native),raw_total=len(native),exclusions=[],
            bins=domain,native_point_ids=[p['id'] for p in native],raw_event_counts=expected[group]))
    assert sum(x['raw_total'] for x in requirements)==355
    sva=[]
    for name,w in result['sva_witnesses']['properties'].items():
        assert w['native_antecedent']==w['passive_antecedent']==w['native_completed']==w['passive_completed']>0
        sva.append(dict(property='p_'+name,native_antecedent_cover=name+'_ante',native_completion_cover=name+'_done',
            native_witness_points=dict(raw_hit=2,raw_total=2),
            completion_witness=dict(raw_hit=w['native_completed'],raw_total=w['native_antecedent'],
                denominator_kind='Native USER antecedent-cover events; NOT full assertion attempts'),
            passive_agreement=True,full_assertion_inventory=dict(status='NOT_MEASURED',raw_total=None)))
    report=dict(profile=profile['id'],status='PASS_RAW_INVENTORY_AND_PASSIVE_AGREEMENT',proposal_only=True,
        functional_requirements=requirements,sva_properties=sva,source_profile_sha256=sha(ROOT/'profile.json'),
        trace_sha256=sha(OUT/'native.trace'),raw_native_sha256=sha(OUT/'native.dat'),
        full_branch='BLOCKED_NATIVE_CONSTRUCT_CONFORMANCE',fsm_states='BLOCKED_NO_NATIVE_RECORDS',
        fsm_arcs='BLOCKED_NO_NATIVE_RECORDS',full_sva='BLOCKED_NO_NATIVE_ASSERTION_INVENTORY',
        instance_status=result['instance_status'],signoff='NOT_CLOSED')
    (OUT/'requirements-and-witnesses.json').write_text(json.dumps(report,indent=2)+'\n')
    # Reconstruct and preserve the exact compiled qualification-mutant source bytes.
    core=(ROOT/'rtl/AXI4_Lite_top.sv').read_text();mut=OUT/'qualification-mutant-sources';mut.mkdir(exist_ok=True)
    for name,old,new in [('ignore_strobes','if (wstrb[b])',"if (1'b1)"),
            ('bvalid_needs_ready','bvalid  = (wstate == W_RESP);','bvalid  = (wstate == W_RESP) && bready;'),
            ('corrupt_read','rdata   = rdata_mux;',"rdata   = rdata_mux ^ 32'h1;")]:
        (mut/(name+'.sv')).write_text(core.replace(old,new),newline='\n')
    index={str(p.relative_to(OUT)):sha(p) for p in OUT.rglob('*') if p.is_file() and p.name!='artifact-index.json'}
    (OUT/'artifact-index.json').write_text(json.dumps(index,indent=2)+'\n')
    print(json.dumps(dict(status=report['status'],functional_raw_total=355,sva_witness_raw_total=16,indexed_files=len(index),instance_status=result['instance_status'],signoff='NOT_CLOSED')))
if __name__=='__main__':main()
