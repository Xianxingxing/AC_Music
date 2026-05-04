import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http_server/http_server.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;

class LanFileServerStatus {
  const LanFileServerStatus({
    required this.running,
    required this.port,
    required this.rootPath,
    required this.username,
    required this.password,
    required this.addresses,
  });

  final bool running;
  final int port;
  final String rootPath;
  final String username;
  final String password;
  final List<String> addresses;
}

class LanFileServer {
  HttpServer? _server;

  bool get isRunning => _server != null;
  int get port => _server?.port ?? 0;

  Future<LanFileServerStatus> start({
    required String rootPath,
    required int port,
    required String username,
    required String password,
  }) async {
    await stop();
    final String normalizedRoot = _normalizeRoot(rootPath);
    final List<String> addrs = await _localIpv4Addresses();
    final HttpServer server = await HttpServer.bind(
      InternetAddress.anyIPv4,
      port,
      shared: true,
    );
    _server = server;
    unawaited(
      _serveLoop(
        server: server,
        rootPath: normalizedRoot,
        username: username,
        password: password,
      ),
    );
    return LanFileServerStatus(
      running: true,
      port: server.port,
      rootPath: normalizedRoot,
      username: username,
      password: password,
      addresses: addrs,
    );
  }

  Future<void> stop() async {
    final HttpServer? server = _server;
    _server = null;
    if (server == null) {
      return;
    }
    await server.close(force: true);
  }

  String _normalizeRoot(String rootPath) {
    final String trimmed = rootPath.trim();
    if (trimmed.isEmpty) {
      return '/';
    }
    return trimmed;
  }

