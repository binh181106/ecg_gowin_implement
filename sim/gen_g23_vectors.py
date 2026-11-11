"""Independent G2.3 stream and window vectors with explicit hand-checked cases."""
import importlib.util
import json
from pathlib import Path
import sys
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[1]; OUT=ROOT/'sim/g23_vectors'
def load(name,path):
    s=importlib.util.spec_from_file_location(name,ROOT/path)
    m=importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
ref=load('g23','src/g23_reference.py'); old=load('oldvec','sim/gen_g22_vectors.py')
def impulses(n,peaks,amp=100):
    return [amp if i in peaks else 0 for i in range(n)]
def stream_cases():
    cases=[('zero',[0]*2048,80),('positive',[100]*2048,80),('negative',[-100]*2048,80),
           ('one',impulses(2048,[300]),80),('two',impulses(2048,[100,300]),80),
           ('variable',impulses(2048,[100,300,600,1000]),80),
           ('refractory',impulses(1024,[100,171,172,244,300,400]),80),
           ('long_gap',impulses(4096,[100,300,600,2500,2700,3000]),80),
           ('max_gap',impulses(2304,[100,172,1972,2044]),80),
           ('plateau',[0]*100+[100]*5+[0]*1943,80),
           ('extrema',[-128,127]*1024,80),
           ('threshold_equal',impulses(1024,[100,200,400],80),80),
           ('below_threshold',impulses(1024,[100,200,400],79),80),
           ('threshold_negative',impulses(1024,[100,200,400]),-1),
           ('threshold_256',impulses(1024,[100,200,400]),256),
           ('long_timestamp',impulses(66000,[65500,65600,65800]),80)]
    for p in [255,256,511,512]:
        cases.append((f'boundary_{p}',impulses(1536,[100,p,900]),80))
    return cases
def write_hex(name,values,width):
    (OUT/name).write_text(''.join(f'{v & ((1<<(4*width))-1):0{width}x}\n' for v in values))
