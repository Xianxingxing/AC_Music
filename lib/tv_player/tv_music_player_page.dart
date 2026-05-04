import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:dart_tags/dart_tags.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:lpinyin/lpinyin.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'tv_design_tokens.dart';
import 'lan_file_server.dart';

enum _FocusSection { topBar, browser, controls, queue }

const List<String> _menuTitles = ['正在播放', '全部歌曲', '文件夹'];
const List<IconData> _menuIcons = [
  Icons.music_note_rounded,
  Icons.library_music_rounded,
  Icons.folder_rounded,
];
const List<_HeaderAction> _headerActions = <_HeaderAction>[
  _HeaderAction(icon: Icons.search_rounded, label: '搜索'),
  _HeaderAction(icon: Icons.settings_rounded, label: '设置'),
];

enum _PlaybackMode { sequential, shuffle, repeatOne }

class TvMusicPlayerPage extends StatefulWidget {
  const TvMusicPlayerPage({
    super.key,
    required this.themeChoice,
    required this.onThemeChanged,
  });

  final TvThemeChoice themeChoice;
  final ValueChanged<TvThemeChoice> onThemeChanged;

  @override
  State<TvMusicPlayerPage> createState() => _TvMusicPlayerPageState();
}

class _TvMusicPlayerPageState extends State<TvMusicPlayerPage> {
  static const int _controlCount = 9;
  static const int _browserColumnCount = 3;
  static const int _browserPageSize = _browserColumnCount * 8;
  static const String _lastScanFolderPreferenceKey = 'last_scan_folder_path';
  static const String _savedScanFoldersPreferenceKey = 'saved_scan_folders_v1';
  static const String _scanSongsCachePreferenceKey = 'scan_songs_cache_v1';
  static const String _lastPlayedSongPathPreferenceKey = 'last_played_song_path';
  static const String _playbackModePreferenceKey = 'playback_mode';
  static const String _fullscreenLyricsCoverEffectPreferenceKey =
      'fullscreen_lyrics_cover_effect_v1';
  static const String _fullscreenLyricsHintSeenPreferenceKey =
      'fullscreen_lyrics_hint_seen_v1';
  static const String _lanServerEnabledKey = 'lan_server_enabled';
  static const String _lanServerPortKey = 'lan_server_port';
  static const String _lanServerUserKey = 'lan_server_user';
  static const String _lanServerPassKey = 'lan_server_pass';
  static const Set<String> _supportedMusicExtensions = {
    '.mp3',
    '.flac',
    '.wav',
    '.m4a',
    '.aac',
    '.ogg',
    '.wma',
    '.aiff',
    '.ape',
    '.alac',
    '.opus',
  };
  final FocusNode _pageFocusNode = FocusNode();
  final AudioPlayer _audioPlayer = AudioPlayer();
  final TagProcessor _tagProcessor = TagProcessor();
  final Map<_FocusSection, int> _lastIndexBySection = {
    _FocusSection.topBar: 4,
    _FocusSection.controls: 4,
    _FocusSection.queue: 0,
  };
  _FocusSection _focusedSection = _FocusSection.topBar;
  int _focusedMenuIndex = 4;
  int _activeMenuIndex = 0;
  int _focusedBrowserIndex = 0;
  int _focusedControlIndex = 4;
  int _focusedQueueIndex = 0;
  String? _scanFolderPath;
  String _scanStatusText = '尚未扫描本地音乐';
  List<_SavedScanFolder> _savedScanFolders = const <_SavedScanFolder>[];
  double _statusOpacity = 0.95;
  Timer? _statusFadeTimer;
  List<_LocalSong> _queueSongs = const <_LocalSong>[];
  int _currentSongIndex = -1;
  Duration _currentPosition = Duration.zero;
  Duration _currentDuration = Duration.zero;
  bool _isPlaying = false;
  _PlaybackMode _playbackMode = _PlaybackMode.sequential;
  bool _isQueueVisible = false;
  bool _isLyricsFullscreen = false;
  bool _showFullscreenOverlay = false;
  /// 已看过操作蒙版；在 prefs 恢复前默认为 true，避免误显示。
  bool _fullscreenLyricsHintSeen = true;
  bool _showFullscreenLyricsFirstHint = false;
  final LanFileServer _lanServer = LanFileServer();
  bool _lanServerEnabled = false;
  int _lanServerPort = 8088;
  String _lanServerUser = 'admin';
  String _lanServerPass = 'admin';
  List<String> _lanServerIps = const <String>[];
  DateTime? _lastFullscreenHorizontalAt;
  LogicalKeyboardKey? _lastFullscreenHorizontalKey;
  DateTime? _lastBrowserActivateAt;
  int _lastBrowserActivateIndex = -1;
  int _songSwitchRequestSerial = 0;
  String? _openedFolderPath;
  bool _fullscreenLyricsCoverEffectEnabled = false;
  final ValueNotifier<_ScanProgressState> _scanProgressNotifier =
      ValueNotifier<_ScanProgressState>(const _ScanProgressState.preparing());
  late final StreamSubscription<PlayerState> _playerStateSub;
  late final StreamSubscription<Duration> _positionSub;
  late final StreamSubscription<Duration?> _durationSub;

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrapAfterLaunch());
    _playerStateSub = _audioPlayer.playerStateStream.listen((
      PlayerState state,
    ) {
      if (!mounted) {
        return;
      }
      if (state.processingState == ProcessingState.completed) {
        if (_playbackMode == _PlaybackMode.repeatOne &&
            _currentSongIndex >= 0 &&
            _currentSongIndex < _queueSongs.length) {
          unawaited(_audioPlayer.seek(Duration.zero));
          unawaited(_audioPlayer.play());
        } else {
          unawaited(_playNext());
        }
      }
      setState(() {
        _isPlaying = state.playing;
      });
    });
    _positionSub = _audioPlayer.positionStream.listen((Duration position) {
      if (!mounted) {
        return;
      }
      setState(() {
        _currentPosition = position;
      });
    });
    _durationSub = _audioPlayer.durationStream.listen((Duration? duration) {
      if (!mounted) {
        return;
      }
      setState(() {
        _currentDuration = duration ?? Duration.zero;
      });
    });
  }

  Future<void> _bootstrapAfterLaunch() async {
    await _restorePlaybackMode();
    await _restoreFullscreenLyricsCoverEffect();
    await _restoreFullscreenLyricsHintSeen();
    await _loadSavedScanFolders();
    await _restoreLastScanFolder();
    if (!mounted) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      if (_queueSongs.isEmpty) {
        unawaited(_openSettingsDialog());
        return;
      }
      setState(() {
        _focusedControlIndex = 4;
        _lastIndexBySection[_FocusSection.controls] = 4;
        _setFocusedSection(_FocusSection.controls);
      });
    });
  }

  @override
  void dispose() {
    _statusFadeTimer?.cancel();
    _playerStateSub.cancel();
    _positionSub.cancel();
    _durationSub.cancel();
    _scanProgressNotifier.dispose();
    _audioPlayer.dispose();
    _pageFocusNode.dispose();
    unawaited(_lanServer.stop());
    super.dispose();
  }

  Future<void> _loadLanServerPrefs() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final bool enabled = prefs.getBool(_lanServerEnabledKey) ?? false;
    final int port = prefs.getInt(_lanServerPortKey) ?? 8088;
    final String user = prefs.getString(_lanServerUserKey) ?? 'admin';
    final String pass = prefs.getString(_lanServerPassKey) ?? 'admin';
    if (!mounted) {
      _lanServerEnabled = enabled;
      _lanServerPort = port;
      _lanServerUser = user;
      _lanServerPass = pass;
      return;
    }
    setState(() {
      _lanServerEnabled = enabled;
      _lanServerPort = port;
      _lanServerUser = user;
      _lanServerPass = pass;
    });
  }

  Future<void> _persistLanServerPrefs() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_lanServerEnabledKey, _lanServerEnabled);
    await prefs.setInt(_lanServerPortKey, _lanServerPort);
    await prefs.setString(_lanServerUserKey, _lanServerUser);
    await prefs.setString(_lanServerPassKey, _lanServerPass);
  }

  Future<void> _toggleLanServer() async {
    if (!_lanServerEnabled) {
      final bool canManageFiles = await _ensureAndroidFileManagePermission();
      final String root = (_scanFolderPath ?? '').trim().isNotEmpty
          ? _scanFolderPath!.trim()
          : '/';
      try {
        final LanFileServerStatus status = await _lanServer.start(
          rootPath: root,
          port: _lanServerPort,
          username: _lanServerUser,
          password: _lanServerPass,
        );
        if (!mounted) {
          return;
        }
        setState(() {
          _lanServerEnabled = true;
          _lanServerPort = status.port;
          _lanServerIps = status.addresses;
        });
        await _persistLanServerPrefs();
        _showStatusMessage(
          canManageFiles
              ? '局域网管理已开启：端口 ${status.port}'
              : '局域网管理已开启（未授予完整文件权限，上传/删除可能受限）',
          autoFade: false,
        );
      } catch (e) {
        if (!mounted) {
          return;
        }
        _showStatusMessage('开启失败：$e', autoFade: false);
      }
      return;
    }
    await _lanServer.stop();
    if (!mounted) {
      return;
    }
    setState(() {
      _lanServerEnabled = false;
      _lanServerIps = const <String>[];
    });
    await _persistLanServerPrefs();
    _showStatusMessage('局域网管理已关闭');
  }

  void _showStatusMessage(String text, {bool autoFade = true}) {
    _statusFadeTimer?.cancel();
    if (!mounted) {
      _scanStatusText = text;
      _statusOpacity = 0.95;
      return;
    }
    setState(() {
      _scanStatusText = text;
      _statusOpacity = 0.95;
    });
    if (!autoFade) {
      return;
    }
    _statusFadeTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) {
        return;
      }
      setState(() {
        _statusOpacity = 0.45;
      });
    });
  }

  Future<void> _saveLastScanFolder(String folderPath) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastScanFolderPreferenceKey, folderPath);
  }

  Future<void> _saveLastPlayedSongPath(String songPath) async {
    final String path = songPath.trim();
    if (path.isEmpty) {
      return;
    }
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastPlayedSongPathPreferenceKey, path);
  }

  Future<String?> _loadLastPlayedSongPath() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? path = prefs.getString(_lastPlayedSongPathPreferenceKey);
    if (path == null || path.trim().isEmpty) {
      return null;
    }
    return path.trim();
  }

  Future<void> _persistPlaybackMode() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_playbackModePreferenceKey, _playbackMode.name);
  }

  Future<void> _restorePlaybackMode() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_playbackModePreferenceKey);
    if (raw == null || raw.trim().isEmpty) {
      return;
    }
    _PlaybackMode restored = _PlaybackMode.sequential;
    for (final _PlaybackMode mode in _PlaybackMode.values) {
      if (mode.name == raw.trim()) {
        restored = mode;
        break;
      }
    }
    if (!mounted) {
      _playbackMode = restored;
      return;
    }
    setState(() {
      _playbackMode = restored;
    });
  }

  Future<void> _restoreFullscreenLyricsCoverEffect() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final bool enabled =
        prefs.getBool(_fullscreenLyricsCoverEffectPreferenceKey) ?? false;
    if (!mounted) {
      _fullscreenLyricsCoverEffectEnabled = enabled;
      return;
    }
    setState(() {
      _fullscreenLyricsCoverEffectEnabled = enabled;
    });
  }

  Future<void> _persistFullscreenLyricsCoverEffect() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(
      _fullscreenLyricsCoverEffectPreferenceKey,
      _fullscreenLyricsCoverEffectEnabled,
    );
  }

  Future<void> _restoreFullscreenLyricsHintSeen() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final bool seen =
        prefs.getBool(_fullscreenLyricsHintSeenPreferenceKey) ?? false;
    if (!mounted) {
      _fullscreenLyricsHintSeen = seen;
      return;
    }
    setState(() {
      _fullscreenLyricsHintSeen = seen;
    });
  }

  Future<void> _persistFullscreenLyricsHintSeen() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_fullscreenLyricsHintSeenPreferenceKey, true);
  }

  void _dismissFullscreenLyricsHint() {
    if (!_showFullscreenLyricsFirstHint) {
      return;
    }
    setState(() {
      _showFullscreenLyricsFirstHint = false;
      _fullscreenLyricsHintSeen = true;
    });
    unawaited(_persistFullscreenLyricsHintSeen());
  }

  Future<int> _resolveLastPlayedSongIndex(List<_LocalSong> songs) async {
    if (songs.isEmpty) {
      return 0;
    }
    final String? lastPath = await _loadLastPlayedSongPath();
    if (lastPath == null) {
      return 0;
    }
    final int idx = songs.indexWhere((song) => song.path == lastPath);
    return idx < 0 ? 0 : idx;
  }

  Future<void> _loadSavedScanFolders() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_savedScanFoldersPreferenceKey);
    if (raw == null || raw.trim().isEmpty) {
      return;
    }
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) {
        return;
      }
      final List<_SavedScanFolder> folders = decoded
          .whereType<Map>()
          .map(
            (Map item) =>
                _SavedScanFolder.fromJson(Map<String, dynamic>.from(item)),
          )
          .toList()
        ..sort((a, b) => b.scannedAt.compareTo(a.scannedAt));
      if (!mounted) {
        _savedScanFolders = folders;
        return;
      }
      setState(() {
        _savedScanFolders = folders;
      });
    } catch (_) {}
  }

  Future<void> _persistSavedScanFolders() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String raw = jsonEncode(
      _savedScanFolders.map((e) => e.toJson()).toList(),
    );
    await prefs.setString(_savedScanFoldersPreferenceKey, raw);
  }

  _SavedScanFolder? _findSavedScanFolder(String folderPath) {
    try {
      return _savedScanFolders.firstWhere((e) => e.path == folderPath);
    } catch (_) {
      return null;
    }
  }

  Future<void> _upsertSavedScanFolder(
    String folderPath,
    int songCount,
    _FolderSnapshot snapshot,
  ) async {
    final String normalized = folderPath.trim();
    if (normalized.isEmpty) {
      return;
    }
    final DateTime now = DateTime.now();
    final List<_SavedScanFolder> next = List<_SavedScanFolder>.from(
      _savedScanFolders,
    );
    final int idx = next.indexWhere((e) => e.path == normalized);
    final _SavedScanFolder item = _SavedScanFolder(
      path: normalized,
      songCount: songCount,
      scannedAt: now,
      snapshot: snapshot,
    );
    if (idx >= 0) {
      next[idx] = item;
    } else {
      next.add(item);
    }
    next.sort((a, b) => b.scannedAt.compareTo(a.scannedAt));
    if (mounted) {
      setState(() {
        _savedScanFolders = next;
      });
    } else {
      _savedScanFolders = next;
    }
    await _persistSavedScanFolders();
  }

  Future<void> _removeSavedScanFolder(String folderPath) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final List<_SavedScanFolder> next = _savedScanFolders
        .where((e) => e.path != folderPath)
        .toList();
    if (mounted) {
      setState(() {
        _savedScanFolders = next;
      });
    } else {
      _savedScanFolders = next;
    }
    await _deleteSongsCache(folderPath);
    // 清理历史版本遗留的 SharedPreferences 缓存字段。
    await prefs.remove(_scanSongsCachePreferenceKey);
    await _persistSavedScanFolders();
  }

  Future<void> _clearAllSavedScanFolders() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _savedScanFolders = const <_SavedScanFolder>[];
      });
    } else {
      _savedScanFolders = const <_SavedScanFolder>[];
    }
    await prefs.remove(_savedScanFoldersPreferenceKey);
    await prefs.remove(_scanSongsCachePreferenceKey);
    final Directory root = await _songsCacheRootDir();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  }

  Future<void> _saveSongsCache(String folderPath, List<_LocalSong> songs) async {
    final Directory root = await _songsCacheRootDir();
    final String folderId = _folderCacheId(folderPath);
    final Directory folderDir = Directory('${root.path}/$folderId');
    if (await folderDir.exists()) {
      await folderDir.delete(recursive: true);
    }
    await folderDir.create(recursive: true);
    final Directory coverDir = Directory('${folderDir.path}/covers');
    await coverDir.create(recursive: true);
    final File cacheFile = File('${folderDir.path}/songs.jsonl');
    final IOSink sink = cacheFile.openWrite();
    try {
      for (int i = 0; i < songs.length; i++) {
        final _LocalSong song = songs[i];
        String coverFile = '';
        if (song.coverBytes != null && song.coverBytes!.isNotEmpty) {
          coverFile = 'covers/$i.bin';
          final File file = File('${folderDir.path}/$coverFile');
          await file.writeAsBytes(song.coverBytes!, flush: false);
        }
        final Map<String, dynamic> item = <String, dynamic>{
          'path': song.path,
          'title': song.title,
          'artist': song.artist,
          'album': song.album,
          'lyrics': song.lyrics,
          'coverFile': coverFile,
        };
        sink.writeln(jsonEncode(item));
        // 每批次刷盘，降低大库扫描结束阶段内存和缓冲压力。
        if ((i + 1) % 100 == 0) {
          await sink.flush();
        }
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
  }

  Future<List<_LocalSong>> _loadSongsCache(String folderPath) async {
    final Directory root = await _songsCacheRootDir();
    final String folderId = _folderCacheId(folderPath);
    final File cacheFile = File('${root.path}/$folderId/songs.jsonl');
    if (!await cacheFile.exists()) {
      return const <_LocalSong>[];
    }
    try {
      final String folderDirPath = '${root.path}/$folderId';
      final List<_LocalSong> songs = <_LocalSong>[];
      final Stream<String> lines = cacheFile
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      await for (final String line in lines) {
        final String trimmed = line.trim();
        if (trimmed.isEmpty) {
          continue;
        }
        final Object? decoded = jsonDecode(trimmed);
        if (decoded is! Map) {
          continue;
        }
        final Map<String, dynamic> map = Map<String, dynamic>.from(decoded);
        final String coverFile = (map['coverFile']?.toString() ?? '').trim();
        Uint8List? coverBytes;
        if (coverFile.isNotEmpty) {
          final File cover = File('$folderDirPath/$coverFile');
          if (await cover.exists()) {
            coverBytes = await cover.readAsBytes();
          }
        }
        final String lyrics = (map['lyrics']?.toString() ?? '').trim();
        final _LocalSong song = _LocalSong(
          path: map['path']?.toString() ?? '',
          title: map['title']?.toString() ?? '未知歌曲',
          artist: map['artist']?.toString() ?? '未知歌手',
          album: map['album']?.toString() ?? '未知专辑',
          lyrics: lyrics,
          timedLyrics: _parseLrcToTimedLines(lyrics),
          coverBytes: coverBytes,
        );
        if (song.path.isNotEmpty) {
          songs.add(song);
        }
      }
      return songs;
    } catch (_) {
      return const <_LocalSong>[];
    }
  }

  Future<void> _deleteSongsCache(String folderPath) async {
    final Directory root = await _songsCacheRootDir();
    final String folderId = _folderCacheId(folderPath);
    final Directory folderDir = Directory('${root.path}/$folderId');
    if (await folderDir.exists()) {
      await folderDir.delete(recursive: true);
    }
  }

  Future<Directory> _songsCacheRootDir() async {
    final Directory baseDir = await getApplicationSupportDirectory();
    final Directory root = Directory('${baseDir.path}/scan_song_cache_v2');
    if (!await root.exists()) {
      await root.create(recursive: true);
    }
    return root;
  }

  String _folderCacheId(String folderPath) {
    final String raw = base64UrlEncode(utf8.encode(folderPath));
    return raw.replaceAll('=', '');
  }

  Future<bool> _loadSongsFromCache(String folderPath) async {
    final List<_LocalSong> songs = await _loadSongsCache(folderPath);
    if (songs.isEmpty || !mounted) {
      return false;
    }
    final int initialIndex = await _resolveLastPlayedSongIndex(songs);
    setState(() {
      _scanFolderPath = folderPath;
      _openedFolderPath = null;
      _queueSongs = songs;
      _currentSongIndex = initialIndex;
      _focusedQueueIndex = initialIndex;
      _lastIndexBySection[_FocusSection.queue] = initialIndex;
      _currentPosition = Duration.zero;
      _currentDuration = Duration.zero;
      _isPlaying = false;
      _focusedControlIndex = 4;
      _lastIndexBySection[_FocusSection.controls] = 4;
      _setFocusedSection(_FocusSection.controls);
    });
    await _saveLastScanFolder(folderPath);
    if (songs.isNotEmpty) {
      await _loadSongPreview(initialIndex);
    }
    _showStatusMessage('已加载缓存：${songs.length} 首歌曲', autoFade: false);
    return true;
  }

  Future<bool> _loadOrScanFolder(
    String folderPath, {
    bool forceRescan = false,
    void Function(_ScanProgressState state)? onProgress,
  }) async {
    final String normalized = folderPath.trim();
    if (normalized.isEmpty) {
      _showStatusMessage('扫描失败：目录为空', autoFade: false);
      return false;
    }
    if (!forceRescan) {
      final _SavedScanFolder? saved = _findSavedScanFolder(normalized);
      if (saved != null) {
        final _FolderSnapshot currentSnapshot = await _buildFolderSnapshot(
          normalized,
        );
        if (saved.snapshot == currentSnapshot) {
          final bool loaded = await _loadSongsFromCache(normalized);
          if (loaded) {
            return true;
          }
        }
      } else {
        final bool loaded = await _loadSongsFromCache(normalized);
        if (loaded) {
          return true;
        }
      }
    }
    return _scanAndLoadFolderWithProgress(normalized, onProgress: onProgress);
  }

  Future<_FolderSnapshot> _buildFolderSnapshot(String folderPath) async {
    String normalizedPath = folderPath.trim();
    if (normalizedPath.startsWith('file://')) {
      normalizedPath = Uri.parse(normalizedPath).toFilePath();
    }
    if (normalizedPath.isEmpty) {
      return const _FolderSnapshot(audioFileCount: 0, latestModifiedMs: 0);
    }
    final Directory directory = Directory(normalizedPath);
    if (!await directory.exists()) {
      return const _FolderSnapshot(audioFileCount: 0, latestModifiedMs: 0);
    }
    int count = 0;
    int latestMs = 0;
    final Stream<FileSystemEntity> entityStream = directory
        .list(recursive: true, followLinks: true)
        .handleError((_) {});
    await for (final FileSystemEntity entity in entityStream) {
      final String path = entity.path;
      final String lowerPath = path.toLowerCase();
      final bool supported = _supportedMusicExtensions.any(lowerPath.endsWith);
      if (!supported) {
        continue;
      }
      try {
        final FileStat stat = await FileStat.stat(path);
        if (stat.type != FileSystemEntityType.file) {
          continue;
        }
        count++;
        final int ms = stat.modified.millisecondsSinceEpoch;
        if (ms > latestMs) {
          latestMs = ms;
        }
      } catch (_) {}
    }
    return _FolderSnapshot(audioFileCount: count, latestModifiedMs: latestMs);
  }

  Future<void> _restoreLastScanFolder() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? folderPath = prefs.getString(_lastScanFolderPreferenceKey);
    if (folderPath == null || folderPath.trim().isEmpty) {
      return;
    }
    if (!mounted) {
      _scanFolderPath = folderPath.trim();
      return;
    }
    setState(() {
      _scanFolderPath = folderPath.trim();
    });
    await _loadSongsFromCache(folderPath.trim());
  }

  Future<bool> _scanAndLoadFolderWithProgress(
    String folderPath, {
    void Function(_ScanProgressState state)? onProgress,
  }) async {
    if (!mounted) {
      return false;
    }
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        useRootNavigator: true,
        builder: (BuildContext progressContext) {
          return _ScanProgressDialog(progress: _scanProgressNotifier);
        },
      ),
    );
    // 给弹窗一帧时间，确保用户能看到扫描进行中状态。
    await Future<void>.delayed(const Duration(milliseconds: 80));
    try {
      _scanProgressNotifier.value = const _ScanProgressState.preparing();
      onProgress?.call(const _ScanProgressState.preparing());
      return await _scanAndLoadFolder(folderPath, onProgress: (state) {
        _scanProgressNotifier.value = state;
        onProgress?.call(state);
      });
    } finally {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      _scanProgressNotifier.value = const _ScanProgressState.preparing();
    }
  }

  Future<bool> _scanAndLoadFolder(
    String folderPath, {
    void Function(_ScanProgressState state)? onProgress,
  }) async {
    final bool hasPermission = await _ensureAndroidStoragePermission();
    if (!hasPermission) {
      _showStatusMessage('扫描失败：Android 存储权限未授权，请在系统设置中允许读取音频', autoFade: false);
      return false;
    }

    final _ScanResult scanResult = await _scanSongsFromFolder(
      folderPath,
      onProgress: onProgress,
    );
    if (!mounted) {
      return false;
    }

    String currentFolder = folderPath.trim();
    if (currentFolder.startsWith('file://')) {
      currentFolder = Uri.parse(currentFolder).toFilePath();
    }

    await _saveLastScanFolder(currentFolder);
    if (!mounted) {
      return false;
    }

    final int initialIndex = await _resolveLastPlayedSongIndex(scanResult.songs);
    setState(() {
      _scanFolderPath = currentFolder;
      _openedFolderPath = null;
      _queueSongs = scanResult.songs;
      if (_queueSongs.isNotEmpty) {
        _currentSongIndex = initialIndex;
        _focusedQueueIndex = initialIndex;
        _lastIndexBySection[_FocusSection.queue] = initialIndex;
        _currentPosition = Duration.zero;
        _currentDuration = Duration.zero;
        _isPlaying = false;
        _focusedControlIndex = 4;
        _lastIndexBySection[_FocusSection.controls] = 4;
        _setFocusedSection(_FocusSection.controls);
      } else {
        _currentSongIndex = -1;
      }
    });

    _showStatusMessage(scanResult.statusText, autoFade: false);
    await _saveSongsCache(currentFolder, scanResult.songs);
    final _FolderSnapshot snapshot = await _buildFolderSnapshot(currentFolder);
    await _upsertSavedScanFolder(
      currentFolder,
      scanResult.songs.length,
      snapshot,
    );
    if (scanResult.songs.isNotEmpty) {
      await _loadSongPreview(initialIndex);
    }
    return true;
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    final LogicalKeyboardKey key = event.logicalKey;
    if (_isLyricsFullscreen && _showFullscreenLyricsFirstHint) {
      if (key == LogicalKeyboardKey.arrowUp ||
          key == LogicalKeyboardKey.arrowDown ||
          key == LogicalKeyboardKey.arrowLeft ||
          key == LogicalKeyboardKey.arrowRight) {
        return KeyEventResult.handled;
      }
      _dismissFullscreenLyricsHint();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.browserBack) {
      unawaited(_handleBackAction());
      return KeyEventResult.handled;
    }
    if (_isQueueVisible &&
        (key == LogicalKeyboardKey.arrowLeft ||
            key == LogicalKeyboardKey.arrowRight)) {
      setState(() {
        _isQueueVisible = false;
        _setFocusedSection(_FocusSection.controls);
      });
      return KeyEventResult.handled;
    }
    if (_isLyricsFullscreen &&
        key == LogicalKeyboardKey.arrowUp &&
        !_showFullscreenOverlay &&
        !_isQueueVisible) {
      setState(() {
        _isQueueVisible = true;
        _setFocusedSection(_FocusSection.queue);
      });
      return KeyEventResult.handled;
    }
    if (_isLyricsFullscreen &&
        !_showFullscreenOverlay &&
        (key == LogicalKeyboardKey.arrowLeft ||
            key == LogicalKeyboardKey.arrowRight)) {
      final DateTime now = DateTime.now();
      final bool isDoublePress =
          _lastFullscreenHorizontalKey == key &&
          _lastFullscreenHorizontalAt != null &&
          now.difference(_lastFullscreenHorizontalAt!) <
              const Duration(milliseconds: 420);
      _lastFullscreenHorizontalAt = now;
      _lastFullscreenHorizontalKey = key;
      if (isDoublePress) {
        if (key == LogicalKeyboardKey.arrowLeft) {
          unawaited(_playPrevious());
        } else {
          unawaited(_playNext());
        }
      }
      return KeyEventResult.handled;
    }
    if (_isLyricsFullscreen &&
        !_showFullscreenOverlay &&
        !_isQueueVisible &&
        key == LogicalKeyboardKey.arrowDown) {
      setState(() {
        _showFullscreenOverlay = true;
        _setFocusedSection(_FocusSection.controls);
      });
      return KeyEventResult.handled;
    }
    if (_isLyricsFullscreen &&
        !_showFullscreenOverlay &&
        !_isQueueVisible &&
        (key == LogicalKeyboardKey.select || key == LogicalKeyboardKey.enter)) {
      unawaited(_togglePlayPause());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _moveVertical(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _moveVertical(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      _moveHorizontal(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _moveHorizontal(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.select || key == LogicalKeyboardKey.enter) {
      _onActivate();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _handleBackAction() async {
    if (_isLyricsFullscreen) {
      if (!mounted) {
        return;
      }
      setState(() {
        if (_showFullscreenOverlay) {
          _showFullscreenOverlay = false;
        } else {
          _isLyricsFullscreen = false;
          _showFullscreenOverlay = false;
        }
      });
      return;
    }
    if (_focusedSection == _FocusSection.queue || _isQueueVisible) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isQueueVisible = false;
        _setFocusedSection(_FocusSection.controls);
      });
      return;
    }
    if (_focusedSection == _FocusSection.controls) {
      if (!mounted) {
        return;
      }
      setState(() {
        _setFocusedSection(_FocusSection.topBar);
      });
      return;
    }
    if (_focusedSection == _FocusSection.browser) {
      if (!mounted) {
        return;
      }
      setState(() {
        if (_activeMenuIndex == 2 && _openedFolderPath != null) {
          _openedFolderPath = null;
          _focusedBrowserIndex = 0;
          return;
        }
        _focusedMenuIndex = _activeMenuIndex;
        _lastIndexBySection[_FocusSection.topBar] = _focusedMenuIndex;
        _setFocusedSection(_FocusSection.topBar);
      });
      return;
    }
    if (_activeMenuIndex != 0 || _focusedMenuIndex != 0) {
      if (!mounted) {
        return;
      }
      setState(() {
        _activeMenuIndex = 0;
        _focusedMenuIndex = 0;
        _focusedBrowserIndex = 0;
        _lastIndexBySection[_FocusSection.topBar] = 0;
        _setFocusedSection(_FocusSection.topBar);
      });
      return;
    }
    await _showExitConfirmDialog();
  }

  Future<void> _showExitConfirmDialog() async {
    final bool? shouldExit = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return const _TvExitConfirmDialog();
      },
    );
    if (shouldExit == true) {
      SystemNavigator.pop();
    }
  }

  void _moveVertical(int step) {
    setState(() {
      if (_isLyricsFullscreen) {
        if (step < 0 && _showFullscreenOverlay) {
          _showFullscreenOverlay = false;
          return;
        }
        if (step > 0 && !_showFullscreenOverlay && !_isQueueVisible) {
          _showFullscreenOverlay = true;
          _setFocusedSection(_FocusSection.controls);
          return;
        }
      }
      switch (_focusedSection) {
        case _FocusSection.topBar:
          if (step > 0) {
            _setFocusedSection(
              _isBrowserMode ? _FocusSection.browser : _FocusSection.controls,
            );
          }
          break;
        case _FocusSection.browser:
          if (_activeMenuIndex == 2 && _openedFolderPath == null) {
            if (step < 0 && _focusedBrowserIndex < _browserColumnCount) {
              _setFocusedSection(_FocusSection.topBar);
            } else {
              _focusedBrowserIndex = (_focusedBrowserIndex +
                      (step * _browserColumnCount))
                  .clamp(
                0,
                _browserMaxIndex,
              );
            }
          } else if (step < 0 && _focusedBrowserIndex == 0) {
            _setFocusedSection(_FocusSection.topBar);
          } else {
            _focusedBrowserIndex = (_focusedBrowserIndex +
                    (step * _browserColumnCount))
                .clamp(
              0,
              _browserMaxIndex,
            );
          }
          break;
        case _FocusSection.controls:
          if (step < 0) {
            _setFocusedSection(_FocusSection.topBar);
          } else if (step > 0 && _isQueueVisible) {
            if (_currentSongIndex >= 0) {
              _focusedQueueIndex = _currentSongIndex.clamp(0, _queueMaxIndex);
              _lastIndexBySection[_FocusSection.queue] = _focusedQueueIndex;
            }
            _setFocusedSection(_FocusSection.queue);
          }
          break;
        case _FocusSection.queue:
          if (step < 0 && _focusedQueueIndex == 0) {
            _setFocusedSection(_FocusSection.controls);
          } else {
            _focusedQueueIndex = (_focusedQueueIndex + step).clamp(
              0,
              _queueMaxIndex,
            );
            _lastIndexBySection[_FocusSection.queue] = _focusedQueueIndex;
          }
          break;
      }
    });
  }

  void _moveHorizontal(int step) {
    setState(() {
      if (_isLyricsFullscreen && !_showFullscreenOverlay) {
        return;
      }
      if (_focusedSection == _FocusSection.topBar) {
        final int nextIndex = (_focusedMenuIndex + step).clamp(
          0,
          _menuTitles.length + _headerActions.length - 1,
        );
        _focusedMenuIndex = nextIndex;
        if (nextIndex < _menuTitles.length) {
          if (_activeMenuIndex != nextIndex) {
            _openedFolderPath = null;
          }
          _activeMenuIndex = nextIndex;
          _focusedBrowserIndex = 0;
        }
        _lastIndexBySection[_FocusSection.topBar] = _focusedMenuIndex;
        return;
      }
      if (_focusedSection == _FocusSection.browser) {
        final int nextIndex = _focusedBrowserIndex + step;
        final bool inRange = nextIndex >= 0 && nextIndex <= _browserMaxIndex;
        if (_activeMenuIndex == 2 && _openedFolderPath == null) {
          if (inRange) {
            final bool sameRow =
                nextIndex ~/ _browserColumnCount ==
                _focusedBrowserIndex ~/ _browserColumnCount;
            if (sameRow) {
              _focusedBrowserIndex = nextIndex;
            }
          }
          return;
        }
        final int currentPageStart =
            (_focusedBrowserIndex ~/ _browserPageSize) * _browserPageSize;
        final int currentPageEnd = (currentPageStart + _browserPageSize - 1)
            .clamp(0, _browserMaxIndex);
        final int localOffset = _focusedBrowserIndex - currentPageStart;
        final int rowInPage = localOffset ~/ _browserColumnCount;
        final bool isLeftEdge = localOffset % _browserColumnCount == 0;
        final bool isRightEdge =
            localOffset % _browserColumnCount == _browserColumnCount - 1 ||
            _focusedBrowserIndex == currentPageEnd;
        final bool sameRow =
            inRange &&
            (nextIndex ~/ _browserColumnCount ==
                _focusedBrowserIndex ~/ _browserColumnCount);
        if (sameRow) {
          _focusedBrowserIndex = nextIndex;
          return;
        }
        if (step > 0 && isRightEdge) {
          final int nextPageStart = currentPageStart + _browserPageSize;
          if (nextPageStart <= _browserMaxIndex) {
            _focusedBrowserIndex =
                (nextPageStart + (rowInPage * _browserColumnCount)).clamp(
              0,
              _browserMaxIndex,
            );
          }
          return;
        }
        if (step < 0 && isLeftEdge) {
          final int previousPageStart = currentPageStart - _browserPageSize;
          if (previousPageStart >= 0) {
            final int previousPageEnd = (previousPageStart + _browserPageSize - 1)
                .clamp(0, _browserMaxIndex);
            _focusedBrowserIndex =
                (previousPageStart +
                        (rowInPage * _browserColumnCount) +
                        (_browserColumnCount - 1))
                    .clamp(previousPageStart, previousPageEnd);
          }
        }
        return;
      }
      if (_focusedSection == _FocusSection.controls) {
        final int nextControl = _focusedControlIndex + step;
        if (nextControl < 0) {
          _focusedMenuIndex = _menuTitles.length + 1;
          _lastIndexBySection[_FocusSection.topBar] = _focusedMenuIndex;
          _setFocusedSection(_FocusSection.topBar);
          return;
        }
        if (nextControl >= _controlCount) {
          return;
        }
        _focusedControlIndex = nextControl;
        _lastIndexBySection[_FocusSection.controls] = _focusedControlIndex;
        return;
      }
      if (_focusedSection == _FocusSection.queue && step != 0) {
        _isQueueVisible = false;
        _setFocusedSection(_FocusSection.controls);
      }
    });
  }

  Future<void> _onActivate() async {
    if (_focusedSection == _FocusSection.topBar) {
      if (_focusedMenuIndex < _menuTitles.length) {
        return;
      }
      final int actionIndex = _focusedMenuIndex - _menuTitles.length;
      switch (actionIndex) {
        case 0:
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (BuildContext context) {
                return _SearchPage(
                  songs: _queueSongs,
                  onSongSelected: (int index) async {
                    Navigator.of(context).pop();
                    await _playSongAt(index);
                  },
                );
              },
            ),
          );
          break;
        case 1:
          await _openSettingsDialog();
          break;
      }
      return;
    }
    if (_focusedSection == _FocusSection.browser) {
      if (_activeMenuIndex == 2 && _openedFolderPath == null) {
        final List<_FolderBucket> buckets = _folderBuckets;
        if (buckets.isEmpty) {
          return;
        }
        final int idx = _focusedBrowserIndex.clamp(0, buckets.length - 1);
        setState(() {
          _openedFolderPath = buckets[idx].folderPath;
          _focusedBrowserIndex = 0;
        });
        return;
      }
      if (_activeMenuIndex == 2 &&
          _openedFolderPath != null &&
          _focusedBrowserIndex == 0) {
        setState(() {
          _openedFolderPath = null;
          _focusedBrowserIndex = 0;
        });
        return;
      }
      await _playFocusedBrowserSong();
      if (_activeMenuIndex == 1 || _activeMenuIndex == 2) {
        final DateTime now = DateTime.now();
        final bool isDoubleActivate =
            _lastBrowserActivateIndex == _focusedBrowserIndex &&
            _lastBrowserActivateAt != null &&
            now.difference(_lastBrowserActivateAt!) <
                const Duration(milliseconds: 450);
        _lastBrowserActivateAt = now;
        _lastBrowserActivateIndex = _focusedBrowserIndex;
        if (isDoubleActivate && mounted) {
          setState(() {
            _activeMenuIndex = 0;
            _focusedMenuIndex = 0;
            _lastIndexBySection[_FocusSection.topBar] = 0;
            _setFocusedSection(_FocusSection.controls);
          });
        }
      }
      return;
    }
    if (_focusedSection == _FocusSection.controls) {
      await _activateControl(_focusedControlIndex);
      return;
    }
    if (_focusedSection == _FocusSection.queue) {
      await _playSongAt(_focusedQueueIndex);
      if (!mounted) {
        return;
      }
      setState(() {
        _isQueueVisible = false;
        _setFocusedSection(_FocusSection.controls);
      });
    }
  }

  void _setFocusedSection(_FocusSection section) {
    _focusedSection = section;
    if (section == _FocusSection.topBar) {
      _focusedMenuIndex = _lastIndexBySection[section] ?? 0;
    } else if (section == _FocusSection.browser) {
      _focusedBrowserIndex = _focusedBrowserIndex.clamp(0, _browserMaxIndex);
    } else if (section == _FocusSection.controls) {
      _focusedControlIndex = _lastIndexBySection[section] ?? 4;
    } else if (section == _FocusSection.queue) {
      final int fallback = _lastIndexBySection[section] ?? 0;
      final int preferred = _currentSongIndex >= 0 ? _currentSongIndex : fallback;
      _focusedQueueIndex = preferred.clamp(0, _queueMaxIndex);
      _lastIndexBySection[_FocusSection.queue] = _focusedQueueIndex;
    }
  }

  int get _queueMaxIndex => _queueSongs.isEmpty ? 0 : _queueSongs.length - 1;
  bool get _isBrowserMode => _activeMenuIndex == 1 || _activeMenuIndex == 2;
  int get _browserItemCount {
    if (_activeMenuIndex == 2 && _openedFolderPath != null) {
      return _browserSongs.length + 1;
    }
    if (_activeMenuIndex == 2 && _openedFolderPath == null) {
      return _folderBuckets.length;
    }
    return _browserSongs.length;
  }
  int get _browserMaxIndex {
    return _browserItemCount <= 0 ? 0 : _browserItemCount - 1;
  }
  List<_LocalSong> get _browserSongs {
    if (_activeMenuIndex == 2) {
      if (_openedFolderPath == null) {
        return const <_LocalSong>[];
      }
      final List<_LocalSong> songs = _queueSongs
          .where((song) => _folderPathOfSong(song) == _openedFolderPath)
          .toList();
      songs.sort((a, b) => a.title.compareTo(b.title));
      return songs;
    }
    return _queueSongs;
  }

  List<_FolderBucket> get _folderBuckets {
    final Map<String, List<_LocalSong>> map = <String, List<_LocalSong>>{};
    for (final _LocalSong song in _queueSongs) {
      final String folderPath = _folderPathOfSong(song);
      map.putIfAbsent(folderPath, () => <_LocalSong>[]).add(song);
    }
    final List<_FolderBucket> buckets = map.entries
        .map(
          (e) => _FolderBucket(
            folderPath: e.key,
            displayName: _folderDisplayName(e.key),
            songs: e.value,
          ),
        )
        .toList();
    buckets.sort((a, b) => a.displayName.compareTo(b.displayName));
    return buckets;
  }

  String _folderPathOfSong(_LocalSong song) {
    final int idx = song.path.lastIndexOf(Platform.pathSeparator);
    if (idx <= 0) {
      return song.path;
    }
    return song.path.substring(0, idx);
  }

  String _folderDisplayName(String folderPath) {
    if (_scanFolderPath != null && folderPath.startsWith(_scanFolderPath!)) {
      String relative = folderPath.substring(_scanFolderPath!.length);
      relative = relative.replaceFirst(RegExp(r'^[\\/]+'), '');
      if (relative.isNotEmpty) {
        return relative;
      }
    }
    final List<String> segments = folderPath
        .split(RegExp(r'[\\/]'))
        .where((segment) => segment.trim().isNotEmpty)
        .toList();
    return segments.isEmpty ? '根目录' : segments.last;
  }

  Future<void> _playFocusedBrowserSong() async {
    if (_browserSongs.isEmpty) {
      return;
    }
    final int browserIndex = _activeMenuIndex == 2 && _openedFolderPath != null
        ? (_focusedBrowserIndex - 1).clamp(0, _browserSongs.length - 1)
        : _focusedBrowserIndex.clamp(0, _browserMaxIndex);
    final _LocalSong selectedSong = _browserSongs[browserIndex];
    final int queueIndex = _queueSongs.indexWhere(
      (_LocalSong song) => song.path == selectedSong.path,
    );
    if (queueIndex < 0) {
      return;
    }
    await _playSongAt(queueIndex);
  }

  _LocalSong? get _currentSong =>
      _currentSongIndex >= 0 && _currentSongIndex < _queueSongs.length
      ? _queueSongs[_currentSongIndex]
      : null;

  Future<void> _activateControl(int controlIndex) async {
    switch (controlIndex) {
      case 0:
        _toggleQueueVisibility();
        break;
      case 1:
        _cyclePlaybackMode();
        break;
      case 2:
        await _seekBy(const Duration(seconds: -15));
        break;
      case 3:
        await _playPrevious();
        break;
      case 4:
        await _togglePlayPause();
        break;
      case 5:
        await _playNext();
        break;
      case 6:
        await _seekBy(const Duration(seconds: 10));
        break;
      case 7:
        await _showSongInfoDialog();
        break;
      case 8:
        _toggleLyricsFullscreen();
        break;
      default:
        break;
    }
  }

  void _cyclePlaybackMode() {
    setState(() {
      switch (_playbackMode) {
        case _PlaybackMode.sequential:
          _playbackMode = _PlaybackMode.shuffle;
          break;
        case _PlaybackMode.shuffle:
          _playbackMode = _PlaybackMode.repeatOne;
          break;
        case _PlaybackMode.repeatOne:
          _playbackMode = _PlaybackMode.sequential;
          break;
      }
    });
    unawaited(_persistPlaybackMode());
    _showStatusMessage('播放模式：${_playbackModeLabel(_playbackMode)}');
  }

  void _toggleQueueVisibility() {
    setState(() {
      if (_isLyricsFullscreen) {
        _showFullscreenOverlay = true;
      }
      _isQueueVisible = !_isQueueVisible;
      if (_isQueueVisible) {
        _focusedQueueIndex = _currentSongIndex >= 0
            ? _currentSongIndex
            : _focusedQueueIndex;
        _lastIndexBySection[_FocusSection.queue] = _focusedQueueIndex;
        _setFocusedSection(_FocusSection.queue);
      } else if (_focusedSection == _FocusSection.queue) {
        _setFocusedSection(_FocusSection.controls);
      }
    });
  }

  void _toggleLyricsFullscreen() {
    final bool entering = !_isLyricsFullscreen;
    setState(() {
      _isLyricsFullscreen = !_isLyricsFullscreen;
      _showFullscreenOverlay = false;
      _isQueueVisible = false;
      _showFullscreenLyricsFirstHint = false;
      _focusedControlIndex = 8;
      _lastIndexBySection[_FocusSection.controls] = 8;
      _setFocusedSection(_FocusSection.controls);
      if (entering && !_fullscreenLyricsHintSeen) {
        _showFullscreenLyricsFirstHint = true;
      }
    });
  }

  Future<void> _showSongInfoDialog() async {
    final _LocalSong? song = _currentSong;
    if (song == null) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return Focus(
          autofocus: true,
          onKeyEvent: (FocusNode node, KeyEvent event) {
            if (event is! KeyDownEvent) {
              return KeyEventResult.ignored;
            }
            if (event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.select) {
              Navigator.of(context).pop();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: AlertDialog(
            backgroundColor: TvColors.card,
            title: const Text('歌曲信息'),
            content: SizedBox(
              width: 520,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    song.title,
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    song.artist,
                    style: TextStyle(
                      fontSize: 18,
                      color: TvColors.textIndex,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text('专辑：${song.album}'),
                  const SizedBox(height: 8),
                  Text('格式：${song.formatDisplay}'),
                  const SizedBox(height: 8),
                  Text('时长：${_formatDuration(_currentDuration)}'),
                  const SizedBox(height: 8),
                  Text('播放模式：${_playbackModeLabel(_playbackMode)}'),
                  const SizedBox(height: 8),
                  Text(
                    '文件：${song.path}',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Color(0xFF8E8E93)),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('关闭'),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _playSongAt(int index) async {
    if (index < 0 || index >= _queueSongs.length) {
      return;
    }
    final int requestSerial = ++_songSwitchRequestSerial;
    final _LocalSong song = _queueSongs[index];
    if (song.path.isEmpty) {
      return;
    }
    if (mounted) {
      setState(() {
        // 先同步 UI 到目标歌曲，避免切歌期间仍显示上一首封面/歌词。
        _currentSongIndex = index;
        _focusedQueueIndex = index.clamp(0, _queueMaxIndex);
        _lastIndexBySection[_FocusSection.queue] = _focusedQueueIndex;
        _currentPosition = Duration.zero;
      });
    }
    try {
      await _audioPlayer.setFilePath(song.path);
      await _audioPlayer.play();
      if (!mounted) {
        return;
      }
      if (requestSerial != _songSwitchRequestSerial) {
        return;
      }
      unawaited(_saveLastPlayedSongPath(song.path));
      // UI 已在请求发起时同步，这里无需重复更新索引。
    } catch (_) {
      if (!mounted) {
        return;
      }
      if (requestSerial != _songSwitchRequestSerial) {
        return;
      }
      await _removeBrokenSongAndContinue(index);
    }
  }

  Future<void> _loadSongPreview(int index) async {
    if (index < 0 || index >= _queueSongs.length) {
      return;
    }
    final int requestSerial = ++_songSwitchRequestSerial;
    final _LocalSong song = _queueSongs[index];
    if (song.path.isEmpty) {
      return;
    }
    try {
      await _audioPlayer.setFilePath(song.path);
      if (!mounted) {
        return;
      }
      if (requestSerial != _songSwitchRequestSerial) {
        return;
      }
      setState(() {
        _currentSongIndex = index;
        _currentPosition = Duration.zero;
        _isPlaying = false;
      });
      unawaited(_saveLastPlayedSongPath(song.path));
    } catch (_) {
      if (!mounted) {
        return;
      }
      if (requestSerial != _songSwitchRequestSerial) {
        return;
      }
      await _removeBrokenSongAndContinue(index, autoPlay: false);
    }
  }

  Future<void> _removeBrokenSongAndContinue(
    int index, {
    bool autoPlay = true,
  }) async {
    if (!mounted || index < 0 || index >= _queueSongs.length) {
      return;
    }
    final _LocalSong brokenSong = _queueSongs[index];
    final int nextIndexBeforeRemoval = index;
    setState(() {
      _queueSongs = List<_LocalSong>.from(_queueSongs)..removeAt(index);
      if (_queueSongs.isEmpty) {
        _currentSongIndex = -1;
        _focusedQueueIndex = 0;
        _lastIndexBySection[_FocusSection.queue] = 0;
        _currentPosition = Duration.zero;
        _currentDuration = Duration.zero;
        _isPlaying = false;
      } else {
        if (_currentSongIndex > index) {
          _currentSongIndex -= 1;
        } else if (_currentSongIndex == index) {
          _currentSongIndex = -1;
        }
        final int clampedFocus = _focusedQueueIndex.clamp(
          0,
          _queueSongs.length - 1,
        );
        _focusedQueueIndex = clampedFocus;
        _lastIndexBySection[_FocusSection.queue] = clampedFocus;
      }
    });
    _showStatusMessage('已移除无法读取歌曲：${brokenSong.title}', autoFade: false);
    if (_queueSongs.isEmpty) {
      await _audioPlayer.stop();
      return;
    }
    final int nextIndex = nextIndexBeforeRemoval.clamp(
      0,
      _queueSongs.length - 1,
    );
    if (autoPlay) {
      await _playSongAt(nextIndex);
    } else {
      await _loadSongPreview(nextIndex);
    }
  }

  Future<void> _togglePlayPause() async {
    if (_currentSongIndex == -1 && _queueSongs.isNotEmpty) {
      await _playSongAt(_focusedQueueIndex.clamp(0, _queueMaxIndex));
      return;
    }
    if (_audioPlayer.playing) {
      await _audioPlayer.pause();
    } else {
      await _audioPlayer.play();
    }
  }

  Future<void> _playPrevious() async {
    if (_queueSongs.isEmpty) {
      return;
    }
    final int nextIndex = (_currentSongIndex <= 0)
        ? _queueSongs.length - 1
        : _currentSongIndex - 1;
    await _playSongAt(nextIndex);
    if (!mounted) {
      return;
    }
    setState(() {
      final int idx = _currentSongIndex.clamp(0, _queueMaxIndex);
      _focusedQueueIndex = idx;
      _lastIndexBySection[_FocusSection.queue] = idx;
    });
  }

  Future<void> _playNext() async {
    if (_queueSongs.isEmpty) {
      return;
    }
    final int nextIndex = _playbackMode == _PlaybackMode.shuffle
        ? _nextShuffleIndex()
        : (_currentSongIndex < 0 || _currentSongIndex >= _queueSongs.length - 1)
        ? 0
        : _currentSongIndex + 1;
    await _playSongAt(nextIndex);
    if (!mounted) {
      return;
    }
    setState(() {
      final int idx = _currentSongIndex.clamp(0, _queueMaxIndex);
      _focusedQueueIndex = idx;
      _lastIndexBySection[_FocusSection.queue] = idx;
    });
  }

  int _nextShuffleIndex() {
    if (_queueSongs.length <= 1) {
      return 0;
    }
    final int seed = DateTime.now().microsecondsSinceEpoch % _queueSongs.length;
    if (seed == _currentSongIndex) {
      return (seed + 1) % _queueSongs.length;
    }
    return seed;
  }

  String _playbackModeLabel(_PlaybackMode mode) {
    switch (mode) {
      case _PlaybackMode.sequential:
        return '顺序播放';
      case _PlaybackMode.shuffle:
        return '随机播放';
      case _PlaybackMode.repeatOne:
        return '单曲循环';
    }
  }

  Future<void> _seekBy(Duration offset) async {
    if (_currentSongIndex < 0) {
      return;
    }
    final Duration target = _currentPosition + offset;
    final Duration max = _currentDuration;
    final Duration clamped = Duration(
      milliseconds: target.inMilliseconds.clamp(0, max.inMilliseconds),
    );
    await _audioPlayer.seek(clamped);
  }

  Future<void> _openSettingsDialog() async {
    await _loadLanServerPrefs();
    if (!mounted) {
      return;
    }
    final TextEditingController folderController = TextEditingController(
      text: _scanFolderPath ?? '',
    );

    await showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        bool isScanning = false;
        int dialogButtonIndex = 0;
        double scanProgress = 0;
        int scanProcessed = 0;
        int scanTotal = 0;
        String currentSongName = '准备扫描...';
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setDialogState) {
            Future<void> runToggleLanServer() async {
              await _toggleLanServer();
              if (!mounted || !context.mounted) {
                return;
              }
              setDialogState(() {});
            }

            Future<void> runScan() async {
              if (isScanning) {
                return;
              }
              final String folderPath = folderController.text.trim();
              setDialogState(() {
                isScanning = true;
                scanProgress = 0;
                scanProcessed = 0;
                scanTotal = 0;
                currentSongName = '准备扫描...';
              });
              final bool didFinishScan = await _loadOrScanFolder(
                folderPath,
                onProgress: (_ScanProgressState state) {
                  if (!context.mounted) {
                    return;
                  }
                  setDialogState(() {
                    scanProcessed = state.processed;
                    scanTotal = state.total;
                    currentSongName = state.currentSong;
                    scanProgress = state.progress;
                  });
                },
              );
              if (!mounted) {
                return;
              }
              setDialogState(() {
                isScanning = false;
              });
              if (!didFinishScan || !mounted || !context.mounted) {
                return;
              }
              Navigator.of(context).pop();
            }

            Future<void> runManageSavedFolders() async {
              await _showSavedFoldersDialog();
              if (!mounted || !context.mounted) {
                return;
              }
              setDialogState(() {});
            }

            Future<void> runSelectFolder() async {
              if (isScanning) {
                return;
              }
              final String initialPath = _resolveInitialFolderBrowserPath(
                folderController.text.trim(),
              );
              if (!context.mounted) {
                return;
              }
              String? folderPath;
              if (Platform.isAndroid) {
                // ignore: use_build_context_synchronously
                folderPath = await showDialog<String>(
                  context: context,
                  builder: (BuildContext context) {
                    return _FolderBrowserDialog(initialPath: initialPath);
                  },
                );
              } else {
                folderPath = await FilePicker.getDirectoryPath(
                  dialogTitle: '选择音乐文件夹',
                );
              }
              if (folderPath != null) {
                final String selectedPath = folderPath;
                setDialogState(() {
                  folderController.text = selectedPath;
                  dialogButtonIndex = 4;
                });
                await runScan();
              }
            }

            return Focus(
              autofocus: true,
              onKeyEvent: (FocusNode node, KeyEvent event) {
                if (event is! KeyDownEvent) {
                  return KeyEventResult.ignored;
                }
                final LogicalKeyboardKey key = event.logicalKey;
                if (key == LogicalKeyboardKey.arrowLeft) {
                  setDialogState(() {
                    final int cur = dialogButtonIndex;
                    if (cur == 1) {
                      dialogButtonIndex = 0;
                    } else if (cur == 7) {
                      dialogButtonIndex = 1;
                    } else if (cur == 5) {
                      dialogButtonIndex = 4;
                    } else if (cur == 6) {
                      dialogButtonIndex = 5;
                    } else if (cur == 4) {
                      dialogButtonIndex = 3;
                    } else if (cur == 3) {
                      dialogButtonIndex = 2;
                    }
                  });
                  return KeyEventResult.handled;
                }
                if (key == LogicalKeyboardKey.arrowRight) {
                  setDialogState(() {
                    final int cur = dialogButtonIndex;
                    if (cur == 0) {
                      dialogButtonIndex = 1;
                    } else if (cur == 1) {
                      dialogButtonIndex = 7;
                    } else if (cur == 2) {
                      dialogButtonIndex = 4;
                    } else if (cur == 3) {
                      dialogButtonIndex = 4;
                    } else if (cur == 4) {
                      dialogButtonIndex = 5;
                    } else if (cur == 5) {
                      dialogButtonIndex = 6;
                    } else if (cur == 6) {
                      dialogButtonIndex = 7;
                    }
                  });
                  return KeyEventResult.handled;
                }
                if (key == LogicalKeyboardKey.arrowUp) {
                  setDialogState(() {
                    final int cur = dialogButtonIndex;
                    if (cur == 2 || cur == 3) {
                      dialogButtonIndex = 4;
                    } else if (cur >= 3) {
                      dialogButtonIndex = 0;
                    }
                  });
                  return KeyEventResult.handled;
                }
                if (key == LogicalKeyboardKey.arrowDown) {
                  setDialogState(() {
                    final int cur = dialogButtonIndex;
                    if (cur <= 1 || cur == 7) {
                      dialogButtonIndex = 3;
                    } else if (cur == 2) {
                      dialogButtonIndex = 4;
                    } else if (cur == 3) {
                      dialogButtonIndex = 4;
                    } else if (cur >= 3 && cur <= 6) {
                      dialogButtonIndex = 2;
                    }
                  });
                  return KeyEventResult.handled;
                }
                if (key == LogicalKeyboardKey.enter ||
                    key == LogicalKeyboardKey.select) {
                  switch (dialogButtonIndex) {
                    case 0:
                      unawaited(runSelectFolder());
                      break;
                    case 1:
                      unawaited(runScan());
                      break;
                    case 2:
                      Navigator.of(context).pop();
                      break;
                    case 3:
                      unawaited(runToggleLanServer());
                      break;
                    case 4:
                      widget.onThemeChanged(TvThemeChoice.light);
                      break;
                    case 5:
                      widget.onThemeChanged(TvThemeChoice.dark);
                      break;
                    case 6:
                      setState(() {
                        _fullscreenLyricsCoverEffectEnabled =
                            !_fullscreenLyricsCoverEffectEnabled;
                      });
                      setDialogState(() {});
                      unawaited(_persistFullscreenLyricsCoverEffect());
                      break;
                    case 7:
                      unawaited(runManageSavedFolders());
                      break;
                  }
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: AlertDialog(
                backgroundColor: TvColors.panel,
                title: Text('设置', style: TextStyle(color: TvColors.textPrimary)),
                content: SizedBox(
                  width: 620,
                  child: DefaultTextStyle(
                    style: TextStyle(color: TvColors.textPrimary, fontSize: 14),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                        '扫描本地歌曲',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: folderController,
                        decoration: const InputDecoration(
                          hintText: '输入或选择要扫描的文件夹路径',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (isScanning) ...[
                        LinearProgressIndicator(
                          minHeight: 6,
                          value: scanTotal > 0 ? scanProgress : null,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          scanTotal > 0
                              ? '扫描进度：$scanProcessed / $scanTotal'
                              : '扫描进度：正在统计歌曲总数...',
                          style: TextStyle(
                            fontSize: 12,
                            color: TvColors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '当前歌曲：$currentSongName',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: TvColors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          _DialogActionButton(
                            icon: Icons.folder_open_rounded,
                            label: '选择文件夹',
                            focused: dialogButtonIndex == 0,
                            enabled: !isScanning,
                            onPressed: () => unawaited(runSelectFolder()),
                          ),
                          _DialogActionButton(
                            icon: Icons.library_music_rounded,
                            label: '开始扫描',
                            focused: dialogButtonIndex == 1,
                            enabled: !isScanning,
                            onPressed: () => unawaited(runScan()),
                          ),
                          _DialogActionButton(
                            icon: Icons.folder_copy_rounded,
                            label: '已扫描目录管理',
                            focused: dialogButtonIndex == 7,
                            enabled: !isScanning,
                            onPressed: () => unawaited(runManageSavedFolders()),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                        Text(
                        _savedScanFolders.isEmpty
                            ? '当前没有已保存的扫描目录'
                            : '已保存目录 ${_savedScanFolders.length} 个，最近：${_savedScanFolders.first.path}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: TvColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 18),
                      const Text(
                        '局域网文件管理',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          _DialogActionButton(
                            icon: Icons.wifi_tethering_rounded,
                            label: _lanServerEnabled ? '关闭局域网管理' : '开启局域网管理',
                            focused: dialogButtonIndex == 3,
                            enabled: !isScanning,
                            onPressed: () => unawaited(runToggleLanServer()),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                        Text(
                        _lanServerEnabled
                            ? '访问：${_lanServerIps.isNotEmpty ? _lanServerIps.first : "设备IP"}:$_lanServerPort  账号：$_lanServerUser  密码：$_lanServerPass'
                            : '关闭状态（开启后在电脑浏览器输入 IP:端口 访问）',
                        style: TextStyle(
                          fontSize: 12,
                          color: TvColors.textSecondary,
                        ),
                      ),
                      if (_lanServerEnabled && _lanServerIps.length > 1) ...[
                        const SizedBox(height: 6),
                          Text(
                          '其他IP：${_lanServerIps.join("  ")}',
                          style: TextStyle(
                            fontSize: 12,
                            color: TvColors.textSecondary,
                          ),
                        ),
                      ],
                      const SizedBox(height: 18),
                      const Text(
                        '外观',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          _DialogActionButton(
                            label: '浅色',
                            focused: dialogButtonIndex == 4,
                            onPressed: () =>
                                widget.onThemeChanged(TvThemeChoice.light),
                          ),
                          _DialogActionButton(
                            label: '深色',
                            focused: dialogButtonIndex == 5,
                            onPressed: () =>
                                widget.onThemeChanged(TvThemeChoice.dark),
                          ),
                          _DialogActionButton(
                            label: _fullscreenLyricsCoverEffectEnabled
                                ? '歌词封面特效：开'
                                : '歌词封面特效：关',
                            focused: dialogButtonIndex == 6,
                            enabled: !isScanning,
                            onPressed: () {
                              setState(() {
                                _fullscreenLyricsCoverEffectEnabled =
                                    !_fullscreenLyricsCoverEffectEnabled;
                              });
                      setDialogState(() {});
                              unawaited(
                                _persistFullscreenLyricsCoverEffect(),
                              );
                            },
                          ),
                        ],
                      ),
                      ],
                    ),
                  ),
                ),
                actions: [
                  _DialogActionButton(
                    label: '关闭',
                    focused: dialogButtonIndex == 2,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<_ScanResult> _scanSongsFromFolder(
    String folderPath, {
    void Function(_ScanProgressState state)? onProgress,
  }) async {
    String normalizedPath = folderPath.trim();
    if (normalizedPath.startsWith('file://')) {
      normalizedPath = Uri.parse(normalizedPath).toFilePath();
    }
    if (normalizedPath.isEmpty) {
      return const _ScanResult(songs: <_LocalSong>[], statusText: '扫描失败：目录为空');
    }
    final Directory directory = Directory(normalizedPath);
    final bool exists = await directory.exists();
    if (!exists) {
      return _ScanResult(
        songs: const <_LocalSong>[],
        statusText: '扫描失败：目录不存在 ($normalizedPath)',
      );
    }
    final List<_LocalSong> songs = <_LocalSong>[];
    int totalAudioFiles = 0;
    final Stream<FileSystemEntity> countStream = directory
        .list(recursive: true, followLinks: true)
        .handleError((_) {});
    await for (final FileSystemEntity entity in countStream) {
      final String lowerPath = entity.path.toLowerCase();
      final bool supported = _supportedMusicExtensions.any(lowerPath.endsWith);
      if (!supported) {
        continue;
      }
      try {
        final FileSystemEntityType type = await FileSystemEntity.type(
          entity.path,
          followLinks: true,
        );
        if (type == FileSystemEntityType.file) {
          totalAudioFiles++;
        }
      } catch (_) {}
    }
    onProgress?.call(
      _ScanProgressState(
        total: totalAudioFiles,
        processed: 0,
        currentSong: '准备扫描...',
      ),
    );
    int scannedFileCount = 0;
    int skippedEntities = 0;
    final Stream<FileSystemEntity> entityStream = directory
        .list(recursive: true, followLinks: true)
        .handleError((_) {
          // 遍历中遇到权限/损坏目录时继续扫描剩余路径。
          skippedEntities++;
        });

    await for (final FileSystemEntity entity in entityStream) {
      final String path = entity.path;
      final String lowerPath = path.toLowerCase();
      final bool supported = _supportedMusicExtensions.any(lowerPath.endsWith);
      if (!supported) {
        continue;
      }
      FileSystemEntityType entityType;
      try {
        entityType = await FileSystemEntity.type(path, followLinks: true);
      } catch (_) {
        skippedEntities++;
        continue;
      }
      if (entityType != FileSystemEntityType.file) {
        continue;
      }
      scannedFileCount++;
      final String fileName = path.split(Platform.pathSeparator).last;
      final int dotIndex = fileName.lastIndexOf('.');
      final String songTitle = dotIndex > 0
          ? fileName.substring(0, dotIndex)
          : fileName;
      _SongTagData? tagData;
      try {
        tagData = await _readSongTag(path);
      } catch (_) {
        tagData = null;
      }
      final String fileLyrics = await _readExternalLyrics(path);
      final String tagLyrics = tagData?.lyrics?.trim() ?? '';

      // 优先使用带时间戳的歌词来做滚动显示。
      // 同时保留 raw lyrics 用于无时间戳时的静态展示。
      final List<_TimedLyricLine> timedFromFile = _parseLrcToTimedLines(
        fileLyrics,
      );
      final List<_TimedLyricLine> timedFromTag = _parseLrcToTimedLines(
        tagLyrics,
      );
      final List<_TimedLyricLine> timedLyrics = timedFromFile.isNotEmpty
          ? timedFromFile
          : timedFromTag;

      final String mergedLyrics = tagLyrics.isNotEmpty ? tagLyrics : fileLyrics;
      songs.add(
        _LocalSong(
          path: path,
          title: (tagData?.title?.trim().isNotEmpty ?? false)
              ? tagData!.title!.trim()
              : songTitle,
          artist: (tagData?.artist?.trim().isNotEmpty ?? false)
              ? tagData!.artist!.trim()
              : '本地文件',
          album: (tagData?.album?.trim().isNotEmpty ?? false)
              ? tagData!.album!.trim()
              : '未知专辑',
          lyrics: mergedLyrics,
          timedLyrics: timedLyrics,
          coverBytes: tagData?.coverBytes,
        ),
      );
      onProgress?.call(
        _ScanProgressState(
          total: totalAudioFiles,
          processed: scannedFileCount,
          currentSong: songTitle,
        ),
      );
    }
    songs.sort((a, b) => a.title.compareTo(b.title));
    if (songs.isEmpty) {
      final String permissionHint = skippedEntities > 0
          ? '；有 $skippedEntities 项无法读取'
          : '';
      return _ScanResult(
        songs: songs,
        statusText: '扫描完成：检查 $scannedFileCount 个文件，找到 0 首$permissionHint',
      );
    }
    final String skippedHint = skippedEntities > 0
        ? '，跳过 $skippedEntities 项不可读内容'
        : '';
    return _ScanResult(
      songs: songs,
      statusText:
          '扫描完成：找到 ${songs.length} 首（检查 $scannedFileCount 个文件$skippedHint）',
    );
  }

  Future<void> _showSavedFoldersDialog() async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        final Set<String> selectedPaths = <String>{};
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setDialogState) {
            Future<void> handleLoad(String path) async {
              final bool ok = await _loadSongsFromCache(path);
              if (!mounted || !context.mounted) {
                return;
              }
              if (ok) {
                Navigator.of(context).pop();
              } else {
                setDialogState(() {});
              }
            }

            Future<void> handleRescan(String path) async {
              final bool ok = await _loadOrScanFolder(path, forceRescan: true);
              if (!mounted || !context.mounted) {
                return;
              }
              if (ok) {
                Navigator.of(context).pop();
              } else {
                setDialogState(() {});
              }
            }

            Future<void> handleDelete(String path) async {
              await _removeSavedScanFolder(path);
              selectedPaths.remove(path);
              if (!mounted || !context.mounted) {
                return;
              }
              setDialogState(() {});
            }

            Future<void> handleClearAll() async {
              await _clearAllSavedScanFolders();
              if (!mounted || !context.mounted) {
                return;
              }
              setDialogState(() {});
            }

            Future<void> handleDeleteSelected() async {
              final List<String> targets = selectedPaths.toList();
              for (final String path in targets) {
                await _removeSavedScanFolder(path);
              }
              selectedPaths.clear();
              if (!mounted || !context.mounted) {
                return;
              }
              setDialogState(() {});
            }

            return AlertDialog(
              backgroundColor: TvColors.card,
              title: const Text('已扫描目录管理'),
              content: SizedBox(
                width: 760,
                child: _savedScanFolders.isEmpty
                    ? Text(
                        '暂无已保存目录。扫描任意目录后会自动保存，下次可直接加载缓存。',
                        style: TextStyle(color: TvColors.textSecondary),
                      )
                    : ListView.separated(
                        shrinkWrap: true,
                        itemCount: _savedScanFolders.length,
                        separatorBuilder: (_, __) => Divider(
                          color: TvColors.panelBorder,
                          height: 16,
                        ),
                        itemBuilder: (BuildContext context, int i) {
                          final _SavedScanFolder item = _savedScanFolders[i];
                          final bool checked = selectedPaths.contains(item.path);
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Checkbox(
                                    value: checked,
                                    onChanged: (bool? value) {
                                      setDialogState(() {
                                        if (value == true) {
                                          selectedPaths.add(item.path);
                                        } else {
                                          selectedPaths.remove(item.path);
                                        }
                                      });
                                    },
                                  ),
                                  Text(
                                    '选择',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: TvColors.textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                              Text(
                                item.path,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 14,
                                  color: TvColors.accent,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '歌曲 ${item.songCount} 首  ·  ${item.scannedAt.toLocal()}',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: TvColors.textSecondary,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  OutlinedButton(
                                    onPressed: () => unawaited(
                                      handleLoad(item.path),
                                    ),
                                    child: const Text('加载缓存'),
                                  ),
                                  OutlinedButton(
                                    onPressed: () => unawaited(
                                      handleRescan(item.path),
                                    ),
                                    child: const Text('单个重扫'),
                                  ),
                                  OutlinedButton(
                                    onPressed: () => unawaited(
                                      handleDelete(item.path),
                                    ),
                                    child: const Text('删除记录'),
                                  ),
                                ],
                              ),
                            ],
                          );
                        },
                      ),
              ),
              actions: [
                TextButton(
                  onPressed: _savedScanFolders.isEmpty
                      ? null
                      : () => unawaited(handleClearAll()),
                  child: const Text('批量删除全部'),
                ),
                TextButton(
                  onPressed: selectedPaths.isEmpty
                      ? null
                      : () => unawaited(handleDeleteSelected()),
                  child: Text('删除选中(${selectedPaths.length})'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('关闭'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<_SongTagData?> _readSongTag(String filePath) async {
    final String lowerPath = filePath.toLowerCase();
    if (lowerPath.endsWith('.flac')) {
      return _FlacMetadataReader.read(filePath);
    }
    if (!lowerPath.endsWith('.mp3')) {
      return null;
    }
    final List<Tag> tags = await _tagProcessor.getTagsFromByteArray(
      File(filePath).readAsBytes(),
      <TagType>[TagType.id3v2],
    );
    if (tags.isEmpty) {
      return null;
    }
    final Map<String, dynamic> map = tags.first.tags;
    Uint8List? coverBytes;
    final dynamic pictureValue = map['picture'];
    if (pictureValue is Map) {
      for (final dynamic value in pictureValue.values) {
        if (value is AttachedPicture && value.imageData.isNotEmpty) {
          coverBytes = Uint8List.fromList(value.imageData);
          break;
        }
      }
    }
    String lyrics = '';
    final dynamic lyricValue = map['lyrics'];
    if (lyricValue is Map) {
      for (final dynamic value in lyricValue.values) {
        if (value is UnSyncLyric && value.lyrics.trim().isNotEmpty) {
          lyrics = value.lyrics.trim();
          break;
        }
      }
    }
    return _SongTagData(
      title: map['title']?.toString(),
      artist: map['artist']?.toString(),
      album: map['album']?.toString(),
      lyrics: lyrics,
      coverBytes: coverBytes,
    );
  }

  Future<String> _readExternalLyrics(String audioPath) async {
    final int dotIndex = audioPath.lastIndexOf('.');
    if (dotIndex <= 0) {
      return '';
    }
    final String lrcPath = '${audioPath.substring(0, dotIndex)}.lrc';
    final File lrcFile = File(lrcPath);
    if (!await lrcFile.exists()) {
      return '';
    }
    try {
      final String content = await lrcFile.readAsString();
      return content.trim();
    } catch (_) {
      return '';
    }
  }

  List<_TimedLyricLine> _parseLrcToTimedLines(String lrcContent) {
    final String content = lrcContent.trim();
    if (content.isEmpty) {
      return const <_TimedLyricLine>[];
    }

    final RegExp timeRegExp = RegExp(r'\[(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?\]');

    final List<_TimedLyricLine> result = <_TimedLyricLine>[];

    for (final String rawLine in const LineSplitter().convert(content)) {
      final String line = rawLine.trimRight();
      if (line.isEmpty) {
        continue;
      }

      // 跳过纯注释/空壳行（例如 [ti:], [ar:]）
      final Iterable<RegExpMatch> matches = timeRegExp.allMatches(line);
      if (matches.isEmpty) {
        continue;
      }

      // 删除所有时间戳标签，剩下的通常就是歌词文本。
      final String text = line.replaceAll(timeRegExp, '').trim();
      if (text.isEmpty) {
        continue;
      }

      for (final RegExpMatch m in matches) {
        final int minutes = int.tryParse(m.group(1) ?? '') ?? 0;
        final int seconds = int.tryParse(m.group(2) ?? '') ?? 0;
        final String? msGroup = m.group(3);
        int milliseconds = 0;
        if (msGroup != null && msGroup.isNotEmpty) {
          // 将毫秒字段归一到 3 位：.1 -> 100ms, .12 -> 120ms, .123 -> 123ms
          if (msGroup.length == 1) {
            milliseconds = int.parse(msGroup) * 100;
          } else if (msGroup.length == 2) {
            milliseconds = int.parse(msGroup) * 10;
          } else {
            milliseconds = int.parse(msGroup);
          }
        }

        result.add(
          _TimedLyricLine(
            time: Duration(
              minutes: minutes,
              seconds: seconds,
              milliseconds: milliseconds,
            ),
            text: text,
          ),
        );
      }
    }

    result.sort((a, b) => a.time.compareTo(b.time));
    return result;
  }

  Future<bool> _ensureAndroidStoragePermission() async {
    if (!Platform.isAndroid) {
      return true;
    }
    final PermissionStatus audioStatus = await Permission.audio.request();
    if (audioStatus.isGranted) {
      return true;
    }
    final PermissionStatus storageStatus = await Permission.storage.request();
    return storageStatus.isGranted;
  }

  Future<bool> _ensureAndroidFileManagePermission() async {
    if (!Platform.isAndroid) {
      return true;
    }
    try {
      final PermissionStatus manageStatus = await Permission
          .manageExternalStorage
          .request();
      if (manageStatus.isGranted) {
        return true;
      }
    } catch (_) {}
    try {
      final PermissionStatus storageStatus = await Permission.storage.request();
      if (storageStatus.isGranted) {
        return true;
      }
    } catch (_) {}
    try {
      final PermissionStatus audioStatus = await Permission.audio.request();
      return audioStatus.isGranted;
    } catch (_) {
      return false;
    }
  }

  String _resolveInitialFolderBrowserPath(String currentValue) {
    final List<String> candidates = <String>[
      currentValue,
      _scanFolderPath ?? '',
      '/storage/emulated/0',
      '/sdcard',
      '/storage/self/primary',
      '/',
    ];
    for (final String candidate in candidates) {
      final String trimmed = candidate.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      if (Directory(trimmed).existsSync()) {
        return trimmed;
      }
    }
    return '/';
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        await _handleBackAction();
        return false;
      },
      child: Scaffold(
        body: Focus(
          autofocus: true,
          focusNode: _pageFocusNode,
          onKeyEvent: _onKeyEvent,
          child: Container(
            color: TvColors.appBackground,
            child: LayoutBuilder(
              builder: (context, constraints) {
                return Center(
                  child: FittedBox(
                    fit: BoxFit.contain,
                    child: SizedBox(
                      width: 1920,
                      height: 1080,
                      child: Stack(
                        children: [
                          Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [
                                  TvColors.gradientStart,
                                  TvColors.gradientEnd,
                                ],
                              ),
                            ),
                            child: SafeArea(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 40,
                                  vertical: 24,
                                ),
                                child: Column(
                                  children: [
                                    if (!_isLyricsFullscreen) ...[
                                      _TopHeader(
                                        focusedIndex: _focusedMenuIndex,
                                        isTopBarFocused:
                                            _focusedSection ==
                                            _FocusSection.topBar,
                                        statusText: _scanStatusText,
                                        statusOpacity: _statusOpacity,
                                      ),
                                      const SizedBox(height: 24),
                                    ],
                                    Expanded(
                                      child: Stack(
                                        children: [
                                          _isBrowserMode
                                              ? _SongBrowserPanel(
                                                  songs: _browserSongs,
                                                  focusedIndex:
                                                      _focusedBrowserIndex,
                                                  currentPlayingPath:
                                                      _currentSong?.path,
                                                  isFolderMode:
                                                      _activeMenuIndex == 2,
                                                  folderBuckets:
                                                      _folderBuckets,
                                                  openedFolderPath:
                                                      _openedFolderPath,
                                                  showBackCard:
                                                      _activeMenuIndex == 2 &&
                                                      _openedFolderPath != null,
                                                  isFocused:
                                                      _focusedSection ==
                                                      _FocusSection.browser,
                                                )
                                              : _NowPlayingPanel(
                                                  isControlFocused:
                                                      _focusedSection ==
                                                      _FocusSection.controls,
                                                  focusedControlIndex:
                                                      _focusedControlIndex,
                                                  currentSong: _currentSong,
                                                  isPlaying: _isPlaying,
                                                  playbackMode: _playbackMode,
                                                  isLyricsFullscreen:
                                                      _isLyricsFullscreen,
                                                  enableLyricsCoverFullscreenBg:
                                                      _fullscreenLyricsCoverEffectEnabled,
                                                  showFullscreenOverlay:
                                                      _showFullscreenOverlay,
                                                  position: _currentPosition,
                                                  duration: _currentDuration,
                                                ),
                                          if (_isLyricsFullscreen)
                                            Positioned.fill(
                                              child: GestureDetector(
                                                behavior:
                                                    HitTestBehavior.translucent,
                                                onTap: () {
                                                  if (_showFullscreenLyricsFirstHint) {
                                                    _dismissFullscreenLyricsHint();
                                                    return;
                                                  }
                                                  if (_showFullscreenOverlay ||
                                                      _isQueueVisible) {
                                                    return;
                                                  }
                                                  unawaited(
                                                    _togglePlayPause(),
                                                  );
                                                },
                                                onDoubleTapDown:
                                                    (TapDownDetails details) {
                                                  if (_showFullscreenLyricsFirstHint) {
                                                    return;
                                                  }
                                                  if (_showFullscreenOverlay ||
                                                      _isQueueVisible) {
                                                    return;
                                                  }
                                                  final double width =
                                                      MediaQuery.of(context)
                                                          .size
                                                          .width;
                                                  if (details
                                                          .localPosition
                                                          .dx <
                                                      width / 2) {
                                                    unawaited(_playPrevious());
                                                  } else {
                                                    unawaited(_playNext());
                                                  }
                                                },
                                                onVerticalDragEnd:
                                                    (DragEndDetails details) {
                                                  if (_showFullscreenLyricsFirstHint) {
                                                    return;
                                                  }
                                                  if (_showFullscreenOverlay ||
                                                      _isQueueVisible) {
                                                    return;
                                                  }
                                                  final double? v =
                                                      details.primaryVelocity;
                                                  if (v == null) {
                                                    return;
                                                  }
                                                  // 手指上滑：出现播放队列；下滑：出现控制条。
                                                  if (v < -300) {
                                                    setState(() {
                                                      _isQueueVisible = true;
                                                      _setFocusedSection(
                                                        _FocusSection.queue,
                                                      );
                                                    });
                                                  } else if (v > 300) {
                                                    setState(() {
                                                      _showFullscreenOverlay = true;
                                                      _setFocusedSection(
                                                        _FocusSection.controls,
                                                      );
                                                    });
                                                  }
                                                },
                                              ),
                                            ),
                                          if (_isQueueVisible)
                                            Positioned(
                                              right: 24,
                                              top: 24,
                                              bottom: 140,
                                              width: 500,
                                              child: _QueuePanel(
                                                isPanelFocused:
                                                    _focusedSection ==
                                                    _FocusSection.queue,
                                                focusedIndex:
                                                    _focusedQueueIndex,
                                                queueSongs: _queueSongs,
                                                currentPlayingIndex:
                                                    _currentSongIndex,
                                              ),
                                            ),
                                          if (_isLyricsFullscreen &&
                                              _showFullscreenLyricsFirstHint)
                                            Positioned.fill(
                                              child: _FullscreenLyricsHintMask(
                                                onDismiss:
                                                    _dismissFullscreenLyricsHint,
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          if (!_isLyricsFullscreen)
                            Positioned(
                              right: 40,
                              bottom: 18,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xAA111524),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: TvColors.cardBorder,
                                  ),
                                ),
                                child: Text(
                                  '遥控提示: 方向键移动焦点, Enter选择',
                                  style: TextStyle(
                                    color: TvColors.textPrimary
                                        .withValues(alpha: 0.9),
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _FullscreenLyricsHintMask extends StatelessWidget {
  const _FullscreenLyricsHintMask({required this.onDismiss});

  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onDismiss,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.62),
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 48),
              child: Material(
                color: TvColors.card,
                elevation: 12,
                borderRadius: TvRadii.panel,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(40, 36, 40, 32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.touch_app_rounded,
                            color: TvColors.accent,
                            size: 32,
                          ),
                          const SizedBox(width: 12),
                          Text(
                            '全屏歌词操作提示',
                            style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w800,
                              color: TvColors.textPrimary,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 28),
                      _hintLine(
                        '上键',
                        '唤出播放队列',
                      ),
                      const SizedBox(height: 16),
                      _hintLine(
                        '下键',
                        '唤出底部控制浮窗',
                      ),
                      const SizedBox(height: 16),
                      _hintLine(
                        '双击左 / 右键',
                        '切换上一曲 / 下一曲',
                      ),
                      const SizedBox(height: 28),
                      Text(
                        '按确定、返回或触摸空白处关闭',
                        style: TextStyle(
                          fontSize: 18,
                          color: TvColors.textSecondary,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _hintLine(String keyLabel, String description) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: TvColors.panel,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: TvColors.panelBorder),
          ),
          child: Text(
            keyLabel,
            style: TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w700,
              color: TvColors.textPrimary,
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              description,
              style: TextStyle(
                fontSize: 22,
                height: 1.35,
                color: TvColors.textPrimary.withValues(alpha: 0.92),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _TvExitConfirmDialog extends StatefulWidget {
  const _TvExitConfirmDialog();

  @override
  State<_TvExitConfirmDialog> createState() => _TvExitConfirmDialogState();
}

class _TvExitConfirmDialogState extends State<_TvExitConfirmDialog> {
  late final FocusNode _exitButtonFocusNode;

  @override
  void initState() {
    super.initState();
    _exitButtonFocusNode = FocusNode(debugLabel: 'tv_exit_confirm.exit');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _exitButtonFocusNode.requestFocus();
      // Android TV：部分设备首帧 traversal 未完成，再等一帧补一次焦点。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_exitButtonFocusNode.hasFocus) {
          _exitButtonFocusNode.requestFocus();
        }
      });
    });
  }

  @override
  void dispose() {
    _exitButtonFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async => false,
      child: Focus(
        canRequestFocus: false,
        descendantsAreFocusable: true,
        skipTraversal: true,
        onKeyEvent: (FocusNode node, KeyEvent event) {
          final LogicalKeyboardKey key = event.logicalKey;
          if (key == LogicalKeyboardKey.escape ||
              key == LogicalKeyboardKey.goBack ||
              key == LogicalKeyboardKey.browserBack) {
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: AlertDialog(
          backgroundColor: TvColors.card,
          title: const Text('退出 AC Music'),
          content: const Text('确定要退出 AC Music 吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            TextButton(
              focusNode: _exitButtonFocusNode,
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('退出'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScanProgressDialog extends StatelessWidget {
  const _ScanProgressDialog({required this.progress});

  final ValueNotifier<_ScanProgressState> progress;

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async => false,
      child: AlertDialog(
        backgroundColor: TvColors.card,
        title: const Text('正在扫描音乐库'),
        content: ValueListenableBuilder<_ScanProgressState>(
          valueListenable: progress,
          builder: (BuildContext context, _ScanProgressState state, _) {
            return SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    state.total > 0
                        ? '进度：${state.processed} / ${state.total}'
                        : '正在统计歌曲总数...',
                  ),
                  const SizedBox(height: 12),
                  LinearProgressIndicator(
                    minHeight: 6,
                    value: state.total > 0 ? state.progress : null,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '当前歌曲：${state.currentSong}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: TvColors.textSecondary),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ScanProgressState {
  const _ScanProgressState({
    required this.total,
    required this.processed,
    required this.currentSong,
  });

  const _ScanProgressState.preparing()
    : total = 0,
      processed = 0,
      currentSong = '准备扫描...';

  final int total;
  final int processed;
  final String currentSong;

  double get progress {
    if (total <= 0) {
      return 0;
    }
    return (processed / total).clamp(0, 1);
  }
}

class _ScanResult {
  const _ScanResult({required this.songs, required this.statusText});

  final List<_LocalSong> songs;
  final String statusText;
}

class _SavedScanFolder {
  const _SavedScanFolder({
    required this.path,
    required this.songCount,
    required this.scannedAt,
    required this.snapshot,
  });

  final String path;
  final int songCount;
  final DateTime scannedAt;
  final _FolderSnapshot snapshot;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'path': path,
      'songCount': songCount,
      'scannedAt': scannedAt.toIso8601String(),
      'snapshot': snapshot.toJson(),
    };
  }

  factory _SavedScanFolder.fromJson(Map<String, dynamic> json) {
    final String rawTime = json['scannedAt']?.toString() ?? '';
    final DateTime scannedAt =
        DateTime.tryParse(rawTime) ?? DateTime.fromMillisecondsSinceEpoch(0);
    return _SavedScanFolder(
      path: json['path']?.toString() ?? '',
      songCount: int.tryParse(json['songCount']?.toString() ?? '0') ?? 0,
      scannedAt: scannedAt,
      snapshot: _FolderSnapshot.fromJson(
        Map<String, dynamic>.from(
          (json['snapshot'] is Map)
              ? (json['snapshot'] as Map)
              : const <String, dynamic>{},
        ),
      ),
    );
  }
}

class _FolderSnapshot {
  const _FolderSnapshot({
    required this.audioFileCount,
    required this.latestModifiedMs,
  });

  final int audioFileCount;
  final int latestModifiedMs;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'audioFileCount': audioFileCount,
      'latestModifiedMs': latestModifiedMs,
    };
  }

  factory _FolderSnapshot.fromJson(Map<String, dynamic> json) {
    return _FolderSnapshot(
      audioFileCount:
          int.tryParse(json['audioFileCount']?.toString() ?? '0') ?? 0,
      latestModifiedMs:
          int.tryParse(json['latestModifiedMs']?.toString() ?? '0') ?? 0,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is _FolderSnapshot &&
        other.audioFileCount == audioFileCount &&
        other.latestModifiedMs == latestModifiedMs;
  }

  @override
  int get hashCode => Object.hash(audioFileCount, latestModifiedMs);
}

class _FolderBucket {
  const _FolderBucket({
    required this.folderPath,
    required this.displayName,
    required this.songs,
  });

  final String folderPath;
  final String displayName;
  final List<_LocalSong> songs;
}

class _HeaderAction {
  const _HeaderAction({required this.icon, required this.label});

  final IconData icon;
  final String label;
}

class _TopHeader extends StatelessWidget {
  const _TopHeader({
    required this.focusedIndex,
    required this.isTopBarFocused,
    required this.statusText,
    required this.statusOpacity,
  });

  final int focusedIndex;
  final bool isTopBarFocused;
  final String statusText;
  final double statusOpacity;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Text(
          'AC Music TV',
          style: TextStyle(
            fontSize: 36,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(width: 20),
        Expanded(
          child: Row(
            children: [
              for (int i = 0; i < _menuTitles.length; i++) ...[
                _TopBarItem(
                  icon: _menuIcons[i],
                  label: _menuTitles[i],
                  selected: focusedIndex == i,
                  focused: isTopBarFocused && focusedIndex == i,
                ),
                if (i != _menuTitles.length - 1) const SizedBox(width: 12),
              ],
            ],
          ),
        ),
        Expanded(
          child: Center(
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 500),
              opacity: statusOpacity,
              child: Text(
                statusText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: TvColors.textSecondary),
              ),
            ),
          ),
        ),
        const SizedBox(width: 16),
        Row(
          children: [
            for (int i = 0; i < _headerActions.length; i++) ...[
              _TopBarItem(
                icon: _headerActions[i].icon,
                label: _headerActions[i].label,
                selected: focusedIndex == _menuTitles.length + i,
                focused:
                    isTopBarFocused && focusedIndex == _menuTitles.length + i,
              ),
              if (i != _headerActions.length - 1) const SizedBox(width: 12),
            ],
          ],
        ),
      ],
    );
  }
}

class _TimedLyricLine {
  const _TimedLyricLine({required this.time, required this.text});

  final Duration time;
  final String text;
}

class _LyricsScroller extends StatefulWidget {
  const _LyricsScroller({
    required this.rawLyrics,
    required this.timedLyrics,
    required this.activeIndex,
    this.visibleLineCount = 7,
    this.fullscreen = false,
    this.usePureWhiteWhenFullscreenCoverEffect = false,
  });

  final String rawLyrics;
  final List<_TimedLyricLine> timedLyrics;
  final int activeIndex;
  final int visibleLineCount;
  final bool fullscreen;
  final bool usePureWhiteWhenFullscreenCoverEffect;

  @override
  State<_LyricsScroller> createState() => _LyricsScrollerState();
}

class _LyricsScrollerState extends State<_LyricsScroller> {
  final ScrollController _controller = ScrollController();
  int _lastActiveIndex = -1;

  double get _itemExtent => widget.fullscreen ? 86.0 : 40.0;

  @override
  void didUpdateWidget(covariant _LyricsScroller oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.activeIndex == _lastActiveIndex) {
      return;
    }
    _lastActiveIndex = widget.activeIndex;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_controller.hasClients) {
        return;
      }
      _scrollToActive();
    });
  }

  void _scrollToActive() {
    if (!widget.timedLyrics.isNotEmpty) {
      return;
    }
    final int clampedIndex = widget.activeIndex.clamp(
      0,
      widget.timedLyrics.length - 1,
    );
    final int centerLine = widget.visibleLineCount ~/ 2;
    final double target = (clampedIndex - centerLine) * _itemExtent;
    final double max = _controller.position.maxScrollExtent;
    _controller.animateTo(
      target.clamp(0.0, max),
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool isLight = Theme.of(context).brightness == Brightness.light;
    final Color baseLyricColor =
        widget.usePureWhiteWhenFullscreenCoverEffect
            ? Colors.white
            : (isLight ? const Color(0xFF475A87) : TvColors.textSecondary);
    if (widget.timedLyrics.isEmpty) {
      return Text(
        widget.rawLyrics,
        maxLines: widget.visibleLineCount,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: widget.fullscreen ? 36 : 24,
          color: baseLyricColor,
          fontStyle: FontStyle.italic,
          height: widget.fullscreen ? 1.5 : 1.25,
        ),
      );
    }

    final int active = widget.activeIndex.clamp(
      0,
      widget.timedLyrics.length - 1,
    );

    return SizedBox(
      height: _itemExtent * widget.visibleLineCount,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: ListView.builder(
          controller: _controller,
          itemExtent: _itemExtent,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: widget.timedLyrics.length,
          itemBuilder: (BuildContext context, int i) {
            final _TimedLyricLine line = widget.timedLyrics[i];
            final bool isActive = i == active;
            final int distance = (i - active).abs();
            final double opacity = widget.fullscreen
                ? switch (distance) {
                    0 => 1.0,
                    1 => 0.72,
                    2 => 0.46,
                    3 => 0.28,
                    _ => 0.16,
                  }
                : (isActive ? 1.0 : 0.58);
            final Color color = baseLyricColor.withValues(alpha: opacity);

            return Center(
              child: Text(
                line.text.replaceAll('\n', ' ').trim(),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: widget.fullscreen
                      ? (isActive ? 52 : 38)
                      : (isActive ? 30 : 24),
                  color: color,
                  fontStyle: FontStyle.italic,
                  fontWeight: isActive ? FontWeight.w800 : FontWeight.w400,
                  height: widget.fullscreen ? 1.65 : 1.15,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _NowPlayingPanel extends StatelessWidget {
  const _NowPlayingPanel({
    required this.isControlFocused,
    required this.focusedControlIndex,
    required this.currentSong,
    required this.isPlaying,
    required this.playbackMode,
    required this.isLyricsFullscreen,
    required this.enableLyricsCoverFullscreenBg,
    required this.showFullscreenOverlay,
    required this.position,
    required this.duration,
  });

  final bool isControlFocused;
  final int focusedControlIndex;
  final _LocalSong? currentSong;
  final bool isPlaying;
  final _PlaybackMode playbackMode;
  final bool isLyricsFullscreen;
  final bool enableLyricsCoverFullscreenBg;
  final bool showFullscreenOverlay;
  final Duration position;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final _LocalSong? song = currentSong;
    final String rawLyrics = (song?.lyrics.trim().isNotEmpty ?? false)
        ? song!.lyrics
        : '未读取到内嵌歌词';
    final List<_TimedLyricLine> timedLyrics =
        song?.timedLyrics ?? const <_TimedLyricLine>[];

    int activeIndex = 0;
    if (timedLyrics.isNotEmpty) {
      for (int i = 0; i < timedLyrics.length; i++) {
        if (timedLyrics[i].time <= position) {
          activeIndex = i;
        } else {
          break;
        }
      }
    }

    if (isLyricsFullscreen) {
      return Container(
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          color: TvColors.panel.withValues(alpha: 0.92),
          borderRadius: TvRadii.panel,
          border: Border.all(color: TvColors.panelBorder),
        ),
        child: Stack(
          children: [
            if (enableLyricsCoverFullscreenBg)
              Positioned.fill(
                child: _FullscreenLyricsCoverBackground(
                  song: currentSong,
                  isPlaying: isPlaying,
                ),
              ),
            Row(
              children: [
                if (!showFullscreenOverlay) ...[
                  SizedBox(
                    width: 250,
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            currentSong?.title ?? '未选择歌曲',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 30,
                              fontWeight: FontWeight.w800,
                              color: TvColors.textPrimary,
                              height: 1.15,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            currentSong?.artist ?? '未知歌手',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              color: TvColors.textSecondary,
                            ),
                          ),
                          const SizedBox(height: 18),
                          _RotatingCoverArt(
                            song: currentSong,
                            size: 168,
                            isPlaying: isPlaying,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 18),
                ],
                Expanded(
                  child: Center(
                    child: _LyricsScroller(
                      rawLyrics: rawLyrics,
                      timedLyrics: timedLyrics,
                      activeIndex: activeIndex,
                      visibleLineCount: 13,
                      fullscreen: true,
                      usePureWhiteWhenFullscreenCoverEffect:
                          enableLyricsCoverFullscreenBg,
                    ),
                  ),
                ),
              ],
            ),
            if (showFullscreenOverlay)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        const Color(0xE6171C2A),
                        const Color(0x99171C2A),
                        const Color(0x00171C2A),
                      ],
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          _CoverArt(song: currentSong, size: 180),
                          const SizedBox(width: 20),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  currentSong?.title ?? '未选择歌曲',
                                  style: const TextStyle(
                                    fontSize: 36,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  currentSong?.artist ?? '未知歌手',
                                  style: TextStyle(
                                    fontSize: 22,
                                    color: TvColors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      _PlayerControlBar(
                        isControlFocused: isControlFocused,
                        focusedControlIndex: focusedControlIndex,
                        isPlaying: isPlaying,
                        playbackMode: playbackMode,
                        isFullscreen: true,
                        position: position,
                        duration: duration,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: TvColors.panel.withValues(alpha: 0.9),
        borderRadius: TvRadii.panel,
        border: Border.all(color: TvColors.panelBorder),
      ),
      child: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                Expanded(
                  flex: 4,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        currentSong?.title ?? '未选择歌曲',
                        style: const TextStyle(
                          fontSize: 46,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        currentSong?.artist ?? '未知歌手',
                        style: TextStyle(
                          fontSize: 26,
                          color: TvColors.textIndex,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Expanded(
                        child: LayoutBuilder(
                          builder:
                              (
                                BuildContext context,
                                BoxConstraints constraints,
                              ) {
                                final double coverSize =
                                    (constraints.maxHeight * 0.62).clamp(
                                      220.0,
                                      320.0,
                                    );
                                return Align(
                                  alignment: Alignment.center,
                                  child: _CoverArt(
                                    song: currentSong,
                                    size: coverSize,
                                  ),
                                );
                              },
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 28),
                Expanded(
                  flex: 6,
                  child: Column(
                    children: [
                      Expanded(
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 8,
                          ),
                          child: Center(
                            child: _LyricsScroller(
                              rawLyrics: rawLyrics,
                              timedLyrics: timedLyrics,
                              activeIndex: activeIndex,
                              visibleLineCount: 11,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 26),
          _PlayerControlBar(
            isControlFocused: isControlFocused,
            focusedControlIndex: focusedControlIndex,
            isPlaying: isPlaying,
            playbackMode: playbackMode,
            isFullscreen: false,
            position: position,
            duration: duration,
          ),
        ],
      ),
    );
  }
}

class _QueuePanel extends StatefulWidget {
  const _QueuePanel({
    required this.isPanelFocused,
    required this.focusedIndex,
    required this.queueSongs,
    required this.currentPlayingIndex,
  });

  final bool isPanelFocused;
  final int focusedIndex;
  final List<_LocalSong> queueSongs;
  final int currentPlayingIndex;

  @override
  State<_QueuePanel> createState() => _QueuePanelState();
}

class _QueuePanelState extends State<_QueuePanel> {
  static const double _queueItemExtent = 82.0;
  final ScrollController _controller = ScrollController();
  int _lastCenteredIndex = -1;
  bool _lastFocusedState = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _QueuePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.isPanelFocused) {
      _lastFocusedState = false;
      return;
    }
    final bool focusJustActivated =
        !oldWidget.isPanelFocused && widget.isPanelFocused;
    if (!focusJustActivated &&
        widget.focusedIndex == oldWidget.focusedIndex &&
        widget.queueSongs.length == oldWidget.queueSongs.length) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToFocused();
    });
  }

  void _scrollToFocused() {
    if (!_controller.hasClients) {
      return;
    }
    final int itemCount = widget.queueSongs.length;
    final int index = itemCount <= 0 ? 0 : widget.focusedIndex.clamp(0, itemCount - 1);
    _lastCenteredIndex = index;
    _lastFocusedState = widget.isPanelFocused;
    // 焦点项尚未构建时，按索引估算位置兜底滚动，确保队列跟随焦点移动。
    final double viewport = _controller.position.viewportDimension;
    final double desired =
        (index * _queueItemExtent) - ((viewport - _queueItemExtent) / 2);
    final double clamped = desired.clamp(
      0.0,
      _controller.position.maxScrollExtent,
    );
    _controller.animateTo(
      clamped,
      duration: const Duration(milliseconds: 170),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: TvColors.panel.withValues(alpha: 0.9),
        borderRadius: TvRadii.panel,
        border: Border.all(color: TvColors.panelBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionTitle('播放队列'),
          const SizedBox(height: 16),
          Expanded(
            child: widget.queueSongs.isEmpty
                ? Center(
                    child: Text(
                      '当前目录未扫描到可用歌曲',
                      style: TextStyle(fontSize: 15, color: TvColors.textSecondary),
                    ),
                  )
                : LayoutBuilder(
                    builder: (BuildContext context, BoxConstraints _) {
                          if (widget.isPanelFocused &&
                              widget.queueSongs.isNotEmpty &&
                              (_lastCenteredIndex != widget.focusedIndex ||
                                  !_lastFocusedState)) {
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              _scrollToFocused();
                            });
                          }
                          return ListView.builder(
                            controller: _controller,
                            itemExtent: _queueItemExtent,
                            itemCount: widget.queueSongs.length,
                            itemBuilder: (BuildContext context, int i) {
                              return _QueueItem(
                                index: i + 1,
                                title: widget.queueSongs[i].title,
                                artist: widget.queueSongs[i].artist,
                                active: widget.focusedIndex == i,
                                focused:
                                    widget.isPanelFocused &&
                                    widget.focusedIndex == i,
                                playing: widget.currentPlayingIndex == i,
                              );
                            },
                          );
                        },
                  ),
          ),
        ],
      ),
    );
  }
}

class _SongBrowserPanel extends StatefulWidget {
  const _SongBrowserPanel({
    required this.songs,
    required this.focusedIndex,
    required this.currentPlayingPath,
    required this.isFolderMode,
    required this.folderBuckets,
    required this.openedFolderPath,
    required this.showBackCard,
    required this.isFocused,
  });

  final List<_LocalSong> songs;
  final int focusedIndex;
  final String? currentPlayingPath;
  final bool isFolderMode;
  final List<_FolderBucket> folderBuckets;
  final String? openedFolderPath;
  final bool showBackCard;
  final bool isFocused;

  @override
  State<_SongBrowserPanel> createState() => _SongBrowserPanelState();
}

class _SongBrowserPanelState extends State<_SongBrowserPanel> {
  static const int _pageSize = 24;
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _focusedItemKey = GlobalKey();
  int _lastCenteredIndex = -1;
  bool _lastCenteredFolderMode = false;
  int _lastCenteredPage = -1;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _SongBrowserPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.isFocused || _displaySongs.isEmpty) {
      return;
    }
    if (oldWidget.focusedIndex != widget.focusedIndex ||
        oldWidget.songs.length != widget.songs.length ||
        oldWidget.isFolderMode != widget.isFolderMode ||
        oldWidget.openedFolderPath != widget.openedFolderPath) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _centerFocusedItem();
      });
    }
  }

  int get _currentPage => (widget.focusedIndex ~/ _pageSize).clamp(
    0,
    _displaySongs.isEmpty ? 0 : (_displaySongs.length - 1) ~/ _pageSize,
  );

  List<_LocalSong> get _displaySongs {
    if (!widget.showBackCard) {
      return widget.songs;
    }
    return <_LocalSong>[
      const _LocalSong(
        path: '__back__',
        title: '返回上级',
        artist: '返回文件夹列表',
        album: '',
        lyrics: '',
        timedLyrics: <_TimedLyricLine>[],
        coverBytes: null,
      ),
      ...widget.songs,
    ];
  }

  void _centerFocusedItem() {
    if (_lastCenteredIndex == widget.focusedIndex &&
        _lastCenteredFolderMode == widget.isFolderMode &&
        _lastCenteredPage == _currentPage) {
      return;
    }
    final BuildContext? targetContext = _focusedItemKey.currentContext;
    if (targetContext == null) {
      return;
    }
    _lastCenteredIndex = widget.focusedIndex;
    _lastCenteredFolderMode = widget.isFolderMode;
    _lastCenteredPage = _currentPage;
    Scrollable.ensureVisible(
      targetContext,
      alignment: 0.5,
      duration: const Duration(milliseconds: 170),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isFocused &&
        (widget.songs.isNotEmpty || widget.showBackCard)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _centerFocusedItem();
      });
    }
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: TvColors.panel.withValues(alpha: 0.9),
        borderRadius: TvRadii.panel,
        border: Border.all(color: TvColors.panelBorder),
      ),
      child: (widget.isFolderMode && widget.openedFolderPath == null)
          ? _buildFolderCards()
          : _displaySongs.isEmpty
          ? Center(
              child: Text(
                '当前目录未扫描到可用歌曲',
                style: TextStyle(fontSize: 18, color: TvColors.textSecondary),
              ),
            )
          : ListView(
              controller: _scrollController,
              children: _buildPagedSongsChildren(),
            ),
    );
  }

  Widget _buildFolderCards() {
    if (widget.folderBuckets.isEmpty) {
      return Center(
        child: Text(
          '当前目录没有可用文件夹',
          style: TextStyle(fontSize: 18, color: TvColors.textSecondary),
        ),
      );
    }
    return ListView(
      controller: _scrollController,
      children: [
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final double itemWidth = (constraints.maxWidth - 32) / 3;
            return Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                for (int i = 0; i < widget.folderBuckets.length; i++)
                  SizedBox(
                    width: itemWidth,
                    child: _FolderCardTile(
                      key: widget.isFocused && i == widget.focusedIndex
                          ? _focusedItemKey
                          : null,
                      name: widget.folderBuckets[i].displayName,
                      count: widget.folderBuckets[i].songs.length,
                      focused: widget.isFocused && i == widget.focusedIndex,
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  List<Widget> _buildPagedSongsChildren() {
    final List<_LocalSong> displaySongs = _displaySongs;
    final int totalPages = displaySongs.isEmpty
        ? 1
        : ((displaySongs.length - 1) ~/ _pageSize) + 1;
    final int page = _currentPage;
    final int start = page * _pageSize;
    final int end = (start + _pageSize).clamp(0, displaySongs.length);
    final List<_LocalSong> pageSongs = displaySongs.sublist(start, end);
    return <Widget>[
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(
          '第 ${page + 1} / $totalPages 页  ·  共 ${displaySongs.length} 项',
          style: TextStyle(fontSize: 13, color: TvColors.textSecondary),
        ),
      ),
      LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double itemWidth = (constraints.maxWidth - 32) / 3;
          return Wrap(
            spacing: 16,
            runSpacing: 16,
            children: [
              for (int i = 0; i < pageSongs.length; i++)
                SizedBox(
                  width: itemWidth,
                  child: widget.showBackCard && (start + i) == 0
                      ? _BackFolderCardTile(
                          key: widget.isFocused && widget.focusedIndex == 0
                              ? _focusedItemKey
                              : null,
                          focused: widget.isFocused && widget.focusedIndex == 0,
                        )
                      : _SongCardTile(
                          key: widget.isFocused &&
                                  (start + i) == widget.focusedIndex
                              ? _focusedItemKey
                              : null,
                          song: pageSongs[i],
                          focused:
                              widget.isFocused &&
                              (start + i) == widget.focusedIndex,
                          playing:
                              pageSongs[i].path == widget.currentPlayingPath,
                          showCover: true,
                        ),
                ),
            ],
          );
        },
      ),
    ];
  }
}

class _SongCardTile extends StatelessWidget {
  const _SongCardTile({
    super.key,
    required this.song,
    required this.focused,
    required this.playing,
    this.showCover = true,
  });

  final _LocalSong song;
  final bool focused;
  final bool playing;
  final bool showCover;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: TvMotion.fast,
      curve: TvMotion.curve,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: playing ? TvColors.cardActive : TvColors.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: focused
              ? TvColors.focusBorder
              : (playing ? TvColors.cardActiveBorder : TvColors.cardBorder),
          width: focused ? 3.4 : 1,
        ),
        boxShadow: focused
            ? const [
                BoxShadow(
                  color: Color(0x66364D9F),
                  blurRadius: 18,
                  offset: Offset(0, 6),
                ),
              ]
            : null,
      ),
      child: Row(
        children: [
          _CoverArt(song: showCover ? song : null, size: 72),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  song.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: TvColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  song.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    color: TvColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Icon(
            playing ? Icons.graphic_eq_rounded : Icons.chevron_right_rounded,
            color: TvColors.textTertiary,
            size: 26,
          ),
        ],
      ),
    );
  }
}

class _FolderCardTile extends StatelessWidget {
  const _FolderCardTile({
    super.key,
    required this.name,
    required this.count,
    required this.focused,
  });

  final String name;
  final int count;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: TvMotion.fast,
      curve: TvMotion.curve,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: TvColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: focused ? TvColors.focusBorder : TvColors.cardBorder,
          width: focused ? 2.4 : 1,
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.folder_rounded, color: TvColors.textPrimary, size: 30),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 18,
                    color: TvColors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$count 首歌曲',
                  style: TextStyle(fontSize: 13, color: TvColors.textSecondary),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, color: TvColors.textTertiary),
        ],
      ),
    );
  }
}

class _BackFolderCardTile extends StatelessWidget {
  const _BackFolderCardTile({super.key, required this.focused});

  final bool focused;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: TvMotion.fast,
      curve: TvMotion.curve,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: TvColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: focused ? TvColors.focusBorder : TvColors.cardBorder,
          width: focused ? 2.4 : 1,
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.arrow_back_rounded, color: TvColors.textPrimary, size: 28),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '返回上级',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 18,
                    color: TvColors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  '回到文件夹列表',
                  style: TextStyle(fontSize: 13, color: TvColors.textSecondary),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_left_rounded, color: TvColors.textTertiary),
        ],
      ),
    );
  }
}

class _FullscreenLyricsCoverBackground extends StatefulWidget {
  const _FullscreenLyricsCoverBackground({
    required this.song,
    required this.isPlaying,
  });

  final _LocalSong? song;
  final bool isPlaying;

  @override
  State<_FullscreenLyricsCoverBackground> createState() =>
      _FullscreenLyricsCoverBackgroundState();
}

class _FullscreenLyricsCoverBackgroundState
    extends State<_FullscreenLyricsCoverBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 22),
    )..repeat();
  }

  @override
  void didUpdateWidget(covariant _FullscreenLyricsCoverBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isPlaying == widget.isPlaying) {
      return;
    }
    if (widget.isPlaying) {
      _controller.repeat();
    } else {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final _LocalSong? song = widget.song;
    final Size screenSize = MediaQuery.of(context).size;
    final double dpr = MediaQuery.of(context).devicePixelRatio;
    final double maxSide =
        screenSize.width > screenSize.height ? screenSize.width : screenSize.height;
    final int cacheEdge = (maxSide * dpr).round().clamp(240, 1100);

    final Widget cover = song?.coverBytes == null
        ? const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[
                  Color(0x33171C2A),
                  Color(0x00171C2A),
                ],
              ),
            ),
          )
        : Image.memory(
            song!.coverBytes!,
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            cacheWidth: cacheEdge,
            cacheHeight: cacheEdge,
          );

    const double blurSigma = 26;
    const double opacity = 0.65;

    final Widget blurred = ImageFiltered(
      imageFilter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
      child: SizedBox.expand(child: cover),
    );

    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (BuildContext context, Widget? child) {
          const double pi = 3.141592653589793;
          final double angle = _controller.value * 2 * pi;
          return Opacity(
            opacity: opacity,
            child: Transform.rotate(
              angle: angle,
              child: Transform.scale(
                // 进一步加大缩放，确保旋转到任意角度时都不露边。
                scale: 2.0,
                child: child,
              ),
            ),
          );
        },
        child: blurred,
      ),
    );
  }
}

class _SearchPage extends StatefulWidget {
  const _SearchPage({required this.songs, required this.onSongSelected});

  final List<_LocalSong> songs;
  final Future<void> Function(int index) onSongSelected;

  @override
  State<_SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<_SearchPage> {
  static const List<String> _letters = <String>[
    'A',
    'B',
    'C',
    'D',
    'E',
    'F',
    'G',
    'H',
    'I',
    'J',
    'K',
    'L',
    'M',
    'N',
    'O',
    'P',
    'Q',
    'R',
    'S',
    'T',
    'U',
    'V',
    'W',
    'X',
    'Y',
    'Z',
  ];

  final TextEditingController _controller = TextEditingController();
  int _focusedLetterIndex = 0;
  int _focusedResultIndex = 0;
  _FocusSection _focusSection = _FocusSection.browser;
  static const int _letterColumns = 2;

  List<int> get _filteredIndices {
    final String query = _controller.text.trim().toLowerCase();
    if (query.isEmpty) {
      return List<int>.generate(widget.songs.length, (int i) => i);
    }
    final List<int> indices = <int>[];
    for (int i = 0; i < widget.songs.length; i++) {
      final _LocalSong song = widget.songs[i];
      final String haystack = '${song.title} ${song.artist}'.toLowerCase();
      final String initials = _toPinyinInitials('${song.title} ${song.artist}');
      if (haystack.contains(query) || initials.contains(query)) {
        indices.add(i);
      }
    }
    return indices;
  }

  String _toPinyinInitials(String text) {
    final String shortPinyin = PinyinHelper.getShortPinyin(text)
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '');
    return shortPinyin;
  }

  @override
  Widget build(BuildContext context) {
    final List<int> filtered = _filteredIndices;
    _focusedResultIndex = _focusedResultIndex.clamp(
      0,
      filtered.isEmpty ? 0 : filtered.length - 1,
    );

    return Scaffold(
      body: Focus(
        autofocus: true,
        onKeyEvent: (FocusNode node, KeyEvent event) {
          if (event is! KeyDownEvent) {
            return KeyEventResult.ignored;
          }
          final LogicalKeyboardKey key = event.logicalKey;
          if (key == LogicalKeyboardKey.escape) {
            Navigator.of(context).pop();
            return KeyEventResult.handled;
          }
          setState(() {
            if (key == LogicalKeyboardKey.arrowLeft) {
              if (_focusSection == _FocusSection.browser) {
                _focusedLetterIndex = (_focusedLetterIndex - 1).clamp(
                  0,
                  _letters.length - 1,
                );
              } else {
                _focusSection = _FocusSection.browser;
              }
            } else if (key == LogicalKeyboardKey.arrowRight) {
              if (_focusSection == _FocusSection.browser) {
                final int nextIndex = (_focusedLetterIndex + 1).clamp(
                  0,
                  _letters.length - 1,
                );
                if ((_focusedLetterIndex % _letterColumns) ==
                        _letterColumns - 1 ||
                    nextIndex == _focusedLetterIndex) {
                  _focusSection = _FocusSection.queue;
                } else {
                  _focusedLetterIndex = nextIndex;
                }
              } else {
                _focusSection = _FocusSection.queue;
              }
            } else if (key == LogicalKeyboardKey.arrowUp) {
              if (_focusSection == _FocusSection.browser) {
                _focusedLetterIndex = (_focusedLetterIndex - _letterColumns)
                    .clamp(0, _letters.length - 1);
              } else {
                _focusedResultIndex = (_focusedResultIndex - 1).clamp(
                  0,
                  filtered.isEmpty ? 0 : filtered.length - 1,
                );
              }
            } else if (key == LogicalKeyboardKey.arrowDown) {
              if (_focusSection == _FocusSection.browser) {
                _focusedLetterIndex = (_focusedLetterIndex + _letterColumns)
                    .clamp(0, _letters.length - 1);
              } else {
                _focusedResultIndex = (_focusedResultIndex + 1).clamp(
                  0,
                  filtered.isEmpty ? 0 : filtered.length - 1,
                );
              }
            } else if (key == LogicalKeyboardKey.enter ||
                key == LogicalKeyboardKey.select) {
              if (_focusSection == _FocusSection.browser) {
                _controller.text = _letters[_focusedLetterIndex];
              } else if (filtered.isNotEmpty) {
                unawaited(widget.onSongSelected(filtered[_focusedResultIndex]));
              }
            }
          });
          return KeyEventResult.handled;
        },
        child: Container(
          color: TvColors.appBackground,
          padding: const EdgeInsets.all(28),
          child: Row(
            children: [
              Container(
                width: 120,
                decoration: BoxDecoration(
                  color: TvColors.panel.withValues(alpha: 0.9),
                  borderRadius: TvRadii.panel,
                  border: Border.all(color: TvColors.panelBorder),
                ),
                child: GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: _letterColumns,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 1.2,
                  ),
                  itemCount: _letters.length,
                  itemBuilder: (BuildContext context, int i) {
                    final bool focused =
                        _focusSection == _FocusSection.browser &&
                        i == _focusedLetterIndex;
                    return AnimatedContainer(
                      duration: TvMotion.fast,
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      decoration: BoxDecoration(
                        color: focused
                            ? TvColors.accent
                            : TvColors.card,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Center(
                        child: Text(
                          _letters[i],
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(width: 24),
              Expanded(
                child: Column(
                  children: [
                    TextField(
                      controller: _controller,
                      onChanged: (_) => setState(() {
                        _focusedResultIndex = 0;
                      }),
                      decoration: const InputDecoration(
                        hintText: '输入歌名或歌手，可配合遥控器语音输入',
                        border: OutlineInputBorder(),
                        filled: true,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Expanded(
                      child: filtered.isEmpty
                          ? const Center(child: Text('未找到匹配歌曲'))
                          : GridView.builder(
                              gridDelegate:
                                  const SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: 3,
                                    mainAxisSpacing: 16,
                                    crossAxisSpacing: 16,
                                    childAspectRatio: 3.15,
                                  ),
                              itemCount: filtered.length,
                              itemBuilder: (BuildContext context, int i) {
                                final _LocalSong song =
                                    widget.songs[filtered[i]];
                                return _SongCardTile(
                                  song: song,
                                  focused:
                                      _focusSection == _FocusSection.queue &&
                                      i == _focusedResultIndex,
                                  playing: false,
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CoverArt extends StatelessWidget {
  const _CoverArt({required this.song, this.size});

  final _LocalSong? song;
  final double? size;

  @override
  Widget build(BuildContext context) {
    final double dpr = MediaQuery.of(context).devicePixelRatio;
    final int cacheEdge = ((size ?? 220) * dpr).round().clamp(80, 1024);
    final Widget content = song?.coverBytes == null
        ? Icon(Icons.album_rounded, size: 200, color: TvColors.textSecondary)
        : Image.memory(
            song!.coverBytes!,
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            cacheWidth: cacheEdge,
            cacheHeight: cacheEdge,
          );
    final Widget child = ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: Container(
        width: size,
        height: size,
        color: TvColors.card,
        child: Center(child: content),
      ),
    );
    if (size == null) {
      return child;
    }
    return SizedBox(width: size, height: size, child: child);
  }
}

class _RotatingCoverArt extends StatefulWidget {
  const _RotatingCoverArt({
    required this.song,
    required this.size,
    required this.isPlaying,
  });

  final _LocalSong? song;
  final double size;
  final bool isPlaying;

  @override
  State<_RotatingCoverArt> createState() => _RotatingCoverArtState();
}

class _RotatingCoverArtState extends State<_RotatingCoverArt>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    )..repeat();
  }

  @override
  void didUpdateWidget(covariant _RotatingCoverArt oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isPlaying == widget.isPlaying) {
      return;
    }
    if (widget.isPlaying) {
      _controller.repeat();
    } else {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final _LocalSong? song = widget.song;
    final double size = widget.size;
    final double dpr = MediaQuery.of(context).devicePixelRatio;
    final int cacheEdge = (size * dpr).round().clamp(120, 1024);
    final Widget image = song?.coverBytes == null
        ? Icon(
            Icons.album_rounded,
            size: size * 0.55,
            color: TvColors.textSecondary,
          )
        : Image.memory(
            song!.coverBytes!,
            fit: BoxFit.cover,
            width: size,
            height: size,
            cacheWidth: cacheEdge,
            cacheHeight: cacheEdge,
          );
    return RotationTransition(
      turns: _controller,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: const [
            BoxShadow(
              color: Color(0x6A000000),
              blurRadius: 18,
              offset: Offset(0, 10),
            ),
          ],
        ),
        child: ClipOval(
          child: Container(
            color: TvColors.card,
            child: Center(child: image),
          ),
        ),
      ),
    );
  }
}

class _PlayerControlBar extends StatelessWidget {
  const _PlayerControlBar({
    required this.isControlFocused,
    required this.focusedControlIndex,
    required this.isPlaying,
    required this.playbackMode,
    required this.isFullscreen,
    required this.position,
    required this.duration,
  });

  final bool isControlFocused;
  final int focusedControlIndex;
  final bool isPlaying;
  final _PlaybackMode playbackMode;
  final bool isFullscreen;
  final Duration position;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final Size screenSize = MediaQuery.of(context).size;
    final double shortestSide =
        screenSize.width < screenSize.height ? screenSize.width : screenSize.height;
    // 目标：720p/9寸车机屏触控更友好（放大到更好点的触控面积）。
    final double touchScale = shortestSide <= 720
        ? 1.2
        : (shortestSide <= 800 ? 1.1 : 1.0);
    final double buttonGap = 14 * touchScale;
    final double smallCircleSize = 54 * touchScale;
    final double bigCircleSize = 66 * touchScale;
    final double playSize = 78 * touchScale;
    final double playIconSize = 42 * touchScale;

    return Column(
      children: [
        Row(
          children: [
            Text(
              _formatDuration(position),
              style: TextStyle(
                color: TvColors.textSecondary,
                fontSize: 16 * touchScale,
              ),
            ),
            SizedBox(width: 12 * touchScale),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  minHeight: 8 * touchScale,
                  value: _progress(position, duration),
                  color: TvColors.accent,
                  backgroundColor: TvColors.panelBorder,
                ),
              ),
            ),
            SizedBox(width: 12 * touchScale),
            Text(
              _formatDuration(duration),
              style: TextStyle(
                color: TvColors.textSecondary,
                fontSize: 16 * touchScale,
              ),
            ),
          ],
        ),
        SizedBox(height: 20 * touchScale),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _CircleButton(
              icon: Icons.queue_music_rounded,
              small: true,
              size: smallCircleSize,
              focused: isControlFocused && focusedControlIndex == 0,
            ),
            SizedBox(width: buttonGap),
            _CircleButton(
              icon: _playbackModeIcon(playbackMode),
              small: true,
              size: smallCircleSize,
              focused: isControlFocused && focusedControlIndex == 1,
            ),
            SizedBox(width: buttonGap),
            _CircleButton(
              icon: Icons.fast_rewind_rounded,
              small: true,
              size: smallCircleSize,
              focused: isControlFocused && focusedControlIndex == 2,
            ),
            SizedBox(width: buttonGap),
            _CircleButton(
              icon: Icons.skip_previous_rounded,
              focused: isControlFocused && focusedControlIndex == 3,
              size: bigCircleSize,
            ),
            SizedBox(width: buttonGap),
            _PlayButton(
              focused: isControlFocused && focusedControlIndex == 4,
              isPlaying: isPlaying,
              size: playSize,
              iconSize: playIconSize,
            ),
            SizedBox(width: buttonGap),
            _CircleButton(
              icon: Icons.skip_next_rounded,
              focused: isControlFocused && focusedControlIndex == 5,
              size: bigCircleSize,
            ),
            SizedBox(width: buttonGap),
            _CircleButton(
              icon: Icons.forward_10_rounded,
              small: true,
              size: smallCircleSize,
              focused: isControlFocused && focusedControlIndex == 6,
            ),
            SizedBox(width: buttonGap),
            _CircleButton(
              icon: Icons.info_outline_rounded,
              small: true,
              size: smallCircleSize,
              focused: isControlFocused && focusedControlIndex == 7,
            ),
            SizedBox(width: buttonGap),
            _CircleButton(
              icon: isFullscreen
                  ? Icons.fullscreen_exit_rounded
                  : Icons.fullscreen_rounded,
              small: true,
              size: smallCircleSize,
              focused: isControlFocused && focusedControlIndex == 8,
            ),
          ],
        ),
      ],
    );
  }

  IconData _playbackModeIcon(_PlaybackMode mode) {
    switch (mode) {
      case _PlaybackMode.sequential:
        return Icons.repeat_rounded;
      case _PlaybackMode.shuffle:
        return Icons.shuffle_rounded;
      case _PlaybackMode.repeatOne:
        return Icons.repeat_one_rounded;
    }
  }
}

class _TopBarItem extends StatelessWidget {
  const _TopBarItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.focused,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: TvMotion.fast,
      curve: TvMotion.curve,
      padding: EdgeInsets.symmetric(
        horizontal: selected ? 16 : 12,
        vertical: 10,
      ),
      decoration: BoxDecoration(
        color: selected ? TvColors.cardActive : TvColors.card,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: focused
              ? TvColors.focusBorder
              : (selected ? TvColors.cardActiveBorder : TvColors.cardBorder),
          width: focused ? 2.2 : 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: TvColors.textPrimary),
          if (selected) ...[
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(fontSize: 14, color: TvColors.textPrimary),
            ),
          ],
        ],
      ),
    );
  }
}

class _DialogActionButton extends StatelessWidget {
  const _DialogActionButton({
    required this.label,
    this.icon,
    this.focused = false,
    this.enabled = true,
    this.onPressed,
  });

  final String label;
  final IconData? icon;
  final bool focused;
  final bool enabled;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final bool isLight = Theme.of(context).brightness == Brightness.light;
    final ButtonStyle style = FilledButton.styleFrom(
      backgroundColor: focused
          ? TvColors.accent
          : (isLight ? const Color(0xFFEFF3FF) : TvColors.card),
      disabledBackgroundColor: isLight
          ? const Color(0xFFE9EEF9)
          : TvColors.card,
      foregroundColor: focused
          ? const Color(0xFFF5F8FF)
          : TvColors.textPrimary,
      side: focused
          ? BorderSide(color: TvColors.focusBorder, width: 2)
          : BorderSide(color: TvColors.cardBorder, width: 1),
    );
    if (icon == null) {
      return FilledButton(
        onPressed: enabled ? onPressed : null,
        style: style,
        child: Text(label),
      );
    }
    return FilledButton.icon(
      onPressed: enabled ? onPressed : null,
      icon: Icon(icon),
      label: Text(label),
      style: style,
    );
  }
}

class _FolderBrowserDialog extends StatefulWidget {
  const _FolderBrowserDialog({required this.initialPath});

  final String initialPath;

  @override
  State<_FolderBrowserDialog> createState() => _FolderBrowserDialogState();
}

class _FolderBrowserDialogState extends State<_FolderBrowserDialog> {
  late String _currentPath;
  List<Directory> _directories = <Directory>[];
  int _focusedIndex = 0;
  int _focusedActionIndex = 0;
  bool _isLoading = true;
  bool _isActionArea = false;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _currentPath = widget.initialPath;
    unawaited(_loadDirectories(_currentPath));
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadDirectories(String path) async {
    setState(() {
      _isLoading = true;
    });
    final Directory dir = Directory(path);
    final List<Directory> subdirs = <Directory>[];
    try {
      await for (final FileSystemEntity entity in dir.list(
        followLinks: false,
      )) {
        if (entity is Directory) {
          subdirs.add(entity);
        }
      }
      subdirs.sort((a, b) => a.path.compareTo(b.path));
    } catch (_) {}
    if (!mounted) {
      return;
    }
    setState(() {
      _currentPath = path;
      _directories = subdirs;
      _focusedIndex = 0;
      _focusedActionIndex = 0;
      _isActionArea = false;
      _isLoading = false;
    });
  }

  void _ensureFocusedVisible() {
    if (!_scrollController.hasClients || _isActionArea) {
      return;
    }
    const double itemExtent = 70;
    final double target = (_focusedIndex * itemExtent) - 140;
    final double max = _scrollController.position.maxScrollExtent;
    _scrollController.animateTo(
      target.clamp(0.0, max),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  Future<void> _enterFocusedDirectory() async {
    if (_focusedIndex < 0 || _focusedIndex >= _directories.length) {
      return;
    }
    await _loadDirectories(_directories[_focusedIndex].path);
  }

  Future<void> _goParent() async {
    final Directory current = Directory(_currentPath);
    final Directory parent = current.parent;
    if (parent.path == current.path) {
      return;
    }
    await _loadDirectories(parent.path);
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: (FocusNode node, KeyEvent event) {
        if (event is! KeyDownEvent) {
          return KeyEventResult.ignored;
        }
        final LogicalKeyboardKey key = event.logicalKey;
        if (key == LogicalKeyboardKey.arrowUp) {
          setState(() {
            if (_isActionArea) {
              _isActionArea = false;
            } else {
              _focusedIndex = (_focusedIndex - 1).clamp(
                0,
                _directories.isEmpty ? 0 : _directories.length - 1,
              );
            }
          });
          _ensureFocusedVisible();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowDown) {
          setState(() {
            if (_directories.isEmpty ||
                _focusedIndex >= _directories.length - 1) {
              _isActionArea = true;
            } else {
              _focusedIndex = (_focusedIndex + 1).clamp(
                0,
                _directories.length - 1,
              );
            }
          });
          _ensureFocusedVisible();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowLeft) {
          if (_isActionArea) {
            setState(() {
              _focusedActionIndex = (_focusedActionIndex - 1).clamp(0, 1);
            });
          } else {
            unawaited(_goParent());
          }
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowRight) {
          if (_isActionArea) {
            setState(() {
              _focusedActionIndex = (_focusedActionIndex + 1).clamp(0, 1);
            });
          } else {
            setState(() {
              _isActionArea = true;
              _focusedActionIndex = 1;
            });
          }
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.select) {
          if (_isActionArea) {
            if (_focusedActionIndex == 0) {
              Navigator.of(context).pop();
            } else {
              Navigator.of(context).pop(_currentPath);
            }
          } else if (_directories.isNotEmpty) {
            unawaited(_enterFocusedDirectory());
          }
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.escape) {
          Navigator.of(context).pop();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: AlertDialog(
        backgroundColor: TvColors.card,
        title: const Text('选择音乐文件夹'),
        content: SizedBox(
          width: 720,
          height: 520,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _currentPath,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: TvColors.textSecondary),
              ),
              const SizedBox(height: 14),
              Expanded(
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : _directories.isEmpty
                    ? Center(
                        child: Text(
                          '当前目录没有可进入的子文件夹',
                          style: TextStyle(color: TvColors.textSecondary),
                        ),
                      )
                    : ListView.builder(
                        controller: _scrollController,
                        itemCount: _directories.length,
                        itemBuilder: (BuildContext context, int i) {
                          final bool focused =
                              !_isActionArea && i == _focusedIndex;
                          final String name = _directories[i].path
                              .split(Platform.pathSeparator)
                              .last;
                          return AnimatedContainer(
                            duration: TvMotion.fast,
                            margin: const EdgeInsets.only(bottom: 10),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 12,
                            ),
                            decoration: BoxDecoration(
                              color: focused
                                  ? TvColors.cardActive
                                  : TvColors.card,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: focused
                                    ? TvColors.focusBorder
                                    : TvColors.cardBorder,
                                width: focused ? 2.2 : 1,
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.folder_rounded,
                                  color: TvColors.textPrimary,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    name.isEmpty ? _directories[i].path : name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 16,
                                      color: TvColors.textPrimary,
                                    ),
                                  ),
                                ),
                                Icon(
                                  Icons.chevron_right_rounded,
                                  color: TvColors.textTertiary,
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
              const SizedBox(height: 10),
              Text(
                '方向键上下选择，右键/回车进入文件夹，左键返回上级',
                style: TextStyle(fontSize: 12, color: TvColors.textSecondary),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            style: TextButton.styleFrom(
              backgroundColor: _isActionArea && _focusedActionIndex == 0
                  ? const Color(0x3307C160)
                  : null,
              side: _isActionArea && _focusedActionIndex == 0
                  ? BorderSide(color: TvColors.focusBorder, width: 2)
                  : null,
            ),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(_currentPath),
            style: FilledButton.styleFrom(
              backgroundColor: _isActionArea && _focusedActionIndex == 1
                  ? TvColors.accent
                  : null,
              side: _isActionArea && _focusedActionIndex == 1
                  ? BorderSide(color: TvColors.focusBorder, width: 2)
                  : null,
            ),
            child: const Text('选择当前文件夹'),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final bool isLight = Theme.of(context).brightness == Brightness.light;
    return Text(
      text,
      style: TextStyle(
        fontSize: 20,
        color: isLight ? const Color(0xFF1A1A1A) : TvColors.textPrimary,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

class _QueueItem extends StatelessWidget {
  const _QueueItem({
    required this.index,
    required this.title,
    required this.artist,
    this.active = false,
    this.focused = false,
    this.playing = false,
  });

  final int index;
  final String title;
  final String artist;
  final bool active;
  final bool focused;
  final bool playing;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: TvMotion.fast,
      curve: TvMotion.curve,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: active ? TvColors.cardActive : TvColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: focused
              ? TvColors.focusBorder
              : (active ? TvColors.cardActiveBorder : TvColors.cardBorder),
          width: focused ? 2.2 : 1,
        ),
      ),
      child: Row(
        children: [
          Text(
            '$index',
            style: TextStyle(
              fontSize: 16,
              color: TvColors.textIndex,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: TvColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  artist,
                  style: TextStyle(
                    fontSize: 13,
                    color: TvColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Icon(
            playing ? Icons.graphic_eq_rounded : Icons.more_vert_rounded,
            color: TvColors.textTertiary,
            size: 18,
          ),
        ],
      ),
    );
  }
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({
    required this.icon,
    this.small = false,
    this.focused = false,
    this.size,
  });

  final IconData icon;
  final bool small;
  final bool focused;
  final double? size;

  @override
  Widget build(BuildContext context) {
    final double resolvedSize = size ?? (small ? 54 : 66);
    final double baseSize = small ? 54 : 66;
    final double baseIconSize = small ? 26 : 32;
    final double resolvedIconSize =
        baseIconSize * (resolvedSize / baseSize);
    return AnimatedContainer(
      duration: TvMotion.fast,
      curve: TvMotion.curve,
      width: resolvedSize,
      height: resolvedSize,
      decoration: BoxDecoration(
        color: focused
            ? const Color(0xFF056B47)
            : TvColors.card,
        shape: BoxShape.circle,
        border: Border.all(
          color: focused ? TvColors.focusBorder : TvColors.cardBorder,
          width: focused ? 2.2 : 1,
        ),
        boxShadow: focused
            ? [
                BoxShadow(
                  color: const Color(0xFF07C160).withValues(alpha: 0.35),
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                ),
              ]
            : null,
      ),
      child: Icon(icon,
          size: resolvedIconSize, color: Colors.white),
    );
  }
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({
    this.focused = false,
    required this.isPlaying,
    required this.size,
    required this.iconSize,
  });

  final bool focused;
  final bool isPlaying;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final bool isLight = Theme.of(context).brightness == Brightness.light;
    final Color buttonColor = isLight
        ? (focused ? const Color(0xFF31405F) : const Color(0xFF2A3550))
        : (focused ? const Color(0xFF06AD56) : TvColors.accent);
    return AnimatedContainer(
      duration: TvMotion.medium,
      curve: TvMotion.curve,
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: buttonColor,
        shape: BoxShape.circle,
        border: Border.all(
          color: focused ? TvColors.focusBorder : Colors.transparent,
          width: 2.5,
        ),
        boxShadow: [
          BoxShadow(
            color: buttonColor.withValues(alpha: isLight ? 0.24 : 0.45),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Icon(
        isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
        size: iconSize,
        color: Colors.white,
      ),
    );
  }
}

double _progress(Duration position, Duration duration) {
  if (duration.inMilliseconds <= 0) {
    return 0;
  }
  final double value = position.inMilliseconds / duration.inMilliseconds;
  return value.clamp(0.0, 1.0);
}

String _formatDuration(Duration value) {
  final int totalSeconds = value.inSeconds;
  final int minutes = (totalSeconds ~/ 60) % 60;
  final int seconds = totalSeconds % 60;
  final int hours = totalSeconds ~/ 3600;
  if (hours > 0) {
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
  return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
}

class _LocalSong {
  const _LocalSong({
    required this.path,
    required this.title,
    required this.artist,
    required this.album,
    required this.lyrics,
    required this.timedLyrics,
    required this.coverBytes,
  });

  final String path;
  final String title;
  final String artist;
  final String album;
  final String lyrics;
  final List<_TimedLyricLine> timedLyrics;
  final Uint8List? coverBytes;

  String get formatDisplay {
    final int dot = path.lastIndexOf('.');
    if (dot < 0 || dot >= path.length - 1) {
      return '未知';
    }
    return path.substring(dot + 1).toUpperCase();
  }

  String folderDisplay(String? scanRootPath) {
    final List<String> segments = path.split(Platform.pathSeparator);
    if (segments.length <= 1) {
      return '根目录';
    }
    final String folderPath = segments
        .sublist(0, segments.length - 1)
        .join(Platform.pathSeparator);
    if (scanRootPath != null && folderPath.startsWith(scanRootPath)) {
      String relative = folderPath.substring(scanRootPath.length);
      relative = relative.replaceFirst(RegExp(r'^[\\/]+'), '');
      return relative.isEmpty ? '根目录' : relative;
    }
    return segments.length >= 2 ? segments[segments.length - 2] : folderPath;
  }
}

class _SongTagData {
  const _SongTagData({
    required this.title,
    required this.artist,
    required this.album,
    required this.lyrics,
    required this.coverBytes,
  });

  final String? title;
  final String? artist;
  final String? album;
  final String? lyrics;
  final Uint8List? coverBytes;
}

class _FlacMetadataReader {
  static const int _metadataBlockStreamInfo = 0;
  static const int _metadataBlockVorbisComment = 4;
  static const int _metadataBlockPicture = 6;
  static const List<String> _lyricsKeys = <String>[
    'LYRICS',
    'UNSYNCEDLYRICS',
    'UNSYNCED LYRICS',
    'DESCRIPTION',
  ];

  static Future<_SongTagData?> read(String filePath) async {
    final Uint8List bytes = await File(filePath).readAsBytes();
    if (bytes.length < 4 ||
        ascii.decode(bytes.sublist(0, 4), allowInvalid: true) != 'fLaC') {
      return null;
    }

    int offset = 4;
    final Map<String, List<String>> comments = <String, List<String>>{};
    Uint8List? coverBytes;

    while (offset + 4 <= bytes.length) {
      final int header = bytes[offset];
      final bool isLastBlock = (header & 0x80) != 0;
      final int blockType = header & 0x7F;
      final int blockLength =
          (bytes[offset + 1] << 16) |
          (bytes[offset + 2] << 8) |
          bytes[offset + 3];
      offset += 4;
      if (offset + blockLength > bytes.length) {
        break;
      }

      final Uint8List block = Uint8List.sublistView(
        bytes,
        offset,
        offset + blockLength,
      );
      switch (blockType) {
        case _metadataBlockStreamInfo:
          break;
        case _metadataBlockVorbisComment:
          _readVorbisComments(block, comments);
          break;
        case _metadataBlockPicture:
          coverBytes ??= _readPictureBlock(block);
          break;
      }

      offset += blockLength;
      if (isLastBlock) {
        break;
      }
    }

    return _SongTagData(
      title: _firstComment(comments, 'TITLE'),
      artist: _firstComment(comments, 'ARTIST'),
      album: _firstComment(comments, 'ALBUM'),
      lyrics: _firstNonEmptyComment(comments, _lyricsKeys),
      coverBytes: coverBytes,
    );
  }

  static void _readVorbisComments(
    Uint8List block,
    Map<String, List<String>> comments,
  ) {
    if (block.length < 8) {
      return;
    }
    final ByteData data = ByteData.sublistView(block);
    int cursor = 0;

    final int vendorLength = _readUint32LE(data, cursor);
    cursor += 4;
    if (cursor + vendorLength + 4 > block.length) {
      return;
    }
    cursor += vendorLength;

    final int commentCount = _readUint32LE(data, cursor);
    cursor += 4;

    for (int i = 0; i < commentCount; i++) {
      if (cursor + 4 > block.length) {
        return;
      }
      final int commentLength = _readUint32LE(data, cursor);
      cursor += 4;
      if (cursor + commentLength > block.length) {
        return;
      }
      final String rawComment = utf8.decode(
        block.sublist(cursor, cursor + commentLength),
        allowMalformed: true,
      );
      cursor += commentLength;

      final int separatorIndex = rawComment.indexOf('=');
      if (separatorIndex <= 0) {
        continue;
      }
      final String key = rawComment
          .substring(0, separatorIndex)
          .trim()
          .toUpperCase();
      final String value = rawComment.substring(separatorIndex + 1).trim();
      if (key.isEmpty || value.isEmpty) {
        continue;
      }
      comments.putIfAbsent(key, () => <String>[]).add(value);
    }
  }

  static Uint8List? _readPictureBlock(Uint8List block) {
    if (block.length < 32) {
      return null;
    }
    final ByteData data = ByteData.sublistView(block);
    int cursor = 0;

    cursor += 4; // picture type
    final int mimeLength = _readUint32BE(data, cursor);
    cursor += 4;
    if (cursor + mimeLength + 4 > block.length) {
      return null;
    }
    cursor += mimeLength;

    final int descriptionLength = _readUint32BE(data, cursor);
    cursor += 4;
    if (cursor + descriptionLength + 20 > block.length) {
      return null;
    }
    cursor += descriptionLength;

    cursor += 4; // width
    cursor += 4; // height
    cursor += 4; // depth
    cursor += 4; // indexed colors

    final int pictureDataLength = _readUint32BE(data, cursor);
    cursor += 4;
    if (cursor + pictureDataLength > block.length) {
      return null;
    }
    if (pictureDataLength == 0) {
      return null;
    }
    return Uint8List.fromList(
      block.sublist(cursor, cursor + pictureDataLength),
    );
  }

  static String? _firstComment(Map<String, List<String>> comments, String key) {
    final List<String>? values = comments[key];
    if (values == null) {
      return null;
    }
    for (final String value in values) {
      if (value.trim().isNotEmpty) {
        return value.trim();
      }
    }
    return null;
  }

  static String _firstNonEmptyComment(
    Map<String, List<String>> comments,
    List<String> keys,
  ) {
    for (final String key in keys) {
      final String? value = _firstComment(comments, key);
      if (value != null && value.isNotEmpty) {
        return value;
      }
    }
    return '';
  }

  static int _readUint32LE(ByteData data, int offset) {
    return data.getUint32(offset, Endian.little);
  }

  static int _readUint32BE(ByteData data, int offset) {
    return data.getUint32(offset, Endian.big);
  }
}
