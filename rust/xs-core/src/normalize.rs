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
