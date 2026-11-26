// App Synchro Film — page web du mode 4 (aucune dépendance, 100 % hors-ligne).
// Même protocole que l'app : hello / ping / pong / state / cmd sur WebSocket,
// horloge NTP (médiane de 8), correction douce via playbackRate.
'use strict';
(function () {
  const DEADBAND = 40, SEEK = 1000, RATE = 0.02, RELEASE = 15, COOLDOWN = 1500;
  const token = new URLSearchParams(location.search).get('token') || '';
  const $ = (id) => document.getElementById(id);
  const video = $('video');
  const now = () => performance.now();

  // Safari (macOS) et tout navigateur iOS/iPadOS (moteur WebKit imposé) :
  // MKV illisible, HEVC seulement étiqueté hvc1, audio AAC/MP3, Range exigé.
  // On force donc le remux, en demandant au serveur le mode « safari ».
  function isSafariLike(ua, platform, maxTouchPoints) {
    const u = (ua || '').toLowerCase(), p = (platform || '').toLowerCase();
    const iOS = /iphone|ipad|ipod/.test(p) || /iphone|ipad|ipod/.test(u);
    const iPadOS = p === 'macintel' && maxTouchPoints > 1;
    const macSafari = u.includes('macintosh') && u.includes('safari') &&
      !/chrome|chromium|crios|fxios|edg|opr|opera|samsungbrowser|firefox/.test(u);
    return iOS || iPadOS || macSafari;
  }
  const SAFARI = isSafariLike(navigator.userAgent, navigator.platform, navigator.maxTouchPoints);
  const remuxQ = SAFARI ? '&safari=1' : '';

  // ---------- Horloge partagée (hôte = local + offset) ----------
  const clock = SFClock.create(); // clock.js (commun aux modes 4 et 5)
  const hostNow = clock.hostNow;
  const addSample = clock.add;

  // ---------- État ----------
  let ws = null, state = null, hello = null, durationMs = null;
  let useRemux = false, remuxOffset = 0, remuxLoadedAt = -1e9, loading = false;
  // seekLead : avance apprise pour compenser le temps qu'un saut met à
  // s'appliquer pendant la lecture (décodage, mise en mémoire tampon).
  const corr = { correcting: false, lastSeekAt: -1e9, drift: null,
    seekLead: 0, startLead: 0, measure: false, fastSeeks: 0, kind: '', armedAt: 0, flowingAt: -1 };
  // Un écart n'est mesuré qu'une fois l'image réellement repartie.
  function arm(kind) { corr.measure = true; corr.kind = kind; corr.armedAt = now(); corr.flowingAt = -1; }
  let seeking = false;

  const positionAt = (st, t) => SFClock.positionAt(st, t, durationMs);
  const expected = () => (state ? positionAt(state, hostNow()) : 0);
  const localPos = () => video.currentTime * 1000 + (useRemux ? remuxOffset : 0);
  const mediaId = () => (hello && hello.media ? hello.media.split('/').pop() : '');
  const q = (extra) => '?token=' + encodeURIComponent(token) + (extra || '');

  function send(msg) {
    if (ws && ws.readyState === 1) ws.send(JSON.stringify(msg));
  }
  const cmd = (action, position) =>
    send(position === undefined ? { type: 'cmd', action } : { type: 'cmd', action, position: Math.round(position) });

  // ---------- Messages / erreurs ----------
  let msgTimer = null;
  function showMessage(text, ms) {
    const m = $('message');
    m.textContent = text;
    m.hidden = false;
    clearTimeout(msgTimer);
    if (ms) msgTimer = setTimeout(() => { m.hidden = true; }, ms);
  }

  // ---------- WebSocket ----------
  let pingTimer = null;
  function ping() {
    clearTimeout(pingTimer);
    send({ type: 'ping', t0: now() });
    pingTimer = setTimeout(ping, clock.samples.length < 8 ? 150 : 10000);
  }
  function connect() {
    ws = new WebSocket('ws://' + location.host + '/ws' + q());
    ws.onopen = () => {
      send({ type: 'hello', v: 1, role: 'guest', name: 'Navigateur', mode: 'browser' });
      ping();
    };
    ws.onmessage = (ev) => {
      const t3 = now();
      let m;
      try { m = JSON.parse(ev.data); } catch (e) { return; }
      switch (m.type) {
        case 'pong': addSample(m.t0, m.t1, m.t2, t3); break;
        case 'hello': onHello(m); break;
        case 'state':
          if (!state || m.state.seq >= state.seq) state = m.state;
          correct();
          break;
        case 'subs': subs = m; applySubs(); break;
        case 'error': showMessage('Hôte : ' + (m.message || m.code)); break;
      }
    };
    ws.onclose = () => {
      clearTimeout(pingTimer);
      $('status').textContent = 'Déconnecté — nouvelle tentative…';
      if (!video.paused) video.pause();
      setTimeout(connect, 2000);
    };
  }

  function onHello(m) {
    const first = !hello;
    hello = m;
    if (m.duration) durationMs = m.duration;
    if (m.mediaName) document.title = m.mediaName + ' — App Synchro Film';
    if (!first) return;
    // Copie du film sur cet appareil (Wi-Fi local, reprise par Range).
    const dl = $('download');
    if (dl && m.media) {
      dl.href = m.media + q('&download=1');
      dl.setAttribute('download', m.mediaName || '');
      dl.hidden = false;
    }
    useRemux = !!m.remux || SAFARI;
    if (useRemux) loadRemux(expected());
    else video.src = m.media + q();
  }

  // ---------- Sous-titres choisis par l'hôte : WebVTT dans <track> ----------
  // En flux réemballé, le temps 0 de la vidéo = remuxOffset dans le film :
  // l'hôte décale les minutages (shift) à chaque rechargement.
  const BITMAP_SUBS = ['hdmv_pgs_subtitle', 'pgssub', 'dvd_subtitle', 'dvdsub', 'dvb_subtitle', 'dvbsub', 'xsub'];
  let subs = null;
  function applySubs() {
    video.querySelectorAll('track').forEach((t) => { t.track.mode = 'disabled'; t.remove(); });
    if (!subs || !subs.selection || subs.selection.kind === 'off') return;
    const sel = subs.selection;
    if (sel.codec && BITMAP_SUBS.indexOf(sel.codec) >= 0) {
      showMessage('Sous-titres image (PGS/VobSub) non pris en charge par le navigateur.', 6000);
      return;
    }
    const t = document.createElement('track');
    t.kind = 'subtitles';
    t.label = sel.title || sel.name || 'Sous-titres';
    t.default = true;
    const shift = useRemux ? -remuxOffset : 0;
    t.src = '/subs/track.vtt' + q('&rev=' + subs.rev + '&shift=' + Math.round(shift));
    t.addEventListener('load', () => { t.track.mode = 'showing'; });
    t.addEventListener('error', () => showMessage('Sous-titres indisponibles.', 5000));
    video.appendChild(t);
    t.track.mode = 'showing';
  }

  // ---------- Remux (MKV…) : flux MP4 fragmenté non « seekable » ----------
  async function loadRemux(posMs) {
    loading = true;
    log('reload ' + Math.round(posMs));
    let start = Math.max(0, Math.round(posMs));
    try {
      // Le flux démarre à l'image clé qui précède `start`. Pendant la lecture,
      // on cherche une image clé un peu en avance sur l'hôte : la page attend
      // alors, image figée, que l'hôte l'atteigne (pas de saut dans le flux,
      // qui le relancerait).
      let info = null;
      for (let i = 0; i < 6; i++) {
        const r = await fetch('/remux/' + mediaId() + '/info' + q('&start=' + start + remuxQ));
        if (!r.ok) throw new Error(await r.text());
        const next = await r.json();
        if (info && next.offsetMs <= info.offsetMs) break; // fin du film
        info = next;
        if (!state || !state.playing || info.offsetMs >= expected() + 1200) break;
        start += 2000;
      }
      const shiftChanged = remuxOffset !== info.offsetMs;
      remuxOffset = info.offsetMs;
      if (subs && shiftChanged) applySubs();
      video.src = '/remux/' + mediaId() + '.mp4' + q('&start=' + start + remuxQ);
      remuxLoadedAt = now();
      corr.lastSeekAt = now();
      corr.correcting = false;
    } catch (e) {
      showMessage('Conversion impossible : ' + e.message);
    } finally {
      loading = false;
    }
  }

  function isBuffered(t) {
    const b = video.buffered;
    for (let i = 0; i < b.length; i++) if (t >= b.start(i) && t <= b.end(i)) return true;
    return false;
  }

  // Rapide en lecture directe. En flux réemballé, un saut force le décodage
  // depuis l'image clé précédente (GOP entier) : on laisse le débit corriger.
  function canFastSeek(ms) { return !useRemux && canSeekLocally(ms); }

  function canSeekLocally(ms) {
    if (!useRemux) return true;
    const t = (ms + corr.seekLead - remuxOffset) / 1000;
    return t >= 0 && isBuffered(t) && isBuffered(Math.max(0, (ms - remuxOffset) / 1000));
  }

  const trace = [];
  function log(m) { trace.push(Math.round(now()) + ' ' + m); if (trace.length > 60) trace.shift(); }

  function seekTo(ms) {
    log('seek ' + Math.round(ms) + ' t=' + video.currentTime.toFixed(2) + ' lead=' + Math.round(corr.seekLead) + ' local=' + canSeekLocally(ms));
    corr.lastSeekAt = now();
    corr.correcting = false;
    video.playbackRate = 1;
    const playing = !!(state && state.playing);
    corr.measure = false;
    if (canSeekLocally(ms)) {
      // Saut direct dans le média : on vise un peu plus loin pour compenser
      // le temps de reprise, appris lors des sauts précédents.
      const target = ms + (playing ? corr.seekLead : 0);
      if (playing) arm('seek');
      video.currentTime = (useRemux ? target - remuxOffset : target) / 1000;
      return;
    }
    const t = (ms - remuxOffset) / 1000;
    // Flux en cours de chargement : on attend qu'il arrive plutôt que de relancer.
    if (t >= 0 && t < 30 && now() - remuxLoadedAt < 6000) return;
    loadRemux(ms + 1500);
  }

  video.addEventListener('error', () => {
    if (!useRemux) {
      useRemux = true;
      showMessage('Format non lu directement : conversion à la volée…', 4000);
      loadRemux(expected());
    } else {
      showMessage('Ce navigateur ne sait pas lire ce film (codec vidéo ou audio non '
        + 'pris en charge, ex. HEVC). Essayez Chrome ou Edge récents, ou utilisez '
        + 'l\'app (mode 2).');
    }
  });
  ['playing', 'seeked'].forEach((ev) => video.addEventListener(ev, () => {
    if (!video.paused) corr.flowingAt = now();
  }));
  video.addEventListener('loadedmetadata', () => {
    if (!durationMs && isFinite(video.duration)) durationMs = video.duration * 1000;
  });

  // ---------- Correction douce ----------
  function setRate(r) { if (Math.abs(video.playbackRate - r) > 1e-6) video.playbackRate = r; }

  function correct() {
    if (!state || clock.samples.length < 3 || !video.src || loading) return;
    const exp = expected();
    const drift = localPos() - exp;
    corr.drift = drift;
    if (state.playing && video.paused) {
      // En avance : on attend, en démarrant un peu tôt (délai de démarrage appris).
      if (drift > Math.max(DEADBAND, corr.startLead) && drift < 10000) return;
      if ((drift < -DEADBAND || drift >= 10000) && now() - corr.lastSeekAt > COOLDOWN) seekTo(exp);
      // Le démarrage prend du temps : on mesurera l'écart une fois lancé.
      arm('start');
      corr.lastSeekAt = now();
      video.play().then(() => { $('unlock').hidden = true; })
        .catch(() => { $('unlock').hidden = false; });
      return;
    }
    if (!state.playing && !video.paused) video.pause();
    if (video.readyState < 2 || video.seeking) return;
    if (now() - corr.lastSeekAt < COOLDOWN) return;
    const abs = Math.abs(drift);
    if (!state.playing) {
      corr.correcting = false;
      setRate(1);
      // Flux réemballé à l'arrêt : pas de rechargement pour un petit écart.
      if (abs >= DEADBAND && (!useRemux || canSeekLocally(exp) || abs > 10000)) seekTo(exp);
      return;
    }
    if (corr.measure && (corr.flowingAt < corr.armedAt || now() - corr.flowingAt < 400)) {
      if (now() - corr.armedAt < 8000) return; // on attend que l'image reparte
      corr.measure = false;
    }
    if (corr.measure) {
      // Premier écart mesuré après un saut : on apprend le délai du saut et,
      // s'il reste un écart net, on refait un saut (3 fois max) plutôt que
      // d'attendre de longues secondes de correction à ±2 %.
      corr.measure = false;
      log('measure ' + corr.kind + ' drift=' + Math.round(drift));
      const learn = (v) => Math.min(1500, Math.max(0, v - drift * 0.9));
      if (corr.kind === 'seek') corr.seekLead = learn(corr.seekLead);
      else corr.startLead = learn(corr.startLead);
      if (abs > 120 && abs <= SEEK && corr.fastSeeks < 3 && canFastSeek(exp)) { corr.fastSeeks++; seekTo(exp); return; }
      corr.fastSeeks = 0;
    }
    if (abs > SEEK) { seekTo(exp); return; }
    if (corr.correcting) {
      if (abs <= RELEASE) { corr.correcting = false; setRate(1); }
      else setRate(drift > 0 ? 1 - RATE : 1 + RATE);
    } else if (abs >= DEADBAND) {
      corr.correcting = true;
      setRate(drift > 0 ? 1 - RATE : 1 + RATE);
    }
  }

  // ---------- Interface ----------
  const fmt = (ms) => {
    const s = Math.max(0, Math.floor(ms / 1000));
    const h = Math.floor(s / 3600), m = Math.floor(s / 60) % 60, ss = s % 60;
    const two = (n) => String(n).padStart(2, '0');
    return h ? h + ':' + two(m) + ':' + two(ss) : two(m) + ':' + two(ss);
  };
  function render() {
    const connected = ws && ws.readyState === 1 && hello;
    const pos = state ? expected() : 0;
    $('play').textContent = state && state.playing ? '❚❚' : '▶';
    $('time').textContent = fmt(pos);
    $('duration').textContent = durationMs ? fmt(durationMs) : '--:--';
    if (!seeking && durationMs) $('seek').value = Math.round((pos / durationMs) * 1000);
    if (connected) {
      const parts = ['Connecté à ' + (hello.name || 'l\'hôte')];
      if (corr.drift !== null) parts.push('écart ' + Math.round(corr.drift) + ' ms');
      if (corr.correcting) parts.push('correction ' + Math.round(video.playbackRate * 100) + ' %');
      if (clock.rtt !== null) parts.push('RTT ' + Math.round(clock.rtt) + ' ms');
      if (useRemux) parts.push('conversion MP4');
      $('status').textContent = parts.join(' · ');
    }
  }

  $('play').onclick = () => {
    if (!state) return;
    video.play().catch(() => {}); // geste utilisateur : débloque le son
    cmd(state.playing ? 'pause' : 'play');
  };
  $('back').onclick = () => cmd('seek', Math.max(0, expected() - 10000));
  $('fwd').onclick = () => cmd('seek', expected() + 10000);
  $('seek').addEventListener('input', () => { seeking = true; });
  $('seek').addEventListener('change', (e) => {
    seeking = false;
    if (durationMs) cmd('seek', (e.target.value / 1000) * durationMs);
  });
  $('unlock').onclick = () => {
    video.play().then(() => { $('unlock').hidden = true; }).catch(() => {});
  };
  $('full').onclick = () => {
    const el = $('stage');
    if (document.fullscreenElement) document.exitFullscreen();
    else if (el.requestFullscreen) el.requestFullscreen();
    else if (video.webkitEnterFullscreen) video.webkitEnterFullscreen();
  };

  // Exposé pour les tests automatisés (Chrome headless).
  window.synchroFilm = { clock, corr, trace, get state() { return state; }, get drift() { return corr.drift; },
    get safari() { return SAFARI; }, get subs() { return subs; },
    subtitleCues() {
      const t = video.querySelector('track');
      if (!t || !t.track.cues) return null;
      return Array.from(t.track.cues).map((c) => ({ start: c.startTime, end: c.endTime, text: c.text, mode: t.track.mode }));
    }, get useRemux() { return useRemux; }, get remuxOffset() { return remuxOffset; }, video, cmd };

  setInterval(() => { correct(); render(); }, 250);
  connect();
})();
