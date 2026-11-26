//! Formats older Office versions saved under ordinary extensions: Excel 2003 XML spreadsheets
//! and "single file web pages" (MHTML), both usually named .xls. Reached through
//! `sniff`, never by extension.
use crate::office::{Out, column};
use crate::{Extraction, Limits};
use anyhow::{Context, Result, anyhow};
use mail_parser::{MessageParser, MimeHeaders, PartType};
use std::{fs::File, io::Read, path::Path};
use xs_index::AnchorKind;

const SS: &str = "urn:schemas-microsoft-com:office:spreadsheet";

fn read(path: &Path, limits: Limits) -> Result<Vec<u8>> {
    let mut bytes = vec![];
    File::open(path)?.take(limits.max_file_bytes).read_to_end(&mut bytes)?;
    Ok(bytes)
}

/// Excel 2003 XML: like the other spreadsheets, one line per non-empty row (cells separated by
/// tabs) anchored "Sheet1!A12" at its first non-empty cell. `ss:Index` skips rows and columns.
pub fn excel_xml(path: &Path, limits: Limits) -> Result<Extraction> {
    let bytes = read(path, limits)?;
    let src = std::str::from_utf8(bytes.strip_prefix(b"\xEF\xBB\xBF").unwrap_or(&bytes)).context("spreadsheet XML is not UTF-8")?;
    let opts = roxmltree::ParsingOptions { allow_dtd: true, ..Default::default() };
    let doc = roxmltree::Document::parse_with_options(src, opts).context("spreadsheet XML unreadable")?;
    let mut out = Out::new(limits);
    'sheets: for (n, sheet) in doc.descendants().filter(|e| e.has_tag_name((SS, "Worksheet"))).enumerate() {
        let name = sheet.attribute((SS, "Name")).map(str::to_owned).unwrap_or_else(|| format!("Sheet{}", n + 1));
        let Some(table) = sheet.children().find(|e| e.has_tag_name((SS, "Table"))) else { continue };
        let mut r = 0usize;
        for row in table.children().filter(|e| e.has_tag_name((SS, "Row"))) {
            r = index(row).unwrap_or(r + 1);
            let mut c = 0usize;
            let mut cells: Vec<(usize, String)> = vec![];
            for cell in row.children().filter(|e| e.has_tag_name((SS, "Cell"))) {
                c = index(cell).unwrap_or(c + 1);
                // Rich text puts html:Font / html:B elements inside Data.
                let text: String = cell
                    .children()
                    .filter(|e| e.has_tag_name((SS, "Data")))
                    .flat_map(|d| d.descendants().filter(|t| t.is_text()).filter_map(|t| t.text()))
                    .collect();
                let text = text.trim();
                if !text.is_empty() {
                    cells.push((c, text.to_owned()));
                }
                c += cell.attribute((SS, "MergeAcross")).and_then(|m| m.parse::<usize>().ok()).unwrap_or(0);
            }
            let Some((first, _)) = cells.first() else { continue };
            out.anchor(AnchorKind::Sheet { sheet: name.clone(), cell: format!("{}{}", column(first - 1), r) });
            let line = cells.into_iter().map(|(_, s)| s).collect::<Vec<_>>().join("\t");
            if !out.push(&line) || !out.push("\n") {
                break 'sheets;
            }
        }
    }
    Ok(out.done("excel2003xml"))
}

/// 1-based `ss:Index`.
fn index(e: roxmltree::Node) -> Option<usize> {
    e.attribute((SS, "Index")).and_then(|i| i.parse().ok()).filter(|&i| i > 0)
}

