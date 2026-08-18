# Setup

Full build walkthrough. Read the top-level README first for what this is
and what it deliberately isn't.

LAN-only Nightscout on a Pi or small PC, driving a TV, fed from Libre 2 Plus via
LibreLinkUp. Nothing is exposed to the internet. The only traffic leaving the
house is the outbound poll to Abbott's API, and the nightly encrypted backup.

**This is a logging and visualisation system, not an alarm.** Her Libre app
stays the safety layer. Nightscout's own alarms are disabled in the compose
file deliberately — two alarm sources that can disagree is worse than one that
works.

---

Runs on a Pi 5 or any amd64 box. See **Platform notes** below — there's one
CPU check that'll stop the stack dead if you skip it.

## Order of operations

Do these in order. Steps 1 and 2 have to happen before the bridge will work at
all, and they're the bit people get wrong.

### 0. Preflight

```bash
./preflight.sh
```

Checks AVX / ARM microarchitecture, docker, storage, display and compositor, and
tells you what to put in `MONGO_TAG`. Thirty seconds, saves an evening.

### 1. LibreView accounts and region

You need **two** accounts:

- **Primary** — owns the sensor, runs the yellow `FreeStyle LibreLink` app on
  whichever phone starts each sensor. This one carries the alarms.
- **Secondary** — used only by this bridge. Create it at libreview.com.

Then link them: in LibreLink on the primary phone, **menu → Connected apps →
LibreLinkUp → Manage → Add connection**, invite the secondary account, and
accept the invitation in the orange `LibreLinkUp` app signed in as the
secondary.

Put the **secondary** credentials in `.env`. Never the primary.

**Region:** UK accounts sit on either `EU` or `EU2`. Start with `EU`; if the
log says "Logged in to the wrong region. Switch to 'EU2'", set
`LINK_UP_REGION=EU2` in `.env` and recreate the container.

### 2. Which phone starts the sensor

Libre alarms only fire on the device that started the sensor. In a two-carer
house, decide this deliberately and stick to it, otherwise you'll both assume
the other phone is covering the night.

The other carer should be a LibreLinkUp follower — they get alerts too, just
slightly behind. Nursery staff go on as followers as well, rather than being
given anything of yours.

Also: if a sensor is ever started with a Libre **reader** instead of the phone
app, you lose real-time readings entirely and drop back to scanning. Always
start with the app.

### 2b. Updating later

Unzip to a scratch directory, never over the top of a working install:

```bash
unzip -q t1-display.zip -d ~/update
cp ~/update/t1-display/display/index.html ~/t1-display/display/
cp ~/update/t1-display/docker-compose.yml ~/t1-display/
```

`.env` is not in the zip, so it can't be clobbered. But check
`docker-compose.yml` afterwards for anything you'd hardcoded - `.env` is the
only safe place for local settings.

### 3. Bring the stack up

```bash
cp env.example .env
chmod 600 .env
$EDITOR .env          # API_SECRET and BASE_URL at minimum
docker compose up -d
```

Watch it come up: `docker compose logs -f`

### 4. Create the bridge token

Two non-obvious steps here. Both produce the same unhelpful HTTP 401.

**a. Create a role for entry uploads.** No built-in Nightscout role grants
`api:entries:create`, so glucose uploads fail without one.

Admin Tools -> **Roles** section -> **Add new Role**
- Name: `entries-upload`
- Permissions: `api:entries:create`

(The Roles section is below Subjects and looks similar - it's easy to add a
Subject by mistake. If a blank row appears in the roles table, the form
submitted before the fields registered; delete it and retry.)

**b. Create the subject.**

Admin Tools -> **Add new Subject**
- Name: `librelink`
- Roles: `careportal devicestatus-upload entries-upload`

Copy the access token, e.g. `librelink-YOURTOKENHERE`.

**c. Hash it.** `NS_API_TOKEN` wants the SHA1 hash, not the token. The name
is misleading - the bridge sends it as a pre-hashed API secret.

```bash
echo -n "librelink-YOURTOKENHERE" | sha1sum | cut -d' ' -f1
```

Mind the `-n`; a trailing newline changes the hash. Put the 40-char hex
string in `.env`, then:

```bash
docker compose up -d --force-recreate librelink
docker compose logs -f librelink
```

`--force-recreate`, not `restart` - a plain restart reuses the old
environment and won't pick up `.env` changes.

Want "Upload of N measurements to Nightscout succeeded". Then pull the
backlog in once:

```bash
docker compose run --rm -e ALL_DATA=true librelink
```

**Verifying a 401.** Check what Nightscout thinks the token can do:

