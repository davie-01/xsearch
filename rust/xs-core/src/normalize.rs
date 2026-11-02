use serde::{Deserialize, Serialize};
use std::ops::Range;
use unicode_normalization::UnicodeNormalization;
mod folding {
    include!(concat!(env!("OUT_DIR"), "/casefold.rs"));
}
pub const NORM_VERSION: &str = "xs-codepoint-nfkd-ucd17-fullfold-ws-v1";
pub fn full_fold(s: &str) -> String {
    s.chars()
        .map(|c| {
            folding::fold(c)
                .map(str::to_owned)
                .unwrap_or_else(|| c.to_string())
        })
        .collect()
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Mode {
    Loose,
    CaseSensitive,
    Strict,
}
impl Mode {
    pub const ALL: [Self; 3] = [Self::Loose, Self::CaseSensitive, Self::Strict];
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Normalized {
    pub text: String,
    /// One source scalar span per output scalar. A collapsed whitespace run covers all sources.
    pub source_spans: Vec<Range<usize>>,
}
pub fn normalize(input: &str, mode: Mode) -> Normalized {
    let mut spans: Vec<Range<usize>> = vec![];
    let text = normalize_impl(input, mode, &mut spans, usize::MAX, usize::MAX);
    Normalized {
        text,
        source_spans: spans,
    }
}
/// Same output as `normalize(..).text` without the per-scalar source map: verification only
/// needs to know whether a document matches, and the map costs 16 bytes per scalar.
pub fn normalize_text(input: &str, mode: Mode) -> String {
    normalize_impl(input, mode, &mut (), usize::MAX, usize::MAX)
}
/// Normalizes only a prefix: stops once `max_out_bytes` of output exist or `max_source_scalars`
/// source scalars were consumed. Identical to the start of `normalize` (each scalar maps
/// independently; only whitespace merging carries state forward), so snippets can map an early
/// hit without normalizing a whole long document.
pub fn normalize_prefix(
    input: &str,
    mode: Mode,
    max_out_bytes: usize,
    max_source_scalars: usize,
) -> Normalized {
    let mut spans: Vec<Range<usize>> = vec![];
    let text = normalize_impl(
        input,
        mode,
        &mut spans,
        max_out_bytes,
        max_source_scalars,
    );
    Normalized {
        text,
        source_spans: spans,
    }
}
/// Source spans of only the `wanted` output scalars (sorted, distinct), in that order. Same
/// mapping as `normalize(..).source_spans`, but memory follows the number of wanted positions,
/// not the document: 16 bytes per scalar is 1.6 GB on a 100 MiB text (R07).
pub fn source_spans_at(input: &str, mode: Mode, wanted: &[usize]) -> Vec<Range<usize>> {
    let mut sink = Selected { wanted, count: 0, kept_last: false, out: Vec::with_capacity(wanted.len()) };
    normalize_impl(input, mode, &mut sink, usize::MAX, usize::MAX);
    sink.out
}

/// Receives the source span of each output scalar as normalization produces it.
trait SpanSink {
    fn push(&mut self, source: usize);
    /// A merged whitespace run: the last output scalar also covers `source`.
    fn extend_last(&mut self, source: usize);
    /// Nothing further can matter: normalization may stop early.
    fn done(&self) -> bool {
        false
    }
}

impl SpanSink for () {
    fn push(&mut self, _: usize) {}
    fn extend_last(&mut self, _: usize) {}
}

impl SpanSink for Vec<Range<usize>> {
    fn push(&mut self, source: usize) {
        Vec::push(self, source..source + 1);
    }
    fn extend_last(&mut self, source: usize) {
        self.last_mut().unwrap().end = source + 1;
    }
}

struct Selected<'a> {
    wanted: &'a [usize],
    count: usize,
    kept_last: bool,
    out: Vec<Range<usize>>,
}

impl SpanSink for Selected<'_> {
    fn push(&mut self, source: usize) {
        self.kept_last = self.wanted.get(self.out.len()) == Some(&self.count);
        if self.kept_last {
            self.out.push(source..source + 1);
        }
        self.count += 1;
    }
    fn extend_last(&mut self, source: usize) {
        if self.kept_last {
            self.out.last_mut().unwrap().end = source + 1;
        }
    }
    // Stop once the output has moved past the last wanted scalar (its span can no longer grow).
    fn done(&self) -> bool {
        self.out.len() == self.wanted.len() && !self.kept_last
    }
}

