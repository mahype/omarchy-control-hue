# Omarchy Light Control for Hue

[![CI](https://github.com/mahype/omarchy-light-control-hue/actions/workflows/ci.yml/badge.svg)](https://github.com/mahype/omarchy-light-control-hue/actions/workflows/ci.yml)
[![Version](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fraw.githubusercontent.com%2Fmahype%2Fomarchy-light-control-hue%2Fmain%2Fmanifest.json&query=%24.version&label=version&color=blue)](manifest.json)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Omarchy 4](https://img.shields.io/badge/Omarchy-4-black.svg)](https://omarchy.org)
[![Philips Hue local API](https://img.shields.io/badge/Philips%20Hue-local%20API%20v2-0065d3.svg)](https://developers.meethue.com/)
[![Local control](https://img.shields.io/badge/control-local%20only-lightgrey.svg)](#privacy-and-security)
[![Verified TLS](https://img.shields.io/badge/TLS-certificate%20verified-brightgreen.svg)](#privacy-and-security)
[![No dependencies](https://img.shields.io/badge/dependencies-none-brightgreen.svg)](#requirements)

Control your Philips Hue lights from the Omarchy bar: rooms, zones, scenes,
colors, color temperature, single lamps and smart plugs. The plugin talks to
the Hue bridge on your local network — no cloud account, no polling. Changes
made elsewhere (Hue app, wall switches, automations) show up instantly through
the bridge's event stream.

![Omarchy Light Control for Hue](preview.png)

## Features

- **Bar icon** shows whether any light is on and marks an unreachable bridge.
- **Rooms and zones** with switch, brightness and a status line such as
  `65 % · Relax` or `80 % · 2700 K`. The color dot shows the current light color.
- **Scene · Color · Temperature** per room, zone or lamp. Scenes come as a
  dropdown, colors as quick swatches plus hue and saturation sliders, color
  temperature as a warm-to-cold slider in Kelvin. Switching the tab only
  changes the view; nothing is sent until you pick a value.
- **Brightness** keeps a running scene's proportions by recalling the scene at
  the new level.
- **Blink** (flash button) to find a room or lamp.
- **Single lamps** inside each room, each with its own controls.
- **Smart plugs** in their own section.
- **All lights** switch in the panel header.
- **Live updates:** changes from the Hue app, switches or automations appear
  instantly through the bridge's event stream.
- **English and German:** the UI follows the system language.
- Controls only appear when the lamps support them.

Unfold a room for its controls. Scene, Color and Temperature are exclusive,
brightness works with all of them:

<table>
  <tr>
    <th width="33%">Scene</th>
    <th width="33%">Color</th>
    <th width="33%">Temperature</th>
  </tr>
  <tr>
    <td valign="top"><img src="screenshots/scenes.png" alt="Scene dropdown of a room"></td>
    <td valign="top"><img src="screenshots/color.png" alt="Color swatches with hue and saturation sliders"></td>
    <td valign="top"><img src="screenshots/temperature.png" alt="Warm to cold color temperature slider"></td>
  </tr>
</table>

## Requirements

- Omarchy 4 or newer
- A Philips Hue bridge (v2, square) on the same network

Everything else is part of every Omarchy install: `python3` for the bridge
helper, `avahi` for discovery and `libsecret` (`secret-tool`) with GNOME
Keyring for the bridge key. There are no other runtime dependencies, and
nothing is built, bundled as a binary or downloaded.

## Installation

```bash
omarchy plugin add https://github.com/mahype/omarchy-light-control-hue.git --enable
```

Then connect your bridge:

1. Click the light bulb in the bar.
2. Click **Find Hue bridge**, then **Select** next to your bridge (or enter its
   IP address).
3. Click **Pair** and press the round link button on top of the bridge within
   30 seconds.

To update later, run `omarchy plugin update io.github.mahype.omarchy-light-control-hue`.

## Removal

Click **Disconnect bridge** under *Connection* in the panel (this deletes the
stored key), then:

```bash
omarchy plugin remove io.github.mahype.omarchy-light-control-hue
rm -rf ~/.config/omarchy-light-control-hue   # bridge selection
```

The Hue bridge keeps a registration entry named
`omarchy-light-control-hue#desktop`; remove it in the Hue app if you like.
Your lights, rooms and scenes are not touched.

## Privacy and security

- **Local only.** All control traffic goes to your Hue bridge over HTTPS. The
  only other address is `discovery.meethue.com`, and only when you search for
  a bridge and none answers via mDNS.
- **Verified TLS.** The bridge certificate must chain to one of Signify's two
  published Hue root certificates (`helper/certs/`, from Signify's developer
  documentation on
  [using HTTPS](https://developers.meethue.com/develop/application-design-guidance/using-https/)
  and [bridge certificates](https://developers.meethue.com/develop/application-design-guidance/hue-bridge-certificates/)),
  and it must name the ID of the bridge you selected.
- **Key in the keyring.** The bridge's application key is stored in the Secret
  Service (service `io.github.mahype.omarchy-light-control-hue`), never in a
  file. `~/.config/omarchy-light-control-hue/config.json` holds only the bridge
  ID, address and name; the directory is created with mode 0700.
- **External programs:** `python3` (the helper in `helper/`, standard library
  only), `avahi-browse` (discovery) and `secret-tool` (keyring). All are called
  with argument arrays, never through a shell.
- No installer, no services, no downloads. No sudo or pkexec is required.

## Keyboard and scripting

The widget registers an IPC target. `expand` opens the panel with a room or
zone unfolded; its second argument picks the tab (`scene`, `color`,
`temperature`, or `""` for the current one):

```bash
omarchy-shell io.github.mahype.omarchy-light-control-hue toggle
omarchy-shell io.github.mahype.omarchy-light-control-hue expand "Living room" color
omarchy-shell io.github.mahype.omarchy-light-control-hue allOff
```

The helper also works on its own:

```bash
hue=~/.config/omarchy/plugins/io.github.mahype.omarchy-light-control-hue/helper/main.py
python3 $hue discover
python3 $hue watch                        # JSON state stream; requests on stdin
python3 $hue set group <grouped_light id> --on true --brightness 60
python3 $hue set light <light id> --color ff8800
python3 $hue scene <scene id> --brightness 50
python3 $hue identify light <light id>
python3 $hue all-off
```

## Development

| Path | Purpose |
|---|---|
| `shell/Service.qml` | Runs the helper, holds the home state, queues commands |
| `shell/Panel.qml`, `shell/*Row.qml`, `shell/LightModes.qml` | Bar popup and its rows |
| `shell/BarWidget.qml` | Bar icon and IPC target |
| `shell/Model.js` | Panel logic and English/German strings |
| `helper/main.py` | Command line and the `watch` stream protocol |
| `helper/hue_bridge.py` | HTTPS, pairing, event stream, discovery |
| `helper/hue_model.py` | Raw CLIP v2 resources → rooms, scenes, lights |
| `helper/hue_color.py` | Color conversion (xy, mirek, RGB) |
| `tests/` | Unit tests and manifest check |

Run the checks (Node 22+, Python 3, jq):

```bash
bash tests/check-manifest.sh
node tests/model.test.js
python3 -B -m unittest discover -s tests
```

Link a checkout into Omarchy:

```bash
ln -s "$PWD" ~/.config/omarchy/plugins/io.github.mahype.omarchy-light-control-hue
omarchy-shell shell rescanPlugins
omarchy plugin enable io.github.mahype.omarchy-light-control-hue
```

Omarchy's file watcher does not follow symlinks, so run
`omarchy restart shell` after changing code.

## Roadmap

- Optional remote control through the Hue cloud when away from home — strictly
  an add-on; the local bridge stays the primary path.
- Hiding and reordering rooms.

## License

MIT — see [LICENSE](LICENSE).

Philips and Hue are trademarks of Signify. This is an independent community
project, not affiliated with or endorsed by Signify.
