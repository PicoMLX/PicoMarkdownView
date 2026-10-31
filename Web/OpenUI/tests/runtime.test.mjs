import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createParser } from '@openuidev/lang-core';
import { openuiLibrary } from '@openuidev/react-ui';
import { JSDOM, VirtualConsole } from 'jsdom';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const assets = path.resolve(root, '../../Sources/PicoOpenUIRuntime/Resources/OpenUI');
const fixtures = JSON.parse(await fs.readFile(path.join(root, 'tests/fixtures.json'), 'utf8'));
const parser = createParser(openuiLibrary.toJSONSchema(), openuiLibrary.root);
for (const fixture of fixtures) {
  const result = parser.parse(fixture.source);
  assert.ok(result.root, `${fixture.id} has a root`);
  assert.equal(result.meta.incomplete, false, `${fixture.id} is complete`);
  assert.deepEqual(result.meta.unresolved, [], `${fixture.id} resolves its references`);
  assert.deepEqual(result.meta.errors, [], `${fixture.id} matches the official schema`);
  console.log('PASS parser:', fixture.id);
}
assert.ok(parser.parse('root = NoSuchComponent("test")').meta.errors.length > 0);

const messages = [];
const layout = { rootHeight: 480, portalTop: 520, portalHeight: 320, modalScrollHeight: 1000, modalClientHeight: 200 };
const resizeObservers = new Set();
const failures = [];
const consoleBridge = new VirtualConsole();
consoleBridge.on('jsdomError', error => failures.push(String(error)));
const dom = await JSDOM.fromFile(path.join(assets, 'index.html'), {
  resources: 'usable', runScripts: 'dangerously', pretendToBeVisual: true, virtualConsole: consoleBridge,
  beforeParse(window) {
    window.webkit = { messageHandlers: { picoOpenUI: { postMessage(message) {
      messages.push(JSON.parse(JSON.stringify(message)));
    } } } };
    window.matchMedia = () => ({ matches: false, addListener() {}, removeListener() {}, addEventListener() {}, removeEventListener() {} });
    window.ResizeObserver = class {
      constructor(callback) { this.callback = callback; this.elements = new Set(); resizeObservers.add(this); }
      observe(element) { this.elements.add(element); setTimeout(() => this.callback([{ target: element, contentRect: { width: 640, height: layout.rootHeight } }]), 0); }
      unobserve(element) { this.elements.delete(element); }
      disconnect() { this.elements.clear(); }
    };
    window.HTMLElement.prototype.getBoundingClientRect = function () {
      if (this.classList?.contains('openui-modal-body')) return { x: 40, y: 60, left: 40, top: 60, width: 300, height: layout.modalClientHeight, right: 340, bottom: 60 + layout.modalClientHeight };
      const portal = this.classList?.contains('openui-date-picker-renderer-floating-content');
      const top = portal ? layout.portalTop : 0;
      const height = portal ? layout.portalHeight : layout.rootHeight;
      return { x: 0, y: top, left: 0, top, width: 640, height, right: 640, bottom: top + height };
    };
    Object.defineProperty(window.HTMLElement.prototype, 'clientHeight', { get() { return this.classList?.contains('openui-modal-body') ? layout.modalClientHeight : layout.rootHeight; } });
    Object.defineProperty(window.HTMLElement.prototype, 'scrollHeight', { get() { return this.classList?.contains('openui-modal-body') ? layout.modalScrollHeight : this.clientHeight; } });
    Object.defineProperty(window.HTMLElement.prototype, 'clientWidth', { get() { return 640; } });
    Object.defineProperty(window.HTMLElement.prototype, 'offsetWidth', { get() { return 640; } });
    Object.defineProperty(window.HTMLElement.prototype, 'offsetHeight', { get() { return 480; } });
    window.SVGElement.prototype.getBBox = () => ({ x: 0, y: 0, width: 160, height: 20 });
    window.HTMLCanvasElement.prototype.getContext = () => ({
      font: '12px sans-serif', measureText: text => ({ width: String(text).length * 7, actualBoundingBoxAscent: 10, actualBoundingBoxDescent: 3 }),
    });
    window.requestIdleCallback = callback => setTimeout(() => callback({ didTimeout: false, timeRemaining: () => 50 }), 0);
    window.cancelIdleCallback = clearTimeout;
    // Size reports must work without animation frames in an inactive child.
    window.requestAnimationFrame = () => 1;
    window.cancelAnimationFrame = () => {};
  },
});
const document = dom.window.document;
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
async function waitFor(predicate, label) {
  for (let index = 0; index < 100; index++) { if (predicate()) return; await sleep(25); }
  throw new Error(`${label} timed out: ${JSON.stringify({ messages, failures })}`);
}
function text() { return document.getElementById('root').textContent; }
function inputs() { return Array.from(document.querySelectorAll('input'), field => ({ name: field.name, value: field.value })); }
function lastErrors(sourceID) {
  return messages.findLast(message => message.kind === 'error' && message.sourceID === sourceID)?.payload ?? [];
}
await waitFor(() => messages.some(message => message.kind === 'ready'), 'bridge ready');
const bridge = dom.window.picoOpenUI;
assert.deepEqual(Object.keys(bridge), ['render'], 'production has no inspection/test helpers');
async function render(fixture, sourceID = fixture.id, colorScheme = 'light') {
  assert.equal(bridge.render({ source: fixture.source, sourceID, colorScheme, isStreaming: false }), true);
  const heading = { 'trip-form': 'Plan a weekend', 'project-status': 'Project overview', 'revenue-chart': 'Q4 revenue', 'date-picker': 'Choose a date', 'math-content': 'Inline', 'scrollable-modal': 'Scroll example', 'markdown-link': 'Read documentation' }[fixture.id];
  await waitFor(() => text().includes(heading), `render ${fixture.id}`);
  await sleep(120);
  assert.deepEqual(lastErrors(sourceID), [], `${fixture.id} renders without errors`);
}
await render(fixtures[0]);
assert.deepEqual(inputs().map(input => input.name), ['traveler', 'email']);
for (const [name, value] of Object.entries({ traveler: 'Ada Lovelace', email: 'ada@example.com' })) {
  const field = document.querySelector(`[name="${name}"]`);
  Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, 'value').set.call(field, value);
  field.dispatchEvent(new dom.window.Event('input', { bubbles: true }));
  field.dispatchEvent(new dom.window.Event('change', { bubbles: true }));
}
await sleep(40);
assert.equal(messages.some(message => message.kind === 'state'), false, 'field changes stay in the renderer');
document.querySelector('button').click();
await waitFor(() => messages.some(message => message.kind === 'action'), 'form submit');
const action = messages.findLast(message => message.kind === 'action');
assert.equal(action.sourceID, 'trip-form');
assert.equal(action.payload.type, 'continue_conversation');
assert.equal(action.payload.humanFriendlyMessage, 'Plan my weekend');
assert.equal(action.payload.params.context.itineraryId, 'TRIP-042');
assert.equal(action.payload.formName, 'trip');
assert.equal(action.payload.formState.trip.traveler.value, 'Ada Lovelace');
assert.equal(action.payload.formState.trip.email.value, 'ada@example.com');
console.log('PASS DOM: native action bridge preserves the official form event');
const semanticActionCount = messages.filter(message => message.kind === 'action').length;
Array.from(document.querySelectorAll('button')).find(button => button.textContent === 'OpenUI docs').click();
await waitFor(() => messages.filter(message => message.kind === 'action').length === semanticActionCount + 1, 'semantic OpenUrl action');
const semanticLink = messages.findLast(message => message.kind === 'action');
assert.equal(semanticLink.payload.type, 'open_url');
assert.equal(semanticLink.payload.params.url, 'https://www.openui.com/docs/openui-lang');
assert.equal(semanticLink.payload.humanFriendlyMessage, '');
assert.equal(semanticLink.payload.formName, 'trip', 'existing semantic actions retain upstream form context');
console.log('PASS DOM: semantic OpenUrl actions keep the upstream event without duplicates');
await render(fixtures[0], 'trip-form', 'dark');
assert.equal(inputs()[0].value, 'Ada Lovelace');
console.log('PASS DOM: theme changes preserve form values');
await render(fixtures[0], 'another-occurrence');
assert.equal(inputs()[0].value, '');
console.log('PASS DOM: occurrence identities isolate form state');
await render(fixtures[1]);
assert.equal(document.querySelectorAll('table').length, 1);
assert.ok(text().includes('Native document'));
console.log('PASS DOM: official cards and table');
await render(fixtures[2]);
assert.ok(document.querySelectorAll('svg').length > 0);
assert.ok(text().includes('Product A'));
console.log('PASS DOM: official chart');
assert.ok(messages.some(message => message.kind === 'size' && message.payload.height === 480));
assert.ok(messages.every(message => ['ready', 'size', 'scrollRegions', 'action', 'error'].includes(message.kind)));
console.log('PASS bridge: timer-based measurement works with suspended animation frames');
await render(fixtures[0], 'css-height');
layout.rootHeight = 25000;
dom.window.dispatchEvent(new dom.window.Event('resize'));
await waitFor(() => messages.findLast(message => message.kind === 'size' && message.sourceID === 'css-height')?.payload.height === 25000,
  'large CSS measurement reaches the native scale-aware limit');
