const { mdToPdf } = require('md-to-pdf');
const path = require('path');

(async () => {
  const inputPath = path.resolve(__dirname, 'itinerary.md');
  const outputPath = path.resolve(__dirname, 'itinerary.pdf');

  await mdToPdf(
    { path: inputPath },
    {
      dest: outputPath,
      pdf_options: {
        format: 'A4',
        margin: { top: '20mm', right: '20mm', bottom: '20mm', left: '20mm' },
        printBackground: true,
      },
      stylesheet_encoding: 'utf-8',
      css: `
        body {
          font-family: "Noto Sans TC", "Microsoft JhengHei", "PingFang TC", sans-serif;
          font-size: 12px;
          line-height: 1.6;
          color: #333;
        }
        h1 { font-size: 20px; color: #1a1a2e; border-bottom: 2px solid #0066cc; padding-bottom: 8px; }
        h2 { font-size: 16px; color: #0066cc; margin-top: 24px; }
        h3 { font-size: 14px; color: #444; }
        table { width: 100%; border-collapse: collapse; margin: 12px 0; font-size: 11px; }
        th { background: #0066cc; color: white; padding: 6px 8px; text-align: left; }
        td { padding: 5px 8px; border: 1px solid #ddd; }
        tr:nth-child(even) { background: #f5f8ff; }
        blockquote { background: #fff3cd; border-left: 4px solid #ffc107; padding: 8px 12px; margin: 8px 0; }
        strong { color: #0066cc; }
        hr { border: none; border-top: 1px solid #ccc; margin: 16px 0; }
        ul, ol { padding-left: 20px; }
        li { margin: 3px 0; }
      `,
    }
  );

  console.log('PDF generated:', outputPath);
})();
