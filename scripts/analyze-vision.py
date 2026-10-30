#!/usr/bin/env python3
"""Publish counts/quality measures only; OCR text and manual references stay in work/m0b."""
import pathlib,json,unicodedata,subprocess,collections
root=pathlib.Path(__file__).resolve().parents[1];w=root/'work/m0b'
def read(name):return json.loads((w/name).read_text())
def text(s):return ''.join(c for c in unicodedata.normalize('NFC',s) if c.isalnum())
def edit(a,b,substring=False):
 previous=[0]*(len(b)+1) if substring else list(range(len(b)+1))
 for i,x in enumerate(a,1):
  current=[i]+[0]*len(b)
  for j,y in enumerate(b,1):current[j]=min(previous[j]+1,current[j-1]+1,previous[j-1]+(x!=y))
  previous=current
 return min(previous) if substring else previous[-1]
calibration=read('vision-user-session-private.json')
reference=json.loads(subprocess.check_output([str(root/'work/m0/bin/NativeProbe'),'extract',read('vision-reference-private.json')['reference_pdf']]))
cal=[]
for r in calibration:
 p=reference['pages'][r['page']-1];expected=text(reference['text'][p['scalarStart']:p['scalarEnd']]);observed=text(r['text'])
 # Cover has an incomplete text layer; dotted TOC leaders are not prose characters.
 if r['page']==1:eligible=False;errors=None;recall=None
 else:
  eligible=True;errors=edit(expected,observed);a=collections.Counter(expected);b=collections.Counter(observed);recall=sum((a&b).values())/len(expected)
 cal.append({k:v for k,v in r.items() if k!='text'}|dict(comparable_reference=eligible,alphanumeric_reference_characters=len(expected),alphanumeric_edits=errors,alphanumeric_bag_recall=recall))
snippets=read('vision-snippets-private.json');scan=[]
for r in read('vision-real-private.json'):
 result=r['result'];normalized=text(result['text']);references=snippets.get(r['source'],{})
 phrases=references.get('phrases',[]);found=sum(text(p) in normalized for p in phrases);body=text(references.get('body',''))
 scan.append({k:v for k,v in r.items() if k!='result'}|{k:v for k,v in result.items() if k!='text'}|dict(manual_phrases=len(phrases),manual_phrases_found=found,manual_body_characters=len(body),manual_body_best_span_edits=edit(body,normalized,True) if body else None))
report={'calibration':cal,'real_inputs':scan,'notes':['PDFKit text is not an independent gold transcription. Cover excluded; TOC leader punctuation excluded only in additional alphanumeric metric.','Manual phrases are spot checks from 3 poster photos and 2 scanned forms; not full-document accuracy.','Two distant-screen scene photos have no reliable full transcription; confidence is not accuracy.','Cold model startup is reported separately from later page requests.']}
(w/'vision-summary.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
for dpi in [150,300]:
 rows=[x for x in cal if x['dpi']==dpi and x['comparable_reference']];total=sum(x['alphanumeric_reference_characters'] for x in rows)
 print('calibration',dpi,'letters/digits CER',sum(x['alphanumeric_edits'] for x in rows)/total)
for x in scan:print(x['source'],x['scale'],'phrases',x['manual_phrases_found'],'/',x['manual_phrases'],'body edits',x['manual_body_best_span_edits'],'/',x['manual_body_characters'])