assert.deepEqual(lastErrors('css-height'), [], 'CSS pixels are not prematurely limited as native points');
layout.rootHeight = 480;
dom.window.dispatchEvent(new dom.window.Event('resize'));
await waitFor(() => messages.findLast(message => message.kind === 'size' && message.sourceID === 'css-height')?.payload.height === 480,
  'normal CSS height restores after a large measurement');
assert.deepEqual(lastErrors('css-height'), []);
console.log('PASS bridge: large CSS heights reach the native host without a scale-blind error');
await render(fixtures.find(fixture => fixture.id === 'date-picker'));
const pickerInput = document.querySelector('.openui-date-picker-renderer-floating-input-container');
pickerInput.click();
await waitFor(() => document.querySelector('.openui-date-picker-renderer-floating-content'), 'calendar portal opens');
const calendar = document.querySelector('.openui-date-picker-renderer-floating-content');
assert.equal(calendar.parentElement, document.body, 'test exercises the stock body portal');
function lastHeight() { return messages.findLast(message => message.kind === 'size' && message.sourceID === 'date-picker')?.payload.height; }
await waitFor(() => lastHeight() === 840, 'calendar grows native frame beyond root');
assert.ok([...resizeObservers].some(observer => observer.elements.has(calendar)), 'portal reflow is observed');
layout.portalHeight = 400;
for (const observer of resizeObservers) {
  if (observer.elements.has(calendar)) observer.callback([{ target: calendar }]);
}
await waitFor(() => lastHeight() === 920, 'calendar intrinsic resize grows native frame');
layout.portalTop = 560;
calendar.style.transform = 'translateY(560px)';
await waitFor(() => lastHeight() === 960, 'calendar placement changes update native frame');
layout.portalTop = -200;
calendar.style.transform = 'translateY(-200px)';
await waitFor(() => lastHeight() === 896, 'above-viewport calendar reserves room for repositioning');
calendar.style.display = 'none';
await waitFor(() => lastHeight() === 480, 'hidden portals do not retain extra height');
calendar.style.display = '';
layout.portalTop = 520;
calendar.style.transform = 'translateY(520px)';
await waitFor(() => lastHeight() === 920, 'visible calendar grows again');
const sizeReports = messages.filter(message => message.kind === 'size').length;
dom.window.dispatchEvent(new dom.window.Event('resize'));
await sleep(100);
assert.equal(messages.filter(message => message.kind === 'size').length, sizeReports, 'unchanged portal extent does not loop size messages');
document.body.dispatchEvent(new dom.window.MouseEvent('mousedown', { bubbles: true }));
await waitFor(() => !document.body.contains(calendar) && lastHeight() === 480, 'closing calendar shrinks native frame');
assert.ok([...resizeObservers].every(observer => !observer.elements.has(calendar)), 'closed portals are unobserved');
console.log('PASS bridge: stock body portals grow, reflow and shrink without size feedback');
await render(fixtures.find(fixture => fixture.id === 'math-content'));
assert.equal(document.querySelectorAll('.katex').length, 2, 'stock TextContent produces inline and display math');
assert.equal(document.querySelectorAll('.katex-display').length, 1);
const mathML = document.querySelector('.katex-mathml');
assert.ok(mathML.querySelector('math'), 'accessible MathML is retained');
assert.equal(dom.window.getComputedStyle(mathML).position, 'absolute', 'KaTeX CSS visually hides the duplicate MathML tree');
assert.equal(dom.window.getComputedStyle(mathML).width, '1px');
assert.equal(document.querySelector('.katex-html').getAttribute('aria-hidden'), 'true');
const css = await fs.readFile(path.join(assets, 'app.css'), 'utf8');
const fontURLs = [...css.matchAll(/url\(([^)]+)\)/g)].map(match => match[1].replace(/^["']|["']$/g, '')).filter(url => /\.(woff2?|ttf)$/.test(url));
assert.ok(fontURLs.length > 0, 'KaTeX fonts are bundled');
for (const url of fontURLs) {
  assert.ok(!url.includes(':') && !path.isAbsolute(url) && !url.startsWith('..'), 'font URLs stay local');
  assert.ok((await fs.stat(path.join(assets, url))).size > 0, `font asset exists: ${url}`);
}
const buildInfo = JSON.parse(await fs.readFile(path.join(assets, 'BuildInfo.json'), 'utf8'));
assert.equal(buildInfo.versions.katex, '0.16.47');
assert.ok(buildInfo.files.some(file => file.name.endsWith('.woff2')), 'metadata accounts for local fonts');
console.log('PASS assets: OpenUI math has KaTeX CSS, accessible MathML and local fonts');
await render(fixtures.find(fixture => fixture.id === 'scrollable-modal'));
const modalBody = document.querySelector('.openui-modal-body');
const portalAnchor = modalBody.querySelector('a');
assert.ok(portalAnchor && !document.getElementById('root').contains(portalAnchor), 'regression uses a link outside the React root DOM');
const portalActionCount = messages.filter(message => message.kind === 'action').length;
const portalClick = new dom.window.MouseEvent('click', { bubbles: true, cancelable: true, button: 0 });
portalAnchor.dispatchEvent(portalClick);
assert.equal(portalClick.defaultPrevented, true);
assert.equal(messages.filter(message => message.kind === 'action').length, portalActionCount + 1);
assert.equal(messages.findLast(message => message.kind === 'action').sourceID, 'scrollable-modal');
assert.equal(messages.findLast(message => message.kind === 'action').payload.humanFriendlyMessage, 'Modal documentation');
function lastRegions(sourceID = 'scrollable-modal') {
  return messages.findLast(message => message.kind === 'scrollRegions' && message.sourceID === sourceID)?.payload;
}
await waitFor(() => lastRegions()?.length === 1, 'actual stock modal reports a scrollable region');
assert.deepEqual(lastRegions(), [{ x: 40, y: 60, width: 300, height: 200, canScrollUp: false, canScrollDown: true }]);
modalBody.scrollTop = 400;
modalBody.dispatchEvent(new dom.window.Event('scroll'));
await waitFor(() => lastRegions()?.[0]?.canScrollUp === true, 'scrolling updates cached edge flags');
assert.equal(lastRegions()[0].canScrollDown, true);
modalBody.scrollTop = 800;
modalBody.dispatchEvent(new dom.window.Event('scroll'));
await waitFor(() => lastRegions()?.[0]?.canScrollDown === false, 'bottom edge lets native transcript scrolling resume');
const unchangedRegionCount = messages.filter(message => message.kind === 'scrollRegions').length;
modalBody.dispatchEvent(new dom.window.Event('scroll'));
await sleep(100);
assert.equal(messages.filter(message => message.kind === 'scrollRegions').length, unchangedRegionCount, 'unchanged scroll maps are deduplicated');
dom.window.dispatchEvent(new dom.window.Event('resize'));
await waitFor(() => messages.filter(message => message.kind === 'scrollRegions').length === unchangedRegionCount + 1,
  'resize refreshes native zoom caches even when CSS regions are unchanged');
layout.modalScrollHeight = layout.modalClientHeight;
modalBody.dispatchEvent(new dom.window.Event('scroll'));
await waitFor(() => lastRegions()?.length === 0, 'non-overflowing controls do not retain wheel events');
layout.modalScrollHeight = 1000;
modalBody.scrollTop = 0;
modalBody.dispatchEvent(new dom.window.Event('scroll'));
await waitFor(() => lastRegions()?.length === 1, 'cached candidates resume reporting when overflow returns');
modalBody.style.visibility = 'hidden';
await waitFor(() => lastRegions()?.length === 0, 'hidden controls do not retain wheel events');
modalBody.style.visibility = '';
await waitFor(() => lastRegions()?.length === 1, 'visible scroll regions return after layout mutation');
document.querySelector('.openui-modal-close').click();
await waitFor(() => lastRegions()?.length === 0, 'closing modal clears regions');
console.log('PASS bridge: stock scroll controls report visible geometry and directional edge state without field values');
await render(fixtures.find(fixture => fixture.id === 'markdown-link'));
await waitFor(() => Array.isArray(lastRegions('markdown-link')), 'new source gets a scoped scroll map');
assert.deepEqual(lastRegions('markdown-link'), []);
const anchor = document.querySelector('a');
assert.equal(anchor.target, '_blank', 'regression uses the official TextContent anchor');
const previousActions = messages.filter(message => message.kind === 'action').length;
const anchorClick = new dom.window.MouseEvent('click', { bubbles: true, cancelable: true, button: 0 });
anchor.dispatchEvent(anchorClick);
assert.equal(anchorClick.defaultPrevented, true, 'ordinary anchors cannot navigate the web child or create another window');
await waitFor(() => messages.filter(message => message.kind === 'action').length === previousActions + 1, 'ordinary anchor reaches the host action callback');
assert.deepEqual(messages.findLast(message => message.kind === 'action'), {
  kind: 'action', sourceID: 'markdown-link',
  payload: { type: 'open_url', params: { url: 'https://www.openui.com/docs/openui-lang' }, humanFriendlyMessage: 'Read documentation' },
});
const keyboardActivation = new dom.window.MouseEvent('click', { bubbles: true, cancelable: true, button: 0, detail: 0 });
anchor.dispatchEvent(keyboardActivation);
assert.equal(keyboardActivation.defaultPrevented, true);
assert.equal(messages.filter(message => message.kind === 'action').length, previousActions + 2, 'keyboard link activation produces one event');
const actionCountBeforeSourceChange = messages.filter(message => message.kind === 'action').length;
bridge.render({ source: fixtures[0].source, sourceID: 'next-link-source', colorScheme: 'light', isStreaming: false });
const staleClick = new dom.window.MouseEvent('click', { bubbles: true, cancelable: true, button: 0 });
anchor.dispatchEvent(staleClick);
assert.equal(staleClick.defaultPrevented, true, 'stale links still cannot navigate the web child');
assert.equal(messages.filter(message => message.kind === 'action').length, actionCountBeforeSourceChange, 'stale rendered source cannot dispatch an action for the new identity');
await render(fixtures[0], 'next-link-source');
console.log('PASS DOM: root, portal and keyboard links use canonical host actions without navigation or stale-source dispatch');
bridge.render({ source: 'root = NoSuchComponent("test")', sourceID: 'invalid', colorScheme: 'light', isStreaming: false });
await waitFor(() => lastErrors('invalid').length > 0, 'invalid source diagnostics');
await render(fixtures[0], 'recovered');
assert.ok(messages.some(message => message.kind === 'error' && message.sourceID === 'recovered' && message.payload.length === 0));
console.log('PASS bridge: diagnostics clear after a valid source');
assert.equal(failures.length, 0, failures.join('\n'));
const html = await fs.readFile(path.join(assets, 'index.html'), 'utf8');
assert.ok(html.includes("connect-src 'none'") && html.includes("frame-src 'none'"));
assert.ok(html.includes("img-src 'self' data: blob:"));
assert.ok(!html.includes('https://'));
console.log('PASS assets: local-only entry and restrictive content policy');
dom.window.close();
