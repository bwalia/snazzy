/// The page students open: live video plus the brainstorm board. One file,
/// no third-party code, all text inserted with textContent (never as HTML).
enum LiveViewerPage {
    static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="dark">
<title>Snazzy Pro Live</title>
<style>
  :root { --ink: #0B1020; --night: #141A33; --line: rgba(255,255,255,.1); --fg: #F2F4F8; --muted: #9AA3B5;
          --a: #6C5CFF; --b: #D946EF; --c: #FF6A55; }
  * { box-sizing: border-box; }
  html, body { margin: 0; background: var(--ink); color: var(--fg);
    font: 16px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
  header { display: flex; align-items: center; gap: 12px; padding: 12px 16px; border-bottom: 1px solid var(--line); }
  .mark { width: 28px; height: 28px; border-radius: 8px; background: linear-gradient(135deg, var(--a), var(--b) 55%, var(--c)); flex: none; }
  header h1 { font-size: 16px; margin: 0; font-weight: 700; }
  #status { margin-left: auto; font-size: 14px; color: var(--muted); display: flex; align-items: center; gap: 8px; min-width: 0; }
  #status .dot { width: 9px; height: 9px; border-radius: 50%; background: #64748B; flex: none; }
  #status.live .dot { background: #EF4444; box-shadow: 0 0 0 4px rgba(239,68,68,.2); }
  #status span { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  main { display: grid; grid-template-columns: minmax(0, 2fr) minmax(300px, 1fr); gap: 16px; padding: 16px; max-width: 1600px; margin: 0 auto; }
  @media (max-width: 860px) { main { grid-template-columns: 1fr; padding: 12px; } }
  .stage { position: relative; background: #000; border-radius: 14px; overflow: hidden; aspect-ratio: 16 / 9; border: 1px solid var(--line); }
  video { width: 100%; height: 100%; display: block; background: #000; }
  .overlay { position: absolute; inset: 0; display: grid; place-items: center; text-align: center; padding: 24px; color: var(--muted); }
  .overlay[hidden] { display: none; }
  #unmute { position: absolute; left: 12px; bottom: 12px; border: 0; border-radius: 999px; padding: 8px 14px;
    background: rgba(11,16,32,.8); color: var(--fg); font: inherit; font-size: 14px; cursor: pointer; }
  #unmute[hidden] { display: none; }
  aside { background: var(--night); border: 1px solid var(--line); border-radius: 14px; padding: 16px; display: flex; flex-direction: column; min-height: 0; }
  aside h2 { margin: 0 0 4px; font-size: 13px; letter-spacing: .08em; text-transform: uppercase; color: var(--muted); }
  #topic { margin: 0 0 12px; font-size: 20px; font-weight: 700; }
  form { display: grid; gap: 8px; margin-bottom: 14px; }
  input, textarea { width: 100%; border-radius: 10px; border: 1px solid var(--line); background: var(--ink); color: var(--fg);
    font: inherit; padding: 10px 12px; }
  textarea { resize: vertical; min-height: 64px; }
  .row { display: flex; gap: 8px; align-items: center; }
  .row input { flex: 1; }
  button.post { border: 0; border-radius: 10px; padding: 10px 16px; font: inherit; font-weight: 700; color: #fff; cursor: pointer;
    background: linear-gradient(135deg, var(--a), var(--b)); }
  button.post:disabled { opacity: .5; cursor: default; }
  #msg { font-size: 13px; color: var(--muted); min-height: 1.2em; }
  #notes { list-style: none; margin: 0; padding: 0; display: grid; gap: 8px; overflow: auto; }
  #notes li { display: flex; gap: 10px; align-items: flex-start; background: rgba(255,255,255,.04); border: 1px solid var(--line);
    border-radius: 12px; padding: 10px 12px; }
  #notes .text { flex: 1; min-width: 0; overflow-wrap: anywhere; }
  #notes .by { display: block; font-size: 12px; color: var(--muted); margin-top: 2px; }
  #notes button { flex: none; border: 1px solid var(--line); background: transparent; color: var(--fg); border-radius: 999px;
    padding: 4px 10px; font: inherit; font-size: 14px; cursor: pointer; }
  #notes button.on { background: rgba(108,92,255,.25); border-color: var(--a); }
  .empty { color: var(--muted); font-size: 14px; }
  #announce { margin: 0 0 12px; padding: 12px 14px; border-radius: 12px; font-weight: 600;
    background: linear-gradient(135deg, rgba(108,92,255,.35), rgba(217,70,239,.3)); border: 1px solid rgba(217,70,239,.5); }
  #announce small { display: block; font-weight: 700; font-size: 11px; letter-spacing: .08em; text-transform: uppercase; opacity: .8; margin-bottom: 2px; }
  #notes li.host { border-color: rgba(217,70,239,.55); background: rgba(217,70,239,.12); }
  .badge { display: inline-block; font-size: 11px; font-weight: 700; padding: 1px 7px; border-radius: 999px; margin-left: 6px;
    background: linear-gradient(135deg, var(--a), var(--b)); color: #fff; vertical-align: 1px; }
  #join { max-width: 360px; margin: 12vh auto; padding: 24px; text-align: center; }
  #join input { text-align: center; font-size: 24px; letter-spacing: .3em; text-transform: uppercase; margin: 16px 0; }
  [hidden] { display: none !important; }
</style>
</head>
<body>
<header>
  <div class="mark" aria-hidden="true"></div>
  <h1>Snazzy Pro Live</h1>
  <div id="status"><div class="dot"></div><span id="statusText">Connecting…</span></div>
</header>

<section id="join" hidden>
  <h2>Join the room</h2>
  <p class="empty">Enter the code shown on the presenter's screen.</p>
  <form id="joinForm"><input id="code" maxlength="6" autocomplete="off" autocapitalize="characters" aria-label="Room code"><button class="post">Join</button></form>
</section>

<main id="room" hidden>
  <div>
    <div class="stage">
      <video id="video" playsinline muted autoplay></video>
      <div class="overlay" id="waiting">Waiting for the presenter to start…</div>
      <button id="unmute" hidden>🔈 Tap for sound</button>
    </div>
  </div>
  <aside aria-labelledby="boardTitle">
    <h2 id="boardTitle">Brainstorm</h2>
    <p id="topic"></p>
    <div id="announce" hidden role="status" aria-live="polite"><small>From the presenter</small><span id="announceText"></span></div>
    <form id="noteForm">
      <textarea id="text" maxlength="280" placeholder="Add an idea…" aria-label="Your idea"></textarea>
      <div class="row">
        <input id="name" maxlength="40" placeholder="Your name (optional)" aria-label="Your name">
        <button class="post" id="post">Post</button>
      </div>
      <div id="msg" role="status"></div>
    </form>
    <ul id="notes"></ul>
  </aside>
</main>

<script>
(() => {
  const $ = id => document.getElementById(id);
  const params = new URLSearchParams(location.search);
  let code = (params.get('k') || '').toUpperCase();
  const store = (k, v) => { try { if (v === undefined) return localStorage.getItem(k); localStorage.setItem(k, v); } catch (e) { return null; } };
  let client = store('snazzy-client');
  if (!client) { client = (crypto.randomUUID ? crypto.randomUUID() : String(Math.random()).slice(2) + Date.now()); store('snazzy-client', client); }
  const q = () => 'k=' + encodeURIComponent(code);
  const headers = () => ({ 'Content-Type': 'application/json', 'X-Room-Code': code, 'X-Snazzy-Client': client });

  if (!code) { $('join').hidden = false; }
  $('joinForm').addEventListener('submit', e => {
    e.preventDefault();
    const c = $('code').value.trim().toUpperCase();
    if (c) location.search = '?k=' + encodeURIComponent(c);
  });
  if (!code) return;
  $('room').hidden = false;
  $('name').value = store('snazzy-name') || '';

  // ---- Board -------------------------------------------------------------
  let board = { notes: [], open: true, topic: '' };
  function renderBoard() {
    $('topic').textContent = board.topic || 'Share your ideas';
    $('announce').hidden = !board.announcement;
    $('announceText').textContent = board.announcement || '';
    $('text').disabled = $('post').disabled = !board.open;
    $('text').placeholder = board.open ? 'Add an idea…' : 'The board is closed.';
    const list = $('notes');
    list.replaceChildren();
    if (!board.notes.length) {
      const li = document.createElement('li'); li.className = 'empty'; li.textContent = 'No ideas yet. Be the first!';
      list.append(li);
    }
    for (const n of board.notes) {
      const li = document.createElement('li');
      const text = document.createElement('div'); text.className = 'text'; text.textContent = n.text;
      const by = document.createElement('span'); by.className = 'by'; by.textContent = n.author; text.append(by);
      if (n.host) { li.className = 'host'; const b = document.createElement('span'); b.className = 'badge'; b.textContent = 'Presenter'; by.append(b); }
      const vote = document.createElement('button');
      vote.textContent = '▲ ' + n.votes; vote.className = n.voted ? 'on' : '';
      vote.setAttribute('aria-label', (n.voted ? 'Remove vote' : 'Vote') + ', ' + n.votes + ' votes');
      vote.disabled = !board.open;
      vote.onclick = () => send('/api/vote', { id: n.id });
      li.append(text, vote); list.append(li);
    }
  }
  async function send(path, body) {
    try {
      const r = await fetch(path + '?' + q(), { method: 'POST', headers: headers(), body: JSON.stringify(body) });
      const j = await r.json();
      if (!r.ok) { $('msg').textContent = j.error || 'Something went wrong.'; return false; }
      board = j; renderBoard(); $('msg').textContent = ''; return true;
    } catch (e) { $('msg').textContent = 'Not connected.'; return false; }
  }
  $('noteForm').addEventListener('submit', async e => {
    e.preventDefault();
    const text = $('text').value.trim();
    if (!text) return;
    store('snazzy-name', $('name').value.trim());
    $('post').disabled = true;
    if (await send('/api/notes', { text, name: $('name').value.trim() })) $('text').value = '';
    $('post').disabled = !board.open;
  });
  $('text').addEventListener('keydown', e => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); $('noteForm').requestSubmit(); } });

