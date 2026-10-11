# Zugbar

Live train info in your Mac's menu bar.

<img src="docs/screenshots/window.jpg" alt="Following an ICE online, with the route on the map">

- **On board:** speed, next stop, delays and tracks from the train's Wi-Fi (DB ICE, ÖBB Railjet, SNCF TGV INOUI)
- **Online:** follow any train in Europe via [Transitous](https://transitous.org), with estimated position and speed
- **Your journey:** destination and connection, with alerts for delays, track changes and tight or missed transfers
- English and German

<table>
  <tr>
    <td valign="top"><img src="docs/screenshots/panel-ice-dark.png" width="230" alt="On an ICE, with destination and connection"></td>
    <td valign="top"><img src="docs/screenshots/panel-discover.png" width="230" alt="Suggestions and live trains"></td>
    <td valign="top"><img src="docs/screenshots/panel-regional.png" width="230" alt="Picking a regional train at a station"></td>
  </tr>
</table>

> [!NOTE]
> Vibe-coded hobby project, mostly written by Claude and built on
> [TrainStatusInfo](https://github.com/niklaswa/TrainStatusInfo), [onboardapis](https://github.com/felix-zenk/onboardapis),
> [ICE-Buddy](https://github.com/ICE-Buddy) and [Transitous](https://transitous.org). The portals are unofficial
> APIs. Not affiliated with DB, ÖBB or SNCF.

## Install

Download the [latest release](https://github.com/zuranihenry/zugbar/releases/latest) and move `Zugbar.app` to
`/Applications` (macOS 14+). It isn't notarized; allow it under *System Settings → Privacy & Security*, or:

```bash
xattr -dr com.apple.quarantine /Applications/Zugbar.app
```

Or build it: `make install`.

## Development

```bash
make demo
make test
swift run Zugbar --lookup "ICE 123"
swift run Zugbar --profile "ICE 123"   # speed profile for the current section
```

Portals live in `Sources/ZugbarCore/Providers/`. Settings → Debug can trigger every notification and simulate
delays on the demo train.

[MIT](LICENSE) · [Third-party notices](THIRD_PARTY_NOTICES.md)
