# AC Music

<p align="center">
  <a href="https://flutter.dev/"><img src="https://img.shields.io/badge/Flutter-3.11-02569B?logo=flutter" alt="Flutter" /></a>
  <a href="https://dart.dev/"><img src="https://img.shields.io/badge/Dart-3.11-0175C2?logo=dart&logoColor=white" alt="Dart" /></a>
  <a href="https://developer.android.com/"><img src="https://img.shields.io/badge/Platform-Android-3DDC84?logo=android&logoColor=white" alt="Android" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-green.svg" alt="License" /></a>
  <img src="https://img.shields.io/badge/version-1.0.2%2B1-666666" alt="version" />
</p>

<p align="center">
  <b>面向电视与桌面的本地音乐播放器</b><br/>
  <sub>Flutter · 本地曲库 · 歌词 · 局域网服务</sub>
</p>

<p align="center">
  <b>English</b>：<a href="README_EN.md">README_EN.md</a>
</p>

---

## 截图

截图位于 `docs/screenshots/`（**JPG**），索引说明见 [docs/screenshots/README.md](docs/screenshots/README.md)。

<p align="center">
  <img src="docs/screenshots/player_main.jpg" alt="主播放界面" width="720" /><br/>
  <sub>主播放 · <code>player_main.jpg</code></sub>
</p>

<p align="center">
  <img src="docs/screenshots/library_tv.jpg" alt="曲库" width="720" /><br/>
  <sub>全部歌曲 / 曲库 · <code>library_tv.jpg</code></sub>
</p>

<p align="center">
  <img src="docs/screenshots/files_manager.jpg" alt="文件管理" width="360" />
  <img src="docs/screenshots/search.jpg" alt="搜索" width="360" /><br/>
  <sub>文件管理 · 搜索</sub>
</p>

<p align="center">
  <img src="docs/screenshots/settings.jpg" alt="设置" width="360" />
  <img src="docs/screenshots/full_screen_lyrics.jpg" alt="全屏歌词" width="360" /><br/>
  <sub>设置 · 全屏歌词</sub>
</p>

---

## 简介

**AC Music** 是一款使用 Flutter 开发的本地音乐播放应用，界面为**遥控器/方向键友好**的 TV 风格设计，同时支持手机与 Android TV 启动器。可递归扫描指定文件夹中的音频文件，读取内嵌与外挂标签、解析 LRC 歌词，并可选开启**局域网 HTTP 服务**，在同网段通过账号密码访问当前曲库根目录。

当前版本：`1.0.2+1`（见 `pubspec.yaml`）

## 功能特性

| 类别 | 说明 |
|------|------|
| **本地曲库** | 选择目录后递归扫描，多目录历史、扫描进度与结果缓存 |
| **播放** | `just_audio` 播放，队列、多种播放模式、进度与封面 |
| **元数据与歌词** | 标签解析；外挂/内嵌 LRC，全屏歌词等 |
| **主题** | 浅色 / 深色 / 跟随系统；深色参考微信深色灰阶 + 品牌绿强调 |
| **Android TV** | `LEANBACK_LAUNCHER`，适合机顶盒、车机大屏 |
| **局域网** | 可配置端口与账号密码的 HTTP 服务 |
| **持久化** | `shared_preferences` 保存主题、扫描目录、播放状态等 |

## 支持格式

例如：`mp3`、`flac`、`wav`、`m4a`、`aac`、`ogg`、`wma`、`aiff`、`ape`、`alac`、`opus`（以应用内扩展名集合为准）。

## 环境要求

- Flutter SDK：`^3.11.5`
- 当前工程以 **Android** 等已启用平台为主；其他平台请自行 `flutter devices` 与依赖验证。

## 快速开始

```bash
git clone https://github.com/Xianxingxing/AC_Music.git
cd AC_Music
flutter pub get
flutter run
```

## 构建 Android APK

```bash
flutter build apk --release
```

产物：`build/app/outputs/flutter-apk/app-release.apk`

## Android 权限

与存储、媒体读取、网络相关权限以 `android/app/src/main/AndroidManifest.xml` 为准。扫描失败时请检查**存储 / 音乐与音频**等授权。

## 工程结构（节选）

```
lib/
├── main.dart
└── tv_player/
    ├── tv_design_tokens.dart
    ├── tv_music_player_page.dart
    └── lan_file_server.dart
assets/fonts/
```

## 技术栈

| 用途 | 依赖 |
|------|------|
| 音频 | `just_audio` |
| 标签 | `dart_tags` |
| 目录 | `file_picker` |
| 权限 | `permission_handler` |
| 存储 | `shared_preferences`、`path_provider` |
| HTTP | `http_server`、`mime` |
| 其他 | `lpinyin` 等 |

## 许可

本项目以 **[MIT License](LICENSE)** 开源。

## 致谢

- [Flutter](https://flutter.dev/) 与各开源依赖库的维护者。

<p align="center">若本项目对你有帮助，欢迎 Star ⭐</p>
