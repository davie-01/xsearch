//! Production content index (ARCHITECTURE §8, M2-1). One writer process commits batches; any
//! number of readers search immutable snapshots. Recall uses UTF-8 byte trigrams over the loose
//! normalization; every candidate is verified against its stored text, so results are exact
//! literal matches under the requested mode (§8.2–8.4).
pub mod doc;
pub mod reader;
pub mod schema;
pub mod writer;

pub use doc::{Anchor, AnchorKind, ContentDoc, ExtractState, PageState, Source};
pub use reader::{Batch, ContentReader, DocView, Hit, Recall, SearchRequest, SearchSession, TextHit, TextMatcher};
pub use writer::{CommitInfo, ContentWriter};
pub use xs_core::normalize::Mode;
pub use xs_core::query::{Expr, parse};