```bash
curl -s "http://localhost:1337/api/v2/authorization/request/<TOKEN>" \
  | python3 -m json.tool
```

`api:entries:create` must appear. If it does and the bridge still 401s, the
hash is the problem, not the role.

Note the auth collections are `auth_subjects` and `auth_roles`, not
`subjects` and `roles`, if you ever need to fix this in mongosh. Nightscout
caches authorization at startup, so recreate it after direct edits.

### 5. Kiosk

```bash
./install-kiosk.sh
sudo reboot
```

### 6. Timers

Edit `systemd-units.txt` for your username and paths, split it into the
individual files, then install them (instructions at the top of that file).

Test the backup by hand first, and **test a restore** — the procedure is in
the comments at the bottom of `ns-backup.sh`.

---

## The display

The kiosk points at the custom display page on port 8080, not at Nightscout
directly. Left panel is the last 24 hours with bolus and carb markers along
the foot; right panel is the across-the-room read, with the last bolus
beneath it.

Design rules it follows, which matter more than they look:

- **Colour is a claim about right now.** If the reading is older than 15
  minutes the panel drains to grey and the age appears in a black badge.
  A stale reading never sits there looking green.
- **Every value carries its age**, set at the same weight as its label.
- **Threshold lines at 3.9 and 14.0** are red and dashed, deliberately unlike
  the grey gridlines - they read as limits rather than scale furniture, so the
  eye catches the trace crossing one. They match the colour bands on the
  current-level panel. Edit `ALERT_LINES` to change them.
- **The y-axis grows, it never clips.** `Y_MAX` is the minimum top of the
  scale, not a ceiling on the data. A fixed ceiling draws a flat line across
  the top of the chart whenever readings go above it, which understates how
  high she actually went - the wrong direction for a scale to be wrong in.
  The upper gridline label follows the stretch, so it reads 21 on a day that
  peaked at 21.
- **Gaps are bridged, but visibly.** LibreLinkUp returns recent data at ~1
  min intervals and history at ~15 min, so a threshold below that turns the
  older trace into a field of unconnected dots. Above 18 minutes the line
  becomes a faded dashed connector rather than solid - continuous enough to
  read, honest enough that a real outage never passes as data.
- **24 hours, thinned for drawing.** A day at one reading a minute is ~1440
  points across roughly 900px of plot, so the trace is sampled down to 720
  before drawing - more points than pixels gains nothing and bloats the SVG.
  The newest reading is always kept. Hour ticks space themselves by window
  size (3-hourly at 24h) and anchor to clock hours, with midnight drawn
  heavier for orientation.
- **The window is captioned with its actual span**, e.g. "LAST 24 HOURS -
  18:14 SAT -> 18:13 SUN". Hour ticks anchor to clock hours, so the first
  label can sit up to 3 hours after the plot begins and the window is
  impossible to work out by counting labels - eight 3-hourly labels look
  like 21 hours even when the trace covers a full day. The caption removes
  that guesswork. If there isn't a full day in the database yet it says so:
  "LAST 24 HOURS - 5.0H OF DATA - 13:13 SUN -> 18:13 SUN".
- **History is fetched by date, not just count.** Relying on `count` alone
  means a deployment that caps it silently gives you a short graph.
- **History and current reading poll separately.** The latest value every 30
  seconds, the full day every 3 minutes. Re-fetching 1400 records twice a
  minute to redraw a line that barely moved is wasted work on a box that
  runs continuously.
- **"None logged" is never "0".** A zero would be a claim about her; "None
  logged in 12 hours" is a claim about the logbook, which is all this page
  can honestly make. Same reason it says "no carbs logged" rather than
  "no carbs".
- **Calculated doses are labelled, not shown as delivered.** On MDI there is
  no pump reporting back, so mylife logs a bolus *calculation*
  (`type: suggested_no_delivery`, `insulinDelivered: 0`) with the advised
  figure in `totalInsulinRecommendation`. The panel shows that number but
  relabels itself "APP CALCULATED" and tags the value "SUGGESTED", because
  what the app advised and what went into her are different facts and must
  never be read as one. A dose logged via Care Portal shows as "LAST BOLUS"
  with no tag.
- **The treatment panel adapts to what the data can actually prove.**
  On pens, the mylife app is a bolus *calculator*: it records the carb entry
  and its own dose suggestion, but nothing links it to what was injected, so
  Glooko always reports `insulin: 0`. The panel therefore shows
  "LAST CARBS - 28g - insulin given by pen, not recorded" rather than a bolus
  figure of zero, which would read as "no insulin given".
  If a delivered dose ever does appear (a pump, or logged by hand in the Care
  Portal), it switches to "LAST BOLUS - 2.5u with 35g" automatically.
