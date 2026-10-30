#!/usr/bin/env python3
"""M0-B evidence contains no extracted text, images, source document names or paths."""
import pathlib,json,hashlib,datetime,os
root=pathlib.Path(__file__).resolve().parents[1];work=root/'work/m0b'
def read(name):return json.loads((work/name).read_text())
names=read('names-final.json');storage=read('storage-final.json')
xpc=read('xpc-user-session.json') if (work/'xpc-user-session.json').exists() else {}
vision=read('vision-summary.json') if (work/'vision-summary.json').exists() else {}
log=(work/'tests-final.log').read_text();regression=(work/'m0a-regression.log').read_text()
checks={
 'no_pinyin_and_overlay_tests':'4 passed; 0 failed' in log,
 'name_layouts':len(names)==32 and {x['entries'] for x in names}=={100000,1000000},
 'stored_read_matrix':len(storage['stored_reads'])==72,
 'bloom_actual_decoder_counters':len(storage['bloom_reads'])==88,
 'xpc_roundtrips':xpc.get('status')=='passed' and sum(x['xpc']['count'] for x in xpc.get('rows',[]))==6000,
 'vision_experiment':len(vision.get('calibration',[]))==20 and len(vision.get('real_inputs',[]))==14,
 'm0a_regression':'18 passed; 0 failed' in regression and '1 passed; 0 failed' in regression and 'FAILED' not in regression,
}
sources=[root/'bench/m0b/Cargo.toml',root/'bench/m0b/Cargo.lock']+list((root/'bench/m0b/src').glob('*.rs'))+list((root/'native/m0b').glob('*'))
sources+=[root/'scripts'/x for x in ['prepare-store-instrumentation.py','run-m0b.sh','m0b-evidence.py','build-xpc-bench.sh','build-vision-probe.sh','run-xpc-bench.command','run-native-m0b.command','run-vision-samples.command','analyze-vision.py','prepare-vision-batch.py']]
xpc_public={k:v for k,v in xpc.items() if k not in ('client_pid','connections')}
xpc_public['connections']=[{k:v for k,v in c.items() if k!='service_pid'} for c in xpc.get('connections',[])]
xpc_public['service_process_reused']=len({c['service_pid'] for c in xpc.get('connections',[])})==1
result={'created_at':datetime.datetime.now().astimezone().isoformat(),'status':'M0-B experiments completed with documented limits' if all(checks.values()) else 'M0-B incomplete','checks':checks,'architecture_baseline':'v0.7.3; no pinyin','name_full_result_comparisons':sum(x['correctness_queries'] for x in names)+sum(x['correctness_queries'] for x in names if x['state']=='one_percent_delta'),'bloom_oracle_comparisons':sum(x['repeats'] for x in storage['bloom_reads']),'instrumentation':read('instrumentation.json'),'names':names,'storage':storage,'xpc':xpc_public,'vision':vision,'source_sha256':{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}}
(root/'docs/m0/M0B-EVIDENCE.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
for base,dirs,files in os.walk(work):
 os.chmod(base,0o700)
 for f in files:
  p=pathlib.Path(base)/f
  if not p.is_symlink():os.chmod(p,0o700 if p.stat().st_mode&0o111 else 0o600)
print(json.dumps({'status':result['status'],'checks':checks,'name_comparisons':result['name_full_result_comparisons'],'bloom_comparisons':result['bloom_oracle_comparisons']},ensure_ascii=False))
raise SystemExit(not all(checks.values()))
