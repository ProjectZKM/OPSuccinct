#!/usr/bin/env python3
"""Differentially test two measured verifier builds deployed on one local node.

usage: differential.py BUILDS FIXTURE SELECTOR BASE CANDIDATE COUNT [RPC]

BASE and CANDIDATE name measure.py outputs BUILDS/<name>-osaka.json. The honest
proof must verify on both; then random single-field and single-bit hash
mutations across every proof section must produce identical accept/reject
results. Use it whenever a tail, module or kernel generator changes.
"""
import json,sys,urllib.request,random
from transport import encode_zero_runs
B,W,sel,base_name,cand_name,count=sys.argv[1:7];count=int(count);RPC=sys.argv[7] if len(sys.argv)>7 else 'http://127.0.0.1:18611'
base=json.load(open(f'{B}/{base_name}-osaka.json'))['entry_address'];cand=json.load(open(f'{B}/{cand_name}-osaka.json'))['entry_address']
m=json.load(open(W+'/compiled/program.json'));meta=m['metadata'];packet=bytearray(open(W+'/raw.bin','rb').read())
digest=bytes.fromhex(json.load(open(W+'/statement.json'))['output_digest'][2:])
nf=meta['field_count']
def rpc(meth,params):
    q=urllib.request.Request(RPC,json.dumps({'jsonrpc':'2.0','id':1,'method':meth,'params':params}).encode(),{'Content-Type':'application/json'})
    with urllib.request.urlopen(q,timeout=600) as f:return json.load(f)
def call(entry,pkt,dig):
    pkt=encode_zero_runs(bytes(pkt),meta['field_count'],meta['hash_count'],8);n=len(pkt);pad=(32-n%32)%32
    r=rpc('eth_call',[{'to':entry,'data':'0x'+sel+(64).to_bytes(32,'big').hex()+dig.hex()+n.to_bytes(32,'big').hex()+pkt.hex()+'00'*pad,'gas':hex(16_777_216)},'latest'])
    return 'accept' if r.get('result','').endswith('1') else 'reject'
def slots(x,acc):
    if isinstance(x,dict):
        if set(x)=={'f'}:acc.append(('f',x['f']))
        elif set(x)=={'h'}:acc.append(('h',x['h']))
        else:[slots(v,acc) for v in x.values()]
    elif isinstance(x,list):[slots(v,acc) for v in x]
    return acc
s=m['schema'];b=s['bundle'];w=b['whir_proof']
sections={'WHIR proof':w,'jagged commit':b['commit'],'preceding commits':b['preceding_commits'],'jagged eval':b['jagged_eval'],'reduction':b['reduction'],
          'GKR':s['proof']['jagged_shard_proof']['logup_gkr_proof'],'zerocheck':s['proof']['jagged_shard_proof']['zerocheck_proof'],'openings':s['proof']['jagged_shard_proof']['opened_values']}
assert call(base,packet,digest)=='accept' and call(cand,packet,digest)=='accept','honest proof must verify on both'
print('honest: both accept')
random.seed(2026);mismatch=0;total=0;summary={}
for name,sec in sections.items():
    pool=slots(sec,[]);picks=random.sample(pool,min(len(pool),count if name=='WHIR proof' else max(3,count//10)))
    rej=0
    for kind,ix in picks:
        bad=bytearray(packet)
        if kind=='f':
            at=38+4*ix;v=int.from_bytes(bad[at:at+4],'little');bad[at:at+4]=((v+random.randrange(1,0x7f000001))%0x7f000001).to_bytes(4,'little')
        else:
            at=38+4*nf+32*ix;bad[at+random.randrange(32)]^=1<<random.randrange(8)
        rb,rc=call(base,bad,digest),call(cand,bad,digest);total+=1
        if rb!=rc:mismatch+=1;print('MISMATCH',name,kind,ix,rb,rc)
        if rc=='reject':rej+=1
    summary[name]=(len(picks),rej)
print('candidate rejections per section (mutated, rejected):',summary)
print(f'wrong digest: base {call(base,packet,bytes([digest[0]^1])+digest[1:])}, cand {call(cand,packet,bytes([digest[0]^1])+digest[1:])}')
print(f'mismatches between Solidity and AOT tails: {mismatch} of {total}')
