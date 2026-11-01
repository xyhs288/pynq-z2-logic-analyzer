// test_view.js —— 不打开浏览器就验证 la_view.html 的脚本
//
// 把页面里的 <script> 扔进 Node，配一套假 DOM/Canvas，依次执行：
//   脚本加载 -> oneFrame 取帧 -> showSnap 装载 -> draw 重绘 -> 历史滑块回看
// 任何运行时异常都会 FAIL。解码结果一并打印，可和期望字节序列对照。
//
// 为什么需要它：页面逻辑（快照/视图/解码）改动后，光靠浏览器看很难判断
// "没报错"和"只是没画出来"，这套假 DOM 能明确区分。
const fs = require('fs');
const vm = require('vm');

const html = fs.readFileSync('la_pynq/ps/la_view.html', 'utf8');
const code = html.match(/<script>([\s\S]*?)<\/script>/)[1];

// ---- 假 canvas 上下文：未知方法一律当空函数 ----
const calls = [];
const ctxTarget = {
  measureText: () => ({ width: 20 }),
  setLineDash: () => {},
  canvas: null,
};
const ctx = new Proxy(ctxTarget, {
  get(t, p) {
    if (p in t) return t[p];
    return (...a) => { calls.push(String(p)); };
  },
  set(t, p, v) { t[p] = v; return true; },
});

const el = () => {
  const e = {
    style: {}, classList: { toggle() {}, add() {}, remove() {} },
    value: '0', textContent: '', max: 0, disabled: false,
    width: 1200, height: 600,
    getContext: () => ctx,
    addEventListener() {}, appendChild() {}, remove() {},
    toBlob() {},
    parentElement: { getBoundingClientRect: () => ({ width: 1200, height: 600 }) },
  };
  return e;
};
const cache = {};
const document = {
  getElementById: id => (cache[id] = cache[id] || el()),
  querySelector: () => el(),
  createElement: () => el(),
  addEventListener() {},
};

let rafCount = 0;
const win = {
  devicePixelRatio: 1,
  addEventListener() {},
  requestAnimationFrame: () => { rafCount++; return 0; },
  ResizeObserver: class { observe() {} },
  setTimeout: () => 0,          // 不真触发，避免 fetchLoop 空转
  setInterval: () => 0,
  clearTimeout: () => {},
  performance: { now: () => Date.now() },
  console,
};

// 用法：node test_view.js <一帧原始数据文件>
//   取数据：curl -o frame.bin "http://192.168.2.99:8080/data?n=8192"
const snapPath = process.argv[2];
if (!snapPath) {
  console.log('用法: node test_view.js <frame.bin>   (curl -o frame.bin http://192.168.2.99:8080/data?n=8192)');
  process.exit(2);
}
const snap = fs.readFileSync(snapPath);

const fetchStub = async (url) => {
  if (String(url).startsWith('/data')) {
    return { ok: true, status: 200, arrayBuffer: async () => snap, json: async () => ({}) };
  }
  return {
    ok: true, status: 200,
    arrayBuffer: async () => new Uint8Array(0),
    json: async () => ({
      div: 40, clk_mhz: 62.5, sample_rate: 1562500, n: 8192, depth: 8192,
      mode: 'ext', fps: 3, wr_ptr: 0, btn_cnt: 0, proto_byte: 0x5A,
      proto: { seen: true, frame_err: false, ack: false },
    }),
  };
};

const sandbox = {
  document, window: win, console,
  fetch: fetchStub,
  performance: win.performance,
  requestAnimationFrame: win.requestAnimationFrame,
  ResizeObserver: win.ResizeObserver,
  devicePixelRatio: 1,
  setTimeout: win.setTimeout,
  setInterval: win.setInterval,
  clearTimeout: win.clearTimeout,
  Uint8Array, Uint16Array, Uint32Array, Int32Array, Float64Array, Math, JSON, Date,
  alert: () => {},
  atob: s => Buffer.from(s, 'base64').toString('binary'),
  Blob: class {},
  URL: { createObjectURL: () => '' },
};
sandbox.globalThis = sandbox;

(async () => {
  vm.createContext(sandbox);
  vm.runInContext(code, sandbox, { filename: 'la_view.js' });
  console.log('脚本执行      : OK');

  // 走真实取帧路径
  await sandbox.oneFrame();
  await sandbox.oneFrame();
  console.log('oneFrame ×2   : OK');

  // 装载最新快照并重绘（这是新逻辑的核心路径）
  sandbox.showSnap(1);
  sandbox.draw();
  console.log('showSnap+draw : OK（无异常）');

  // 解码结果（draw 内部用同一套 decodeUART）
  const buf = new Uint8Array(snap);
  const ev = sandbox.decodeUART(buf, buf.length, 0, 16, 6);
  const seq = ev.map(e => e.v.toString(16).toUpperCase().padStart(2, '0')).join(' ');
  console.log('解码          :', seq);
  console.log('帧错误        :', ev.filter(e => !e.ok).length);

  // 左右翻页按钮（这次新加的）：从假 DOM 取回 onclick 直接触发
  cache['btn-next'].onclick();
  console.log('btn-next      : OK');
  cache['btn-prev'].onclick();
  console.log('btn-prev      : OK');

  // 历史滑块：脚本把处理器挂在元素上，从假 DOM 里取回来直接触发
  const scrubEl = cache['scrub'];
  scrubEl.value = '0';
  scrubEl.oninput();
  console.log('scrub.oninput : OK（无异常）');
  sandbox.draw();
  console.log('回看后 draw   : OK');

  console.log('\n绘图调用次数  :', calls.length);
  console.log('RESULT        : PASS');
})().catch(e => {
  console.log('RESULT        : FAIL');
  console.log(e && e.stack ? e.stack.split('\n').slice(0, 6).join('\n') : e);
  process.exit(1);
});