fn normalize_impl<S: SpanSink>(
    input: &str,
    mode: Mode,
    spans: &mut S,
    max_out_bytes: usize,
    max_source_scalars: usize,
) -> String {
    let mut out = String::with_capacity(input.len());
    let mut last_space = false;
    if mode == Mode::Strict {
        // Strict keeps every scalar as is: no decomposition, folding or whitespace merging.
        let mut end = input.len();
        for (n, (b, _)) in input.char_indices().enumerate() {
            if n >= max_source_scalars || b >= max_out_bytes {
                end = b;
                break;
            }
        }
        let out = &input[..end];
        for i in 0..out.chars().count() {
            if spans.done() {
                break;
            }
            spans.push(i);
        }
        return out.to_owned();
    }
    let mut push = |d: char, i: usize, out: &mut String, spans: &mut S| {
        let d = if d.is_whitespace() { ' ' } else { d };
        if d == ' ' && last_space {
            spans.extend_last(i);
        } else {
            out.push(d);
            spans.push(i);
        }
        last_space = d == ' ';
    };
    let mut decomposed: Vec<char> = Vec::with_capacity(8);
    for (i, c) in input.chars().enumerate() {
        if i >= max_source_scalars || out.len() >= max_out_bytes || spans.done() {
            break;
        }
        // ASCII fast path: NFKD is identity; loose folding is A–Z → a–z only.
        if c.is_ascii() {
            let d = if mode == Mode::Loose {
                c.to_ascii_lowercase()
            } else {
                c
            };
            push(d, i, &mut out, spans);
            continue;
        }
        // Per-scalar NFKD without allocating a String per character.
        decomposed.clear();
        // A single scalar's full decomposition is already in canonical order; the exhaustive
        // test against `nfkd()` below checks this for every scalar the tables touch.
        unicode_normalization::char::decompose_compatible(c, |d| decomposed.push(d));
        for &d in &decomposed {
            if mode == Mode::Loose
                && let Some(f) = folding::fold(d)
            {
                for x in f.chars() {
                    push(x, i, &mut out, spans);
                }
                continue;
            }
            push(d, i, &mut out, spans);
        }
    }
    out
}
#[allow(dead_code)]
fn normalize_reference(input: &str, mode: Mode) -> Normalized {
    let mut chars: Vec<char> = vec![];
    let mut spans: Vec<Range<usize>> = vec![];
    for (i, c) in input.chars().enumerate() {
        let mapped: String = if mode == Mode::Strict {
            c.to_string()
        } else {
            c.to_string()
                .nfkd()
                .flat_map(|d| {
                    if mode == Mode::Loose {
                        folding::fold(d)
                            .map(str::to_string)
                            .unwrap_or_else(|| d.to_string())
                    } else {
                        d.to_string()
                    }
                    .chars()
                    .collect::<Vec<_>>()
                })
                .collect()
        };
        for d in mapped.chars() {
            let d = if mode != Mode::Strict && d.is_whitespace() {
                ' '
            } else {
                d
            };
            if mode != Mode::Strict && d == ' ' && chars.last() == Some(&' ') {
                spans.last_mut().unwrap().end = i + 1;
            } else {
                chars.push(d);
                spans.push(i..i + 1);
            }
        }
    }
    Normalized {
        text: chars.into_iter().collect(),
        source_spans: spans,
    }
}
impl Normalized {
    pub fn source_range(&self, scalar_range: Range<usize>) -> Option<Range<usize>> {
        if scalar_range.start >= scalar_range.end {
            return None;
        }
        Some(
            self.source_spans.get(scalar_range.start)?.start
                ..self.source_spans.get(scalar_range.end - 1)?.end,
        )
    }
}
pub fn scalar_to_utf16(s: &str, r: Range<usize>) -> Option<Range<usize>> {
    let mut offsets = vec![0];
    for c in s.chars() {
        offsets.push(offsets.last().unwrap() + c.len_utf16());
    }
    if r.start > r.end {
        return None;
    }
    Some(*offsets.get(r.start)?..*offsets.get(r.end)?)
}
pub fn scalar_to_utf8(s: &str, r: Range<usize>) -> Option<Range<usize>> {
    let mut offsets = s.char_indices().map(|(i, _)| i).collect::<Vec<_>>();
    offsets.push(s.len());
    if r.start > r.end {
        return None;
    }
    Some(*offsets.get(r.start)?..*offsets.get(r.end)?)
}
pub fn occurrences(text: &str, needle: &str) -> Vec<Range<usize>> {
    if needle.is_empty() {
        return vec![];
    }
    text.char_indices()
        .enumerate()
        .filter(|(_, (byte, _))| text[*byte..].starts_with(needle))
        .map(|(scalar, _)| scalar..scalar + needle.chars().count())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn fast_paths_match_reference() {
        let mut samples: Vec<String> = [
            "",
            "abc",
            "ABC  def\t\n x",
            "cafe\u{301} café ﬁ Straße İ ＡＢＣ",
            "😀𠀀甲乙丙",
            "a\t\n b",
            "각 각",
            "a\u{315}\u{300}",
            "  lead and trail  ",
            "ǅ ẞ Ⅻ ㎒ ﬀ",
            "\u{3000}全角\u{3000}空格",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect();
        // Every scalar the casefold and NFKD tables touch, embedded in ASCII context.
        for c in (0x80u32..0x3_0000).filter_map(char::from_u32) {
            if folding::fold(c).is_some() || c.to_string().nfkd().ne(std::iter::once(c)) {
                samples.push(format!("A{c} B"));
            }
        }
        for s in &samples {
            for mode in Mode::ALL {
                let reference = normalize_reference(s, mode);
                assert_eq!(normalize(s, mode), reference, "{s:?} {mode:?}");
                assert_eq!(normalize_text(s, mode), reference.text, "{s:?} {mode:?}");
                for k in 0..=s.chars().count() {
                    let p = normalize_prefix(s, mode, usize::MAX, k);
                    assert!(reference.text.starts_with(&p.text), "{s:?} {mode:?} {k}");
                    assert_eq!(
                        p.source_spans[..],
                        reference.source_spans[..p.source_spans.len()]
                            .iter()
                            .map(|r| r.start..r.end.min(k.max(r.start + 1)))
                            .collect::<Vec<_>>()[..],
                        "{s:?} {mode:?} {k}"
                    );
                }
            }
        }
    }
}
