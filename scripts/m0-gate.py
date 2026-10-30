#!/usr/bin/env python3
"""Aggregate scoped M0 evidence. Permission evidence must come from the real user session."""
import json,pathlib
root=pathlib.Path(__file__).resolve().parents[1];work=root/'work/m0'
def read(name):return json.loads((work/name).read_text())
v=read('validation-final.json');u=read('unicode-report.json');e=read('extraction-report.json');p=read('native-checks.json')
permission=read('permission-user-session.json') if (work/'permission-user-session.json').exists() else {}
log=(work/'tests-final.log').read_text()
gates={
 'automated_tests':'18 passed; 0 failed' in log and '1 passed; 0 failed' in log and 'test result: FAILED' not in log,
 'recall':v['mismatches']==0 and v['comparisons']>0,
 'unicode_c_abi':u['differences']==0 and u['rust_count']==u['swift_count']==u['vectors'],
 'extraction':all(x['status']=='extracted' for x in e) and all(x.get('text_fragments',0)==x.get('fragments_found',0) for x in e),
 'formats':all(any(x['file'].lower().endswith(ext) for x in e) for ext in ['.txt','.pdf','.doc','.docx']),
 'pdf_offsets':all(x['checked']>0 and x['selectionMismatches']==0 and x['emptyBounds']==0 for x in p),
 'signed_permission_chain':permission.get('app',{}).get('read') is True and permission.get('xpc',{}).get('read') is True and permission.get('xpc',{}).get('child',{}).get('read') is True,
}
result=dict(status='M0-A sample gates passed' if all(gates.values()) else 'M0-A incomplete',gates=gates,documents=len(e),comparisons=v['comparisons'],unicode_vectors=u['vectors'],pdf_selections=sum(x['checked'] for x in p))
(work/'gate.json').write_text(json.dumps(result,ensure_ascii=False,indent=2));print(json.dumps(result,ensure_ascii=False))
raise SystemExit(not all(gates.values()))
