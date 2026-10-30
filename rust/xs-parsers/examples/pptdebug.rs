//! Structure counts of one .ppt (no text): top-level record types, lists, persist entries.
fn main() {
    let a = std::env::args().nth(1).unwrap();
    let mut ole = cfb::open(&a).unwrap();
    let mut d = vec![];
    std::io::Read::read_to_end(&mut ole.open_stream("/PowerPoint Document").unwrap(), &mut d).unwrap();
    let mut pos = 0;
    let mut tops = std::collections::BTreeMap::<u16, u32>::new();
    let mut last_doc = 0;
    while pos + 8 <= d.len() {
        let rtype = u16::from_le_bytes([d[pos + 2], d[pos + 3]]);
        let len = u32::from_le_bytes([d[pos + 4], d[pos + 5], d[pos + 6], d[pos + 7]]) as usize;
        *tops.entry(rtype).or_default() += 1;
        if rtype == 0x03E8 {
            last_doc = pos;
            // lists inside this doc
            let body = &d[pos + 8..pos + 8 + len];
            let mut q = 0;
            while q + 8 <= body.len() {
                let vi = u16::from_le_bytes([body[q], body[q + 1]]);
                let rt = u16::from_le_bytes([body[q + 2], body[q + 3]]);
                let l = u32::from_le_bytes([body[q + 4], body[q + 5], body[q + 6], body[q + 7]]) as usize;
                if rt == 0x0FF0 {
                    let lb = &body[q + 8..q + 8 + l];
                    let mut k = 0;
                    let (mut persist, mut texts) = (0, 0);
                    while k + 8 <= lb.len() {
                        let t = u16::from_le_bytes([lb[k + 2], lb[k + 3]]);
                        let ll = u32::from_le_bytes([lb[k + 4], lb[k + 5], lb[k + 6], lb[k + 7]]) as usize;
                        if t == 0x03F3 { persist += 1 }
                        if t == 0x0FA0 || t == 0x0FA8 { texts += 1 }
                        k += 8 + ll;
                    }
                    println!("doc@{pos} list inst={} persistAtoms={persist} textAtoms={texts}", vi >> 4);
                }
                q += 8 + l;
            }
        }
        pos += 8 + len;
    }
    println!("last doc @{last_doc}, stream len {}, top-level types: {:x?}", d.len(), tops);
}
