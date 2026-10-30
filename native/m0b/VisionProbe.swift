import Foundation
import AppKit
import PDFKit
import Vision
import ImageIO
struct OCRRow: Codable {
    let page: Int; let dpi: Int; let width: Int; let height: Int
    let renderMs: Double; let recognizeMs: Double; let characters: Int; let referenceCharacters: Int
    let editDistance: Int; let characterErrorRate: Double?; let characterBagRecall: Double?
    let meanConfidence: Double; let revision: Int; let referenceAvailable: Bool
    let text: String
}
func clean(_ s:String)->[Unicode.Scalar] {Array(s.precomposedStringWithCanonicalMapping.unicodeScalars.filter{!CharacterSet.whitespacesAndNewlines.contains($0)})}
func distance(_ a:[Unicode.Scalar],_ b:[Unicode.Scalar])->Int {
    if a.isEmpty{return b.count};if b.isEmpty{return a.count}
    var previous=Array(0...b.count);var current=Array(repeating:0,count:b.count+1)
    for i in 1...a.count {current[0]=i;for j in 1...b.count{current[j]=min(previous[j]+1,current[j-1]+1,previous[j-1]+(a[i-1]==b[j-1] ? 0:1))};swap(&previous,&current)}
    return previous[b.count]
}
func raster(_ page:PDFPage,dpi:Int)->CGImage? {
    let bounds=page.bounds(for:.mediaBox);let scale=Double(dpi)/72
    let width=Int(ceil(bounds.width*scale));let height=Int(ceil(bounds.height*scale))
    guard width>0,height>0,width*height<40_000_000,let c=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{return nil}
    c.setFillColor(NSColor.white.cgColor);c.fill(CGRect(x:0,y:0,width:width,height:height));c.scaleBy(x:scale,y:scale);c.translateBy(x:-bounds.minX,y:-bounds.minY);page.draw(with:.mediaBox,to:c)
    return c.makeImage()
}
let args=CommandLine.arguments
do {
    if args.count>=4 && args[1] == "--render" {
        guard let pdf=PDFDocument(url:URL(fileURLWithPath:args[2])) else{throw NSError(domain:"PDF open failed",code:1)}
        let folder=URL(fileURLWithPath:args[3]);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        for i in 0..<min(pdf.pageCount,10) {
            guard let page=pdf.page(at:i),let image=raster(page,dpi:150),let dest=CGImageDestinationCreateWithURL(folder.appendingPathComponent("page-\(i+1).png") as CFURL,"public.png" as CFString,1,nil) else {throw NSError(domain:"PDF render failed",code:2)}
            CGImageDestinationAddImage(dest,image,nil);guard CGImageDestinationFinalize(dest) else{throw NSError(domain:"PNG write failed",code:3)}
        }
        exit(0)
    }
    if args.count>=4 && args[1] == "--batch" {
        struct Job:Codable {let source:String;let path:String;let kind:String;let page:Int;let dpi:Int;let maxDimension:Int}
        struct Row:Codable {let source:String;let kind:String;let scale:Int;let nativePDFCharacters:Int;let result:OCRRow}
        let jobs=try JSONDecoder().decode([Job].self,from:Data(contentsOf:URL(fileURLWithPath:args[2])));var output:[Row]=[]
        for job in jobs {try autoreleasepool {
            let begin=DispatchTime.now().uptimeNanoseconds;var image:CGImage?;var nativeCount=0
            if job.kind == "scan_pdf" {
                if let pdf=PDFDocument(url:URL(fileURLWithPath:job.path)),let page=pdf.page(at:job.page-1){nativeCount=clean(page.string ?? "").count;image=raster(page,dpi:job.dpi)}
            } else if let source=CGImageSourceCreateWithURL(URL(fileURLWithPath:job.path) as CFURL,nil) {
                image=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:job.maxDimension] as CFDictionary)
            }
            guard let image=image else{throw NSError(domain:"Input decode failed",code:4)}
            let rendered=DispatchTime.now().uptimeNanoseconds;let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate;request.recognitionLanguages=["zh-Hans","en-US"];request.usesLanguageCorrection=true
            try VNImageRequestHandler(cgImage:image,options:[:]).perform([request]);let done=DispatchTime.now().uptimeNanoseconds
            let candidates=(request.results ?? []).compactMap{$0.topCandidates(1).first};let text=candidates.map(\.string).joined(separator:"\n");let count=clean(text).count
            let row=OCRRow(page:job.page,dpi:job.dpi,width:image.width,height:image.height,renderMs:Double(rendered-begin)/1e6,recognizeMs:Double(done-rendered)/1e6,characters:count,referenceCharacters:0,editDistance:0,characterErrorRate:nil,characterBagRecall:nil,meanConfidence:candidates.isEmpty ? 0:Double(candidates.reduce(Float(0)){$0+$1.confidence})/Double(candidates.count),revision:request.revision,referenceAvailable:false,text:text)
            output.append(Row(source:job.source,kind:job.kind,scale:job.kind=="scan_pdf" ? job.dpi:job.maxDimension,nativePDFCharacters:nativeCount,result:row));fputs("OCR \(job.source), scale \(job.kind=="scan_pdf" ? job.dpi:job.maxDimension) complete\n",stderr)
        }}
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];try encoder.encode(output).write(to:URL(fileURLWithPath:args[3]));print("Completed \(output.count) real scan/image observations.");exit(0)
    }
    guard args.count>=3,let pdf=PDFDocument(url:URL(fileURLWithPath:args[1])),!pdf.isLocked else{throw NSError(domain:"Usage: VisionProbe PDF OUTPUT_JSON [PAGES]",code:1)}
    let limit=min(pdf.pageCount,args.count>3 ? Int(args[3]) ?? 10 : 10);var rows:[OCRRow]=[]
    for dpi in [150,300] {for i in 0..<limit {
        try autoreleasepool {
            guard let page=pdf.page(at:i) else{throw NSError(domain:"Missing PDF page",code:2)}
            let reference=clean(page.string ?? "");let begin=DispatchTime.now().uptimeNanoseconds
            guard let image=raster(page,dpi:dpi) else{throw NSError(domain:"Rasterization failed or image limit",code:3)}
            let rendered=DispatchTime.now().uptimeNanoseconds
            let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate;request.recognitionLanguages=["zh-Hans","en-US"];request.usesLanguageCorrection=true
            try VNImageRequestHandler(cgImage:image,options:[:]).perform([request])
            let recognized=DispatchTime.now().uptimeNanoseconds
            let candidates=(request.results ?? []).compactMap{$0.topCandidates(1).first};let text=candidates.map(\.string).joined(separator:"\n");let chars=clean(text)
            var refBag:[Unicode.Scalar:Int]=[:];var gotBag:[Unicode.Scalar:Int]=[:]
            for c in reference{refBag[c,default:0]+=1};for c in chars{gotBag[c,default:0]+=1}
            let overlap=refBag.reduce(0){$0+min($1.value,gotBag[$1.key,default:0])};let edits=distance(reference,chars)
            rows.append(OCRRow(page:i+1,dpi:dpi,width:image.width,height:image.height,renderMs:Double(rendered-begin)/1e6,recognizeMs:Double(recognized-rendered)/1e6,characters:chars.count,referenceCharacters:reference.count,editDistance:edits,characterErrorRate:reference.isEmpty ? nil : Double(edits)/Double(reference.count),characterBagRecall:reference.isEmpty ? nil : Double(overlap)/Double(reference.count),meanConfidence:candidates.isEmpty ? 0 : Double(candidates.reduce(Float(0)){$0+$1.confidence})/Double(candidates.count),revision:request.revision,referenceAvailable:!reference.isEmpty,text:text))
            fputs("OCR page \(i+1)/\(limit) at \(dpi) DPI complete\n",stderr)
        }
    }}
    let e=JSONEncoder();e.outputFormatting=[.prettyPrinted,.sortedKeys];try e.encode(rows).write(to:URL(fileURLWithPath:args[2]));print("Completed \(rows.count) local OCR observations.")
} catch {fputs("Vision probe failed: \(error)\n",stderr);exit(1)}
