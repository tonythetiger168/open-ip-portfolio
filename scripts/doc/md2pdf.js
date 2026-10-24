// SPDX-License-Identifier: Apache-2.0
// Print HTML pages to PDF with headless Chromium (Playwright).
//   node scripts/doc/md2pdf.js <in.html> <out.pdf> [<in.html> <out.pdf> ...]
const { chromium } = require('playwright');

(async () => {
  const args = process.argv.slice(2);
  const browser = await chromium.launch();
  const page = await browser.newPage();
  for (let i = 0; i + 1 < args.length; i += 2) {
    await page.goto('file://' + require('path').resolve(args[i]), { waitUntil: 'load' });
    const title = await page.title();
    await page.pdf({
      path: args[i + 1], format: 'A4', printBackground: true, preferCSSPageSize: true,
      displayHeaderFooter: true,
      headerTemplate: `<div style="font-size:7pt;color:#777;width:100%;padding:0 14mm;font-family:sans-serif">` +
        `<span>open-ip-portfolio</span><span style="float:right">${title.replace(/</g, '&lt;')}</span></div>`,
      footerTemplate: '<div style="font-size:7pt;color:#777;width:100%;text-align:center;font-family:sans-serif">' +
        '<span class="pageNumber"></span> / <span class="totalPages"></span></div>',
    });
  }
  await browser.close();
})().catch(e => { console.error(e); process.exit(1); });
