#!/usr/bin/env python3
import pathlib,sys,subprocess,json,time,hashlib,os,zipfile,xml.etree.ElementTree as ET
root=pathlib.Path(__file__).resolve().parents[1]
work=root/'work/m0';work.mkdir(parents=True,exist_ok=True);os.chmod(work,0o700)
native=root/'work/m0/bin/NativeProbe'
sample=pathlib.Path(sys.argv[1]) if len(sys.argv)>1 else root/'Tests/Fixtures/m0'
reports=[];corpus=[]
for p in sorted(sample.iterdir()):
    if p.suffix.lower() not in ('.doc','.docx','.pdf','.txt'):continue
    start=time.monotonic();report={'file':p.name,'source_bytes':p.stat().st_size}
    try:
        if p.suffix.lower() in ('.txt','.docx'):
            r=subprocess.run([str(root/'target/release/xs'),'extract',str(p)],capture_output=True,timeout=90,check=True)
            result=json.loads(r.stdout);result.update(pages=[],selections=[],method='Rust ZIP/XML' if p.suffix.lower()=='.docx' else 'Rust encoding_rs strict decode')
            if p.suffix.lower()=='.docx':
                with zipfile.ZipFile(p) as archive:
                    names=sorted(n for n in archive.namelist() if n=='word/document.xml' or n.startswith('word/header') or n.startswith('word/footer') or n in ('word/footnotes.xml','word/endnotes.xml'))
                    fragments=[];part_counts={}
                    for name in names:
                        tree=ET.fromstring(archive.read(name));values=[e.text or '' for e in tree.iter('{http://schemas.openxmlformats.org/wordprocessingml/2006/main}t')]
                        fragments.extend(x for x in values if x.strip());part_counts[name]=len(values)
                report.update(xml_parts=part_counts,text_fragments=len(fragments),fragments_found=sum(x in result['text'] for x in fragments),anchors=len(result['anchors']))
                alt=subprocess.run([str(native),'extract',str(p)],capture_output=True,timeout=90)
                report['native_alternative_success']=alt.returncode==0
                if alt.returncode==0:
                    alt_text=json.loads(alt.stdout)['text'];report['native_alternative_characters']=len(alt_text)
                    report['native_fragments_found']=sum(x in alt_text for x in fragments)
        else:
            r=subprocess.run([str(native),'extract',str(p),'数据共享'],capture_output=True,timeout=90)
            if r.returncode:raise RuntimeError(r.stderr.decode(errors='replace')[:600])
            result=json.loads(r.stdout)
        text=result['text'];report.update(method=result['method'],characters=len(text),pages=len(result['pages']),waiting_ocr_pages=sum(x['state']=='waiting_ocr' for x in result['pages']),partial_text_pages=sum(x['state']=='partial_text' for x in result['pages']),selection_count=len(result['selections']),selection_exact=sum(x['exact'] for x in result['selections']),selection_rect_valid=sum(x['rectNonempty'] for x in result['selections']))
        if p.suffix.lower()=='.doc':
            alt=subprocess.run(['/usr/bin/textutil','-convert','txt','-stdout',str(p)],capture_output=True,timeout=90)
            alt_text=alt.stdout.decode('utf-8',errors='strict') if alt.returncode==0 else ''
            report.update(textutil_success=alt.returncode==0,textutil_characters=len(alt_text),same_text=text==alt_text)
            report['whitespace_insensitive_same']=''.join(text.split())==''.join(alt_text.split())
        corpus.append({'id':len(corpus)+1,'name':p.name,'text':text})
        report['status']='extracted'
        # Detailed private output stays under ignored 0700 work directory, never in public reports.
        detail=work/('extract-'+hashlib.sha256(p.name.encode()).hexdigest()[:12]+'.json')
        detail.write_text(json.dumps(result,ensure_ascii=False));detail.chmod(0o600)
    except Exception as e:report.update(status='failed',error=str(e))
    report['elapsed_ms']=round((time.monotonic()-start)*1000,2);reports.append(report)
(work/'extraction-report.json').write_text(json.dumps(reports,ensure_ascii=False,indent=2))
(work/'real-corpus.json').write_text(json.dumps(corpus,ensure_ascii=False));(work/'real-corpus.json').chmod(0o600)
print(json.dumps({'files':len(reports),'success':sum(x['status']=='extracted' for x in reports),'report':str(work/'extraction-report.json')},ensure_ascii=False))