- **The dose suggestion is shown, and labelled as one.** Glooko puts the
  mylife bolus-calculator output in the treatment `notes` as JSON; the panel
  reads `totalInsulinRecommendation` from it and renders
  "app suggested 0.9u - not confirmed given". On pens that figure is usually
  close to what was injected, which makes it worth having - but the wording
  is deliberate and shouldn't be shortened. It is what the app proposed, not
  a record of a dose. If it ever reads as a delivered figure to anyone in the
  house, take it off the display.
- **The caveat never leaves the screen.** If Nightscout becomes unreachable
  the footer says so rather than leaving old numbers looking current.

Graph markers: blue triangle = bolus, amber square = carbs.

Tuning is at the top of the script in `display/index.html`:

```js
var STALE_MIN = 15;          // when the colour drains
var TREATMENT_WINDOW_H = 12; // how far back before "none logged"
var GRAPH_HOURS = 24;        // history window
var MAX_POINTS = 720;        // trace is thinned above this many points
var GAP_MIN = 18;            // gap before the line breaks to dashed
var ALERT_LINES = [3.9, 14.0];  // red dashed threshold lines on the plot
var CARB_PAIR_MIN = 20;      // carbs this close to a bolus count as one event
var Y_MIN = 2, Y_MAX = 18;   // y-axis FLOOR - grows to fit higher readings
```

Colour bands on the current-level panel (mmol/L):

| Range | Panel | Label |
|---|---|---|
| under 3.0 | deep red | Urgent low |
| 3.0 - 3.9 | red | Low |
| 3.9 - 10.0 | green | In range |
| 10.0 - 14.0 | amber | High |
| 14.0 and over | red | Very high |

Edit `bandFor()` in `display/index.html` to change these. The shaded band on
the graph stays at 3.9-10.0, the standard consensus target.

Stock Nightscout views are still there if you want one:

| Path | What it shows |
|---|---|
| `:8080/` | The display page (default) |
| `:1337/` | Full Nightscout graph view, all pills |
| `:1337/clock-color.html` | BG only, colour background |

## When it breaks

**Symptom: data stops, everything else looks fine.**

Nine times out of ten Abbott bumped the LibreLinkUp app version and started
rejecting the pinned one.

```bash
docker compose logs --tail=50 librelink
```

Look for auth failures. Fix by updating `LINK_UP_VERSION` in `.env` to the
current value from the upstream repo README, then
`docker compose up -d librelink`.

This is the one recurring maintenance chore in the whole build. The staleness
timer exists to tell you it's happened before anyone's squinting at a frozen
number.

**Nightscout logging too much.** The connect plugin is very chatty - it
writes a full state dump every minute. Once Glooko is proven, cap the log so
it can't fill the disk. In `docker-compose.yml`, under the `nightscout`
service:

```yaml
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
```

**Symptom: sustained load average around 1.2 on an idle box.**

Check what's actually eating it before assuming it's the browser:

```bash
top -bn1 | head -12
docker stats --no-stream
```

The culprit here was `unclutter` (~64% CPU) spinning against `Xwayland`
(~55%). It's an X11 pointer-hiding tool; under cage it fights Xwayland
indefinitely, and on a TV with no mouse there's no cursor to hide anyway.

```bash
pkill unclutter
sed -i '/unclutter/d' ~/.local/bin/ns-kiosk.sh
sudo systemctl restart ns-kiosk
```

The containers are near-idle in normal operation - Mongo ~0.3%, everything
else 0.00%. If Docker shows otherwise, that's a different problem.

**Symptom: "Logged in to the wrong region. Switch to 'EU2'".**

Set `LINK_UP_REGION=EU2` in `.env` (not in the compose file) and
`docker compose up -d --force-recreate librelink`.

Keep every site-specific value in `.env`, never hardcoded in
`docker-compose.yml`. The compose file gets replaced when you take an update;
`.env` doesn't. Anything you edit into the yml will silently revert to its
default the next time you copy a new one over, and the failure shows up
minutes to hours later as a stalled feed.

**Symptom: bridge logs `getaddrinfo EAI_AGAIN`.**

DNS failing inside the container, not a credentials problem - the bridge
misreports it as "Invalid authentication token". Common on minimal Debian
where the host's `/etc/resolv.conf` points at systemd-resolved's stub
(`127.0.0.53`), which means nothing inside a container.

