# AC Music

<p align="center">
  <a href="https://flutter.dev/"><img src="https://img.shields.io/badge/Flutter-3.11-02569B?logo=flutter" alt="Flutter" /></a>
  <a href="https://dart.dev/"><img src="https://img.shields.io/badge/Dart-3.11-0175C2?logo=dart&logoColor=white" alt="Dart" /></a>
  <a href="https://developer.android.com/"><img src="https://img.shields.io/badge/Platform-Android-3DDC84?logo=android&logoColor=white" alt="Android" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-green.svg" alt="License" /></a>
  <img src="https://img.shields.io/badge/version-1.0.2%2B1-666666" alt="version" />
</p>

<p align="center">
  <b>Local music player for TV &amp; desktop</b><br/>
  <sub>Flutter · Local library · Lyrics · LAN HTTP</sub>
</p>

<p align="center">
  <b>中文</b>：<a href="README.md">README.md</a>
</p>

---

## Screenshots

Screenshots are stored under `docs/screenshots/` as **JPG** files. See [docs/screenshots/README.md](docs/screenshots/README.md) for the full index.

<p align="center">
  <img src="docs/screenshots/player_main.jpg" alt="Main player" width="720" /><br/>
  <sub>Main player · <code>player_main.jpg</code></sub>
</p>

<p align="center">
  <img src="docs/screenshots/library_tv.jpg" alt="Library" width="720" /><br/>
  <sub>Library / all songs · <code>library_tv.jpg</code></sub>
</p>

<p align="center">
  <img src="docs/screenshots/files_manager.jpg" alt="Files" width="360" />
  <img src="docs/screenshots/search.jpg" alt="Search" width="360" /><br/>
  <sub>File manager · Search</sub>
</p>

<p align="center">
  <img src="docs/screenshots/settings.jpg" alt="Settings" width="360" />
  <img src="docs/screenshots/full_screen_lyrics.jpg" alt="Fullscreen lyrics" width="360" /><br/>
  <sub>Settings · Fullscreen lyrics</sub>
</p>

---

## Overview

**AC Music** is a Flutter **local music player** with a **remote / D-pad friendly** TV-style UI, runnable on phones and **Android TV** (Leanback). It scans audio files under a chosen folder recursively, reads embedded & external tags, parses **LRC** lyrics, and optionally starts a **LAN HTTP file server** (port + basic auth) for the current library root.

**Version:** `1.0.2+1` (see `pubspec.yaml`)

## Features

| Area | Description |
|------|-------------|
| **Library** | Recursive scan, folder history, progress, cached results |
| **Playback** | `just_audio`, queue, shuffle/repeat modes, progress & cover art |
| **Metadata & lyrics** | Tags; embedded/external LRC with fullscreen lyrics |
| **Theming** | Light / dark / system; dark theme uses neutral grays + green accent (WeChat-like) |
| **Android TV** | `LEANBACK_LAUNCHER` for set-top / large screens |
| **LAN** | Optional HTTP server with configurable credentials |
| **Persistence** | `shared_preferences` for theme, folders, playback state |

## Supported formats (examples)

`mp3`, `flac`, `wav`, `m4a`, `aac`, `ogg`, `wma`, `aiff`, `ape`, `alac`, `opus` — exact set follows the app’s extension list.

## Requirements

- **Flutter** SDK `^3.11.5`
- Primary target: **Android**; validate other platforms with `flutter devices` and dependency checks.

## Quick start

```bash
git clone https://github.com/Xianxingxing/AC_Music.git
cd AC_Music
flutter pub get
flutter run
```

## Build release APK

```bash
flutter build apk --release
```

Output: `build/app/outputs/flutter-apk/app-release.apk`

## Android permissions

See `android/app/src/main/AndroidManifest.xml`. Grant storage / audio permissions if scanning fails.

## License

Distributed under the **[MIT License](LICENSE)**.

## Acknowledgements

[Flutter](https://flutter.dev/) and all open-source package authors.

<p align="center">If this project helps you, a ⭐ is appreciated.</p>
