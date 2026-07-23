const PDFDocument = require('pdfkit');
const fs = require('fs');
const path = require('path');

const md = fs.readFileSync(path.resolve(__dirname, 'itinerary.md'), 'utf8');
const doc = new PDFDocument({ size: 'A4', margin: 45, info: { Title: '釜山四天跨年行程 2026-2027' } });
const out = fs.createWriteStream(path.resolve(__dirname, 'itinerary.pdf'));
doc.pipe(out);

// Font helpers — pdfkit built-in Helvetica for ASCII, fallback for CJK
// We'll embed a CJK font if available, else use built-in
let cjkFont = null;
const fontPaths = [
  path.resolve(__dirname, '../../fonts/NotoSansCJKtc-Regular.otf'),
  '/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc',
  '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
  '/usr/share/fonts/truetype/noto/NotoSansSC-Regular.otf',
  '/usr/share/fonts/truetype/arphic/uming.ttc',
];
for (const fp of fontPaths) {
  if (fs.existsSync(fp)) { cjkFont = fp; break; }
}

let cjkBold = null;
const boldPaths = [
  path.resolve(__dirname, '../../fonts/NotoSansCJKtc-Bold.otf'),
  '/usr/share/fonts/truetype/noto/NotoSansCJK-Bold.ttc',
];
for (const fp of boldPaths) {
  if (fs.existsSync(fp)) { cjkBold = fp; break; }
}

if (cjkFont) {
  doc.registerFont('CJK', cjkFont);
  doc.registerFont('CJK-Bold', cjkBold || cjkFont);
}

const F = {
  normal: cjkFont ? 'CJK' : 'Helvetica',
  bold: cjkFont ? 'CJK-Bold' : 'Helvetica-Bold',
};

// Colors
const C = {
  title: '#1a1a2e',
  h2: '#0044aa',
  h2bg: '#ddeeff',
  h3: '#444444',
  tableHead: '#003d99',
  tableHeadFg: '#ffffff',
  tableEven: '#f0f4ff',
  tableBorder: '#cccccc',
  blockquote: '#fff8e1',
  blockquoteLine: '#ffc107',
  strong: '#cc2200',
  muted: '#666666',
  text: '#222222',
};

const PAGE_W = 595 - 90; // A4 width minus margins
const LEFT = 45;

function font(bold) { return doc.font(bold ? F.bold : F.normal); }
function text(str, opts) { doc.text(str, opts); }

// Parse markdown lines into tokens
function parse(raw) {
  const lines = raw.split('\n');
  const tokens = [];
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    if (line.startsWith('# ')) { tokens.push({ type: 'h1', text: line.slice(2) }); i++; }
    else if (line.startsWith('## ')) { tokens.push({ type: 'h2', text: line.slice(3) }); i++; }
    else if (line.startsWith('### ')) { tokens.push({ type: 'h3', text: line.slice(4) }); i++; }
    else if (line.startsWith('> ')) { tokens.push({ type: 'blockquote', text: line.slice(2) }); i++; }
    else if (line === '---') { tokens.push({ type: 'hr' }); i++; }
    else if (line.match(/^\s*-\s*\[[ x]\]/)) {
      const done = line.includes('[x]');
      const t = line.replace(/^\s*-\s*\[[ x]\]\s*/, '');
      tokens.push({ type: 'listitem', text: (done ? '☑ ' : '☐ ') + t }); i++;
    }
    else if (line.startsWith('- ')) { tokens.push({ type: 'listitem', text: '• ' + line.slice(2) }); i++; }
    else if (line.startsWith('|')) {
      // Table
      const tableLines = [];
      while (i < lines.length && lines[i].startsWith('|')) { tableLines.push(lines[i]); i++; }
      const headers = tableLines[0].split('|').map(s => s.trim()).filter(s => s);
      const rows = tableLines.slice(2).map(l => l.split('|').map(s => s.trim()).filter(s => s));
      tokens.push({ type: 'table', headers, rows });
    }
    else if (line.trim() === '') { tokens.push({ type: 'blank' }); i++; }
    else { tokens.push({ type: 'para', text: line }); i++; }
  }
  return tokens;
}

// Strip inline markdown (bold, italic, links) and return plain text
function strip(str) {
  return str
    .replace(/\*\*(.+?)\*\*/g, '$1')
    .replace(/\*(.+?)\*/g, '$1')
    .replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')
    .replace(/`(.+?)`/g, '$1');
}

// Check if string has bold
function hasBold(str) { return /\*\*/.test(str); }

function renderInline(str, x, y, opts = {}) {
  // Split on **bold** and render segments
  const parts = str.split(/(\*\*[^*]+\*\*)/);
  // pdfkit doesn't support per-word bold inline easily; just strip and render
  doc.font(F.normal).fontSize(opts.size || 10.5).fillColor(opts.color || C.text)
    .text(strip(str), x !== undefined ? x : LEFT, y !== undefined ? y : undefined, {
      width: opts.width || PAGE_W,
      continued: opts.continued || false,
      align: opts.align || 'left',
    });
}

