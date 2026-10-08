# Wall Display

An e-ink wall display that looks printed, not digital. A Mac mini renders a web page to an image every
15 minutes. A reMarkable 2 hanging on the wall downloads that image and draws it.

```
Mac mini (always on)                         reMarkable 2 (on the wall)
┌───────────────────────────────┐   HTTP    ┌──────────────────────────────┐
│ server/dashboard.html         │  :8765    │ device/wall-display.sh       │
│   → Playwright screenshot     │ ───────▶  │   wget dashboard.png         │
│   → 16 grays, rotate 90°      │           │   → FBInk → rm2fb → e-ink    │
│ out/dashboard.png             │           │                              │
└───────────────────────────────┘           └──────────────────────────────┘
```

The native pen app that runs on the tablet lives in its own repo, [wall-ink](https://github.com/AustinKeeton/wall-ink).

Roadmap: **v0** reMarkable 2 (now) → **v1** 13.3" Spectra 6 color panel → **v2** large statement piece.
The server stays the same across versions; only the device end changes.

## Layout

| Path | What it is |
|---|---|
| `config.json` | Size, rotation, refresh interval, location, units, bottom note |
| `server/dashboard.html` | The design. Portrait and landscape layouts (CSS `orientation` media query) |
| `server/serve.py` | Renders the page to `out/dashboard.png` on a timer and serves `out/` over HTTP |
| `deploy/com.audie.wall-display.plist` | LaunchAgent that keeps the server running on the Mac mini |
| `device/wall-display.sh` | Tablet side: fetch the image, redraw only if it changed, full refresh hourly |
| `device/sleeptest.sh` | Tablet side: one sleep → RTC wake → Wi-Fi → redraw cycle, logged |
| `tools/` | MacBook only, not in git: codexctl, rm2fb/FBInk packages and firmware images used for the tablet setup |

## Config

```json
"width": 1872, "height": 1404, "rotate": 90
```

The page is rendered at `width`×`height`, then rotated counter-clockwise by `rotate` into the panel's
native 1404×1872 portrait framing. `1872×1404` with `rotate: 90` is landscape with the tablet's **wide
bezel (spine) at the top**. For portrait use `1404×1872` with `rotate: 0`.

`location` is neighborhood-level coordinates only, which is all Open-Meteo needs.

## Server (Mac mini)

- Host: **Audie's M1 Mac mini**, `mini.local` / `10.0.0.97`, user `audie`. From the MacBook: `ssh mini`
  (key `~/.ssh/mini`).
- Project at `~/wall-display` on the mini. Python deps via `uv` (Homebrew). Chromium via
  `uv run playwright install chromium`.
- Runs as a LaunchAgent in the **Background** session (`LimitLoadToSessionType`), so it starts at login,
  restarts on crash, and can be managed over SSH. The mini auto-logs in as `audie`, never sleeps,
  and restarts after a power failure, so the server comes back by itself.
- Serves `http://10.0.0.97:8765/dashboard.png`. Log: `~/wall-display/out/server.log`.

```sh
# on the mini
launchctl print user/$(id -u)/com.audie.wall-display | grep -E 'state|pid'   # status
launchctl kickstart -k user/$(id -u)/com.audie.wall-display                  # restart
launchctl bootout user/$(id -u)/com.audie.wall-display                       # stop
launchctl bootstrap user/$(id -u) ~/Library/LaunchAgents/com.audie.wall-display.plist  # start
tail -f ~/wall-display/out/server.log
```

Deploy changes from the MacBook (preview locally first with `uv run server/serve.py --once`):

```sh
rsync -a --exclude .venv --exclude out --exclude tools --exclude __pycache__ ~/wall-display/ mini:wall-display/
ssh mini 'launchctl kickstart -k user/$(id -u)/com.audie.wall-display'
```

## Tablet (reMarkable 2)

- `ssh remarkable` → `root@10.0.0.40` over Wi-Fi (key `~/.ssh/remarkable`). Over USB it's always
  `root@10.11.99.1`. The Wi-Fi address can change; give it a DHCP reservation in the router.
- Firmware **3.22.4.2**. The original 3.16.2.3 is still on the other partition.
- Backup taken before any changes: `~/remarkable-backup-2026-10-08/rm2-home-etc.tar.gz` on the MacBook.

### What was changed on the tablet

| Change | How to undo |
|---|---|
| Firmware 3.16.2.3 → 3.22.4.2 | `codexctl restore` should swap back to the other partition (untested; codexctl's install was buggy on this tablet, so check first) |
| Auto-updates off: `swupdate.service`/`.socket` masked, `update-engine.service` disabled | `systemctl unmask swupdate.service swupdate.socket && systemctl enable --now update-engine` |
| `/opt` → `/home/root/opt` symlink (replaced a bind-mount unit that made a boot ordering cycle with `/home` on 3.22) | `rm /opt` |
| `rm2fb.service.d/conflicts.conf`: rm2fb `Conflicts=xochitl` (xochitl crashes and its handler reboots the tablet if it starts while rm2fb holds the screen) | delete the drop-in |
| `wall-ink.service` (from the wall-ink repo; not enabled) | delete it |
| rm2fb server: `/opt/bin/rm2fb_server`, `/opt/lib/librm2fb_*`, units `rm2fb.service`/`.socket` in `/etc/systemd/system` (**not enabled**) | delete them |
| FBInk 1.25.0: `/opt/bin/fbink` (Toltec `fbink_1.25.0-2_rmall.ipk`) | delete it |
| SSH over Wi-Fi turned back on (3.22 turns it off) | `rm-ssh-over-wlan off` |

Everything outside `/home` lives on the root partition and gets wiped by a firmware update.

### Switching between wall display and normal tablet

Nothing starts automatically yet, so a reboot always brings the normal reMarkable back.

```sh
# show the dashboard
systemctl stop xochitl && systemctl start rm2fb.service
LD_PRELOAD=/opt/lib/librm2fb_client.so /opt/bin/fbink -c -f -g file=/path/to/image.png

# give the tablet back
systemctl stop rm2fb.service && systemctl start xochitl
```

Only one of `xochitl` and `rm2fb` can drive the screen at a time; the conflict drop-in makes systemd
stop one before starting the other. For the pen app, `systemctl start wall-ink` / `stop wall-ink` does
the whole swap.

### Sleep and wake (battery)

Tested on 2026-10-08 with `device/sleeptest.sh`:

- The RTC alarm wakes the tablet from deep sleep: `echo +900 > /sys/class/rtc/rtc0/wakealarm`.
- **Always suspend with `systemctl suspend`.** It runs `/lib/systemd/system-sleep/sleep-wifi.sh`, which
  shuts the Wi-Fi chip down before sleep and brings it back after. Writing `mem` to
  `/sys/power/state` directly skips the hook, and the Wi-Fi chip (brcmfmac over SDIO) crashes on resume.
- After waking: Wi-Fi is back in about 9 s, and the whole fetch-and-redraw cycle keeps it awake about 15 s.
- The tablet draws about 250–300 mA while awake. Sleep current hasn't been measured yet; an unplugged
  overnight run will show real battery life.

## Gotchas found during setup

- **It's a reMarkable 2, not a 1.** The rM2 has no normal framebuffer; rm2fb (timower/rM2-stuff v0.1.4)
  provides one and needs an exact firmware build. It supports 3.20, 3.22.4, 3.23.0.54 and 3.23.0.64,
  not 3.16.
- **codexctl's install failed on 3.16**: its SSH session's `PATH` is only `/usr/bin:/bin`, so the
  installer couldn't find `/usr/sbin/rootdev` or `/sbin/fw_setenv`. What worked:
  `PATH=/usr/sbin:/sbin:/usr/bin:/bin swupdate-from-image-file /tmp/<image>.swu`.
- **`reboot &` over SSH gets killed** when the session closes. Use `systemctl reboot`.
- **The SSH host key changes after a firmware update.** Expected: `ssh-keygen -R <ip>` and reconnect.
- **`!` commands in Claude Code can't prompt for passwords.** Run `ssh-copy-id` in a real Terminal.
- **CSS order matters in `dashboard.html`.** The landscape `@media` block must stay *after* the base
  rules, or the base rules win.

## Status and next steps

- [x] Render server on the Mac mini, landscape layout, Jacksonville weather
- [x] Tablet on 3.22.4.2 with rm2fb and FBInk; test draw works
- [x] Sleep → RTC wake → Wi-Fi → redraw cycle works
- [ ] Wall mount (none yet)
- [ ] Step 3: run `wall-display.sh` on a sleep/wake loop as a service, stop `xochitl` for good
- [ ] Measure battery life unplugged overnight; choose the refresh interval
- [ ] Later: use the pen on the display
- [ ] v1: Waveshare 13.3" Spectra 6 build (render a 6-color palette instead of 16 grays)
