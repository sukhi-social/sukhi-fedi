// SPDX-License-Identifier: AGPL-3.0-or-later
// 星の棚のまね ── その場で鳴らす、やわらかい lofi。
// 本物の星の棚は、名前を書けば使ってよい曲を <audio> で流す。これは、その手ざわりを確かめるための代わり。
// 鍵盤(Rhodes ふう)・ベース・ひとふしの旋律・跳ねる太鼓・部屋の響き・テープの揺れ・レコードのちりちり。
// 16 小節でひとめぐり。はじめは鍵盤だけ、途中でひと息ついて、また戻ってくる。
(() => {
  'use strict';
  const hz = (m) => 440 * Math.pow(2, (m - 69) / 12);
  const Q = { maj9: [4, 7, 11, 14], m9: [3, 7, 10, 14], m7: [3, 7, 10, 15], d9: [4, 10, 14, 16], maj7: [4, 7, 11, 16], m11: [3, 7, 10, 17], sus: [5, 7, 10, 14] };

  // 曲ごとの気配。root は MIDI。scale は旋律に使う音の高さ(0〜11)。
  const SONGS = {
    'morning-window': {
      bpm: 74, swing: 0.6, scale: [5, 7, 9, 0, 2], bright: 2600, seed: 11,
      prog: [[53, 'maj9'], [52, 'm7'], [50, 'm9'], [48, 'maj9']],
      kick: [0, 5], ghost: [3], snare: [2, 6], extra: 'birds',
    },
    'quiet-rain': {
      bpm: 66, swing: 0.62, scale: [0, 3, 5, 7, 10], bright: 1900, seed: 23,
      prog: [[48, 'm9'], [56, 'maj7'], [51, 'maj9'], [46, 'd9']],
      kick: [0, 4, 5], ghost: [7], snare: [2, 6], extra: 'rain',
    },
    'tea-steam': {
      bpm: 82, swing: 0.58, scale: [2, 4, 7, 9, 11], bright: 3000, seed: 37,
      prog: [[50, 'm9'], [55, 'd9'], [48, 'maj9'], [57, 'm11']],
      kick: [0, 3, 5], ghost: [7], snare: [2, 6], extra: 'kettle',
    },
  };

  function rng(seed) {
    let a = seed >>> 0;
    return () => { a = (a + 0x6d2b79f5) >>> 0; let t = a; t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
  }

  const L = {
    ctx: null, playing: false, volume: 0.8,
    ensure() {
      if (this.ctx) return true;
      const AC = window.AudioContext || window.webkitAudioContext;
      if (!AC) return false;
      const c = (this.ctx = new AC());
      // 出口:音量 → テープの丸み(lowpass がゆっくり揺れる)→ 軽い圧縮 → スピーカー
      this.out = c.createGain(); this.out.gain.value = 0;
      this.tone = c.createBiquadFilter(); this.tone.type = 'lowpass'; this.tone.frequency.value = 2400; this.tone.Q.value = 0.4;
      this.low = c.createBiquadFilter(); this.low.type = 'highpass'; this.low.frequency.value = 38;
      const comp = c.createDynamicsCompressor(); comp.threshold.value = -20; comp.ratio.value = 3; comp.attack.value = 0.01; comp.release.value = 0.25;
      this.bus = c.createGain(); this.bus.gain.value = 1;
      this.bus.connect(this.tone); this.tone.connect(this.low); this.low.connect(comp); comp.connect(this.out); this.out.connect(c.destination);
      // 部屋の響き(その場で作る残響)
      this.verb = c.createConvolver(); this.verb.buffer = this.impulse(2.6, 2.8);
      this.verbIn = c.createGain(); this.verbIn.gain.value = 0.32;
      this.verbIn.connect(this.verb); this.verb.connect(this.bus);
      // 鍵盤とベースは、太鼓が鳴るたびに少し身を引く(息をするような揺れ)
      this.duck = c.createGain(); this.duck.connect(this.bus);
      // 鍵盤の揺れ(トレモロ)
      this.keys = c.createGain(); this.keys.gain.value = 0.85;
      const trem = c.createOscillator(); trem.frequency.value = 4.2;
      const tremAmt = c.createGain(); tremAmt.gain.value = 0.12;
      trem.connect(tremAmt); tremAmt.connect(this.keys.gain); trem.start();
      this.keys.connect(this.duck); this.keys.connect(this.verbIn);
      // テープの揺れ:ゆっくりの wow と、細かい flutter を、全部の音の detune へ
      this.wow = c.createGain(); this.wow.gain.value = 1;
      const w1 = c.createOscillator(); w1.frequency.value = 0.33; const w1g = c.createGain(); w1g.gain.value = 7;
      const w2 = c.createOscillator(); w2.frequency.value = 5.7; const w2g = c.createGain(); w2g.gain.value = 1.6;
      w1.connect(w1g); w1g.connect(this.wow); w2.connect(w2g); w2g.connect(this.wow); w1.start(); w2.start();
      const tl = c.createOscillator(); tl.frequency.value = 0.07; const tlg = c.createGain(); tlg.gain.value = 260;
      tl.connect(tlg); tlg.connect(this.tone.frequency); tl.start();
      // ノイズの素
      this.white = this.noiseBuf(2, (i, r) => r * 2 - 1);
      this.vinyl = this.noiseBuf(4, (i, r, sr) => {
        let v = (r * 2 - 1) * 0.035;
        if (Math.random() < 0.00035) v += (Math.random() < 0.5 ? -1 : 1) * (0.35 + Math.random() * 0.6);
        return v;
      });
      return true;
    },
    noiseBuf(sec, f) {
      const c = this.ctx; const len = Math.floor(c.sampleRate * sec);
      const b = c.createBuffer(1, len, c.sampleRate); const d = b.getChannelData(0);
      for (let i = 0; i < len; i++) d[i] = f(i, Math.random(), c.sampleRate);
      return b;
    },
    impulse(sec, decay) {
      const c = this.ctx; const len = Math.floor(c.sampleRate * sec);
      const b = c.createBuffer(2, len, c.sampleRate);
      for (let ch = 0; ch < 2; ch++) {
        const d = b.getChannelData(ch); let lp = 0;
        for (let i = 0; i < len; i++) { lp = lp * 0.55 + (Math.random() * 2 - 1) * 0.45; d[i] = lp * Math.pow(1 - i / len, decay); }
      }
      return b;
    },
    osc(type, f, t0) {
      const o = this.ctx.createOscillator(); o.type = type; o.frequency.setValueAtTime(f, t0);
      this.wow.connect(o.detune);
      o.onended = () => { try { this.wow.disconnect(o.detune); } catch (e) { /* もう外れている */ } };
      return o;
    },

    start(id) {
      if (!this.ensure()) return false;
      this.halt();
      const c = this.ctx; c.resume();
      const s = (this.song = SONGS[id] || SONGS['morning-window']);
      this.rand = rng(s.seed);
      this.motif = null;
      this.bar = 0; this.step = 0;
      this.beat = 60 / s.bpm;
      this.next = c.currentTime + 0.12;
      this.tone.frequency.setValueAtTime(s.bright, c.currentTime);
      const now = c.currentTime;
      this.out.gain.cancelScheduledValues(now); this.out.gain.setValueAtTime(this.out.gain.value, now);
      this.out.gain.linearRampToValueAtTime(this.volume * 0.7, now + 2.5);
      this.loops = [this.bed('vinyl', 0.5, 'bandpass', 2600, 0.6), this.bed('white', 0.012, 'highpass', 5200)];
      if (s.extra === 'rain') this.loops.push(this.bed('white', 0.07, 'lowpass', 1400), this.bed('white', 0.03, 'bandpass', 5000, 0.8));
      this.timer = setInterval(() => this.tick(), 60);
      this.tick();
      this.playing = true;
      return true;
    },
    bed(buf, gain, type, f, q) {
      const c = this.ctx; const src = c.createBufferSource(); src.buffer = this[buf]; src.loop = true;
      src.playbackRate.value = 0.9 + Math.random() * 0.2;
      const fl = c.createBiquadFilter(); fl.type = type; fl.frequency.value = f; if (q) fl.Q.value = q;
      const g = c.createGain(); g.gain.value = gain;
      src.connect(fl); fl.connect(g); g.connect(this.bus); src.start(c.currentTime, Math.random() * 1.5);
      return src;
    },
    setVolume(v) {
      this.volume = v;
      if (this.ctx && this.playing) this.out.gain.setTargetAtTime(v * 0.7, this.ctx.currentTime, 0.08);
    },
    halt() {
      if (this.timer) clearInterval(this.timer);
      this.timer = null;
      (this.loops || []).forEach((l) => { try { l.stop(); } catch (e) { /* もう止まっている */ } });
      this.loops = [];
    },
    stop() {
      this.halt();
      this.playing = false;
      if (!this.ctx) return;
      const c = this.ctx; const now = c.currentTime;
      this.out.gain.cancelScheduledValues(now); this.out.gain.setValueAtTime(this.out.gain.value, now);
      this.out.gain.linearRampToValueAtTime(0, now + 0.35);
      clearTimeout(this.sus); this.sus = setTimeout(() => { if (!this.playing && c.state === 'running') c.suspend(); }, 450);
    },

    // ── 譜面 ──
    // 8 分音符で 1 小節 8 つ。16 小節でひとめぐり:
    //   0–1 鍵盤だけ / 2–7 太鼓とベースが入る / 8–13 旋律が入る / 14–15 ひと息(太鼓が抜けて、音がこもる)
    tick() {
      const c = this.ctx; const s = this.song;
      while (this.next < c.currentTime + 0.35) {
        const st = this.step % 8; const bar = this.bar % 16;
        const t = this.next + (this.rand() - 0.5) * 0.012; // 人の手の、わずかなずれ
        const [root, q] = s.prog[this.bar % s.prog.length];
        const pair = this.beat; const first = pair * s.swing; const len = st % 2 === 0 ? first : pair - first;
        const drums = bar >= 2 && bar < 14;
        const breath = bar >= 14;

        if (st === 0) {
          if (bar === 14) this.tone.frequency.setTargetAtTime(s.bright * 0.45, t, 0.6);
          if (bar === 0) this.tone.frequency.setTargetAtTime(s.bright, t, 1.2);
          this.chord(root, Q[q], t, pair * 3.6, breath ? 0.75 : 1);
          if (bar % 4 === 0) this.motif = this.makeMotif(root, q);
        }
        // 2 拍目の裏で、ときどき和音をそっと押し直す
        if (st === 5 && this.rand() < 0.4 && !breath) this.chord(root, Q[q].slice(1), t, pair * 1.4, 0.55);

        if (drums) {
          if (s.kick.includes(st) || (s.ghost.includes(st) && this.rand() < 0.35)) this.kick(t, st === 0 ? 1 : 0.7);
          if (s.snare.includes(st)) this.snare(t, 1);
          if (st === 7 && bar % 4 === 3) this.snare(t + len * 0.5, 0.35); // 小さなつなぎ
          const acc = st % 2 === 0 ? 1 : 0.6;
          if (this.rand() < 0.94) this.hat(t, acc * (0.75 + this.rand() * 0.35), st === 7 && this.rand() < 0.3);
          this.bass(root, st, t, len, bar);
        } else if (bar < 2 && st === 0 && bar === 1) {
          this.bassNote(root - 12, t, pair * 3, 0.6);
        }

        if (bar >= 8 && bar < 14 && this.motif) {
          const n = this.motif[(bar % 2) * 8 + st];
          if (n) this.lead(n.m, t, n.d * pair * 0.5, n.v);
        }
        if (s.extra === 'birds' && st === 3 && this.rand() < 0.05) this.bird(t);
        if (s.extra === 'kettle' && st === 0 && bar === 15) this.steam(t, pair * 4);

        this.next += len;
        this.step++;
        if (this.step % 8 === 0) this.bar++;
      }
    },
    makeMotif(root, q) {
      // 2 小節ぶんの短いふし。休みを多めに。最後は和音の音に落ち着く。
      const s = this.song; const r = this.rand;
      const pool = [];
      for (let m = 64; m <= 81; m++) if (s.scale.includes(m % 12)) pool.push(m);
      const tones = Q[q].map((i) => (root + i) % 12).concat([root % 12]);
      const rhythms = [[0, 3, 4], [1, 2, 6], [0, 2, 3, 6], [3, 4], [0, 5], [2, 3, 5]];
      const out = new Array(16).fill(null);
      let idx = Math.floor(pool.length / 2 + (r() - 0.5) * 4);
      for (let half = 0; half < 2; half++) {
        const rh = rhythms[Math.floor(r() * rhythms.length)];
        rh.forEach((st, k) => {
          idx = Math.max(0, Math.min(pool.length - 1, idx + Math.floor(r() * 5) - 2));
          let m = pool[idx];
          if (st % 2 === 0) { // 表拍は、なるべく和音の音へ
            for (let d = 0; d < 3; d++) { if (tones.includes(m % 12)) break; m = pool[Math.min(pool.length - 1, ++idx)]; }
          }
          const nextSt = rh[k + 1] ?? 8;
          out[half * 8 + st] = { m, d: Math.min(3, nextSt - st) + (half === 1 && k === rh.length - 1 ? 2 : 0), v: 0.7 + r() * 0.3 };
        });
      }
      return out;
    },

    // ── 音色 ──
    ep(m, t, dur, vel) {
      // Rhodes ふう:サインに、同じ高さのサインで揺さぶりをかける(FM)。叩いた瞬間だけ明るい。
      const c = this.ctx; const f = hz(m);
      const car = this.osc('sine', f, t); const mod = this.osc('sine', f, t); const tine = this.osc('sine', f * 7.02, t);
      const mg = c.createGain(); mg.gain.setValueAtTime(f * 1.6 * vel, t); mg.gain.exponentialRampToValueAtTime(f * 0.18, t + 0.5);
      const tg = c.createGain(); tg.gain.setValueAtTime(0.03 * vel, t); tg.gain.exponentialRampToValueAtTime(0.0001, t + 0.18);
      const g = c.createGain();
      g.gain.setValueAtTime(0.0001, t); g.gain.linearRampToValueAtTime(0.075 * vel, t + 0.006);
      g.gain.exponentialRampToValueAtTime(0.03 * vel, t + 0.6); g.gain.exponentialRampToValueAtTime(0.0001, t + dur + 1.2);
      mod.connect(mg); mg.connect(car.frequency);
      car.connect(g); tine.connect(tg); tg.connect(g); g.connect(this.keys);
      const end = t + dur + 1.3;
      [car, mod, tine].forEach((o) => { o.start(t); o.stop(end); });
    },
    chord(root, ivs, t, dur, vel) {
      const base = root < 52 ? root + 12 : root;
      ivs.forEach((iv, k) => this.ep(base + iv - (iv > 14 ? 12 : 0), t + k * 0.014 + this.rand() * 0.006, dur, vel * (0.8 + this.rand() * 0.25)));
    },
    bass(root, st, t, len, bar) {
      const r = root - 12 >= 40 ? root - 24 : root - 12; const p = this.beat;
      if (st === 0) this.bassNote(r, t, p * 1.4, 1);
      else if (st === 3 && this.rand() < 0.5) this.bassNote(r + 12, t, p * 0.4, 0.55);
      else if (st === 4) this.bassNote(r + (this.rand() < 0.5 ? 7 : 0), t, p * 1.1, 0.85);
      else if (st === 7) {
        // 次の和音へ、半音か全音で歩いて近づく
        const [nr] = this.song.prog[(bar + 1) % this.song.prog.length];
        const nb = nr - 12 >= 40 ? nr - 24 : nr - 12;
        if (this.rand() < 0.6) this.bassNote(nb + (nb > r ? -1 : 1) * (this.rand() < 0.5 ? 1 : 2), t, len * 0.9, 0.6);
      }
    },
    bassNote(m, t, dur, vel) {
      const c = this.ctx; const f = hz(m);
      const o = this.osc('sine', f, t); const o2 = this.osc('triangle', f, t);
      const lp = c.createBiquadFilter(); lp.type = 'lowpass'; lp.frequency.setValueAtTime(900, t); lp.frequency.exponentialRampToValueAtTime(260, t + 0.25);
      const g = c.createGain();
      g.gain.setValueAtTime(0.0001, t); g.gain.linearRampToValueAtTime(0.32 * vel, t + 0.015);
      g.gain.exponentialRampToValueAtTime(0.18 * vel, t + 0.2); g.gain.exponentialRampToValueAtTime(0.0001, t + dur + 0.15);
      const g2 = c.createGain(); g2.gain.value = 0.25;
      o.connect(g); o2.connect(g2); g2.connect(g); g.connect(lp); lp.connect(this.duck);
      [o, o2].forEach((x) => { x.start(t); x.stop(t + dur + 0.2); });
    },
    lead(m, t, dur, vel) {
      // 口笛と鉄琴のあいだのような、丸い音。少しだけ揺らす。
      const c = this.ctx; const f = hz(m);
      const o = this.osc('triangle', f, t); const o2 = this.osc('sine', f * 2, t);
      const vib = c.createOscillator(); vib.frequency.value = 5.2; const vg = c.createGain();
      vg.gain.setValueAtTime(0, t); vg.gain.linearRampToValueAtTime(9, t + 0.35);
      vib.connect(vg); vg.connect(o.detune);
      const lp = c.createBiquadFilter(); lp.type = 'lowpass'; lp.frequency.value = 2200;
      const g = c.createGain(); const g2 = c.createGain(); g2.gain.value = 0.18;
      g.gain.setValueAtTime(0.0001, t); g.gain.linearRampToValueAtTime(0.06 * vel, t + 0.03);
      g.gain.exponentialRampToValueAtTime(0.035 * vel, t + 0.3); g.gain.exponentialRampToValueAtTime(0.0001, t + dur + 0.5);
      o.connect(lp); o2.connect(g2); g2.connect(lp); lp.connect(g); g.connect(this.duck);
      const send = c.createGain(); send.gain.value = 0.9; g.connect(send); send.connect(this.verbIn);
      [o, o2, vib].forEach((x) => { x.start(t); x.stop(t + dur + 0.6); });
    },
    kick(t, vel) {
      const c = this.ctx;
      const o = c.createOscillator(); o.frequency.setValueAtTime(130, t); o.frequency.exponentialRampToValueAtTime(46, t + 0.12);
      const g = c.createGain(); g.gain.setValueAtTime(0.0001, t); g.gain.linearRampToValueAtTime(0.55 * vel, t + 0.004); g.gain.exponentialRampToValueAtTime(0.0001, t + 0.38);
      const lp = c.createBiquadFilter(); lp.type = 'lowpass'; lp.frequency.value = 600;
      o.connect(g); g.connect(lp); lp.connect(this.bus); o.start(t); o.stop(t + 0.4);
      // 鍵盤とベースが、ふっと身を引く
      this.duck.gain.cancelScheduledValues(t); this.duck.gain.setValueAtTime(0.72, t); this.duck.gain.setTargetAtTime(1, t + 0.02, 0.12);
    },
    noise(t, dur, type, f, q, gain, dest, decay) {
      const c = this.ctx; const src = c.createBufferSource(); src.buffer = this.white;
      const fl = c.createBiquadFilter(); fl.type = type; fl.frequency.value = f; fl.Q.value = q;
      const g = c.createGain(); g.gain.setValueAtTime(0.0001, t); g.gain.linearRampToValueAtTime(gain, t + 0.003); g.gain.exponentialRampToValueAtTime(0.0001, t + (decay || dur));
      src.connect(fl); fl.connect(g); g.connect(dest || this.bus);
      src.start(t, Math.random() * 1.5); src.stop(t + dur + 0.05);
      return g;
    },
    snare(t, vel) {
      // ブラシで撫でたような、ざらっとした面と、ほんの少しの胴鳴り
      const g = this.noise(t, 0.28, 'bandpass', 1900, 0.7, 0.18 * vel, this.bus, 0.24);
      const send = this.ctx.createGain(); send.gain.value = 0.6; g.connect(send); send.connect(this.verbIn);
      const c = this.ctx; const o = c.createOscillator(); o.frequency.setValueAtTime(210, t); o.frequency.exponentialRampToValueAtTime(150, t + 0.08);
      const og = c.createGain(); og.gain.setValueAtTime(0.07 * vel, t); og.gain.exponentialRampToValueAtTime(0.0001, t + 0.1);
      o.connect(og); og.connect(this.bus); o.start(t); o.stop(t + 0.12);
    },
    hat(t, vel, open) {
      this.noise(t, open ? 0.3 : 0.06, 'highpass', 7400, 0.5, 0.05 * vel, this.bus, open ? 0.26 : 0.045);
    },
    bird(t) {
      const c = this.ctx;
      for (let k = 0; k < 2 + Math.floor(this.rand() * 2); k++) {
        const s = t + k * 0.13; const o = c.createOscillator(); const base = 2600 + this.rand() * 900;
        o.frequency.setValueAtTime(base, s); o.frequency.exponentialRampToValueAtTime(base * 1.35, s + 0.06);
        const g = c.createGain(); g.gain.setValueAtTime(0.0001, s); g.gain.linearRampToValueAtTime(0.012, s + 0.01); g.gain.exponentialRampToValueAtTime(0.0001, s + 0.09);
        o.connect(g); g.connect(this.verbIn); g.connect(this.bus); o.start(s); o.stop(s + 0.1);
      }
    },
    steam(t, dur) {
      const c = this.ctx; const src = c.createBufferSource(); src.buffer = this.white; src.loop = true;
      const fl = c.createBiquadFilter(); fl.type = 'bandpass'; fl.Q.value = 1.2; fl.frequency.setValueAtTime(1800, t); fl.frequency.linearRampToValueAtTime(3200, t + dur);
      const g = c.createGain(); g.gain.setValueAtTime(0.0001, t); g.gain.linearRampToValueAtTime(0.02, t + dur * 0.6); g.gain.linearRampToValueAtTime(0.0001, t + dur);
      src.connect(fl); fl.connect(g); g.connect(this.bus); src.start(t); src.stop(t + dur + 0.05);
    },
  };

  window.Lofi = L;
})();
