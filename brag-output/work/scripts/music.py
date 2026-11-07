# ClingCling の動画の音。120 BPM・ニ長調。効果音も同じ拍・同じ調で書き、一つの曲として混ぜる。
import sys, wave
import numpy as np

SR = 48000
BPM = 120
BEAT = 60 / BPM
DUR = 21.0
N = int(SR * DUR)
rng = np.random.default_rng(7)

def buf(): return np.zeros(N)
def at(t): return int(round(t * SR))
def midi(m): return 440 * 2 ** ((m - 69) / 12)

def add(track, start, sig, gain=1.0):
    i = at(start)
    if i >= N: return
    j = min(N, i + len(sig))
    track[i:j] += sig[: j - i] * gain

def env(n, a=0.005, d=0.3, sustain=0.0, rel=None):
    t = np.arange(n) / SR
    e = np.minimum(1, t / max(a, 1e-4)) * (sustain + (1 - sustain) * np.exp(-t / d))
    if rel:
        e *= np.clip((n / SR - t) / rel, 0, 1)
    return e

def lowpass(x, cutoff):
    # 1 次のローパスを 2 回
    a = np.exp(-2 * np.pi * cutoff / SR)
    for _ in range(2):
        y = np.empty_like(x); s = 0.0
        for k in range(len(x)):
            s = (1 - a) * x[k] + a * s; y[k] = s
        x = y
    return x

def highpass(x, cutoff): return x - lowpass(x, cutoff)

