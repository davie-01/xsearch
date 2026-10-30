#!/usr/bin/env python3
"""Compare all Unicode scalars transformed by the pinned Rust normalizer with Foundation."""
import json,pathlib,subprocess
root=pathlib.Path(__file__).resolve().parents[1]
out=root/'work/m0'
with open(out/'unicode-vectors.json','wb') as f:subprocess.run([root/'target/release/xs','unicode-vectors'],stdout=f,check=True)
for name,cmd in [('rust',[root/'target/release/xs','normalize']),('swift',[out/'bin/NativeProbe','normalize'])]:
    with open(out/f'unicode-{name}.json','wb') as f:subprocess.run(cmd+[out/'unicode-vectors.json'],stdout=f,check=True)
r=json.load(open(out/'unicode-rust.json'));s=json.load(open(out/'unicode-swift.json'));vectors=json.load(open(out/'unicode-vectors.json'))
diffs=[dict(vector=i,codepoints=[f'U+{ord(c):04X}' for c in vectors[i]['input']],mode=vectors[i]['mode'],rust=a,swift=b) for i,(a,b) in enumerate(zip(r,s)) if a!=b]
report=dict(vectors=len(vectors),rust_count=len(r),swift_count=len(s),differences=len(diffs),examples=diffs[:30])
(out/'unicode-report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
print(json.dumps({k:v for k,v in report.items() if k!='examples'}))
raise SystemExit(bool(diffs) or len(r)!=len(s))
