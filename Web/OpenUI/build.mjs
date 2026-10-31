import { build } from 'esbuild';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.dirname(fileURLToPath(import.meta.url));
const dist = path.resolve(root, '../../Sources/PicoOpenUIRuntime/Resources/OpenUI');
const pins = JSON.parse(await fs.readFile(path.join(root, 'package.json'), 'utf8'));
await fs.mkdir(dist, { recursive: true });
const versions = Object.fromEntries(Object.entries(pins.dependencies).filter(([name]) => name.startsWith('@openuidev/') || name === 'react' || name === 'react-dom'));
const result = await build({
  absWorkingDir: root,
  entryPoints: [path.join(root, 'src/main.jsx')],
  outfile: path.join(dist, 'app.js'),
  bundle: true, platform: 'browser', format: 'iife', target: 'safari26',
  minify: true, legalComments: 'linked', metafile: true,
  define: {
    'process.env.NODE_ENV': '"production"',
    'process.env.OPENUI_TELEMETRY_DISABLED': '"1"',
    'process.env.DO_NOT_TRACK': '"1"',
    '__PICO_OPENUI_VERSIONS__': JSON.stringify(versions),
  },
  logLevel: 'info',
});
await fs.writeFile(path.join(dist, 'index.html'), `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
<title>OpenUI content</title><link rel="stylesheet" href="app.css"><script defer src="app.js"></script></head><body><main id="root" aria-label="Interactive OpenUI content"></main></body></html>\n`);
await fs.writeFile(path.join(dist, 'Versions.json'), JSON.stringify(versions, null, 2) + '\n');
const packageNames = [...new Set(Object.keys(result.metafile.inputs).map(input => /node_modules\/((?:@[^/]+\/)?[^/]+)/.exec(input)?.[1]).filter(Boolean))].sort();
let notices = '# Bundled OpenUI third party notices\n\n';
for (const name of packageNames) {
  const location = path.join(root, 'node_modules', name);
  const metadata = JSON.parse(await fs.readFile(path.join(location, 'package.json'), 'utf8'));
  notices += `\n## ${name} ${metadata.version}\nLicense: ${typeof metadata.license === 'string' ? metadata.license : JSON.stringify(metadata.license ?? 'see package')}\n`;
  const files = (await fs.readdir(location)).filter(file => /^(licen[cs]e|copying|notice)(\.|$)/i.test(file)).sort();
  for (const file of files) {
    const filePath = path.join(location, file);
    if ((await fs.stat(filePath)).isFile()) notices += `\n${file}\n\n${await fs.readFile(filePath, 'utf8')}\n`;
  }
  if (name.startsWith('@openuidev/') && files.length === 0) {
    notices += '\nMIT License\nCopyright (c) 2011-2024 Thesys Inc.\n\nPermission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:\nThe above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.\nTHE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.\n';
  }
}
await fs.writeFile(path.join(dist, 'THIRD_PARTY_NOTICES.txt'), notices);
const files = await Promise.all(['app.js','app.css','index.html'].map(async name => ({name, bytes:(await fs.stat(path.join(dist,name))).size})));
await fs.writeFile(path.join(dist, 'BuildInfo.json'), JSON.stringify({ versions, files, bundledPackageCount:packageNames.length }, null, 2) + '\n');
console.log(JSON.stringify({ versions, files, bundledPackageCount: packageNames.length }, null, 2));
