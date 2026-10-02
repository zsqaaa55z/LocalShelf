import { clamp, totalPages, pageAt, preloadIndices, validBook, validateManifest, progressKey, rememberedIndex } from './core.js';

const $ = id => document.getElementById(id);
// Reader uses the same document; browser history must not override the saved shelf offset.
if ('scrollRestoration' in history) history.scrollRestoration = 'manual';
const readSaved = (key, fallback) => { try { return JSON.parse(localStorage.getItem(key)) ?? fallback; } catch { return fallback; } };
const save = (key, value) => { try { localStorage.setItem(key, JSON.stringify(value)); } catch { /* private browsing / full storage: reading still works */ } };
const prefs = readSaved('lsweb.preferences', {});
const state = {
  library: prefs.library === 'manual' ? 'manual' : 'eh', size: [50,100,150,200,250,300,350,400,450,500].includes(prefs.size) ? prefs.size : 100,
  columns: ['auto','3','4','5','6'].includes(prefs.columns) ? prefs.columns : 'auto',
  hide: prefs.hide === true, preload: prefs.preload !== false, offset: 0, total: 0, books: [], libraryId: '',
  related: null, home: null, request: null, requestID: 0, book: null, selected: null,
  menuRequest: 0, possible: new Set(), parts: {},
  manifest: [], index: 0, lastReadIndex: null, readerID: 0, pageID: 0, scroll: 0, loadingCatalog: false,
  progress: readSaved('lsweb.progress', {}), objects: new Map(), fetching: new Map(), activeObject: null,
  covers: new Map(), coverQueue: [], coverActive: 0, coverObserver: null, coverGeneration: 0,
};
if (!state.progress || typeof state.progress !== 'object' || Array.isArray(state.progress)) state.progress = {};
function persistPrefs() { save('lsweb.preferences', { library: state.library, size: state.size, columns: state.columns, hide: state.hide, preload: state.preload }); }
function toast(text) { $('toast').textContent = text; $('toast').hidden = false; clearTimeout(toast.timer); toast.timer = setTimeout(() => { $('toast').hidden = true; }, 3200); }
const messages = {
  login_required: '登录已到期，请重新输入阅读密码。', login_failed: '密码不正确，或 NAS 尚未启用固定阅读密码。',
  login_rate_limited: '登录尝试过于频繁，请稍后再试；连续输错后 NAS 会暂时锁定登录。', reader_unavailable: '暂时无法连接 NAS 阅读服务，请检查服务和网络。',
  reader_busy: '阅读服务正在忙，请稍后重试。', page_changed: '此页内容已更新，请返回书库后重新打开。',
  not_found: '本地文件不可用，或内容已从书库移除。', catalog_changed: '书库正在更新，请刷新后重试。',
  same_origin_required: '访问地址与网关配置不一致，请检查网页入口配置。', unsupported_image: '这个文件不是浏览器可读取的图片格式。',
};
async function api(path, options = {}) {
  const response = await fetch(path, { credentials: 'same-origin', ...options });
  if (!response.ok) {
    let code = ''; try { code = (await response.json()).error; } catch { /* interrupted response */ }
    if (response.status === 401) showLogin(messages.login_required);
    throw Error(messages[code] || `请求未完成（${response.status}），可以重试。`);
  }
  return response.json();
}
function post(path, data = {}) { return api(path, { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-LocalShelf-Request': '1' }, body: JSON.stringify(data) }); }
function prefix() { return `api/${state.library}/v1/books`; }
function showLogin(note = '') {
  $('bootView').hidden = true;
  state.request?.abort(); state.requestID++;
  if (state.book) exitReader(false);
  clearCovers(); state.books = []; $('bookGrid').replaceChildren();
  for (const dialog of document.querySelectorAll('dialog[open]')) dialog.close();
  $('libraryView').hidden = true; $('readerView').hidden = true; $('loginView').hidden = false;
  $('loginError').textContent = note;
}
async function enter() {
  const health = await api('api/health');
  const manual = health.capabilities?.includes('manual-library-v1');
  document.querySelector('[data-library="manual"]').disabled = !manual;
  if (!manual) state.library = 'eh';
  $('bootView').hidden = true; $('loginView').hidden = true; $('libraryView').hidden = false;
  await loadCatalog();
}
$('loginForm').addEventListener('submit', async event => {
  event.preventDefault(); $('loginButton').disabled = true; $('loginError').textContent = '';
  try { await post('auth/login', { password: $('password').value }); $('password').value = ''; await enter(); }
  catch (error) { $('loginError').textContent = error.message; }
  finally { $('loginButton').disabled = false; }
});

function renderHeading() {
  for (const button of document.querySelectorAll('[data-library]')) button.setAttribute('aria-pressed', String(button.dataset.library === state.library));
  $('shelfTitle').firstChild.textContent = state.related ? `${state.related.name} ` : '书库 ';
  $('shelfEyebrow').textContent = state.related ? (state.related.kind === 'authors' ? 'BY THE SAME AUTHOR' : 'IN THE SAME SERIES') : 'YOUR PRIVATE COLLECTION';
  $('shelfNote').textContent = state.related ? '沿用原书库顺序；可能相关的结果另作标记。' : (state.library === 'eh' ? '保留 Eh 下载顺序，按你熟悉的方式浏览。' : '独立管理；漫画内图片按 Windows 修改日期递增排列。');
  $('backRelated').hidden = !state.related;
  $('bookCount').textContent = state.loadingCatalog && !state.books.length ? '正在加载…' : `${state.total.toLocaleString()} 本`;
  $('rangeLabel').textContent = state.total ? `${state.offset + 1}–${Math.min(state.offset + state.size, state.total)} / ${state.total.toLocaleString()}` : '';
  const pages = totalPages(state.total, state.size), current = Math.floor(state.offset / state.size);
  const options = document.createDocumentFragment();
  for (let p = pages - 1; p >= 0; p--) { const option = new Option(`第 ${p + 1} 页`, String(p)); option.selected = p === current; options.append(option); }
  $('catalogPage').replaceChildren(options); $('catalogTotal').textContent = `/ ${pages}`;
  $('previousCatalog').disabled = state.loadingCatalog || current === 0;
  $('nextCatalog').disabled = state.loadingCatalog || current >= pages - 1;
  $('catalogPage').disabled = state.loadingCatalog;
}
async function loadCatalog({ restoreScroll = 0 } = {}) {
  state.request?.abort(); const controller = new AbortController(); state.request = controller;
  const requestID = ++state.requestID;
  state.loadingCatalog = true; $('bookGrid').setAttribute('aria-busy', 'true');
  $('status').textContent = '正在读取书库…'; renderHeading();
  try {
    let route = `${prefix()}?offset=${state.offset}&limit=${state.size}`;
    if (state.related) route = relatedRoute(state.related, true);
    const value = await api(route, { signal: controller.signal });
    if (requestID !== state.requestID) return;
    const catalog = state.related ? value.catalog : value;
    if (!catalog || !Array.isArray(catalog.books) || catalog.books.length > state.size || !catalog.books.every(validBook) ||
        !Number.isSafeInteger(catalog.total) || catalog.total < 0 || catalog.total > 200000 || !/^[a-f0-9]{64}$/.test(catalog.libraryId)) throw Error('书库返回的数据不完整，请稍后重试。');
    state.total = catalog.total;
    if (state.offset >= state.total && state.offset > 0) { state.offset = (totalPages(state.total, state.size) - 1) * state.size; return loadCatalog(); }
    if (state.related && Number.isInteger(value.offset)) state.offset = value.offset;
    state.books = catalog.books; state.libraryId = catalog.libraryId;
    state.possible = new Set(value.possibleBookIDs || []); state.parts = value.partLabels || {};
    renderBooks();
    $('status').textContent = ''; $('emptyState').hidden = state.total !== 0;
    $('emptyState').querySelector('h2').textContent = state.related ? '没有找到相关作品' : '这里还没有漫画';
    window.scrollTo(0, restoreScroll);
  } catch (error) {
    if (error.name !== 'AbortError' && requestID === state.requestID) $('status').textContent = `${error.message} 点击右侧“刷新”重试。`;
  } finally {
    if (requestID === state.requestID) { state.loadingCatalog = false; $('bookGrid').setAttribute('aria-busy', 'false'); renderHeading(); }
  }
}

function clearCovers() {
  state.coverGeneration++; state.coverObserver?.disconnect(); state.coverObserver = null;
  state.coverQueue = [];
  for (const record of state.covers.values()) record.near = false;
  for (const record of state.covers.values()) { record.cancel?.(); record.img.removeAttribute('src'); }
  state.covers.clear(); state.coverQueue = [];
}
function runCoverQueue() {
  while (state.coverActive < 4 && state.coverQueue.length) {
    const record = state.coverQueue.shift(); record.queued = false;
    if (!record.near || record.loaded || record.loading || state.hide || state.book) continue;
    record.loading = true; state.coverActive++;
    let finished = false;
    const done = success => {
      if (finished) return; finished = true;
      record.img.onload = record.img.onerror = null;
      record.loading = false; record.loaded = success; record.cancel = null; state.coverActive--;
      if (!success) record.placeholder.textContent = '封面暂不可用';
      runCoverQueue();
    };
    record.cancel = () => done(false);
    record.img.onload = () => done(true); record.img.onerror = () => done(false);
    record.img.src = record.url;
  }
}
function observeCovers() {
  state.coverObserver?.disconnect();
  if (state.hide || state.book) return;
  state.coverObserver = new IntersectionObserver(entries => {
    for (const entry of entries) {
      const record = state.covers.get(entry.target);
      if (!record) continue;
      record.near = entry.isIntersecting;
      if (record.near && !record.loaded && !record.loading && !record.queued) { record.queued = true; state.coverQueue.push(record); }
      if (!record.near) { record.cancel?.(); record.img.removeAttribute('src'); record.loaded = false; }
    }
    runCoverQueue();
  }, { rootMargin: '450px 0px' });
  for (const element of state.covers.keys()) state.coverObserver.observe(element);
}
function renderBooks(possible = state.possible, parts = state.parts) {
  clearCovers(); const fragment = document.createDocumentFragment();
  $('bookGrid').className = `book-grid${state.columns === 'auto' ? '' : ' columns-' + state.columns}`;
  for (const book of state.books) {
    const card = document.createElement('article'); card.className = 'book-card';
    const button = document.createElement('button'); button.className = 'cover-button'; button.setAttribute('aria-label', `阅读 ${book.title}`);
    const cover = document.createElement('div'); cover.className = 'cover';
    const placeholder = document.createElement('span'); placeholder.className = 'cover-placeholder';
    placeholder.textContent = state.hide ? '封面已隐藏' : book.available ? 'LOCALSHELF' : '文件暂不可用'; cover.append(placeholder);
    if (!state.hide && book.available) {
      const img = document.createElement('img'); img.alt = ''; img.decoding = 'async'; img.draggable = false;
      cover.append(img);
      const identity = /^[a-f0-9]{64}$/.test(book.coverIdentity) ? `&v=${book.coverIdentity}` : '';
      state.covers.set(cover, { img, placeholder, url: `${prefix()}/${book.id}/cover?width=480${identity}`, near: false, loaded: false, loading: false, queued: false });
    }
    if (Number.isInteger(book.pageCount) && book.pageCount > 0) {
      const badge = document.createElement('span'); badge.className = 'page-badge'; badge.textContent = book.pageCount;
      badge.setAttribute('aria-label', `${book.pageCount} 页`); cover.append(badge);
    }
    button.append(cover); button.addEventListener('click', () => openBook(book)); card.append(button);
    const info = document.createElement('div'); info.className = 'book-info';
    const title = document.createElement('button'); title.className = 'book-title'; title.textContent = book.title; title.title = book.title;
    title.addEventListener('click', () => openBook(book));
    const more = document.createElement('button'); more.textContent = '⋯'; more.className = 'book-more quiet'; more.setAttribute('aria-label', `更多：${book.title}`);
    more.addEventListener('click', () => showBookMenu(book)); info.append(title, more); card.append(info);
    card.addEventListener('contextmenu', event => { event.preventDefault(); showBookMenu(book); });
    if (possible.has(book.id) || parts[book.id]) { const label = document.createElement('p'); label.className = 'book-label'; label.textContent = [parts[book.id], possible.has(book.id) ? '可能相关' : ''].filter(Boolean).join(' · '); card.append(label); }
    fragment.append(card);
  }
  $('bookGrid').replaceChildren(fragment); observeCovers();
}
async function catalogPage(page) { state.offset = clamp(page, 0, totalPages(state.total, state.size) - 1) * state.size; await loadCatalog(); }
$('previousCatalog').onclick = () => catalogPage(state.offset / state.size - 1);
$('nextCatalog').onclick = () => catalogPage(state.offset / state.size + 1);
$('catalogPage').onchange = () => catalogPage(Number($('catalogPage').value));
$('refreshButton').onclick = () => loadCatalog({ restoreScroll: window.scrollY });
for (let n = 50; n <= 500; n += 50) $('pageSize').append(new Option(`${n} 本`, n));
$('pageSize').value = state.size;
$('pageSize').onchange = () => { state.size = Number($('pageSize').value); state.offset = Math.floor(state.offset / state.size) * state.size; persistPrefs(); loadCatalog(); };
$('columns').value = state.columns;
$('columns').onchange = () => { state.columns = $('columns').value; persistPrefs(); $('bookGrid').className = `book-grid${state.columns === 'auto' ? '' : ' columns-' + state.columns}`; };
for (const button of document.querySelectorAll('[data-library]')) button.onclick = () => {
  if (state.library === button.dataset.library) return;
  state.library = button.dataset.library; state.offset = 0; state.related = null; state.home = null;
  clearCovers(); state.books = []; $('bookGrid').replaceChildren(); persistPrefs(); loadCatalog();
};
window.addEventListener('scroll', () => { $('toTop').hidden = window.scrollY < 500; }, { passive: true });
$('toTop').onclick = () => window.scrollTo({ top: 0, behavior: 'auto' });

function showBookMenu(book) { state.menuRequest++; state.selected = book; $('bookDialogTitle').textContent = book.title; $('relatedOptions').replaceChildren(); $('bookDialog').showModal(); }
$('readBookButton').onclick = () => { $('bookDialog').close(); openBook(state.selected); };
function relatedRoute(selection, members = false) {
  const query = new URLSearchParams({ evidence: '3', relaxed: '1', offset: String(members ? state.offset : 0), limit: String(state.size) });
  if (selection.kind === 'authors') { query.set('credit', '1'); query.set('includePossible', '1'); }
  return `${prefix()}/${selection.bookId}/${selection.kind}${members ? '/' + selection.id : ''}?${query}`;
}
async function relatedOptions(kind) {
  const book = state.selected; if (!book) return;
  const requestID = ++state.menuRequest;
  const selection = { kind, bookId: book.id };
  $('relatedOptions').textContent = '正在查找关联…';
  try {
    const data = await api(relatedRoute(selection));
    if (!Array.isArray(data.options) || requestID !== state.menuRequest || state.selected !== book || !$('bookDialog').open) return;
    $('relatedOptions').replaceChildren();
    if (!data.options.length) { $('relatedOptions').textContent = '暂未识别到可用关联。'; return; }
    for (const option of data.options.slice(0, 100)) {
      if (!/^[a-f0-9]{64}$/.test(option.id)) continue;
      const button = document.createElement('button'); button.textContent = `${option.name || option.title || '相关作品'} · ${option.count ?? '—'} 本${option.possibleCount ? ' · 含可能相关' : ''}`;
      button.onclick = () => {
        if (!state.related) state.home = { offset: state.offset, scroll: window.scrollY };
        state.related = { ...selection, id: option.id, name: option.name || option.title || '相关作品' };
        state.offset = 0; $('bookDialog').close(); loadCatalog();
      };
      $('relatedOptions').append(button);
    }
  } catch (error) { if (requestID === state.menuRequest) $('relatedOptions').textContent = error.message; }
}
$('authorButton').onclick = () => relatedOptions('authors'); $('seriesButton').onclick = () => relatedOptions('series');
$('backRelated').onclick = () => { state.related = null; state.offset = Math.floor((state.home?.offset || 0) / state.size) * state.size; loadCatalog({ restoreScroll: state.home?.scroll || 0 }); };

let progressTimer;
function flushProgress() { clearTimeout(progressTimer); save('lsweb.progress', state.progress); }
function saveProgress() {
  if (!state.book || state.lastReadIndex === null || !state.manifest[state.lastReadIndex]) return;
  state.progress[progressKey(state.libraryId, state.book.id)] = { number: state.manifest[state.lastReadIndex].number, time: Date.now() };
  // Keep recent metadata only; do not sort/serialize the whole library on each rapid turn.
  if (Object.keys(state.progress).length > 2000) {
    state.progress = Object.fromEntries(Object.entries(state.progress).sort((a,b) => (b[1]?.time || 0) - (a[1]?.time || 0)).slice(0, 2000));
  }
  clearTimeout(progressTimer); progressTimer = setTimeout(flushProgress, 300);
}
function imageURL(index) { const p = state.manifest[index]; return `${prefix()}/${state.book.id}/pages/${p.number}?v=${p.sha256}`; }
function disposePrepared(keep = new Set()) {
  for (const [index, controller] of state.fetching) if (!keep.has(index)) { controller.abort(); state.fetching.delete(index); }
  for (const [index, value] of state.objects) if (!keep.has(index)) { URL.revokeObjectURL(value.url); state.objects.delete(index); }
}
async function prepare(index, epoch) {
  if (state.objects.has(index) || state.fetching.has(index)) return;
  const controller = new AbortController(); state.fetching.set(index, controller);
  const route = imageURL(index), size = state.manifest[index].size;
  try {
    const response = await fetch(route, { signal: controller.signal, credentials: 'same-origin' });
    if (!response.ok || Number(response.headers.get('Content-Length')) > 8 * 1024 * 1024) { await response.body?.cancel(); return; }
    // Trusted gateway enforces length. Manifest size <= 8 MiB; do not buffer arbitrary response sizes.
    if (Number(response.headers.get('Content-Length')) !== size) { await response.body?.cancel(); return; }
    const blob = await response.blob();
    if (controller.signal.aborted || epoch !== state.readerID || blob.size !== size || !state.book) return;
    if (!preloadIndices(state.index, state.manifest).includes(index) && state.index !== index) return;
    state.objects.set(index, { url: URL.createObjectURL(blob), size: blob.size });
  } catch { /* speculative work never blocks reading */ }
  finally { if (state.fetching.get(index) === controller) state.fetching.delete(index); }
}
function preloadAdjacent() {
  if (!state.book) return;
  const adjacent = state.preload && !document.hidden ? preloadIndices(state.index, state.manifest) : [];
  disposePrepared(new Set([state.index, ...adjacent]));
  for (const index of adjacent) prepare(index, state.readerID);
}
async function openBook(book) {
  if (!book?.available) { toast('这本漫画的本地文件暂不可用。'); return; }
  saveProgress(); disposePrepared();
  state.scroll = window.scrollY; state.book = book; state.manifest = []; state.index = 0; state.lastReadIndex = null;
  const epoch = ++state.readerID; state.pageID++;
  state.coverObserver?.disconnect(); state.coverQueue = [];
  for (const record of state.covers.values()) { record.near = false; record.cancel?.(); record.img.removeAttribute('src'); record.loaded = false; record.queued = false; }
  $('libraryView').hidden = true; $('readerView').hidden = false; document.body.classList.add('reading');
  $('readerTitle').textContent = book.title; $('readerSubtitle').textContent = state.library === 'eh' ? 'Eh 同步 · 原始页序' : '手动上传 · 修改日期递增';
  $('pageImage').removeAttribute('src'); $('pageStatus').textContent = '正在读取页清单…'; $('retryPage').hidden = true;
  $('pageNumber').value = 1; $('pageTotal').textContent = '/ —'; $('pageSlider').value = 0; $('pageSlider').max = 0;
  $('pageSlider').disabled = true; $('previousPage').disabled = true; $('nextPage').disabled = true; $('pageNumber').disabled = true;
  history.pushState({ reader: true }, '', '#reading');
  try {
    const value = await api(`${prefix()}/${book.id}/manifest`);
    if (epoch !== state.readerID || state.book !== book) return;
    if (value.libraryId !== state.libraryId || value.id !== book.id) throw Error('书库身份发生变化，请刷新后重试。');
    state.manifest = validateManifest(value);
    if (!state.manifest.length) { $('pageStatus').textContent = '这本漫画暂时没有可读图片。'; return; }
    state.index = rememberedIndex(state.progress[progressKey(state.libraryId, book.id)], state.manifest);
    showPage(state.index); $('pageStage').focus();
  } catch (error) { if (epoch === state.readerID) { $('pageStatus').textContent = error.message; $('retryPage').hidden = false; } }
}
function showPage(index, { force = false } = {}) {
  if (!state.book || !state.manifest.length) return;
  const next = pageAt(index, state.manifest.length);
  $('pageNumber').value = next + 1;
  if (!force && state.index === next && $('pageImage').getAttribute('src') && $('pageImage').naturalWidth > 0) return;
  state.index = next;
  const pageID = ++state.pageID, img = $('pageImage');
  state.fetching.get(state.index)?.abort(); state.fetching.delete(state.index);
  // Release the previous GIF decoder before assigning the new image; do not hold a whole strip of players.
  img.onload = img.onerror = null; img.removeAttribute('src');
  disposePrepared(new Set([state.index, ...preloadIndices(state.index, state.manifest)]));
  $('pageStatus').textContent = '正在加载…'; $('retryPage').hidden = true;
  $('pageSlider').disabled = false; $('pageSlider').max = state.manifest.length - 1; $('pageSlider').value = state.index;
  $('pageSlider').setAttribute('aria-valuetext', `第 ${state.index + 1} 张，共 ${state.manifest.length} 张`);
  $('pageNumber').disabled = false; $('pageNumber').max = state.manifest.length; $('pageNumber').value = state.index + 1;
  $('pageTotal').textContent = `/ ${state.manifest.length}`;
  $('previousPage').disabled = state.index === 0; $('nextPage').disabled = state.index === state.manifest.length - 1;
  img.alt = `漫画第 ${state.index + 1} 张`;
  img.onload = () => { if (pageID !== state.pageID) return; state.lastReadIndex = state.index; $('pageStatus').textContent = ''; saveProgress(); preloadAdjacent(); };
  img.onerror = () => { if (pageID !== state.pageID) return; $('pageStatus').textContent = '图片加载失败、内容已更新或会话已到期。可以重试，或返回书库刷新。'; $('retryPage').hidden = false; };
  img.src = state.objects.get(state.index)?.url || imageURL(state.index);
}
function exitReader(updateHistory = true) {
  if (!state.book) return;
  saveProgress(); flushProgress(); state.book = null; state.readerID++; state.pageID++;
  const img = $('pageImage'); img.onload = img.onerror = null; img.removeAttribute('src'); disposePrepared();
  $('readerView').hidden = true; $('libraryView').hidden = false; document.body.classList.remove('reading');
  if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
  window.scrollTo(0, state.scroll); observeCovers();
  if (updateHistory && history.state?.reader) history.back();
}
$('closeReader').onclick = () => exitReader();
window.addEventListener('popstate', () => { if (state.book) exitReader(false); });
$('previousPage').onclick = () => showPage(state.index - 1); $('nextPage').onclick = () => showPage(state.index + 1);
let sliderTimer;
$('pageSlider').oninput = () => { $('pageNumber').value = Number($('pageSlider').value) + 1; clearTimeout(sliderTimer); sliderTimer = setTimeout(() => showPage(Number($('pageSlider').value)), 90); };
$('pageSlider').onchange = () => { clearTimeout(sliderTimer); showPage(Number($('pageSlider').value)); };
$('pageNumber').onchange = () => showPage(Number($('pageNumber').value) - 1);
$('pageNumber').onkeydown = event => { if (event.key === 'Enter') { showPage(Number($('pageNumber').value) - 1); $('pageStage').focus(); } };
$('retryPage').onclick = () => { if (state.manifest.length) showPage(state.index, { force: true }); else { const book = state.book; exitReader(false); history.replaceState(null, '', location.pathname); openBook(book); } };
async function toggleFullscreen() { try { if (document.fullscreenElement) await document.exitFullscreen(); else await $('readerView').requestFullscreen(); } catch { toast('此浏览器或嵌入页面不允许全屏。'); } }
$('fullscreenButton').onclick = toggleFullscreen;
window.addEventListener('keydown', event => {
  if (!state.book || document.querySelector('dialog[open]') || ['INPUT','SELECT','TEXTAREA'].includes(event.target.tagName)) return;
  if (event.key === 'ArrowRight' || event.key === 'ArrowLeft') { event.preventDefault(); showPage(state.index + (event.key === 'ArrowRight' ? 1 : -1)); }
  if (event.key === 'Escape') exitReader();
  if (event.key.toLowerCase() === 'f') { event.preventDefault(); toggleFullscreen(); }
});
let pointer = null;
$('pageStage').addEventListener('pointerdown', event => { if (event.pointerType === 'touch') pointer = { x: event.clientX, y: event.clientY }; });
$('pageStage').addEventListener('pointercancel', () => { pointer = null; });
$('pageStage').addEventListener('pointerup', event => { if (!pointer) return; const dx = event.clientX - pointer.x, dy = event.clientY - pointer.y; pointer = null; if (Math.abs(dx) > 45 && Math.abs(dx) > Math.abs(dy) * 1.5) showPage(state.index + (dx < 0 ? 1 : -1)); });
document.addEventListener('visibilitychange', () => { if (document.hidden) { saveProgress(); flushProgress(); disposePrepared(new Set([state.index])); } else if (state.book) preloadAdjacent(); });
window.addEventListener('pagehide', flushProgress);

$('settingsButton').onclick = () => { $('hideCovers').checked = state.hide; $('preloadPages').checked = state.preload; $('settingsDialog').showModal(); };
for (const button of document.querySelectorAll('[data-close]')) button.onclick = () => $(button.dataset.close).close();
$('hideCovers').onchange = () => { state.hide = $('hideCovers').checked; persistPrefs(); renderBooks(); };
$('preloadPages').onchange = () => { state.preload = $('preloadPages').checked; persistPrefs(); preloadAdjacent(); };
$('resetProgress').onclick = () => $('resetDialog').showModal();
$('confirmReset').onclick = () => { state.progress = {}; flushProgress(); $('resetDialog').close(); toast('此浏览器的阅读进度已重置。'); };
$('logoutButton').onclick = async () => { try { await post('auth/logout'); showLogin(); } catch (error) { toast(error.message); } };
window.addEventListener('offline', () => toast('网络已断开。已加载的图片仍可阅读。'));
window.addEventListener('online', () => toast('网络已恢复，可以重试加载。'));

async function boot() {
  if (location.hash) history.replaceState(null, '', location.pathname + location.search);
  try { const session = await api('auth/session'); if (session.authenticated) await enter(); else showLogin(); }
  catch (error) { showLogin(error.message); }
}
boot();