# ── 和音（1 小節 = 2 秒）
D, Bm, G, A, Em = [50, 54, 57], [47, 50, 54], [43, 47, 50], [45, 49, 52], [40, 43, 47]
bars = [D, Bm, G, A, D, Bm, G, A, Em, A]  # 0–20 秒
def chord_at(t):
    if t >= 18.5: return D
    return bars[min(int(t // 2), len(bars) - 1)]

drums, bass, keys, lead, sfx = buf(), buf(), buf(), buf(), buf()

# ── ドラム
def kick():
    n = at(0.32); t = np.arange(n) / SR
    f = 48 + 110 * np.exp(-t / 0.035)
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / 0.11)
def clap():
    n = at(0.22); x = rng.standard_normal(n)
    x = highpass(lowpass(x, 3200), 900)
    t = np.arange(n) / SR
    e = np.exp(-t / 0.06) * (1 + 0.6 * ((t > 0.012) & (t < 0.024)))
    return x * e
HAT_NOISE = highpass(rng.standard_normal(at(0.06)), 7000)
def hat(open_=False):
    n = at(0.18 if open_ else 0.05)
    return HAT_NOISE[:n] if not open_ else np.resize(HAT_NOISE, n) * 1.0 * np.exp(-np.arange(n) / SR / 0.06) / np.exp(0)

K, C = kick(), clap()
for b in range(int(DUR / BEAT)):
    t = b * BEAT
    if t >= 20.0: break
    hook = t < 2.5
    if not hook or b in (1, 2, 4):  # フックでは見出しの入りだけを叩く
        add(drums, t, K, 0.9)
    if not hook and b % 2 == 1 and not (16 <= t < 18.5 and b % 4 == 1):
        add(drums, t, C, 0.32)
    if not hook:
        add(drums, t + BEAT / 2, hat(), 0.13)
        add(drums, t, hat(), 0.07)
# 締めの一打
add(drums, 18.5, K, 1.0)

# ── ベース（8 分で根音、プライバシーの場面は 4 分で落ち着かせる）
def bass_note(m, length):
    n = at(length); t = np.arange(n) / SR
    f = midi(m)
    x = np.sin(2 * np.pi * f * t) + 0.35 * np.sin(2 * np.pi * 2 * f * t) + 0.12 * np.sin(2 * np.pi * 3 * f * t)
    return x * env(n, 0.004, 0.18, 0.35, 0.03)
t = 2.5
while t < 20.0:
    root = chord_at(t)[0] - 12
    step = BEAT if 16 <= t < 18.5 else BEAT / 2
    octave = 12 if (int(round(t / (BEAT / 2))) % 4 == 3) else 0
    add(bass, t, bass_note(root + octave, step * 0.9), 0.32)
    t += step
add(bass, 18.5, bass_note(38, 2.0), 0.36)

# ── エレピ風のコード（小節の頭と 3 拍目の裏）
def ep(ms, length):
    n = at(length); t = np.arange(n) / SR
    x = np.zeros(n)
    for m in ms:
        f = midi(m + 12)
        x += np.sin(2 * np.pi * f * t + 0.8 * np.sin(2 * np.pi * f * 2 * t) * np.exp(-t / 0.4))
    return x / len(ms) * env(n, 0.01, 0.6, 0.15, 0.08)
for b in range(int(20 / BEAT)):
    t = b * BEAT
    if b % 4 in (0, 2) or (b % 4 == 3 and t >= 2.5):
        add(keys, t + (BEAT / 2 if b % 4 == 3 else 0), ep(chord_at(t), BEAT * 1.6), 0.16 if t >= 2.5 else 0.2)
add(keys, 18.5, ep(D + [62], 2.5), 0.26)

# ── プラックのメロディ（D メジャー・ペンタ）
def pluck(m, length=0.35):
    n = at(length); t = np.arange(n) / SR
    f = midi(m)
    x = np.sin(2 * np.pi * f * t) + 0.3 * np.sin(2 * np.pi * 2 * f * t) + 0.1 * np.sin(2 * np.pi * 3 * f * t)
    return x * env(n, 0.002, 0.09, 0.0, 0.02)
# 1 小節 8 つの 8 分。None は休み
motif_a = [74, None, 78, 81, None, 78, 76, None]
motif_b = [74, None, 76, 78, None, 81, 83, 81]
for bar in range(1, 10):
    t0 = bar * 2.0
    if t0 < 2.5 and bar == 1:
        pass
    motif = motif_a if bar % 2 else motif_b
    if 8 <= bar <= 8:  # プライバシーの場面は間引く
        motif = [74, None, None, None, 78, None, None, None]
    shift = {0: 0, 1: -3, 2: -7, 3: -5, 4: 0, 5: -3, 6: -7, 7: -5, 8: -2, 9: -5}[bar] if False else 0
    for i, m in enumerate(motif):
        tt = t0 + i * BEAT / 2
        if m is None or tt >= 18.5: continue
        # 和音に合わない音は一つ下の和音構成音へ
        ch = [c % 12 for c in chord_at(tt)] + [2 if chord_at(tt) in (D, Bm, G) else 9]
        mm = m
        while mm % 12 not in ch: mm -= 1
        add(lead, tt, pluck(mm), 0.12)
# フック: 見出しが入る拍にだけ
for tt, m in [(0.5, 74), (1.0, 78), (1.5, 81), (2.0, 78)]:
    add(lead, tt, pluck(m, 0.5), 0.14)
# 締めのアルペジオ
for i, m in enumerate([74, 78, 81, 86]):
    add(lead, 18.5 + i * BEAT / 2, pluck(m, 0.8), 0.13)

# ── 効果音（同じ調・同じ拍）
def click():
    n = at(0.04); t = np.arange(n) / SR
    x = highpass(rng.standard_normal(n), 2500) * np.exp(-t / 0.006)
    x += 0.5 * np.sin(2 * np.pi * midi(93) * t) * np.exp(-t / 0.012)  # A6
    return x
def pop(m=86):
    n = at(0.18); t = np.arange(n) / SR
    f = midi(m) * (1 + 0.5 * np.exp(-t / 0.02))
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * env(n, 0.002, 0.05)
def whoosh(length=0.4, rise=True):
    n = at(length); x = rng.standard_normal(n)
    x = lowpass(highpass(x, 800), 4000)
    t = np.arange(n) / SR
    e = (t / length) ** 2 if rise else np.exp(-t / 0.1)
    return x * e
def drop(m=81):
    n = at(0.35); t = np.arange(n) / SR
    f = midi(m) * np.exp(-t / 0.25)
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * env(n, 0.003, 0.12)

for t in [0.25, 3.25, 7.5, 10.25, 11.75]:
    add(sfx, t, click(), 0.35)
for t, m in [(3.5, 86), (5.75, 86), (9.0, 86), (10.5, 90), (12.5, 86)]:
    add(sfx, t, pop(m), 0.22)
add(sfx, 7.75, pop(90), 0.18)          # ブラウザが開く
add(sfx, 15.0, drop(81), 0.2)          # API キーが消える
for t in [2.5, 5.5, 16.0, 18.5]:
    w = whoosh(0.4)
    add(sfx, t - 0.4, w, 0.05)

# ── ミックス
mix = drums * 0.9 + bass * 1.0 + keys * 1.0 + lead * 1.0 + sfx * 1.0
# 冒頭はわずかに絞り、最後は 20.2 秒からフェード
tt = np.arange(N) / SR
mix *= np.clip((DUR - tt) / 0.8, 0, 1)
mix = np.tanh(mix * 1.2) / np.tanh(1.2)
mix /= np.max(np.abs(mix)) / 0.89
stereo = np.stack([mix, mix], axis=1)
out = sys.argv[1]
with wave.open(out, "wb") as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
    w.writeframes((stereo * 32767).astype(np.int16).tobytes())
print("wrote", out)
