#!/usr/bin/env python3
"""Create deterministic synthetic fixtures; never touches the supplied real corpus."""
import json, pathlib, zipfile
root=pathlib.Path(__file__).resolve().parents[1]
out=root/'Tests/Fixtures/m0'
texts=['合同 AI IP cafe\u0301 ﬁ ＡＢＣ 𠀀 😀', 'café\t\nＡ  A', 'Straße STRASSE İ i\u0307', '가 가', 'q\u0307\u0323 q\u0323\u0307', 'a\u0085b\u00a0c\u2028d\u3000e', 'α xα xy\x00', 'a'*3, '']
vectors=[dict(input=s,mode=m) for s in texts for m in ['loose','case_sensitive','strict']]
(out/'normalization.json').write_text(json.dumps(vectors,ensure_ascii=False,indent=2))
(out/'sample.txt').write_text(texts[0]+'\n数据共享。合同验收。\n')
ns='http://schemas.openxmlformats.org/wordprocessingml/2006/main'
parts={
'word/document.xml':f'<w:document xmlns:w="{ns}"><w:body><w:p><w:r><w:t>正文合同 café ﬁ 😀</w:t></w:r></w:p><w:tbl><w:tr><w:tc><w:p><w:r><w:t>表格单元格 AI</w:t></w:r></w:p></w:tc></w:tr></w:tbl><w:p><w:r><w:drawing><w:txbxContent><w:p><w:r><w:t>文本框数据共享</w:t></w:r></w:p></w:txbxContent></w:drawing></w:r></w:p></w:body></w:document>',
'word/header1.xml':f'<w:hdr xmlns:w="{ns}"><w:p><w:r><w:t>页眉甲方</w:t></w:r></w:p></w:hdr>',
'word/footer1.xml':f'<w:ftr xmlns:w="{ns}"><w:p><w:r><w:t>页脚乙方</w:t></w:r></w:p></w:ftr>',
'word/footnotes.xml':f'<w:footnotes xmlns:w="{ns}"><w:footnote w:id="1"><w:p><w:r><w:t>脚注验收说明</w:t></w:r></w:p></w:footnote></w:footnotes>',
'word/endnotes.xml':f'<w:endnotes xmlns:w="{ns}"><w:endnote w:id="1"><w:p><w:r><w:t>尾注编号2202</w:t></w:r></w:p></w:endnote></w:endnotes>',
'[Content_Types].xml':'<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>',
'_rels/.rels':'<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>'
}
with zipfile.ZipFile(out/'structure.docx','w',zipfile.ZIP_DEFLATED) as z:
    for name,value in parts.items():
        info=zipfile.ZipInfo(name,date_time=(2026,1,1,0,0,0));info.compress_type=zipfile.ZIP_DEFLATED;z.writestr(info,value)
print('Generated synthetic text, normalization vectors and DOCX structure fixture.')

