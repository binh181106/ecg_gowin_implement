"""G2.3 independent batch mathematics on one chronological stream.

Candidates are enumerated once; accepted events are filtered once. Window
snapshots select confirmed events by timestamp, never detect peaks in windows.
G2.2 reference remains immutable and supplies the frozen arithmetic.
"""
import argparse
from bisect import bisect_right
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('g22', ROOT/'src/g22_reference.py')
g22 = importlib.util.module_from_spec(spec); spec.loader.exec_module(g22)


def zero_crossings(samples):
    nonzero = [x for x in samples if x != 0]
    return sum(a*b < 0 for a,b in zip(nonzero, nonzero[1:]))


def rr_fields(current=0, previous=0, current_valid=False, previous_valid=False):
    cv = bool(current_valid and 1 <= current <= 32767)
    pv = bool(cv and previous_valid and 1 <= previous <= 32767)
    quotient = current*4096//previous if pv else 0
    return [current if cv else 0, previous if pv else 0,
            min(32767,quotient), current-previous if pv else 0], pv, quotient>32767


def chronological(samples, threshold=80, refractory=72, maximum=1800):
    assert 1 <= refractory <= maximum <= 32767
    assert all(-128 <= x <= 127 for x in samples)
    candidates = [p for p in range(1,len(samples)-1)
                  if 1 <= threshold <= 127 and samples[p] >= threshold
                  and samples[p] > samples[p-1] and samples[p] >= samples[p+1]]
    events = []
    for p in candidates:
        if not events or p-events[-1] >= refractory:
            events.append(p)
    states=[]
    for n in range(len(samples)):
        k=bisect_right(events,n-1)
        past=events[:k]
        current=previous=0
        if past and n-1-past[-1] <= maximum:
            if len(past)>=2 and past[-1]-past[-2] <= maximum:
                current=past[-1]-past[-2]
                if len(past)>=3 and past[-2]-past[-3] <= maximum:
                    previous=past[-2]-past[-3]
        states.append(dict(next_index=n+1,event=bool(past and past[-1]==n-1),
                           event_timestamp=past[-1] if past else 0,
                           current=current,previous=previous,
                           current_valid=bool(current),previous_valid=bool(previous)))
    return dict(candidates=candidates,events=events,states=states)


def features(samples, snapshot=None):
    f=g22.features(samples)
    f[3]=zero_crossings(samples)
    s=snapshot or {}
    f[8:12]=rr_fields(**{k:s.get(k,0) for k in
                         ['current','previous','current_valid','previous_valid']})[0]
    return f


def make_golden(mode):
    result=g22.make_golden(mode)
    raw=[int(x,16) for x in (ROOT/'src/ecg_rom.hex').read_text().split()]
    samples=[g22.frozen.preprocess(x,mode) for x in raw]
    stream=chronological(samples)
    result['source']='G2.3 signed nonzero ZC and continuous positive peak RR; G2.2 arithmetic'
    result['arithmetic_contract']='G2.2 frozen / G2.3 ZC-RR'
    result['rr_events']=stream['events']
    result.pop('rr_physiologically_valid',None)
    result['qrs_clinically_validated']=False
    result['rr_validity_contract']='current_valid and previous_valid in rr_snapshot; missing fields0; no UART validity bits'
    result['rr_parameters']=dict(threshold=80,refractory_samples=72,max_rr_samples=1800)
    for i,w in enumerate(result['windows']):
        s=stream['states'][511+i*256]; window=samples[i*256:i*256+512]
        old=w['features_rtl']; new=features(window,s)
        assert all(new[k]==old[k] for k in [0,1,2,4,5,6,7])
        w['features_rtl']=new; w['rr_snapshot']=s
        w.pop('rr_physiologically_valid',None)
        w['packet']=g22.frozen.packet(new,i+1); w['checksum']=w['packet'][-1]
    result['formulas'].update(dict(rr='signed positive local maximum; refractory72; continuous timestamp differences; timeout1800',
        f_zc='opposite adjacent signs after deleting zeros',
        f_rr='latest valid continuous interval, samples; otherwise0',
        f_rr_prev='previous valid continuous interval, samples; otherwise0',
        f_rr_ratio='pair_valid ? min(32767,current*4096//previous) : 0; F=12',
        f_rr_diff='pair_valid ? current-previous : 0; signed samples'))
    for name in ['src/g23_reference.py','src/rr_tracker.v','G2_3_DESIGN_CONTRACT.txt']:
        result['provenance']['source_sha256'][name]=hashlib.sha256((ROOT/name).read_bytes()).hexdigest()
    return result


def sv_include(golden):
    return g22.sv_include(golden).replace('g22_reference','g23_reference')


def main():
    parser=argparse.ArgumentParser(description=__doc__); parser.add_argument('--check',action='store_true')
    args=parser.parse_args()
    for name,mode in [('g23_signed','rom-centered'),('g23_legacy','legacy')]:
        result=make_golden(mode); out=ROOT/'src/golden'/name
        if args.check:
            saved=json.loads((out/'expected_packets.json').read_text())
            for key in ['windows','formulas','rr_events','rr_parameters','rr_validity_contract','qrs_clinically_validated']:
                assert saved[key]==result[key],(name,key)
            assert (out/'expected_packets.sv').read_text()==sv_include(result)
        else:
            out.mkdir(parents=True,exist_ok=True)
            (out/'expected_packets.json').write_text(json.dumps(result,indent=2)+'\n')
            (out/'expected_packets.sv').write_text(sv_include(result))
        print('PASS '+name+' events='+str(result['rr_events'])+' 231 strict bytes')


if __name__=='__main__': main()
