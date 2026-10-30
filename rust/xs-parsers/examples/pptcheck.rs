//! PPT extraction sanity (counts only): slides, chars per slide, template-text leaks.
use xs_index::AnchorKind;
fn main() {
    for a in std::env::args().skip(1) {
        let e = xs_parsers::office::pptx(std::path::Path::new(&a), xs_parsers::Limits::default()).unwrap();
        let slides = e.anchors.iter().filter(|x| matches!(x.kind, AnchorKind::Slide { .. })).count();
        let notes = e.anchors.iter().filter(|x| matches!(x.kind, AnchorKind::Part { .. })).count();
        let leaks = ["单击此处编辑", "Click to edit", "单击此处添加", "Click to add"].iter().map(|p| e.text.matches(p).count()).sum::<usize>();
        let chars = e.text.chars().count();
        println!("slides={slides}\tnotes={notes}\tchars={chars}\tper_slide={}\ttemplate_leaks={leaks}", chars / slides.max(1));
    }
}
