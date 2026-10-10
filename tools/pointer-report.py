#!/usr/bin/env python3
"""Pointer smoothness report from both logs, written while diagnostics are on.

Usage: tools/pointer-report.py <mac log> <windows log> <since, e.g. 2026-10-03T10:59>
Copy the Windows log first: scp user@your-pc:AppData/Local/Unictrl/unictrl.log win.log
Switch diagnostics on: Mac debug notification "diagnostics-on"; Windows "Diagnostics": true in
settings.json, then restart Unictrl there.
"""
import re, sys, statistics as st
from collections import Counter
mac, win, since = sys.argv[1], sys.argv[2], sys.argv[3]

def kv(line):
    return dict(re.findall(r'(\w+)=([-\d.,]+)', line))

def pct(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(len(xs) * p))] if xs else 0

remote = []   # (ts, dict) for moving remote seconds
local = []
main_stalls = []
pc_stats = []
crossings = 0
for line in open(mac, errors='replace'):
    ts = line[:23]
    if ts < since: continue
    if ' mac_mouse ' in line:
        d = kv(line)
        # tap_delay keys collide with device_gap; parse the groups explicitly
        g = {}
        for grp in ('device_gap_ms', 'tap_gap_ms', 'tap_delay_ms'):
            m = re.search(grp + r' p50=([\d.]+) p90=([\d.]+) p99=([\d.]+) max=([\d.]+)', line)
            if m: g[grp] = list(map(float, m.groups()))
        d.update(g)
        if int(d.get('n', 0)) < 30: continue
        (remote if 'mode=remote' in line else local).append((ts, d))
    elif ' main_stall ' in line:
        main_stalls.append((ts, float(kv(line)['ms'])))
    elif ' pc_stats ' in line:
        pc_stats.append((ts, kv(line)))
    elif ' enter_remote ' in line:
        crossings += 1

spikes = []
inj = []
for line in open(win, errors='replace'):
    ts = line[:23]
    if ts < since: continue
    if ' delay_spike ' in line:
        d = kv(line); spikes.append((ts, float(d['late_ms']), float(d['waited_ms']), float(d['prev_process_ms'])))
    elif ' injected_mouse ' in line:
        m = re.search(r'packets=(\d+).*p99=([\d.]+) max=([\d.]+)', line)
        if m and int(m.group(1)) >= 30: inj.append((ts, float(m.group(2)), float(m.group(3))))

print(f'Since {since}: {crossings} crossings to the PC')
print(f'\n== Mac, pointer on the PC: {len(remote)} moving seconds (local: {len(local)})')
for name, rows in (('remote', remote), ('local', local)):
    if not rows: continue
    stalls = sum(int(d.get('stalls', 0)) for _, d in rows)
    late = sum(int(d.get('late', 0)) for _, d in rows)
    sec_stall = sum(1 for _, d in rows if int(d.get('stalls', 0)) > 0)
    td99 = [d['tap_delay_ms'][2] for _, d in rows if 'tap_delay_ms' in d]
    td90 = [d['tap_delay_ms'][1] for _, d in rows if 'tap_delay_ms' in d]
    tdmax = [d['tap_delay_ms'][3] for _, d in rows if 'tap_delay_ms' in d]
    print(f'  {name}: radio stalls {stalls} (in {sec_stall} s, {100*sec_stall/len(rows):.1f} %), late-at-tap {late}; '
          f'tap delay p90 median {st.median(td90):.1f} ms, p99 median {st.median(td99):.1f} ms, '
          f'seconds with a tap delay >= 16 ms: {sum(1 for x in tdmax if x >= 16)}, worst {max(tdmax):.1f} ms')
    if name == 'remote':
        rf = [int(d.get('refreezes', 0)) / int(d['n']) for _, d in rows]
        print(f'  put-backs per mouse event: median {st.median(rf):.2f}')
print(f'\n== Mac main thread blocked >= 40 ms while on the PC: {len(main_stalls)}'
      + (f', median {st.median([m for _, m in main_stalls]):.0f} ms, max {max(m for _, m in main_stalls):.0f} ms' if main_stalls else ''))
print('   (main thread does not carry moves since the tap thread; listed for correlation)')

print(f'\n== PC: {len(inj)} moving seconds; seconds with an injection gap p99 > 40 ms: {sum(1 for _, p, _ in inj if p > 40)} '
      f'({100*sum(1 for _, p, _ in inj if p > 40)/max(1,len(inj)):.1f} %)')
print(f'== PC delay spikes (move arrived >= 20 ms late): {len(spikes)}')
if spikes:
    lates = [s[1] for s in spikes]
    print(f'   late ms: median {st.median(lates):.0f}, p90 {pct(lates,.9):.0f}, max {max(lates):.0f}')
    net = sum(1 for s in spikes if s[2] >= 0.8 * s[1])      # receive thread was idle: data came late
    burst = sum(1 for s in spikes if s[2] < 5 and s[3] < 5)  # arrived bunched right behind another
    busy = sum(1 for s in spikes if s[3] >= 8)               # previous message held the thread
    print(f'   receive thread idle the whole time (late delivery): {net}; arrived in a bunch: {burst}; PC busy with the previous message: {busy}')
    big = [s for s in spikes if s[1] >= 50]
    print(f'   >= 50 ms: {len(big)}')
    # do spikes line up with Mac main-thread stalls?
    def secs(ts): h, m, s = ts[11:23].split(':'); return int(h)*3600 + int(m)*60 + float(s)
    ms_t = [secs(t) for t, _ in main_stalls]
    near = sum(1 for s in big if any(abs(secs(s[0]) - t) < 1.5 for t in ms_t))
    print(f'   of those, within 1.5 s of a Mac main-thread stall: {near}')
    print('   by hour:', dict(sorted(Counter(s[0][11:13] for s in spikes).items())))
hitch = sum(int(d.get('hitches', 0)) for _, d in pc_stats); slow = sum(int(d.get('slow', 0)) for _, d in pc_stats)
print(f'\n== pc_stats lines with something to report: {len(pc_stats)}; hitches {hitch}, slow injections {slow}')
