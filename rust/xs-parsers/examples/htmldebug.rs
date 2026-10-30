fn main() {
    let p = std::env::args().nth(1).unwrap();
    let b = std::fs::read(&p).unwrap();
    let e = xs_parsers::decode_text(&b, false).unwrap();
    println!("bytes={} decoded_chars={} method={} state={:?}", b.len(), e.text.chars().count(), e.method, e.state);
}