/// MHTML: every HTML part read like a web page, in order (Excel puts each sheet in a part of
/// its own); a part anchor per HTML part, named after its file.
pub fn web_archive(path: &Path, limits: Limits) -> Result<Extraction> {
    let bytes = read(path, limits)?;
    let msg = MessageParser::default().parse(&bytes[..]).ok_or_else(|| anyhow!("not a web archive"))?;
    let mut out = Out::new(limits);
    let mut para = 0;
    for part in &msg.parts {
        let PartType::Html(h) = &part.body else { continue };
        let location = part.content_location().unwrap_or("");
        let name = location.rsplit(['/', '\\']).next().unwrap_or("").to_owned();
        // Excel's sheet tab bar repeats the sheet names; its frameset page holds only the
        // "your browser does not support frames" notice.
        if name.eq_ignore_ascii_case("tabstrip.htm") || h.to_ascii_lowercase().contains("<frameset") {
            continue;
        }
        out.anchor(AnchorKind::Part { name: if name.is_empty() { "页面".into() } else { name } });
        crate::web::html_into(h, &mut out, &mut para);
        if out.partial {
            break;
        }
    }
    Ok(out.done("mhtml"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(dir: &tempfile::TempDir, name: &str, s: &str) -> std::path::PathBuf {
        let p = dir.path().join(name);
        std::fs::write(&p, s).unwrap();
        p
    }

    #[test]
    fn excel_2003_xml_rows_and_cells() {
        let d = tempfile::tempdir().unwrap();
        let xml = r#"<?xml version="1.0"?>
<?mso-application progid="Excel.Sheet"?>
<Workbook xmlns="urn:schemas-microsoft-com:office:spreadsheet" xmlns:ss="urn:schemas-microsoft-com:office:spreadsheet" xmlns:html="http://www.w3.org/TR/REC-html40">
 <Worksheet ss:Name="漏洞">
  <Table>
   <Row><Cell><Data ss:Type="String">漏洞名称</Data></Cell><Cell ss:MergeAcross="1"><Data ss:Type="String">位置</Data></Cell><Cell><Data ss:Type="Number">7.5</Data></Cell></Row>
   <Row ss:Index="4"><Cell ss:Index="2"><ss:Data ss:Type="String"><html:B>加粗</html:B>文字</ss:Data></Cell></Row>
  </Table>
 </Worksheet>
 <Worksheet ss:Name="空"><Table/></Worksheet>
</Workbook>"#;
        let e = excel_xml(&write(&d, "a.xls", xml), Limits::default()).unwrap();
        assert_eq!(e.text, "漏洞名称\t位置\t7.5\n加粗文字\n");
        let cells: Vec<_> = e.anchors.iter().map(|a| a.kind.clone()).collect();
        assert_eq!(cells, vec![
            AnchorKind::Sheet { sheet: "漏洞".into(), cell: "A1".into() },
            AnchorKind::Sheet { sheet: "漏洞".into(), cell: "B4".into() },
        ]);
    }

    #[test]
    fn web_archive_reads_every_html_part() {
        let d = tempfile::tempdir().unwrap();
        let mht = "MIME-Version: 1.0\r\nContent-Type: multipart/related; boundary=\"B\"\r\n\r\n--B\r\nContent-Location: file:///C:/x/file1.htm\r\nContent-Type: text/html; charset=\"utf-8\"\r\n\r\n<html><frameset><noframes>此页面使用了框架</noframes></frameset></html>\r\n--B\r\nContent-Location: file:///C:/x/file1.files/tabstrip.htm\r\nContent-Type: text/html\r\n\r\n<html><body>Sheet1</body></html>\r\n--B\r\nContent-Location: file:///C:/x/file1.files/sheet001.htm\r\nContent-Type: text/html; charset=\"us-ascii\"\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n<html><body><table><tr><td>&#20154;=E5=91=98</td><td>=E4=BF=9D=E9=99=A9</td></tr></table></body></html>\r\n--B\r\nContent-Location: file:///C:/x/file1.files/stylesheet.css\r\nContent-Type: text/css\r\n\r\ntd{}\r\n--B--\r\n";
        let e = web_archive(&write(&d, "b.xls", mht), Limits::default()).unwrap();
        assert!(e.text.contains("人"), "{:?}", e.text);
        assert!(!e.text.contains("Sheet1") && !e.text.contains("框架"));
        assert!(!e.text.contains("td{}"));
        assert!(e.anchors.iter().any(|a| a.kind == AnchorKind::Part { name: "sheet001.htm".into() }));
    }
}