  Future<void> _serveLoop({
    required HttpServer server,
    required String rootPath,
    required String username,
    required String password,
  }) async {
    await for (final HttpRequest req in server) {
      try {
        final bool authed = _checkBasicAuth(
          req.headers.value(HttpHeaders.authorizationHeader) ?? '',
          username,
          password,
        );
        if (!authed) {
          req.response.statusCode = HttpStatus.unauthorized;
          req.response.headers.set(
            HttpHeaders.wwwAuthenticateHeader,
            'Basic realm="AC Music File Manager"',
          );
          req.response.write('Unauthorized');
          await req.response.close();
          continue;
        }

        final Uri uri = req.uri;
        final String path = uri.path;
        if (path == '/' || path == '/index.html') {
          req.response.headers.contentType = ContentType.html;
          req.response.write(_indexHtml());
          await req.response.close();
          continue;
        }

        if (path == '/api/list' && req.method == 'GET') {
          final String requested = uri.queryParameters['path'] ?? rootPath;
          final String resolved = _resolveUnderRoot(rootPath, requested);
          final Directory dir = Directory(resolved);
          final bool exists = await dir.exists();
          if (!exists) {
            _json(req, {'ok': false, 'error': '目录不存在'});
            continue;
          }
          final List<Map<String, Object?>> entries = [];
          await for (final FileSystemEntity ent in dir.list(
            followLinks: false,
          )) {
            final String name = p.basename(ent.path);
            final FileSystemEntityType t = await FileSystemEntity.type(
              ent.path,
              followLinks: false,
            );
            final bool isDir = t == FileSystemEntityType.directory;
            int size = 0;
            if (!isDir) {
              try {
                size = await File(ent.path).length();
              } catch (_) {
                size = 0;
              }
            }
            entries.add({
              'name': name,
              'path': ent.path,
              'isDir': isDir,
              'size': size,
            });
          }
          entries.sort((a, b) {
            final bool ad = a['isDir'] == true;
            final bool bd = b['isDir'] == true;
            if (ad != bd) return ad ? -1 : 1;
            return (a['name']?.toString() ?? '').compareTo(
              b['name']?.toString() ?? '',
            );
          });
          _json(req, {
            'ok': true,
            'root': rootPath,
            'cwd': resolved,
            'entries': entries,
          });
          continue;
        }

        if (path == '/api/download' && req.method == 'GET') {
          final String requested = uri.queryParameters['path'] ?? '';
          final String resolved = _resolveUnderRoot(rootPath, requested);
          final File file = File(resolved);
          final bool exists = await file.exists();
          if (!exists) {
            req.response.statusCode = HttpStatus.notFound;
            req.response.write('Not Found');
            await req.response.close();
            continue;
          }
          final String? mime = lookupMimeType(resolved);
          if (mime != null) {
            req.response.headers.set(HttpHeaders.contentTypeHeader, mime);
          }
          req.response.headers.set(
            'content-disposition',
            'attachment; filename="${p.basename(resolved)}"',
          );
          await req.response.addStream(file.openRead());
          await req.response.close();
          continue;
        }

        if (path == '/api/mkdir' && req.method == 'POST') {
          try {
            final Map<String, dynamic> body = await _readJson(req);
            final String base = _resolveUnderRoot(
              rootPath,
              body['path']?.toString() ?? rootPath,
            );
            final String name = (body['name']?.toString() ?? '').trim();
            if (name.isEmpty) {
              _json(req, {'ok': false, 'error': '文件夹名为空'});
              continue;
            }
            final Directory target = Directory(p.join(base, name));
            await target.create(recursive: true);
            _json(req, {'ok': true});
          } on FileSystemException catch (e) {
            _json(req, {'ok': false, 'error': '无权限或创建失败：${e.message}'});
          }
          continue;
        }

        if (path == '/api/delete' && req.method == 'POST') {
          try {
            final Map<String, dynamic> body = await _readJson(req);
            final String targetPath = _resolveUnderRoot(
              rootPath,
              body['path']?.toString() ?? '',
            );
            final FileSystemEntityType t = await FileSystemEntity.type(
              targetPath,
              followLinks: false,
            );
            if (t == FileSystemEntityType.notFound) {
              _json(req, {'ok': false, 'error': '目标不存在'});
              continue;
            }
            if (t == FileSystemEntityType.directory) {
              await Directory(targetPath).delete(recursive: true);
            } else {
              await File(targetPath).delete();
            }
            _json(req, {'ok': true});
          } on FileSystemException catch (e) {
            _json(req, {'ok': false, 'error': '无删除权限或删除失败：${e.message}'});
          }
          continue;
        }

        if (path == '/api/rename' && req.method == 'POST') {
          try {
            final Map<String, dynamic> body = await _readJson(req);
            final String targetPath = _resolveUnderRoot(
              rootPath,
              body['path']?.toString() ?? '',
            );
            final String newName = (body['newName']?.toString() ?? '').trim();
            if (newName.isEmpty) {
              _json(req, {'ok': false, 'error': '新名称为空'});
              continue;
            }
            final String newPath = p.join(p.dirname(targetPath), newName);
            final FileSystemEntityType t = await FileSystemEntity.type(
              targetPath,
              followLinks: false,
            );
            if (t == FileSystemEntityType.directory) {
              await Directory(targetPath).rename(newPath);
            } else {
              await File(targetPath).rename(newPath);
            }
            _json(req, {'ok': true});
          } on FileSystemException catch (e) {
            _json(req, {'ok': false, 'error': '重命名失败：${e.message}'});
          }
          continue;
        }

        if (path == '/api/upload' && req.method == 'POST') {
          try {
            final String requested = uri.queryParameters['path'] ?? rootPath;
            final String resolvedDir = _resolveUnderRoot(rootPath, requested);
            final Directory dir = Directory(resolvedDir);
            if (!await dir.exists()) {
              _json(req, {'ok': false, 'error': '上传目录不存在'});
              continue;
            }
            final HttpBody body = await HttpBodyHandler.processRequest(req);
            if (body.type != 'form') {
              _json(req, {'ok': false, 'error': '仅支持表单上传'});
              continue;
            }
            final Map<String, dynamic> form = body.body as Map<String, dynamic>;
            final dynamic fileField = form['file'];
            if (fileField is! HttpBodyFileUpload) {
              _json(req, {'ok': false, 'error': '缺少文件字段 file'});
              continue;
            }
            final String filename = p.basename(fileField.filename);
            final String relativeRaw = (form['relPath']?.toString() ?? '')
                .trim();
            final String safeRelative = relativeRaw.replaceAll('\\', '/');
            String targetDir = resolvedDir;
            if (safeRelative.isNotEmpty) {
              final String parentRel = p.dirname(safeRelative);
              if (parentRel != '.' && parentRel != '/') {
                final String nested = _resolveUnderRoot(
                  resolvedDir,
                  p.join(resolvedDir, parentRel),
                );
                await Directory(nested).create(recursive: true);
                targetDir = nested;
              }
            }
            final File out = File(p.join(targetDir, filename));
            await out.writeAsBytes(fileField.content as List<int>, flush: true);
            _json(req, {'ok': true, 'name': filename});
          } on FileSystemException catch (e) {
            _json(req, {'ok': false, 'error': '无上传权限或上传失败：${e.message}'});
          }
          continue;
        }

        req.response.statusCode = HttpStatus.notFound;
        req.response.write('Not Found');
        await req.response.close();
      } catch (e) {
        try {
          req.response.statusCode = HttpStatus.internalServerError;
          req.response.write('Error: $e');
          await req.response.close();
        } catch (_) {}
      }
    }
  }