```bash
# host resolves but container doesn't?
docker compose exec librelink node -e \
  "require('dns').lookup('api-eu2.libreview.io',(e,a)=>console.log(e||a))"
```

Fix by giving the daemon explicit upstream servers:

```bash
sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{ "dns": ["1.1.1.1", "8.8.8.8"] }
EOF
sudo systemctl restart docker
```

**Symptom: gaps in the history.**

LibreLinkUp lags on recent historical data. The bridge polls for new readings
only; run a full sync once a day to fill the holes:

```bash
docker compose run --rm -e ALL_DATA=true librelink
```

Worth adding as a third timer once you've seen how much it actually catches.

**Symptom: readings in mg/dL.**

`DISPLAY_UNITS: mmol` is set in the compose file, but the clock views have a
long history of falling back to mg/dL if anything's off. 5.6 versus 101 is not
a mistake you want on a wall display — check before you trust the display.

---

## Platform notes

### The CPU check that matters

MongoDB 5.0+ needs the **AVX** instruction set on x86_64. Without it mongod
exits immediately with `Illegal instruction (core dumped)`.

This is not just an old-hardware problem — Celeron, Atom, Pentium Silver and
the N-series lack AVX in current models, which is exactly the sort of small
quiet machine you'd want on a shelf. Check it:

```bash
lscpu | grep -i avx
```

Nothing back? Set `MONGO_TAG=4.4` in `.env`. That's the last release before
the requirement. It's EOL and unpatched, which on a LAN-only box with no
inbound exposure is an acceptable trade — but know you're making it.

On arm64 the equivalent line is ARMv8.2-A: Pi 5 (Cortex-A76) fine, Pi 4
(Cortex-A72) not, use 4.4. 32-bit ARM won't work at all.

### Pi vs a repurposed PC

|  | Pi 5 | amd64 PC |
|---|---|---|
| Mongo | fine, check ARMv8.2-A | fine, **check AVX** |
| Kiosk | wayfire/labwc autostart | `cage` systemd service |
| TV power | manual (CEC available if wanted) | manual |
| Idle power | ~6W | ~40–80W (≈£100–150/yr more) |
| Noise/heat | silent | fans, in a room that has enough heat |
| Storage | must add SSD/NVMe | usually already has one |

`install-kiosk.sh` detects which of the three it's on and does the right
thing. On Debian it installs `cage`, sets the box to boot to console instead
of a desktop login, and runs Chromium fullscreen on tty1 as a systemd service.
That's a proper appliance — no desktop, no panel, no login prompt.

To undo that later: `sudo systemctl disable --now ns-kiosk` and
`sudo systemctl set-default graphical.target`.

### Storage

**SSD or NVMe, not an SD card.** Libre 2 Plus streams every minute; Mongo
writes continuously and will chew through a card.

### Keep it off the DMRCore box

Different reliability profile, and you don't want an experiment taking the
display down.

## Treatments — bolus and carbs

Nightscout renders last bolus, IOB, COB and the bolus wizard preview once
treatment data exists. **These pills only appear on the main view at `/`, not
on the clock views** — so if you want them on the wall, set
`KIOSK_URL=http://localhost:1337/` rather than the colour clock.

Three routes, in order of preference:

### 1. Glooko (automatic)

The only automatic path. mylife App has no Nightscout integration - the pump
talks only to mylife App, which forwards to mylife Cloud and Glooko.

In `.env`:

```
NS_EXTRA_ENABLE=connect
CONNECT_GLOOKO_EMAIL=...
CONNECT_GLOOKO_PASSWORD=...
CONNECT_GLOOKO_ENV=eu
CONNECT_GLOOKO_TIMEZONE_OFFSET=1     # BST; 0 in winter
```

Then `docker compose up -d nightscout`.

**Run it as a plugin, not a sidecar.** nightscout-connect reads `CONNECT_*`
variables through cgm-remote-monitor's extended-settings parser. That parser
lives in Nightscout, not in the standalone repo - so running the package as
its own container leaves every option undefined and it crash loops on
`url.parse` with `baseURL` unset. Hours of debugging live in that sentence.

Things to know:

- **Log into the Glooko mobile app at least once first** - the API isn't
  enabled on the account until you have.
- **It is not real-time.** Every hop batches. Fine as a record, useless as a
  live check.
- **Upstream marks the Glooko driver Experimental.**
- **EU auth has a known open issue.** If login fails, that's likely why.
- **The timezone offset doesn't follow DST.**
- **Glooko can also upload CGM** if LibreView is linked to it. Don't link it -
  glucose comes from LibreLinkUp, and two sources means doubled points.

