#!/usr/bin/env python3
import pathlib,sys,json,subprocess
root=pathlib.Path(__file__).resolve().parents[1];work=root/'work/m0b'
sample=pathlib.Path(sys.argv[1]);calibration=pathlib.Path(sys.argv[2]).resolve()
files=sorted(p for p in sample.iterdir() if p.resolve()!=calibration and p.suffix.lower() in ['.pdf','.jpg','.jpeg','.png'])
jobs=[];mapping={}
for i,p in enumerate(files):
 source=f'sample-{i+1}';mapping[source]=p.name;kind='scan_pdf' if p.suffix.lower()=='.pdf' else 'photo'
 pages=1
 if kind=='scan_pdf':
  meta=json.loads(subprocess.check_output([str(root/'work/m0/bin/NativeProbe'),'extract',str(p)]));pages=min(10,len(meta['pages']))
 for page in range(1,pages+1):
  for scale in ([150,300] if kind=='scan_pdf' else [2000,6000]):jobs.append(dict(source=source,path=str(p.resolve()),kind=kind,page=page,dpi=scale if kind=='scan_pdf' else 0,maxDimension=scale if kind=='photo' else 0))
for name,data in [('vision-batch-private.json',jobs),('vision-source-map-private.json',mapping)]:
 p=work/name;p.write_text(json.dumps(data,ensure_ascii=False,indent=2));p.chmod(0o600)
print(json.dumps({'inputs':len(files),'observations':len(jobs)}))
