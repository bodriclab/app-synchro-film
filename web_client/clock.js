// App Synchro Film — horloge partagée des pages web (modes 4 et 5).
// L'hôte est l'horloge de référence : hôte ≈ performance.now() + offset,
// offset = médiane des 8 derniers échanges ping/pong (style NTP).
'use strict';
window.SFClock = {
  create() {
    const median = (a) => {
      const s = a.slice().sort((x, y) => x - y);
      const m = s.length >> 1;
      return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
    };
    const clock = {
      samples: [], offset: 0, rtt: null,
      hostNow: () => performance.now() + clock.offset,
      // t0/t3 : heure locale d'envoi/réception ; t1/t2 : heure de l'hôte.
      add(t0, t1, t2, t3) {
        clock.samples.push({ off: ((t1 - t0) + (t2 - t3)) / 2, rtt: Math.max(0, (t3 - t0) - (t2 - t1)) });
        if (clock.samples.length > 8) clock.samples.shift();
        clock.offset = median(clock.samples.map((s) => s.off));
        clock.rtt = median(clock.samples.map((s) => s.rtt));
      },
    };
    return clock;
  },
  // Position de lecture attendue à l'heure hôte t (même formule que l'app).
  positionAt(st, t, durationMs) {
    let p = st.playing ? st.position + (t - st.at) * st.rate : st.position;
    if (p < 0) p = 0;
    if (durationMs && p > durationMs) p = durationMs;
    return p;
  },
};