  bool _checkBasicAuth(String authHeader, String username, String password) {
    if (!authHeader.startsWith('Basic ')) {
      return false;
    }
    final String encoded = authHeader.substring(6).trim();
    String decoded;
    try {
      decoded = utf8.decode(base64.decode(encoded));
    } catch (_) {
      return false;
    }
    final int idx = decoded.indexOf(':');
    if (idx <= 0) {
      return false;
    }
    final String u = decoded.substring(0, idx);
    final String p0 = decoded.substring(idx + 1);
    return u == username && p0 == password;
  }

  String _resolveUnderRoot(String rootPath, String requested) {
    final String base = p.normalize(rootPath);
    final String req = requested.trim().isEmpty ? base : requested.trim();
    final String joined = p.normalize(
      p.isAbsolute(req) ? req : p.join(base, req),
    );
    if (!p.isWithin(base, joined) && joined != base) {
      return base;
    }
    return joined;
  }

  Future<Map<String, dynamic>> _readJson(HttpRequest req) async {
    final String raw = await utf8.decoder.bind(req).join();
    if (raw.trim().isEmpty) {
      return <String, dynamic>{};
    }
    final Object? decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    return <String, dynamic>{};
  }

  void _json(HttpRequest req, Map<String, Object?> data) {
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(data));
    req.response.close();
  }

  Future<List<String>> _localIpv4Addresses() async {
    try {
      final List<NetworkInterface> ifaces = await NetworkInterface.list(
        type: InternetAddressType.any,
        includeLoopback: false,
      );
      final List<String> addrs = [];
      for (final NetworkInterface iface in ifaces) {
        for (final InternetAddress addr in iface.addresses) {
          if (addr.type == InternetAddressType.IPv4) {
            addrs.add(addr.address);
          }
        }
      }
      addrs.sort();
      return addrs;
    } catch (_) {
      return const <String>[];
    }
  }

  String _indexHtml() {
    return r'''<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>AC Music - 局域网文件管理</title>
  <style>
    body { font-family: system-ui, -apple-system, Segoe UI, Roboto, Arial; margin: 0; background: #0f1118; color: #e8eeff; }
    header { padding: 14px 16px; background: #171c2a; border-bottom: 1px solid #2a3148; display: flex; gap: 10px; align-items: center; }
    .btn { background: #252b3f; color: #e8eeff; border: 1px solid #333a54; padding: 8px 12px; border-radius: 10px; cursor: pointer; }
    .btn:hover { border-color: #5b6db0; }
    input { background: #0f1322; color: #e8eeff; border: 1px solid #2a3148; padding: 8px 10px; border-radius: 10px; width: 520px; max-width: 60vw; }
    main { padding: 16px; }
    .path { opacity: .85; margin-bottom: 10px; }
    .grid { display: grid; grid-template-columns: 1fr auto auto auto; gap: 10px; align-items: center; }
    .row { padding: 10px 12px; border: 1px solid #2a3148; border-radius: 12px; background: #121625; }
    .name { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .muted { opacity: .75; font-size: 12px; }
    .danger { border-color: #6b2b2b; }
    .danger:hover { border-color: #ff6b6b; }
    .split { display: flex; gap: 10px; flex-wrap: wrap; margin-bottom: 12px; }
    .upload-status { margin: 10px 0; padding: 10px 12px; border: 1px solid #2a3148; border-radius: 12px; background: #121625; }
    .bar { width: 100%; height: 10px; border-radius: 999px; background: #1a2033; overflow: hidden; margin-top: 8px; }
    .bar > div { height: 100%; width: 0%; background: linear-gradient(90deg, #4f72ff, #74a0ff); transition: width .18s ease; }
    .fail-list { margin-top: 8px; max-height: 140px; overflow: auto; font-size: 12px; color: #ffbdbd; }
    .hidden { display: none; }
  </style>
</head>
<body>
  <header>
    <strong>AC Music 文件管理</strong>
    <span class="muted">（需要账号密码）</span>
  </header>
  <main>
    <div class="split">
      <input id="path" placeholder="路径" />
      <button class="btn" onclick="go()">打开</button>
      <button class="btn" onclick="up()">上级</button>
      <button class="btn" onclick="mkdir()">新建文件夹</button>
      <input id="files" type="file" multiple />
      <input id="folder" type="file" webkitdirectory directory multiple />
      <button class="btn" onclick="uploadFiles(false)">批量上传文件</button>
      <button class="btn" onclick="uploadFiles(true)">上传文件夹(保留结构)</button>
    </div>
    <div id="uploadStatus" class="upload-status hidden">
      <div id="uploadText">准备上传...</div>
      <div class="bar"><div id="uploadBar"></div></div>
      <div id="failWrap" class="hidden">
        <div style="margin-top:8px;display:flex;gap:8px;align-items:center;">
          <span class="muted">失败项：</span>
          <button class="btn" onclick="retryFailed()">重试失败项</button>
        </div>
        <div id="failList" class="fail-list"></div>
      </div>
    </div>
    <div class="path" id="pwd"></div>
    <div class="grid" id="list"></div>
  </main>
  <script>
    let failedUploads = [];
    function q(id){ return document.getElementById(id); }
    function setUploadUI(visible){
      q('uploadStatus').classList.toggle('hidden', !visible);
      if(!visible){
        q('uploadBar').style.width = '0%';
        q('uploadText').textContent = '准备上传...';
        q('failWrap').classList.add('hidden');
        q('failList').innerHTML = '';
      }
    }
    function updateProgress(done, total){
      const pct = total <= 0 ? 0 : Math.round((done / total) * 100);
      q('uploadBar').style.width = pct + '%';
      q('uploadText').textContent = `上传中：${done}/${total} (${pct}%)`;
    }
    function showFailed(){
      if(!failedUploads.length){
        q('failWrap').classList.add('hidden');
        q('failList').innerHTML = '';
        return;
      }
      q('failWrap').classList.remove('hidden');
      q('failList').innerHTML = failedUploads
        .map(f => `<div>• ${f.rel}：${f.error || '上传失败'}</div>`)
        .join('');
    }
    async function apiList(path){
      const r = await fetch('/api/list?path=' + encodeURIComponent(path));
      return await r.json();
    }
    function fmtSize(n){
      if(!n) return '-';
      const u=['B','KB','MB','GB','TB'];
      let i=0; let v=n;
      while(v>=1024 && i<u.length-1){ v/=1024; i++; }
      return (i===0? v : v.toFixed(1)) + ' ' + u[i];
    }
    async function render(path){
      const j = await apiList(path);
      if(!j.ok){ alert(j.error||'失败'); return; }
      q('path').value = j.cwd;
      q('pwd').textContent = '当前目录：' + j.cwd;
      const el = q('list');
      el.innerHTML = '';
      for(const e of j.entries){
        const row = document.createElement('div'); row.className = 'row name';
        row.textContent = (e.isDir? '📁 ' : '📄 ') + e.name;
        const size = document.createElement('div'); size.className='row muted'; size.textContent = e.isDir? '-' : fmtSize(e.size);
        const open = document.createElement('button'); open.className='btn'; open.textContent = e.isDir? '进入' : '下载';
        open.onclick = () => e.isDir ? render(e.path) : (location.href='/api/download?path='+encodeURIComponent(e.path));
        const del = document.createElement('button'); del.className='btn danger'; del.textContent='删除';
        del.onclick = async () => { if(!confirm('确定删除 '+e.name+' ?')) return;
          const r = await fetch('/api/delete',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({path:e.path})});
          const j2 = await r.json(); if(!j2.ok){ alert(j2.error||'删除失败'); } else { render(q('path').value); }
        };
        el.appendChild(row); el.appendChild(size); el.appendChild(open); el.appendChild(del);
      }
    }
    function go(){ render(q('path').value); }
    function up(){
      const path = q('path').value;
      if(!path || path === '/') return;
      const p = path.replace(/\/+$/,'').split('/'); p.pop();
      const next = p.length? p.join('/') : '/';
      render(next);
    }
    async function mkdir(){
      const name = prompt('文件夹名');
      if(!name) return;
      const r = await fetch('/api/mkdir',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({path:q('path').value,name})});
      const j = await r.json(); if(!j.ok){ alert(j.error||'失败'); } else { render(q('path').value); }
    }
    async function uploadFiles(useFolder){
      const input = useFolder ? q('folder') : q('files');
      const files = Array.from(input.files || []);
      if(!files.length){ alert('请选择要上传的内容'); return; }
      setUploadUI(true);
      failedUploads = [];
      let okCount = 0;
      let failCount = 0;
      let done = 0;
      updateProgress(done, files.length);
      for(const f of files){
        const fd = new FormData();
        fd.append('file', f, f.name);
        const rel = useFolder ? (f.webkitRelativePath || f.name) : f.name;
        fd.append('relPath', rel);
        try{
          const r = await fetch('/api/upload?path='+encodeURIComponent(q('path').value), { method:'POST', body: fd });
          const j = await r.json();
          if(j.ok){
            okCount++;
          } else {
            failCount++;
            failedUploads.push({ file: f, rel, error: j.error || '上传失败' });
            console.warn(j.error || '上传失败');
          }
        }catch(_){
          failCount++;
          failedUploads.push({ file: f, rel, error: '网络或服务异常' });
        }
        done++;
        updateProgress(done, files.length);
      }
      await render(q('path').value);
      showFailed();
      alert('上传完成：成功 '+okCount+' 个，失败 '+failCount+' 个');
    }
    async function retryFailed(){
      if(!failedUploads.length){
        alert('没有失败项');
        return;
      }
      const retryItems = failedUploads.slice();
      failedUploads = [];
      setUploadUI(true);
      let okCount = 0;
      let failCount = 0;
      let done = 0;
      updateProgress(done, retryItems.length);
      for(const item of retryItems){
        const fd = new FormData();
        fd.append('file', item.file, item.file.name);
        fd.append('relPath', item.rel);
        try{
          const r = await fetch('/api/upload?path='+encodeURIComponent(q('path').value), { method:'POST', body: fd });
          const j = await r.json();
          if(j.ok){
            okCount++;
          } else {
            failCount++;
            failedUploads.push({ file: item.file, rel: item.rel, error: j.error || '上传失败' });
          }
        }catch(_){
          failCount++;
          failedUploads.push({ file: item.file, rel: item.rel, error: '网络或服务异常' });
        }
        done++;
        updateProgress(done, retryItems.length);
      }
      await render(q('path').value);
      showFailed();
      alert('重试完成：成功 '+okCount+' 个，失败 '+failCount+' 个');
    }
    render('/');
  </script>
</body>
</html>''';
  }
}