def main():
    OUT.mkdir(exist_ok=True)
    assert ref.zero_crossings([-1,0,0,1])==1
    assert ref.zero_crossings([-1,0,-1])==0
    assert ref.zero_crossings([0,1,0,-1,0,1,0])==2
    assert ref.zero_crossings([-128,127]*256)==511
    assert ref.rr_fields(300,200,1,1)==([300,200,6144,100],True,False)
    assert ref.rr_fields(1800,72,1,1)==([1800,72,32767,1728],True,True)
    assert ref.rr_fields(200,0,1,0)[0]==[200,0,0,0]
    trace=[]; records=[]
    for name,samples,threshold in stream_cases():
        model=ref.chronological(samples,threshold)
        if name in ['zero','positive','negative','below_threshold','threshold_negative','threshold_256']:
            assert model['events']==[]
        if name=='variable':
            assert model['events']==[100,300,600,1000]
            assert [ref.features(samples[i:i+512],model['states'][i+511])[8:] for i in range(0,1537,256)] == [
                [200,0,0,0],[300,200,6144,100],[400,300,5461,100],
                [400,300,5461,100],[400,300,5461,100],[400,300,5461,100],[400,300,5461,100]]
        if name=='long_gap':
            assert model['states'][2401]['current_valid']
            assert not model['states'][2402]['current_valid']
            assert not model['states'][2501]['current_valid']
            assert model['states'][2701]['current']==200
        if name=='plateau': assert model['events']==[100]
        if name=='max_gap':
            assert model['events']==[100,172,1972,2044]
            assert model['states'][1973]['current']==1800
        if name=='refractory': assert model['events']==[100,244,400]
        for n,(x,s) in enumerate(zip(samples,model['states'])):
            trace.append([int(n==0),threshold,x,*[int(s[k]) for k in
                ['next_index','event','event_timestamp','current','previous','current_valid','previous_valid']]])
        records.append(dict(name=name,length=len(samples),threshold=threshold,events=model['events']))
    write_hex('trace.hex',[v for row in trace for v in row],16)
    (OUT/'streams.json').write_text(json.dumps(records,indent=2)+'\n')
    # Original313 windows retained; extra zeros/sign-boundary and RR port cases.
    cases=[(name,samples,{}) for name,samples in old.cases()]
    for seq in [[-1,0,-1],[1,0,1],[-1,0,0,1],[1,0,-1],[0,-128,0,127,0]]:
        cases.append((f'zc_{seq}',(seq*512)[:512],{}))
    for c,p,cv,pv in [(0,0,0,0),(200,0,1,0),(300,200,1,1),(200,300,1,1),
                       (1800,72,1,1),(72,1800,1,1),(32767,1,1,1),(1,32767,1,1),
                       (100,0,1,1),(32768,72,1,1),(100,32768,1,1),(100,100,0,1)]:
        cases.append((f'rr_{c}_{p}_{cv}_{pv}',[10]*512,
                      dict(current=c,previous=p,current_valid=cv,previous_valid=pv)))
    windows=[]
    for name,samples,s in cases:
        f=ref.features(samples,s); a=ref.g22.arithmetic(samples)
        assert all(f[k]==ref.g22.features(samples)[k] for k in [0,1,2,4,5,6,7])
        fields,pair,sat=ref.rr_fields(**s)
        windows.append(dict(name=name,samples=samples,features=f,**a,
            snapshot=[s.get(k,0) for k in ['current','previous','current_valid','previous_valid']],
            pair_valid=int(pair),ratio_saturated=int(sat),latency=1557+(30 if a['rms_fp'] else 1)+(30 if pair else 1)))
    write_hex('samples.hex',[v for w in windows for v in w['samples']],2)
    write_hex('features.hex',[v for w in windows for v in w['features']],4)
    write_hex('snapshots.hex',[v for w in windows for v in w['snapshot']+[w['pair_valid'],w['ratio_saturated']]],4)
    write_hex('internals.hex',[w[k] for w in windows for k in ['total','energy','var_num','abs_peak','rms_fp','latency']],16)
    (OUT/'counts.svh').write_text(f'localparam integer NUM_CASES={len(windows)};\n')
    (OUT/'trace_counts.svh').write_text(f'localparam integer NUM_TRACE={len(trace)};\n')
    (OUT/'cases.json').write_text(json.dumps(windows,indent=1)+'\n')
    prior=json.loads((ROOT/'sim/g21_vectors/cases.json').read_text())
    write_hex('g21_features.hex',[v for w in prior for v in ref.features(w['signed'])],4)
    # Synthetic chronological overlap/boundary fixture, independent packet math.
    synthetic=impulses(2048,[100,255,511,900]); model=ref.chronological(synthetic)
    write_hex('synthetic_raw.hex',[v+128 for v in synthetic],2)
    write_hex('synthetic_signed.hex',synthetic,2)
    golden=ref.make_golden('rom-centered')
    golden['rr_events']=model['events']
    for i,w in enumerate(golden['windows']):
        s=model['states'][511+256*i]; w['features_rtl']=ref.features(synthetic[256*i:256*i+512],s)
        w['rr_snapshot']=s; w['packet']=ref.g22.frozen.packet(w['features_rtl'],i+1)
    assert golden['windows'][0]['features_rtl'][8:]==[155,0,0,0]
    assert golden['windows'][1]['features_rtl'][8:]==[256,155,6765,101]
    assert golden['windows'][2]['features_rtl'][8:]==[389,256,6224,133]
    assert all(w['features_rtl'][8:]==[389,256,6224,133] for w in golden['windows'][2:])
    (OUT/'synthetic_packets.sv').write_text(ref.sv_include(golden))
    (OUT/'synthetic_packets.json').write_text(json.dumps(golden,indent=2)+'\n')
    print(f'G23 PYTHON PASS streams={len(records)} samples={len(trace)} windows={len(windows)} frozen_G22_math=PASS')
if __name__=='__main__': main()
