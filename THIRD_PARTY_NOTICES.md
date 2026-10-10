# Third-party notices

## onboardapis

The ICE trainset names (`Sources/ZugbarCore/Resources/ice_names.json`) and the SNCF INOUI endpoints are taken from [felix-zenk/onboardapis](https://github.com/felix-zenk/onboardapis).

```
MIT License

Copyright (c) 2022 - 2026 Felix Zenk and contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.```

## Transitous

Online lookups use [Transitous](https://transitous.org). Its timetable data comes from the operators and aggregators listed at https://transitous.org/sources/. `Tests/ZugbarCoreTests/Fixtures/transitous_*.json` are recorded API responses.

## OpenStreetMap

Track speed limits come from [OpenStreetMap](https://www.openstreetmap.org), © OpenStreetMap contributors, via Overpass. `Sources/ZugbarCore/Resources/main_line_tracks.lzfse` (LZFSE-compressed JSON) is a database derived from it (main-line tracks in and around Germany and Austria with their `maxspeed`, built with `Zugbar --bundle-tracks`) and is available under the [Open Database License (ODbL) 1.0](https://opendatacommons.org/licenses/odbl/1-0/). `Tests/ZugbarCoreTests/Fixtures/overpass_tracks.json` is a recorded Overpass response.
