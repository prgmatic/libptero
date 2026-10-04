// Exercise the actual embedded viewer script as code, without a browser or UI.
import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

class Element {
  constructor(tag = 'div') { this.tag = tag; this.children = []; this.style = {}; this.handlers = new Map(); this.textContent = ''; this.clientWidth = 1000; }
  append(...items) { this.children.push(...items); }
  replaceChildren(...items) { this.children = items; }
  addEventListener(name, callback) { this.handlers.set(name, callback); }
  fire(name, event = {}) { this.handlers.get(name)?.({ target: this, preventDefault() {}, ...event }); }
  getBoundingClientRect() { return { left: 0, top: 0, width: this.clientWidth }; }
  setPointerCapture() {}
  click() { this.fire('click'); }
  getContext() { return new Proxy({}, { get: () => () => {}, set: () => true }); }
}
const footer = fs.readFileSync(new URL('viewer_footer.html', import.meta.url), 'utf8');
const script = footer.slice(footer.indexOf('<script>') + 8, footer.lastIndexOf('</script>'));
function viewer(data) {
  const elements = new Map();
  const document = {
    getElementById(id) { if (!elements.has(id)) elements.set(id, new Element()); return elements.get(id); },
    createElement(tag) { return new Element(tag); },
  };
  document.getElementById('trace-data').textContent = JSON.stringify(data);
  const context = vm.createContext({ document, window: { devicePixelRatio: 2, addEventListener() {} }, Blob,
    URL: { createObjectURL: () => 'blob:test', revokeObjectURL() {} }, setTimeout: callback => callback() });
  vm.runInContext(script, context, { timeout: 10000 });
  return { elements, evaluate: expression => vm.runInContext(expression, context, { timeout: 10000 }) };
}
const fixture = { version: 1, id: 1, hz: 46875000, elapsed: 4687500, dropped: 0,
  labels: ['Frame', 'Update', 'PI DMA', 'AI queued', 'Submit'],
  events: [[0,0,0,0,1,0],[10,0,0,1,2,0],[15,0,4,2,3,4096],[20,3,5,3,0,2],
    [25,2,1,4,0,100],[30,1,0,1,2,0],[40,1,4,2,3,0],[50,1,0,0,1,0]] };
const v = viewer(fixture);
assert.equal(v.evaluate('spans.length'), 3);
assert.equal(v.evaluate('spans.find(s => s.id === 2).slot'), 1, 'nested CPU work occupies a separate row');
assert.equal(v.elements.get('stats').children.length, 3);
assert.equal(v.elements.get('notice')?.style.display, undefined);
v.elements.get('zoom-in').click();
assert.equal(v.evaluate('end-start'), 50);
v.elements.get('timeline').fire('keydown', { key: '0' });
assert.equal(v.evaluate('end-start'), 100);
v.elements.get('search').fire('input', { target: { value: 'PI DMA' } });
assert.equal(v.elements.get('stats').children.length, 1);
v.elements.get('search').fire('input', { target: { value: '' } });
const cpu = v.elements.get('legend').children[0].children[0];
cpu.checked = false; cpu.fire('change');
assert.equal(v.evaluate('visible.has(0)'), false);
assert.equal(v.elements.get('stats').children.length, 1);
cpu.checked = true; cpu.fire('change');
v.evaluate('select(spans.find(s => s.id === 3))');
assert.match(v.elements.get('details').textContent, /Value: 4096/);
v.elements.get('timeline').fire('wheel', { deltaY: -1, clientX: 500 });
assert.equal(v.evaluate('end-start'), 80);
v.elements.get('timeline').fire('pointerdown', { clientX: 500, pointerId: 1 });
v.elements.get('timeline').fire('pointermove', { clientX: 450 });
v.elements.get('timeline').fire('pointerup', { clientX: 450, clientY: 100 });
assert.ok(v.evaluate('start') > 0);
v.elements.get('reset').click();
assert.equal(v.evaluate('start'), 0);
v.elements.get('download').click();

const unfinished = viewer({ ...fixture, dropped: 2, events: fixture.events.slice(0, 5) });
assert.equal(unfinished.evaluate('spans.filter(s => !s.complete).length'), 3);
assert.match(unfinished.elements.get('notice').textContent, /omitted 2 events/);
assert.equal(unfinished.elements.get('stats').children.length, 0);
const stopped = viewer({ ...fixture, events: [[0,0,0,0,1,0]] });
assert.equal(stopped.evaluate('spans[0].end'), 100, 'open work reaches the stop boundary without overflow');
const empty = viewer({ ...fixture, elapsed: 0, events: [], labels: [] });
assert.equal(empty.evaluate('spans.length'), 0);
assert.ok(empty.elements.get('timeline').height > 0);
if (process.argv[2]) {
  const data = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
  const hardware = viewer(data);
  assert.equal(hardware.evaluate('open.size'), 0, 'hardware capture completes every scope');
  assert.ok(hardware.evaluate('spans.length') > 0);
  assert.equal(hardware.evaluate('new Set(trace.events.map(e => e[2])).size'), 6);
  console.log(`Verified hardware viewer: ${data.events.length} events across all six lanes.`);
}
console.log('Viewer code checks passed: nesting, filters, lane toggles, selection, zoom, pan, overflow and empty capture.');
