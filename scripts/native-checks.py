#!/usr/bin/env python3
"""Validate native PDF ranges without writing document contents to the report."""
import json,pathlib,subprocess,sys
root=pathlib.Path(__file__).resolve().parents[1];work=root/'work/m0';native=work/'bin/NativeProbe'
def call(*args):return json.loads(subprocess.check_output([str(native),*map(str,args)]))
call('make-pdf',work/'synthetic.pdf')
checks=[]
for path in [work/'synthetic.pdf',*sorted(pathlib.Path(sys.argv[1]).glob('*.pdf'))]:
    report=call('pdf-verify',path)
    assert report['checked']>0, 'No expected PDF test terms found'
    assert report['selectionMismatches']==0 and report['emptyBounds']==0, 'PDF range mismatch'
    if path==work/'synthetic.pdf':
        assert report['queryHits'].get('😀',0)>0, 'UTF-16 surrogate selection was not exercised'
        extracted=call('extract',path)
        if '\x00' in extracted['text'] or '\ufffd' in extracted['text']:
            assert any(p['state']=='partial_text' for p in extracted['pages']), 'Invalid text layer incorrectly marked complete'
        (work/'pdf-synthetic-check.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
    else:
        (work/'pdf-real-check.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
    checks.append(dict(synthetic=path==work/'synthetic.pdf',**report))
(work/'native-checks.json').write_text(json.dumps(checks,ensure_ascii=False,indent=2))
print(json.dumps(dict(pdf_files=len(checks),checked=sum(x['checked'] for x in checks),mismatches=sum(x['selectionMismatches'] for x in checks))))
