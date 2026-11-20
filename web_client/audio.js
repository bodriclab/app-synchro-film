// App Synchro Film — page web du mode 5 (audio seul, aucune dépendance,
// 100 % hors-ligne). Page servie en http sur le réseau local : PAS de
// contexte sécurisé, donc ni AudioWorklet ni WebCodecs. L'hôte envoie des
// trames PCM s16le 48 kHz stéréo de 20 ms horodatées (WebSocket binaire
// /pcm, ~1,2 s d'avance) ; chaque trame est programmée avec un
// AudioBufferSourceNode à l'instant exact où la timeline de l'hôte
// l'atteint (horloge NTP partagée, latence de sortie et décalage manuel
// compensés).
'use strict';
(function () {
  const FRAME_MS = 20, RATE = 48000, SPF = 960, HEADER = 16, FLAG_PCM = 1;
  // s programmées d'avance dans le contexte audio. Page masquée (écran
  // éteint, onglet en arrière-plan) : les minuteries sont ralenties, on
  // programme plus loin (les paquets, eux, continuent d'arriver).
  const HORIZON = 0.3, HORIZON_HIDDEN = 1.0;
  const SAFETY = 0.005;     // s minimum avant de démarrer une source
  const CONTIG = 0.030;     // s d'écart toléré avant de recaler net (sinon trames jointives)
  const MAX_SKEW = 0.01;    // correction douce : vitesse ±1 % max (écart rattrapé en ~1 s)
  const FADE = 96;          // échantillons (2 ms) de fondu aux discontinuités
  const OFFSET_KEY = 'synchroFilm.audioOffsetMs';
  const token = new URLSearchParams(location.search).get('token') || '';
  const $ = (id) => document.getElementById(id);
  const now = () => performance.now();
  const q = () => '?token=' + encodeURIComponent(token);
  const clock = SFClock.create();

  let ws = null, pcmWs = null, state = null, durationMs = null, ctx = null, master = null;
  let manualMs = clampOffset(Number(localStorage.getItem(OFFSET_KEY)) || 0);
  const stats = { received: 0, scheduled: 0, late: 0, concealed: 0, missing: 0,
    resyncs: 0, flushes: 0, maxContigErrMs: 0 };

  function clampOffset(v) { return Math.max(-500, Math.min(500, Math.round(v))); }
  const fmt = (ms) => {
    const s = Math.max(0, Math.floor(ms / 1000));
    const h = Math.floor(s / 3600), m = Math.floor(s / 60) % 60, x = s % 60;
    const p = (n) => String(n).padStart(2, '0');
    return (h ? h + ':' : '') + p(m) + ':' + p(x);
  };
  const expected = () => (state ? SFClock.positionAt(state, clock.hostNow(), durationMs) : 0);
  function showMessage(text) { $('message').textContent = text; $('message').hidden = !text; }

  // ---------- Contrôle (même protocole que l'app et le mode 4) ----------
  function send(msg) { if (ws && ws.readyState === 1) ws.send(JSON.stringify(msg)); }
  const cmd = (action, position) =>
    send(position === undefined ? { type: 'cmd', action } : { type: 'cmd', action, position: Math.round(position) });
  let pingTimer = null;
  function ping() {
    clearTimeout(pingTimer);
    send({ type: 'ping', t0: now() });
    pingTimer = setTimeout(ping, clock.samples.length < 8 ? 150 : 5000);
  }
  function connect() {
    ws = new WebSocket('ws://' + location.host + '/ws' + q());
    ws.onopen = () => {
      send({ type: 'hello', v: 1, role: 'guest', name: 'Navigateur (son)', mode: 'browser_audio' });
      ping();
      setConn('Connecté', 'ok');
    };
    ws.onmessage = (ev) => {
      const t3 = now();
      let m;
      try { m = JSON.parse(ev.data); } catch (e) { return; }
      switch (m.type) {
        case 'pong': clock.add(m.t0, m.t1, m.t2, t3); break;
        case 'hello':
          if (m.duration) durationMs = m.duration;
          if (m.mediaName) { $('title').textContent = m.mediaName; document.title = m.mediaName + ' — son'; }
          break;
        case 'state': onState(m.state); break;
        case 'error': showMessage('Hôte : ' + (m.message || m.code)); break;
      }
    };
    ws.onclose = () => {
      clearTimeout(pingTimer);
      setConn('Déconnecté — nouvelle tentative…', 'ko');
      flush();
      setTimeout(connect, 2000);
    };
  }
  function connectPcm() {
    pcmWs = new WebSocket('ws://' + location.host + '/pcm' + q());
    pcmWs.binaryType = 'arraybuffer';
    pcmWs.onmessage = (ev) => onPacket(ev.data);
    pcmWs.onclose = () => setTimeout(connectPcm, 2000);
  }
  function setConn(text, cls) { const c = $('conn'); c.textContent = text; c.className = 'pill ' + (cls || ''); }

  function onState(st) {
    if (state && st.seq < state.seq) return;
    const changed = !state || st.seq !== state.seq;
    state = st;
    // Nouvel état (lecture, pause, saut) : on reprogramme tout depuis le buffer.
    if (changed) flush();
    schedule();
  }

  // ---------- Buffer de gigue (indexé par n° de trame) ----------
  const frames = new Map();
  let epoch = -1;
  const newerEpoch = (a, b) => b < 0 || (((a - b) & 0xffff) > 0 && ((a - b) & 0xffff) < 0x8000);
  function onPacket(buf) {
    if (!(buf instanceof ArrayBuffer) || buf.byteLength < HEADER + 4) return;
    const d = new DataView(buf);
    if (d.getUint8(0) !== 0x53 || d.getUint8(1) !== 0x46 || d.getUint8(2) !== 1) return;
    if (!(d.getUint8(3) & FLAG_PCM)) return;
    const e = d.getUint16(4), pos = d.getUint32(12);
    if (e !== epoch) {
      if (!newerEpoch(e, epoch)) return; // paquet d'un flux périmé
      epoch = e; // saut côté hôte : on vide tout
      frames.clear();
      flush();
    }
    const n = (buf.byteLength - HEADER) >> 2;
    const pcm = new Int16Array(buf, HEADER, n * 2);
    const l = new Float32Array(n), r = new Float32Array(n);
    for (let i = 0; i < n; i++) { l[i] = pcm[2 * i] / 32768; r[i] = pcm[2 * i + 1] / 32768; }
    const idx = Math.round(pos / FRAME_MS);
    if (lastIdx !== null && idx <= lastIdx) return; // trop tard
    frames.set(idx, { l, r });
    stats.received++;
    if (frames.size > 400) frames.delete(Math.min(...frames.keys()));
    schedule(); // les messages WebSocket ne sont pas ralentis comme les minuteries
  }

  // ---------- Correspondance horloge locale ↔ contexte audio ----------
  // currentTime avance par blocs : on garde le max des écarts récents
  // (le bloc le plus récent), ce qui suit aussi la dérive des deux horloges.
  const mapSamples = [];
  let mapOff = null;
  function updateMap() {
    mapSamples.push(ctx.currentTime - now() / 1000);
    if (mapSamples.length > 40) mapSamples.shift();
    mapOff = Math.max(...mapSamples);
  }
  const ctxAt = (perfMs) => perfMs / 1000 + mapOff;
  const perfAt = (ctxT) => (ctxT - mapOff) * 1000;
  // Latence entre la programmation et le son réellement entendu.
  const outLatency = () => (ctx.baseLatency || 0) + (ctx.outputLatency || 0);
  const lead = () => outLatency() + manualMs / 1000;
  // Instant (temps du contexte) où démarrer la trame idx.
  function startFor(idx) {
    const hostT = state.at + (idx * FRAME_MS - state.position) / (state.rate || 1);
    return ctxAt(hostT - clock.offset) - lead();
  }

  // ---------- Programmation ----------
  let scheduled = [];
  let lastIdx = null, lastEnd = null, lastData = null, lastWasReal = false;
  function flush() {
    for (const s of scheduled) { try { s.src.stop(); } catch (e) { /* déjà fini */ } }
    if (scheduled.length) stats.flushes++;
    scheduled = [];
    lastIdx = null; lastEnd = null; lastWasReal = false;
  }

  function makeBuffer(data, fadeIn, fadeOutAll) {
    const b = ctx.createBuffer(2, SPF, RATE);
    const l = Float32Array.from(data.l), r = Float32Array.from(data.r);
    if (fadeIn) for (let i = 0; i < FADE; i++) { l[i] *= i / FADE; r[i] *= i / FADE; }
    if (fadeOutAll) for (let i = 0; i < SPF; i++) { const g = 1 - i / SPF; l[i] *= g; r[i] *= g; }
    b.copyToChannel(l, 0);
    b.copyToChannel(r, 1);
    return b;
  }

  function schedule() {
    if (!ctx || ctx.state !== 'running' || !state || !state.playing || clock.samples.length < 3) return;
    updateMap();
    const ctxNow = ctxAt(now());
    scheduled = scheduled.filter((s) => s.end > ctxNow - 0.1);
    for (const k of frames.keys()) if (lastIdx !== null && k <= lastIdx) frames.delete(k);
    if (lastIdx === null) {
      // Première trame : celle qui doit sonner juste après maintenant.
      const heardAt = perfAt(ctxNow + SAFETY + lead()) + clock.offset;
      lastIdx = Math.floor(SFClock.positionAt(state, heardAt, durationMs) / FRAME_MS) - 1;
    }
    for (let guard = 0; guard < 80; guard++) {
      const idx = lastIdx + 1;
      if (durationMs && idx * FRAME_MS >= durationMs) break;
      const target = startFor(idx);
      if (target > ctxNow + (document.hidden ? HORIZON_HIDDEN : HORIZON)) break;
      let when = target;
      let fadeIn = !lastWasReal;
      if (lastEnd !== null) {
        if (Math.abs(target - lastEnd) <= CONTIG) when = lastEnd; // jointif, sans clic
        else { stats.resyncs++; fadeIn = true; }
      }
      // Trame pas encore arrivée mais encore attendue à temps : on patiente.
      if (!frames.has(idx) && when > ctxNow + 0.05) break;
      let offset = 0;
      if (when < ctxNow + SAFETY) { offset = ctxNow + SAFETY - when; when = ctxNow + SAFETY; }
      lastIdx = idx;
      if (offset >= FRAME_MS / 1000) { stats.late++; lastEnd = null; lastWasReal = false; frames.delete(idx); continue; }
      const data = frames.get(idx);
      frames.delete(idx);
      let buffer;
      if (data) {
        buffer = makeBuffer(data, fadeIn || offset > 0, false);
        lastData = data; lastWasReal = true;
      } else if (lastWasReal && lastData) {
        buffer = makeBuffer(lastData, false, true); // masquage : trame répétée en fondu
        stats.concealed++; lastWasReal = false;
      } else {
        stats.missing++; lastEnd = null; lastWasReal = false;
        continue;
      }
      const src = ctx.createBufferSource();
      src.buffer = buffer;
      // Trames jointives : on rattrape l'écart restant en jouant la trame
      // très légèrement plus vite/lentement (inaudible), comme le mode 4.
      const start = when - offset;
      // when > target : en retard → un peu plus vite (rattrapage proportionnel, ~1 s).
      const rate = offset > 0 ? 1 : 1 + Math.max(-MAX_SKEW, Math.min(MAX_SKEW, when - target));
      src.playbackRate.value = rate;
      src.connect(master);
      src.start(when, offset);
      const err = Math.abs(start - target) * 1000;
      if (err > stats.maxContigErrMs) stats.maxContigErrMs = err;
      const end = when + (FRAME_MS / 1000 - offset) / rate;
      scheduled.push({ src, idx, start, end, rate, offset });
      lastEnd = end;
      stats.scheduled++;
    }
  }

  // ---------- Déverrouillage audio (iOS : geste utilisateur obligatoire) ----------
  function unlock() {
    try {
      if (navigator.audioSession) navigator.audioSession.type = 'playback'; // iOS : ignorer le mode silencieux
    } catch (e) { /* non supporté */ }
    if (!ctx) {
      const AC = window.AudioContext || window.webkitAudioContext;
      if (!AC) { showMessage('Ce navigateur ne gère pas Web Audio.'); return; }
      try { ctx = new AC({ sampleRate: RATE, latencyHint: 'interactive' }); } catch (e) { ctx = new AC(); }
      master = ctx.createGain();
      master.connect(ctx.destination);
      ctx.onstatechange = refreshUi;
    }
    // Un tampon silencieux démarré dans le geste débloque iOS.
    const s = ctx.createBufferSource();
    s.buffer = ctx.createBuffer(1, 1, ctx.sampleRate);
    s.connect(ctx.destination);
    s.start(0);
    ctx.resume().then(refreshUi, refreshUi);
  }

  // ---------- Interface ----------
  function setOffset(v) {
    manualMs = clampOffset(v);
    localStorage.setItem(OFFSET_KEY, String(manualMs));
    $('slider').value = manualMs;
    $('offsetValue').textContent = (manualMs > 0 ? '+' : '') + manualMs + ' ms';
    flush();
    schedule();
  }
  function refreshUi() {
    const running = ctx && ctx.state === 'running';
    $('unlock').hidden = !!running;
    if (state) {
      $('state').textContent = state.playing ? '▶ Lecture' : '⏸ Pause';
      $('play').textContent = state.playing ? '⏸' : '▶';
      $('pos').textContent = fmt(expected());
    }
    $('dur').textContent = durationMs ? fmt(durationMs) : '--:--';
    if (ctx) {
      $('latency').textContent = 'Latence de sortie compensée : ' + Math.round(outLatency() * 1000) +
        ' ms (auto) ' + (manualMs >= 0 ? '+ ' : '− ') + Math.abs(manualMs) + ' ms (réglage)';
    }
  }
  $('unlock').addEventListener('click', unlock);
  $('play').addEventListener('click', () => { if (!ctx) unlock(); cmd(state && state.playing ? 'pause' : 'play'); });
  $('back').addEventListener('click', () => cmd('seek', Math.max(0, expected() - 10000)));
  $('fwd').addEventListener('click', () => cmd('seek', expected() + 10000));
  $('slider').addEventListener('input', (e) => setOffset(Number(e.target.value)));
  $('reset').addEventListener('click', () => setOffset(0));
  document.addEventListener('visibilitychange', () => { if (!document.hidden && ctx) ctx.resume(); });
  setOffset(manualMs);
  if (!token) showMessage('Lien incomplet : scannez le QR code de l\'hôte.');
  connect();
  connectPcm();
  setInterval(schedule, 20);
  setInterval(refreshUi, 250);

  // Point d'accès pour les tests automatisés.
  window.synchroAudio = {
    clock, stats, unlock, cmd, setOffset,
    get ctx() { return ctx; }, get state() { return state; }, get frames() { return frames.size; },
    // Position du son en cours (ms du film) et instant d'écoute (ms epoch).
    probe() {
      if (!ctx || mapOff === null) return null;
      const p = now();
      const c = ctxAt(p);
      const s = scheduled.find((x) => x.start <= c && c < x.end);
      return {
        epochMs: performance.timeOrigin + p,
        playingMs: s ? s.idx * FRAME_MS + s.offset * 1000 + (c - (s.start + s.offset)) * 1000 * s.rate : null,
        latencyMs: outLatency() * 1000, manualMs, rawLagMs: (c - ctx.currentTime) * 1000,
      };
    },
  };
})();
