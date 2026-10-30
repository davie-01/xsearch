import Foundation
import AppKit
import PDFKit

struct Span: Codable { let start: Int; var end: Int }
struct Normalized: Codable { let text: String; let source_spans: [Span] }
func foundationNormalize(_ text: String, mode: String) -> Normalized {
    var result: [Unicode.Scalar] = []; var spans: [Span] = []
    for (i, scalar) in text.unicodeScalars.enumerated() {
        var mapped = String(scalar)
        if mode != "strict" {
            mapped = mapped.decomposedStringWithCompatibilityMapping
            if mode == "loose" { mapped = mapped.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")) }
        }
        for d in mapped.unicodeScalars {
            let whitespace = CharacterSet.whitespacesAndNewlines.contains(d)
            let c: Unicode.Scalar = mode != "strict" && whitespace ? " " : d
            if mode != "strict" && c == " " && result.last == " " { spans[spans.count-1].end = i+1 }
            else { result.append(c); spans.append(Span(start:i,end:i+1)) }
        }
    }
    return Normalized(text: String(String.UnicodeScalarView(result)), source_spans: spans)
}
func normalize(_ text: String, mode: String) -> Normalized {
    let bytes=Array(text.utf8)+[0]
    let code: UInt8 = mode == "strict" ? 2 : mode == "case_sensitive" ? 1 : 0
    return bytes.withUnsafeBufferPointer { buffer in
        guard let result=xs_normalize_utf8(buffer.baseAddress!,buffer.count-1,code) else {fatalError("normalizer rejected input")}
        defer { xs_string_free(result) }
        let data=Data(bytes:result,count:strlen(result))
        return try! JSONDecoder().decode(Normalized.self,from:data)
    }
}
func emit<T: Encodable>(_ value:T) throws {
    let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(value));FileHandle.standardOutput.write(Data([10]))
}
struct Vector: Codable {let input:String;let mode:String}
struct PageInfo: Codable {let page:Int;let scalarStart:Int;let scalarEnd:Int;let utf16Count:Int;let state:String;let invalidScalarCount:Int}
struct SelectionInfo: Codable {let page:Int;let utf16Start:Int;let utf16Length:Int;let exact:Bool;let rectNonempty:Bool}
struct Extracted: Codable {let text:String;let pages:[PageInfo];let selections:[SelectionInfo];let method:String}
struct PDFCheck: Codable {let pages:Int;let checked:Int;let selectionMismatches:Int;let emptyBounds:Int;let queryHits:[String:Int];let textQualityWarningPages:Int}
let args=CommandLine.arguments
do {
    guard args.count>=3 else {throw NSError(domain:"Usage: NativeProbe normalize|extract|make-pdf PATH [query]",code:1)}
    switch args[1] {
    case "normalize", "normalize-foundation":
        let vectors=try JSONDecoder().decode([Vector].self,from:Data(contentsOf:URL(fileURLWithPath:args[2])))
        try emit(vectors.map{args[1] == "normalize" ? normalize($0.input,mode:$0.mode) : foundationNormalize($0.input,mode:$0.mode)})
    case "make-pdf":
        let out=NSMutableData();var media=CGRect(x:0,y:0,width:595,height:842)
        guard let consumer=CGDataConsumer(data:out),let ctx=CGContext(consumer:consumer,mediaBox:&media,nil) else{throw NSError(domain:"PDF context",code:2)}
        for line in ["XSearch 合同 ABC ﬁ cafe\u{301} 😀 𠀀", "第二页 数据共享 合同 AI"] {
            ctx.beginPDFPage(nil)
            let g=NSGraphicsContext(cgContext:ctx,flipped:false);NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=g
            (line as NSString).draw(at:NSPoint(x:40,y:740),withAttributes:[.font:NSFont.systemFont(ofSize:18)])
            NSGraphicsContext.restoreGraphicsState();ctx.endPDFPage()
        }
        ctx.closePDF();try (out as Data).write(to:URL(fileURLWithPath:args[2]));try emit(["created":true])
    case "pdf-verify":
        guard let doc=PDFDocument(url:URL(fileURLWithPath:args[2])),!doc.isLocked else {throw NSError(domain:"PDF unavailable",code:3)}
        let queries=["合同","数据共享","项目","系统","fi","cafe","café","😀","𠀀","AI"]
        var checked=0;var mismatches=0;var empty=0;var hits:[String:Int]=[:];var warningPages=0
        for p in 0..<doc.pageCount {
            guard let page=doc.page(at:p) else{continue};let source=page.string ?? ""
            if source.unicodeScalars.contains(where:{$0.value==0 || $0.value==0xfffd}){warningPages+=1}
            var utf16=[0];for c in source.unicodeScalars {utf16.append(utf16.last!+(c.value>0xffff ? 2:1))}
            let ns=source as NSString
            for mode in ["loose","case_sensitive","strict"] {
                let n=normalize(source,mode:mode);let chars=Array(n.text.unicodeScalars)
                for q in queries {
                    let needle=Array(normalize(q,mode:mode).text.unicodeScalars)
                    guard !needle.isEmpty && chars.count>=needle.count else{continue}
                    for i in 0...(chars.count-needle.count) where chars[i..<(i+needle.count)].elementsEqual(needle) {
                        let start=n.source_spans[i].start;let end=n.source_spans[i+needle.count-1].end
                        let range=NSRange(location:utf16[start],length:utf16[end]-utf16[start]);let expected=ns.substring(with:range)
                        let selection=page.selection(for:range);checked+=1;hits[q,default:0]+=1
                        if selection?.string != expected {mismatches+=1}
                        if selection?.bounds(for:page).isEmpty ?? true {empty+=1}
                    }
                }
            }
        }
        try emit(PDFCheck(pages:doc.pageCount,checked:checked,selectionMismatches:mismatches,emptyBounds:empty,queryHits:hits,textQualityWarningPages:warningPages))
    case "extract":
        let url=URL(fileURLWithPath:args[2]);let ext=url.pathExtension.lowercased()
        if ext=="pdf" {
            guard let doc=PDFDocument(url:url),!doc.isLocked else{throw NSError(domain:"PDF unavailable/locked",code:3)}
            var text="";var pages:[PageInfo]=[];var selections:[SelectionInfo]=[]
            let query=args.count>3 ? args[3] : "数据共享"
            for i in 0..<doc.pageCount {
                guard let page=doc.page(at:i) else{continue};let s=page.string ?? "";let start=text.unicodeScalars.count
                let invalid=s.unicodeScalars.filter{$0.value==0 || $0.value==0xfffd}.count
                let state=s.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? "waiting_ocr" : invalid>0 ? "partial_text" : "text"
                pages.append(PageInfo(page:i+1,scalarStart:start,scalarEnd:start+s.unicodeScalars.count,utf16Count:s.utf16.count,state:state,invalidScalarCount:invalid))
                text+=s+"\n"
                let ns=s as NSString;var remaining=NSRange(location:0,length:ns.length)
                while remaining.length>0 && !query.isEmpty {
                    let range=ns.range(of:query,options:[],range:remaining);if range.location==NSNotFound{break}
                    let selection=page.selection(for:range)
                    selections.append(SelectionInfo(page:i+1,utf16Start:range.location,utf16Length:range.length,exact:selection?.string==query,rectNonempty:!(selection?.bounds(for:page).isEmpty ?? true)))
                    let next=range.location+range.length;remaining=NSRange(location:next,length:ns.length-next)
                }
            }
            try emit(Extracted(text:text,pages:pages,selections:selections,method:"PDFKit"))
        } else {
            let options:[NSAttributedString.DocumentReadingOptionKey:Any]=[.documentType:ext=="doc" || ext=="dot" ? NSAttributedString.DocumentType.docFormat : NSAttributedString.DocumentType.officeOpenXML]
            let attributed=try NSAttributedString(url:url,options:options,documentAttributes:nil)
            try emit(Extracted(text:attributed.string,pages:[],selections:[],method:"NSAttributedString"))
        }
    default: throw NSError(domain:"Unknown command",code:1)
    }
} catch { FileHandle.standardError.write(Data("NativeProbe failed: \(error)\n".utf8));exit(1) }