function renderTokens(tokens) {
  let listBuffer = [];

  function flushList() {
    if (!listBuffer.length) return;
    listBuffer.forEach(t => {
      doc.font(F.normal).fontSize(10.5).fillColor(C.text)
        .text(strip(t), LEFT + 12, undefined, { width: PAGE_W - 12 });
    });
    listBuffer = [];
    doc.moveDown(0.2);
  }

  tokens.forEach(tok => {
    if (tok.type !== 'listitem') flushList();

    switch (tok.type) {
      case 'h1':
        doc.moveDown(0.3);
        doc.font(F.bold).fontSize(17).fillColor(C.title).text(strip(tok.text), LEFT, undefined, { width: PAGE_W });
        // underline
        const y1 = doc.y + 3;
        doc.moveTo(LEFT, y1).lineTo(LEFT + PAGE_W, y1).strokeColor(C.h2).lineWidth(2).stroke();
        doc.moveDown(0.5);
        break;

      case 'h2':
        doc.moveDown(0.4);
        const h2y = doc.y;
        doc.rect(LEFT, h2y, PAGE_W, 20).fill(C.h2bg);
        doc.font(F.bold).fontSize(12.5).fillColor(C.h2).text(strip(tok.text), LEFT + 6, h2y + 4, { width: PAGE_W - 12 });
        doc.y = h2y + 24;
        doc.moveDown(0.2);
        break;

      case 'h3':
        doc.moveDown(0.3);
        doc.font(F.bold).fontSize(11).fillColor(C.h3).text(strip(tok.text), LEFT, undefined, { width: PAGE_W });
        doc.moveDown(0.1);
        break;

      case 'blockquote':
        doc.moveDown(0.2);
        const bqy = doc.y;
        const bqText = strip(tok.text);
        const bqHeight = Math.max(20, doc.heightOfString(bqText, { width: PAGE_W - 22 }) + 10);
        doc.rect(LEFT, bqy, PAGE_W, bqHeight).fill(C.blockquote);
        doc.moveTo(LEFT, bqy).lineTo(LEFT, bqy + bqHeight).strokeColor(C.blockquoteLine).lineWidth(3).stroke();
        doc.font(F.normal).fontSize(10).fillColor('#555').text(bqText, LEFT + 10, bqy + 5, { width: PAGE_W - 22 });
        doc.y = bqy + bqHeight + 4;
        doc.moveDown(0.1);
        break;

      case 'hr':
        doc.moveDown(0.3);
        const hry = doc.y;
        doc.moveTo(LEFT, hry).lineTo(LEFT + PAGE_W, hry).strokeColor('#cccccc').lineWidth(0.5).stroke();
        doc.moveDown(0.4);
        break;

      case 'listitem':
        listBuffer.push(tok.text);
        break;

      case 'table':
        renderTable(tok.headers, tok.rows);
        break;

      case 'para':
        if (tok.text.trim()) {
          doc.font(F.normal).fontSize(10.5).fillColor(C.text).text(strip(tok.text), LEFT, undefined, { width: PAGE_W });
          doc.moveDown(0.15);
        }
        break;

      case 'blank':
        // skip extra blanks but give small space
        break;
    }
  });
  flushList();
}

function renderTable(headers, rows) {
  doc.moveDown(0.3);
  const colCount = headers.length;
  // Dynamic col widths based on content
  const colWidths = headers.map((h, i) => {
    const maxLen = Math.max(h.length, ...rows.map(r => (r[i] || '').length));
    return maxLen;
  });
  const totalLen = colWidths.reduce((a, b) => a + b, 0);
  const widths = colWidths.map(w => (w / totalLen) * PAGE_W);

  const CELL_PAD = 4;
  const ROW_H_BASE = 14;

  // Calculate row heights
  function rowHeight(cells) {
    let maxH = ROW_H_BASE;
    cells.forEach((cell, i) => {
      const h = doc.heightOfString(strip(cell || ''), { width: widths[i] - CELL_PAD * 2, font: F.normal, fontSize: 10 }) + CELL_PAD * 2;
      if (h > maxH) maxH = h;
    });
    return maxH;
  }

  // Header row
  let x = LEFT;
  const headerH = rowHeight(headers);
  if (doc.y + headerH > doc.page.height - 60) doc.addPage();
  const hy = doc.y;
  headers.forEach((h, i) => {
    doc.rect(x, hy, widths[i], headerH).fill(C.tableHead);
    doc.font(F.bold).fontSize(10).fillColor(C.tableHeadFg)
      .text(strip(h), x + CELL_PAD, hy + CELL_PAD, { width: widths[i] - CELL_PAD * 2, height: headerH - CELL_PAD * 2 });
    x += widths[i];
  });
  doc.y = hy + headerH;

  // Data rows
  rows.forEach((row, ri) => {
    const cells = headers.map((_, i) => row[i] || '');
    const rh = rowHeight(cells);
    if (doc.y + rh > doc.page.height - 60) doc.addPage();
    const ry = doc.y;
    let rx = LEFT;
    cells.forEach((cell, i) => {
      const bg = ri % 2 === 1 ? C.tableEven : '#ffffff';
      doc.rect(rx, ry, widths[i], rh).fill(bg).stroke(C.tableBorder);
      doc.font(F.normal).fontSize(10).fillColor(C.text)
        .text(strip(cell), rx + CELL_PAD, ry + CELL_PAD, { width: widths[i] - CELL_PAD * 2, height: rh - CELL_PAD * 2 });
      rx += widths[i];
    });
    doc.y = ry + rh;
  });

  doc.moveDown(0.4);
}

const tokens = parse(md);
renderTokens(tokens);

doc.end();
out.on('finish', () => console.log('PDF written to', path.resolve(__dirname, 'itinerary.pdf')));
out.on('error', e => { console.error(e); process.exit(1); });