### 2. xDrip+ (manual, Android) — fallback only

Not needed if Glooko works. Documented here because the Glooko driver is
experimental and EU auth has a known open issue, so it's worth knowing what
plan B looks like without re-deriving it.


Configure as a **Nightscout Follower** — data source pointed at
`http://<pi>:1337` with your API secret, and Nightscout upload enabled with
the same token. It then displays BG from your Pi and syncs treatments back.

Never point xDrip+ at the sensor directly. The sensor allows exactly one
connected device — whichever responds to the BLE advertisement first wins —
and the patched-app route requires uninstalling LibreLink entirely. Either
way you'd be dismantling her alarm layer to improve a graph. Libre 2 Plus
(301-series) BLE in xDrip is also unreliable at the moment.

Because this build is LAN-only, xDrip+ syncs on home wifi only. Treatments
entered elsewhere queue and land on return, with original timestamps intact —
so the history stays correct even though the display lags.

### 3. Care Portal (manual, any browser)

Already enabled. Bookmark it on both phones. Few taps per entry.

### A word on how to use this

The question a bolus panel invites is "has she had her tea insulin?" — and
none of these routes can answer that reliably. Glooko lags; manual entry is
only as good as the last person's discipline. The failure mode is someone
glancing at the screen, seeing nothing, and dosing again.

Treat it as a **record**, not an authority. The answer to "has she been
given insulin" stays where it already lives — the app and the pen. Make sure
whatever's on screen always shows the timestamp, so "nothing logged" can
never read as "nothing given."

## Display output

Run `./preflight.sh` — it lists connectors, whether each is connected, and
the modes it could read.

### DisplayPort (best case)

Digital, EDID reads properly, no mode forcing needed. Check whether the port
is **DP++** (Dual-Mode DisplayPort — look for the logo by the socket):

- **DP++** → passive DP→HDMI cable, ~£5
- **not DP++** → active adapter, ~£20

Buy active if you can't tell; it works in both cases. A single DP→HDMI cable
beats adapter-plus-cable — fewer connectors to work loose behind a unit.

### HDMI

Nothing to do.

### VGA and analogue output

Workable, and honestly fine for this — a giant clock face is the most
analogue-tolerant thing you could put on a screen. But:

- **Check the TV has a VGA socket.** They disappeared from TVs around 2016.
  If it hasn't, you need an *active* VGA→HDMI converter — analogue to digital,
  so a passive cable won't do. Most want USB power.
- **Expect EDID trouble.** Over VGA the machine often can't read the TV's
  capabilities and falls back to 1024×768, letterboxes, or outputs nothing.
  Fix with `./force-display.sh` — run it bare to see connectors, then e.g.
  `./force-display.sh VGA-1 1920x1080@60`. Reboot to apply, `--revert` to undo.
  Try 1280x720@60 first if 1080p won't take.
- **Overscan** — if the TV crops the edges, look for its picture-size setting:
  "Just Scan", "Screen Fit", "1:1" or "Full Pixel" depending on make.
- **Old GPU** — anything VGA-only may have graphics wlroots won't drive. If
  `cage` refuses to start, use `KIOSK_BACKEND=x11 ./install-kiosk.sh`, which
  runs bare X with no window manager and software rendering.

### TV power

The TV gets switched off by hand overnight, so there's no CEC in this build
and `cec-tv.sh` isn't included.

Worth knowing: the machine keeps running with the TV off, so nothing stops
logging — the overnight data is there in the morning regardless.

The one wrinkle is that powering a display off and on makes the connector
disappear and return. Usually harmless, but occasionally Chromium comes back
on a zero-size output or fails to repaint. The `ns-kiosk-restart` timer
restarts the kiosk at 06:00 to sidestep that. It touches only the browser —
Nightscout, Mongo and the bridge are untouched, so no data is affected.

If you ever do want automatic TV power, note that **neither DisplayPort nor
VGA carries CEC**, and an adapter can't create it. It needs a Pulse-Eight
USB-CEC adapter on a PC.

**OLED?** Switching it off overnight is exactly what protects it — the clock
view is almost entirely static, so an always-on panel would be the risk.

---

## What this deliberately doesn't do

- No alarms. The Libre app owns that.
- No internet exposure. No proxy, no certs, no DDNS, no port forward.
- No dosing calculations, no predictions, no bolus advice.

If any of that changes later, the security posture has to change with it —
in particular `AUTH_DEFAULT_ROLES` must move from `readable` to `denied`
**before** anything becomes reachable from outside the house, or the URL alone
gets anyone her full history.
