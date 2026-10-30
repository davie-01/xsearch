#!/usr/bin/env python3
"""Private, reproducible measurement-only Tantivy copy; never modifies registry or production build."""
import pathlib,shutil,hashlib,json
root=pathlib.Path(__file__).resolve().parents[1]
sources=list((root/'.tools/cargo/registry/src').glob('*/tantivy-0.27.0'))
assert len(sources)==1,'Expected locally cached Tantivy 0.27.0'
source=sources[0];target=root/'work/m0b/tantivy-instrumented'
if target.exists():shutil.rmtree(target)
shutil.copytree(source,target)
p=target/'src/store/reader.rs';original=p.read_text();s=original
s=s.replace('type Block = OwnedBytes;', '''type Block = OwnedBytes;
// M0-B sync-reader counters: blocks decoded, compressed bytes supplied, decoded bytes,
// decoder nanoseconds, decompressed-block cache hits. No physical-I/O claim.
static M0_METRICS: [std::sync::atomic::AtomicU64; 5] = [const { std::sync::atomic::AtomicU64::new(0) }; 5];
''',1)
s=s.replace('impl StoreReader {','''impl StoreReader {
    /// M0-B measurement only. Reset with no concurrent readers/merges.
    pub fn m0_reset_metrics() {for counter in &M0_METRICS {counter.store(0, Ordering::Relaxed);}}
    /// M0-B sync-reader metrics; see counter definition.
    pub fn m0_metrics() -> [u64;5] {std::array::from_fn(|i|M0_METRICS[i].load(Ordering::Relaxed))}
''',1)
s=s.replace('''if let Some(block) = self.cache.get_from_cache(cache_key) {
            return Ok(block);
        }''','''if let Some(block) = self.cache.get_from_cache(cache_key) {
            M0_METRICS[4].fetch_add(1, Ordering::Relaxed);
            return Ok(block);
        }''',1)
old='''        let decompressed_block =
            OwnedBytes::new(self.decompressor.decompress(compressed_block.as_ref())?);'''
new='''        let decode_start = std::time::Instant::now();
        let decompressed_block =
            OwnedBytes::new(self.decompressor.decompress(compressed_block.as_ref())?);
        M0_METRICS[0].fetch_add(1, Ordering::Relaxed);
        M0_METRICS[1].fetch_add(compressed_block.len() as u64, Ordering::Relaxed);
        M0_METRICS[2].fetch_add(decompressed_block.len() as u64, Ordering::Relaxed);
        M0_METRICS[3].fetch_add(decode_start.elapsed().as_nanos() as u64, Ordering::Relaxed);'''
assert s.count(old)==1;s=s.replace(old,new,1);assert s!=original;p.write_text(s)
patch={'upstream':'tantivy 0.27.0','file':'src/store/reader.rs','original_sha256':hashlib.sha256(original.encode()).hexdigest(),'instrumented_sha256':hashlib.sha256(s.encode()).hexdigest(),'scope':'synchronous StoreReader cache-miss decompression only; independent bench workspace'}
(root/'work/m0b/instrumentation.json').write_text(json.dumps(patch,indent=2)+'\n')
print('Prepared isolated Tantivy decompression counters.')
