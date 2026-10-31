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
      constructor(callback) { this.callback = callback; }
      observe(element) { setTimeout(() => this.callback([{ target: element, contentRect: { width: 640, height: 480 } }]), 0); }
      unobserve() {} disconnect() {}
    };
    window.HTMLElement.prototype.getBoundingClientRect = function () {
      return { x: 0, y: 0, left: 0, top: 0, width: 640, height: 480, right: 640, bottom: 480 };
    };
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
  const heading = fixture.id === 'trip-form' ? 'Plan a weekend' : fixture.id === 'project-status' ? 'Project overview' : 'Q4 revenue';
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
assert.ok(messages.every(message => ['ready', 'size', 'action', 'error'].includes(message.kind)));
console.log('PASS bridge: timer-based measurement works with suspended animation frames');
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
