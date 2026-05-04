# 应用截图 / Screenshots

本目录存放 **AC Music** 在 GitHub 与文档中使用的界面截图。根目录 [README.md](../../README.md) 的「截图」区会引用其中部分文件；以下清单与当前仓库内**实际存在的文件**一致（格式为 **JPG**）。

## 文件清单 / File index

| 文件 | 中文说明 | English |
|------|----------|---------|
| `player_main.jpg` | 主播放界面：封面、曲名、控制条、进度等 | Main player: cover, title, controls, progress |
| `library_tv.jpg` | 曲库 / 列表浏览，适合电视遥控与方向键操作 | Library / list view, TV & D-pad friendly |
| `files_manager.jpg` | 文件 / 目录管理或本地曲库入口相关界面 | File or folder management, local library entry |
| `search.jpg` | 搜索音乐或曲库 | Search within library |
| `settings.jpg` | 设置（主题、扫描目录、局域网等） | Settings: theme, scan folders, LAN server, etc. |
| `full_screen_lyrics.jpg` | 全屏歌词 / 歌词展示 | Fullscreen lyrics view |

## 与根目录 README 的对应关系

根 [README.md](../../README.md) 中目前用于首屏展示的建议引用为：

- `player_main.jpg` — 主图一（主播放）
- `library_tv.jpg` — 主图二（曲库 / TV）

其余截图可在 README 中按需追加 `<img>`，或用于 Issue、Release 说明、应用商店素材等。

## 更新与导出建议

- **格式**：当前统一为 **JPG**；若更换为 PNG，请同步修改根目录 `README.md` 里所有 `docs/screenshots/*.png` 或 `*.jpg` 引用。
- **尺寸**：宽度约 **720～1080 px** 即可，便于网页加载；保持横屏比例以符合 TV / 车机展示。
- **命名**：请保持上表文件名，或更新本文件与 [README.md](../../README.md) 中的路径，避免 GitHub 上裂图。

## 快速校验

在仓库根目录执行（仅作本地检查）：

```bash
ls -la docs/screenshots/*.{jpg,jpeg,png} 2>/dev/null
```

应能列出本目录下所有用于展示的位图资源。
