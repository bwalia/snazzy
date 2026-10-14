/// The candidate's interview page (one file, no outside resources). It reads
/// `state` every second and posts to `start`, `answer`, `event` and `self-id`
/// next to its own address. Mobile first, keyboard and screen-reader friendly.
enum CandidatePage {
    static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>Interview</title>
<style>
:root { --bg:#f7f7fb; --card:#fff; --text:#1c1c28; --muted:#5d5d73; --accent:#5b4ce6; --accent-text:#fff; --line:#dcdce6; --me:#ece9ff; --warn:#8a4b00; }
@media (prefers-color-scheme: dark) { :root { --bg:#121218; --card:#1d1d26; --text:#f2f2f7; --muted:#a9a9bd; --accent:#8b80ff; --accent-text:#111; --line:#33333f; --me:#2b2750; --warn:#ffb35c; } }
body.big { font-size: 125%; }
body.contrast { --bg:#000; --card:#000; --text:#fff; --muted:#fff; --accent:#ffde00; --accent-text:#000; --line:#fff; --me:#222; }
* { box-sizing: border-box; }
body { margin:0; background:var(--bg); color:var(--text); font: 17px/1.5 -apple-system, system-ui, "Segoe UI", Roboto, sans-serif; }
main { max-width: 720px; margin: 0 auto; padding: 16px; }
h1 { font-size: 1.35em; margin: .2em 0 .1em; }
.muted { color: var(--muted); }
.card { background: var(--card); border: 1px solid var(--line); border-radius: 14px; padding: 16px; margin: 12px 0; }
.notice { white-space: pre-wrap; }
button, .btn { font: inherit; border-radius: 10px; border: 1px solid var(--line); background: var(--card); color: var(--text); padding: 10px 14px; min-height: 44px; cursor: pointer; }
button.primary { background: var(--accent); color: var(--accent-text); border-color: var(--accent); font-weight: 600; }
button:focus-visible, textarea:focus-visible, input:focus-visible, select:focus-visible { outline: 3px solid var(--accent); outline-offset: 2px; }
button:disabled { opacity: .5; cursor: default; }
textarea, input[type=text], select { font: inherit; width: 100%; border-radius: 10px; border: 1px solid var(--line); background: var(--card); color: var(--text); padding: 10px; }
textarea { min-height: 120px; resize: vertical; }
.row { display: flex; gap: 8px; flex-wrap: wrap; align-items: center; }
.spacer { flex: 1; }
.chat { display: flex; flex-direction: column; gap: 10px; }
.msg { padding: 10px 14px; border-radius: 14px; max-width: 92%; white-space: pre-wrap; }
.msg.interviewer { background: var(--card); border: 1px solid var(--line); align-self: flex-start; }
.msg.candidate { background: var(--me); align-self: flex-end; }
.who { font-size: .8em; color: var(--muted); margin-bottom: 2px; }
.bar { height: 8px; background: var(--line); border-radius: 4px; overflow: hidden; }
.bar > div { height: 100%; background: var(--accent); width: 0; transition: width .3s; }
.sticky { position: sticky; bottom: 0; background: var(--bg); padding: 8px 0 12px; }
label { display: block; margin: 8px 0 4px; font-weight: 600; }
fieldset { border: 1px solid var(--line); border-radius: 10px; margin: 10px 0; padding: 8px 12px; }
.choice { display: flex; gap: 8px; align-items: center; margin: 6px 0; font-weight: normal; }
.sr { position: absolute; left: -9999px; }
.typing { color: var(--muted); font-style: italic; }
.warn { color: var(--warn); }
</style>
</head>
<body>
<main id="app" aria-live="polite"><p class="muted">Loading…</p></main>
<script>
(() => {
  const base = location.pathname.replace(/\/$/, "");
  const app = document.getElementById("app");
  let state = null, lastTurns = -1, draft = "", pasted = false, sending = false, view = "", skipped = false;
  const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;","'":"&#39;"}[c]));
  const post = async (path, body) => {
    const r = await fetch(base + "/" + path, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body || {}) });
    return r.ok ? r.json() : Promise.reject(await r.text());
  };
  const mins = s => { s = Math.max(0, Math.round(s)); return Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0"); };

  async function poll() {
    try {
      const r = await fetch(base + "/state", { cache: "no-store" });
      state = await r.json();
      render();
    } catch (e) { /* keep the page; try again */ }
    setTimeout(poll, state && state.busy ? 700 : 1500);
  }

  function render() {
    const s = state;
    if (!s) return;
    if (s.phase === "invalid" || s.phase === "expired") {
      return set("gone", `<h1>This interview link isn't available</h1><p class="muted">${s.phase === "expired" ? "It has expired." : "It may have been used already or withdrawn."} Please contact the person who sent it.</p>`);
    }
    if (s.phase === "notice") return renderNotice(s);
    if (s.phase === "finished") return renderFinished(s);
    renderInterview(s);
  }

  function set(key, html) { if (view !== key) { app.innerHTML = html; view = key; } }

  function renderNotice(s) {
    if (view === "notice") return;
    const adj = (s.adjustments_offered || []).map((a, i) =>
      `<label class="choice"><input type="checkbox" name="adj" value="${esc(a)}"> ${esc(a)}</label>`).join("");
    set("notice", `
      <h1>${esc(s.title)}</h1><p class="muted">${esc(s.organisation)}</p>
      <section class="card"><h2 class="sr">About this interview</h2><div class="notice">${esc(s.notice)}</div></section>
      <section class="card">
        <h2 style="font-size:1.05em;margin-top:0">Adjustments (optional)</h2>
        ${adj}
        <label for="other">Anything else?</label>
        <input type="text" id="other" maxlength="300" autocomplete="off">
        <div class="row" style="margin-top:8px">
          <label class="choice"><input type="checkbox" id="big"> Larger text</label>
          <label class="choice"><input type="checkbox" id="contrast"> High contrast</label>
        </div>
      </section>
      <div class="row">
        <button class="primary" id="go">I understand. Start the interview</button>
        <button id="person">I'd prefer to speak to a person</button>
      </div>`);
    document.getElementById("big").onchange = e => document.body.classList.toggle("big", e.target.checked);
    document.getElementById("contrast").onchange = e => document.body.classList.toggle("contrast", e.target.checked);
    document.getElementById("go").onclick = async () => {
      const list = [...document.querySelectorAll("input[name=adj]:checked")].map(i => i.value);
      const other = document.getElementById("other").value.trim();
      if (other) list.push(other);
      await post("start", { notice_hash: s.notice_hash, adjustments: list }).catch(() => {});
      view = ""; poll();
    };
    document.getElementById("person").onclick = async () => { await post("event", { event: "person" }).catch(() => {}); view = ""; };
  }

  function renderInterview(s) {
    if (view !== "interview") {
      set("interview", `
        <h1>${esc(s.title)}</h1>
        <div class="row muted" style="font-size:.9em"><span id="prog"></span><span class="spacer"></span><span id="time" aria-label="Time left"></span></div>
        <div class="bar" role="progressbar" aria-label="Progress" aria-valuemin="0" aria-valuemax="100"><div id="barfill"></div></div>
        <div class="chat" id="chat" role="log" aria-live="polite" style="margin-top:12px"></div>
        <div class="sticky" id="composer"></div>`);
      lastTurns = -1;
    }
    document.getElementById("prog").textContent = `Question progress ${Math.round((s.progress || 0) * 100)}%`;
    document.getElementById("barfill").style.width = Math.round((s.progress || 0) * 100) + "%";
    document.querySelector("[role=progressbar]").setAttribute("aria-valuenow", Math.round((s.progress || 0) * 100));
    document.getElementById("time").textContent = s.seconds_left != null ? mins(s.seconds_left) + " left" : "";
    const chat = document.getElementById("chat");
    if ((s.turns || []).length !== lastTurns || String(!!s.busy) !== chat.dataset.busy) {
      chat.innerHTML = (s.turns || []).map(t =>
        `<div class="msg ${t.role}"><div class="who">${t.role === "candidate" ? "You" : esc(s.interviewer_name)}</div>${esc(t.text)}</div>`).join("")
        + (s.busy ? `<div class="typing">${esc(s.interviewer_name)} is reading your answer…</div>` : "");
      chat.dataset.busy = String(!!s.busy);
      lastTurns = (s.turns || []).length;
      window.scrollTo(0, document.body.scrollHeight);
    }
    renderComposer(s);
  }

  function renderComposer(s) {
    const box = document.getElementById("composer");
    const key = (s.phase === "paused" ? "p" : "i") + "|" + (s.choices || []).join(",") + "|" + s.busy;
    if (box.dataset.key === key) return;
    box.dataset.key = key;
    if (s.phase === "paused") {
      box.innerHTML = `<div class="card"><p>The interview is paused. Your time isn't running.</p><button class="primary" id="resume">Carry on</button></div>`;
      document.getElementById("resume").onclick = () => post("event", { event: "resume" }).catch(() => {});
      return;
    }
    const controls = `
      <div class="row" style="margin-top:8px">
        <button data-ev="repeat">Repeat the question</button>
        <button data-ev="rephrase">Rephrase it</button>
        ${s.allow_pause ? `<button data-ev="pause">Pause</button>` : ""}
        <span class="spacer"></span>
        <button data-ev="person">Speak to a person instead</button>
      </div>`;
    if (s.choices && s.choices.length) {
      box.innerHTML = `<fieldset><legend>Your answer</legend><div class="row">${s.choices.map(c =>
        `<button class="primary" data-choice="${esc(c)}" ${s.busy ? "disabled" : ""}>${esc(c)}</button>`).join("")}</div></fieldset>` + controls;
      box.querySelectorAll("[data-choice]").forEach(b => b.onclick = () => send(b.dataset.choice, "typed"));
    } else {
      box.innerHTML = `
        <label for="answer">Your answer</label>
        <textarea id="answer" maxlength="6000" ${s.busy ? "disabled" : ""} placeholder="Type your answer. Take your time."></textarea>
        <div class="row" style="margin-top:8px"><span class="muted" style="font-size:.85em">Ctrl+Enter or ⌘+Enter to send</span><span class="spacer"></span>
        <button class="primary" id="send" ${s.busy ? "disabled" : ""}>Send answer</button></div>` + controls;
      const ta = document.getElementById("answer");
      ta.value = draft;
      ta.oninput = () => { draft = ta.value; };
      ta.onpaste = () => { pasted = true; };
      ta.onkeydown = e => { if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) { e.preventDefault(); send(ta.value, pasted ? "pasted" : "typed"); } };
      document.getElementById("send").onclick = () => send(ta.value, pasted ? "pasted" : "typed");
      if (!s.busy) ta.focus();
    }
    box.querySelectorAll("[data-ev]").forEach(b => b.onclick = () => post("event", { event: b.dataset.ev }).catch(() => {}));
  }

  async function send(text, input) {
    text = (text || "").trim();
    if (!text || sending) return;
    sending = true;
    try { await post("answer", { text, input }); draft = ""; pasted = false; } catch (e) {}
    sending = false;
    const box = document.getElementById("composer"); if (box) box.dataset.key = "";
    poll();
  }

  function renderFinished(s) {
    const done = s.self_id_done || skipped;
    if (view === "finished" + (done ? "1" : "0")) return;
    const thanks = `<h1>Thank you</h1><div class="card"><p>${esc(s.closing || "Your interview is complete.")}</p>
      ${s.end_reason === "human_requested" ? "<p>We've told the hiring team you'd like to speak to a person. This won't count against you.</p>" : ""}</div>`;
    if (!s.self_id || done) {
      set("finished1", thanks + (s.self_id_done ? `<p class="muted">Thank you for answering. You can close this page.</p>` : `<p class="muted">You can close this page.</p>`));
      return;
    }
    const qs = s.self_id.map(q => `<fieldset><legend>${esc(q.label)}</legend>${q.options.map(o =>
      `<label class="choice"><input type="radio" name="${esc(q.id)}" value="${esc(o)}"> ${esc(o)}</label>`).join("")}</fieldset>`).join("");
    set("finished0", thanks + `
      <section class="card">
        <h2 style="font-size:1.05em;margin-top:0">Optional: help us check our process is fair</h2>
        <p class="muted">These questions are voluntary. Your answers are stored separately from your interview, are never seen by the AI or by the people deciding, and are only reported in groups of 10 or more.</p>
        ${qs}
        <div class="row"><button class="primary" id="sid">Send answers</button><button id="skip">Skip</button></div>
      </section>`);
    document.getElementById("sid").onclick = async () => {
      const answers = {};
      s.self_id.forEach(q => { const c = document.querySelector(`input[name="${q.id}"]:checked`); if (c) answers[q.id] = c.value; });
      await post("self-id", { answers }).catch(() => {});
      view = ""; poll();
    };
    document.getElementById("skip").onclick = () => { skipped = true; view = ""; render(); };
  }

  poll();
})();
</script>
</body>
</html>
"""#
}