  // ---- Status and live updates ------------------------------------------------
  function setStatus(s) {
    const live = !!s.live;
    $('status').classList.toggle('live', live);
    $('statusText').textContent = live ? ('Live' + (s.slide ? ' · ' + s.slide : '')) : (s.message || 'Waiting for the presenter');
    if (live) player.ensure(); else player.idle();
  }
  function connect() {
    const es = new EventSource('/api/events?' + q() + '&c=' + encodeURIComponent(client));
    es.addEventListener('board', e => { board = JSON.parse(e.data); renderBoard(); });
    es.addEventListener('status', e => setStatus(JSON.parse(e.data)));
    es.onerror = () => { $('statusText').textContent = 'Reconnecting…'; $('status').classList.remove('live'); };
  }

  // ---- Video ------------------------------------------------------------------
  const video = $('video');
  const MS = window.ManagedMediaSource || window.MediaSource;
  const player = {
    running: false, generation: -1, timer: null,
    idle() { $('waiting').hidden = false; $('waiting').textContent = 'Waiting for the presenter to start…'; },
    async ensure() {
      if (this.running) return;
      this.running = true;
      $('waiting').textContent = 'Connecting to the stream…';
      try {
        const st = await (await fetch('/live/status?' + q(), { cache: 'no-store' })).json();
        const mime = 'video/mp4; codecs="' + (st.codecs || 'avc1.640028,mp4a.40.2') + '"';
        if (MS && MS.isTypeSupported && MS.isTypeSupported(mime)) await this.mse(mime);
        else if (video.canPlayType('application/vnd.apple.mpegurl')) this.hls();
        else { $('waiting').textContent = 'This browser can\'t play the live video. Try Safari, Chrome or Edge.'; this.running = false; }
      } catch (e) { this.running = false; setTimeout(() => this.ensure(), 2000); }
    },
    hls() {
      video.src = '/live/stream.m3u8?' + q();
      video.play().catch(() => {});
      video.onplaying = () => { $('waiting').hidden = true; $('unmute').hidden = !video.muted; };
    },
    async mse(mime) {
      const ms = new MS();
      if (window.ManagedMediaSource) video.disableRemotePlayback = true;
      video.src = URL.createObjectURL(ms);
      await new Promise(r => ms.addEventListener('sourceopen', r, { once: true }));
      const sb = ms.addSourceBuffer(mime);
      sb.mode = 'segments';
      const append = data => new Promise((resolve, reject) => {
        sb.addEventListener('updateend', resolve, { once: true });
        sb.addEventListener('error', reject, { once: true });
        sb.appendBuffer(data);
      });
      let next = -1, lastTime = -1, stalled = 0;
      const restart = () => { this.running = false; clearTimeout(this.timer); try { ms.endOfStream(); } catch (e) {} this.ensure(); };
      const tick = async () => {
        try {
          const st = await (await fetch('/live/status?' + q(), { cache: 'no-store' })).json();
          if (!st.live) { this.timer = setTimeout(tick, 1000); return; }
          if (this.generation !== st.generation) {
            if (this.generation !== -1) return restart();
            this.generation = st.generation;
            await append(await (await fetch('/live/init.mp4?' + q(), { cache: 'no-store' })).arrayBuffer());
          }
          const seqs = st.segments.map(s => s.seq);
          const newest = seqs[seqs.length - 1];
          // Far behind (a slow link, or the tab was asleep): skip to near live
          // rather than downloading the backlog and never catching up.
          if (next < 0 || next < seqs[0] || newest - next > 3) next = Math.max(seqs[0], newest - 1);
          // Download the missing segments side by side (one connection at a time
          // is slow over a distant link), then add them in order.
          const wanted = seqs.filter(n => n >= next).slice(0, 4);
          const parts = await Promise.all(wanted.map(n =>
            fetch('/live/seg-' + n + '.m4s?' + q()).then(r => r.ok ? r.arrayBuffer() : null).catch(() => null)));
          for (let i = 0; i < parts.length && parts[i]; i++) { await append(parts[i]); next = wanted[i] + 1; }
          // Stay close to live, and get past gaps (a missed segment leaves a
          // hole the video would wait at forever).
          if (video.buffered.length) {
            const end = video.buffered.end(video.buffered.length - 1);
            if (!video.paused && Math.abs(video.currentTime - lastTime) < 0.01) stalled++; else stalled = 0;
            lastTime = video.currentTime;
            if (end - video.currentTime > 4 || video.currentTime < video.buffered.start(0) || (stalled >= 4 && end - video.currentTime > 0.5)) {
              video.currentTime = Math.max(0, end - 1);
              stalled = 0;
            }
            if (video.currentTime - video.buffered.start(0) > 30 && !sb.updating) sb.remove(0, video.currentTime - 10);
          }
          if (video.paused) video.play().then(() => { $('waiting').hidden = true; $('unmute').hidden = !video.muted; }).catch(() => {});
        } catch (e) { /* retry */ }
        this.timer = setTimeout(tick, 500);
      };
      tick();
    },
  };
  $('unmute').onclick = () => { video.muted = false; video.play().catch(() => {}); $('unmute').hidden = true; };
  video.addEventListener('playing', () => { $('waiting').hidden = true; });

  renderBoard();
  connect();
})();
</script>
</body>
</html>
"""#
}
