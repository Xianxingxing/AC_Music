# AC Music

<p align="center">
  <a href="https://flutter.dev/"><img src="https://img.shields.io/badge/Flutter-3.11-02569B?logo=flutter" alt="Flutter" /></a>
  <a href="https://dart.dev/"><img src="https://img.shields.io/badge/Dart-3.11-0175C2?logo=dart&logoColor=white" alt="Dart" /></a>
  <a href="https://developer.android.com/"><img src="https://img.shields.io/badge/Platform-Android-3DDC84?logo=android&logoColor=white" alt="Android" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-green.svg" alt="License" /></a>
  <img src="https://img.shields.io/badge/version-1.0.2%2B1-666666" alt="version" />
</p>

<p align="center">
  <b>面向电视与桌面的本地音乐播放器</b> · <b>Local music player for TV &amp; desktop</b><br/>
  <sub>Flutter · 本地曲库 · 歌词 · 局域网服务 | Local library · Lyrics · LAN HTTP</sub>
</p>

<p align="center">
  <a href="#简体中文">简体中文</a> · <a href="#english">English</a>
</p>

---

## Screenshots · 截图

> **English:** Place PNG files under `docs/screenshots/` using the filenames below so images render on GitHub.  
> **中文：** 将同名 PNG 放入 `docs/screenshots/` 后，下列图片会在仓库页面正常显示；未放置前可能出现裂图，属正常。

<p align="center">
  <img src="docs/screenshots/player_main.png" alt="AC Music player" width="720" /><br/>
  <sub>主界面 / Main player · <code>docs/screenshots/player_main.png</code></sub>
</p>

<p align="center">
  <img src="docs/screenshots/library_tv.png" alt="Library or TV UI" width="720" /><br/>
  <sub>曲库或 TV 界面（可选）/ Library or TV (optional) · <code>docs/screenshots/library_tv.png</code></sub>
</p>

See `docs/screenshots/README.md` for naming tips.

---

<a id="简体中文"></a>

## 简体中文

### 简介

**AC Music** 是一款使用 Flutter 开发的本地音乐播放应用，界面为**遥控器/方向键友好**的 TV 风格设计，同时支持手机与 Android TV 启动器。可递归扫描指定文件夹中的音频文件，读取内嵌与外挂标签、解析 LRC 歌词，并可选开启**局域网 HTTP 服务**，在同网段通过账号密码访问当前曲库根目录。

当前版本：`1.0.2+1`（见 `pubspec.yaml`）

### 功能特性

| 类别 | 说明 |
|------|------|
| **本地曲库** | 选择目录后递归扫描，多目录历史、扫描进度与结果缓存 |
| **播放** | `just_audio` 播放，队列、多种播放模式、进度与封面 |
| **元数据与歌词** | 标签解析；外挂/内嵌 LRC，全屏歌词等 |
| **主题** | 浅色 / 深色 / 跟随系统；深色参考微信深色灰阶 + 品牌绿强调 |
| **Android TV** | `LEANBACK_LAUNCHER`，适合机顶盒、车机大屏 |
| **局域网** | 可配置端口与账号密码的 HTTP 服务 |
| **持久化** | `shared_preferences` 保存主题、扫描目录、播放状态等 |

### 支持格式

例如：`mp3`、`flac`、`wav`、`m4a`、`aac`、`ogg`、`wma`、`aiff`、`ape`、`alac`、`opus`（以应用内扩展名集合为准）。

### 环境要求

- Flutter SDK：`^3.11.5`
- 当前工程以 **Android** 等已启用平台为主；其他平台请自行 `flutter devices` 与依赖验证。

### 快速开始

```bash
git clone <你的仓库地址>
cd <项目根目录>   # 含 pubspec.yaml
flutter pub get
flutter run
```

### 构建 Android APK

```bash
flutter build apk --release
```

产物：`build/app/outputs/flutter-apk/app-release.apk`

### Android 权限

与存储、媒体读取、网络相关权限以 `android/app/src/main/AndroidManifest.xml` 为准。扫描失败时请检查**存储 / 音乐与音频**等授权。

### 工程结构（节选）

```
lib/
├── main.dart
└── tv_player/
    ├── tv_design_tokens.dart
    ├── tv_music_player_page.dart
    └── lan_file_server.dart
assets/fonts/
```

### 技术栈

| 用途 | 依赖 |
|------|------|
| 音频 | `just_audio` |
| 标签 | `dart_tags` |
| 目录 | `file_picker` |
| 权限 | `permission_handler` |
| 存储 | `shared_preferences`、`path_provider` |
| HTTP | `http_server`、`mime` |
| 其他 | `lpinyin` 等 |

### 许可

本项目以 **[MIT License](LICENSE)** 开源。

---

<a id="english"></a>

## English

### Overview

**AC Music** is a Flutter **local music player** with a **remote / D-pad friendly** TV-style UI, runnable on phones and **Android TV** (Leanback). It scans audio files under a chosen folder recursively, reads embedded & external tags, parses **LRC** lyrics, and optionally starts a **LAN HTTP file server** (port + basic auth) for the current library root.

**Version:** `1.0.2+1` (see `pubspec.yaml`)

### Features

| Area | Description |
|------|-------------|
| **Library** | Recursive scan, folder history, progress, cached results |
| **Playback** | `just_audio`, queue, shuffle/repeat modes, progress & cover art |
| **Metadata & lyrics** | Tags; embedded/external LRC with fullscreen lyrics |
| **Theming** | Light / dark / system; dark theme uses neutral grays + green accent (WeChat-like) |
| **Android TV** | `LEANBACK_LAUNCHER` for set-top / large screens |
| **LAN** | Optional HTTP server with configurable credentials |
| **Persistence** | `shared_preferences` for theme, folders, playback state |

### Supported formats (examples)

`mp3`, `flac`, `wav`, `m4a`, `aac`, `ogg`, `wma`, `aiff`, `ape`, `alac`, `opus` — exact set follows the app’s extension list.

### Requirements

- **Flutter** SDK `^3.11.5`
- Primary target: **Android**; validate other platforms with `flutter devices` and dependency checks.

### Quick start

```bash
git clone <your-repo-url>
cd <project-root>   # directory containing pubspec.yaml
flutter pub get
flutter run
```

### Build release APK

```bash
flutter build apk --release
```

Output: `build/app/outputs/flutter-apk/app-release.apk`

### Android permissions

See `android/app/src/main/AndroidManifest.xml`. Grant storage / audio permissions if scanning fails.

### License

Distributed under the **[MIT License](LICENSE)**.

### Acknowledgements

[Flutter](https://flutter.dev/) and all open-source package authors.

<p align="center">
  If this project helps you, a ⭐ is appreciated. · 若对你有帮助，欢迎 Star ⭐
</p>
