// 哔哩哔哩 Lazer 插件的离线契约测试。
//
// 跑法：把本文件连同 test/fixtures/ 一起放进 Lazer 源码树，然后
//   flutter test test/plugin_contract_test.dart
//
// 它通过 LuaPluginRuntime 加载真实的 manifest.json + *.lua，再把确定性的 JSON
// fixture 从 httpHandler 喂进去，全程不走网络。仓库布局是
//   <repo>/manifest.json, <repo>/main.lua, <repo>/bili/*.lua, <repo>/test/fixtures/
// 所以源码根可用环境变量 PLUGIN_ROOT=<repo> 指定。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/plugins/lua_plugin_runtime.dart';
import 'package:lazer_nextgen/plugins/plugin_manifest.dart';

String get _repoRoot {
  // 优先级：环境变量 PLUGIN_ROOT > 从当前目录向上找 manifest.json。
  // 本仓库没有 pubspec.yaml，所以要借 Lazer 源码树的 flutter 环境跑，
  // 那种情况下当前目录是 Lazer 根，必须用 PLUGIN_ROOT 指回本仓库。
  final override = Platform.environment['PLUGIN_ROOT'];
  if (override != null && override.isNotEmpty) {
    return override.replaceAll('\\', '/');
  }
  var dir = Directory.current.absolute;
  for (var i = 0; i < 6; i++) {
    if (File('${dir.path}/manifest.json').existsSync() &&
        File('${dir.path}/main.lua').existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return Directory.current.absolute.path;
}

String get _srcRoot => _repoRoot;
String get _fixturesRoot => '$_repoRoot/test/fixtures';

// Records every outgoing request URL so tests can assert signed-query details.
final List<String> _requestUrls = <String>[];

// T4 test switches: flip inside a test to make the offline handler emit
// deterministic bulk pages or a specific upstream error code.
bool _bulkArcMode = false;
int? _forcedGatewayCode;
// Cover fix: emit fav folders without their own cover so the plugin must fall
// back to the first video's cover from /fav/resource/list.
bool _favFoldersNoCover = false;

List<Map<String, dynamic>> _bulkVlist(int pn) => List.generate(50, (i) => {
  'bvid': 'BVbulk${pn}_$i',
  'title': '批量歌曲 $pn-$i',
  'author': 'UP$pn',
  'mid': 1000 + pn,
  'pic': '//i0.hdslb.com/bfs/bulk/$pn-$i.jpg',
  'length': '3:00',  // 真机 vlist 时长字段
});

// 直接读仓库里的 manifest.json，避免测试里写死一份与真实清单漂移。
final _manifest = PluginManifest.fromJson(
  jsonDecode(File('$_srcRoot/manifest.json').readAsStringSync())
      as Map<String, dynamic>,
);

Map<String, String> _loadSources() {
  final sources = <String, String>{};
  final root = Directory(_srcRoot);
  for (final entity in root.listSync(recursive: true)) {
    if (entity is File && entity.path.endsWith('.lua')) {
      final rel = entity.path
          .replaceAll('\\', '/')
          .substring(_srcRoot.replaceAll('\\', '/').length)
          .replaceFirst(RegExp(r'^/+'), '');
      sources[rel] = entity.readAsStringSync();
    }
  }
  return sources;
}

String _fixture(String name) =>
    File('$_fixturesRoot/$name.json').readAsStringSync();

Future<Map<String, dynamic>> _handler(Map<String, dynamic> spec) async {
  final url = spec['url'] as String;
  final method = (spec['method'] as String? ?? 'GET').toUpperCase();
  final uri = Uri.parse(url);
  final path = uri.path;
  _requestUrls.add(url);
  String body = '{}';
  final headers = <String, dynamic>{};

  if (_forcedGatewayCode != null) {
    body = jsonEncode({'code': _forcedGatewayCode, 'message': 'forced'});
  } else if (path.contains('/x/web-interface/nav')) {
    body = _fixture('nav');
  } else if (path.contains('/x/web-interface/wbi/search/type')) {
    final searchType = uri.queryParameters['search_type'];
    body = _fixture(searchType == 'bili_user' ? 'search_user' : 'search');
  } else if (path.contains('/x/web-interface/card')) {
    body = _fixture('card');
  } else if (path.contains('/x/web-interface/view')) {
    body = _fixture('view');
  } else if (path.contains('/x/player/playurl')) {
    body = _fixture('playurl');
  } else if (path.contains('/x/player/wbi/v2') ||
             path.contains('/x/player/v2')) {
    body = _fixture('player_wbi');
  } else if (uri.host == 'aisubtitle.hdslb.com') {
    body = _fixture('subtitle');
  } else if (path.contains('/x/v3/fav/folder/created/list-all')) {
    if (_favFoldersNoCover) {
      final parsed = jsonDecode(_fixture('fav_folders')) as Map<String, dynamic>;
      for (final f in (parsed['data']['list'] as List)) {
        (f as Map).remove('cover');
        f.remove('pic');
      }
      body = jsonEncode(parsed);
    } else {
      body = _fixture('fav_folders');
    }
  } else if (path.contains('/x/v3/fav/resource/list')) {
    body = _fixture('fav_resources');
  } else if (path.contains('/x/v3/fav/resource/deal') && method == 'POST') {
    body = _fixture('fav_deal');
  } else if (path.contains('/x/web-interface/popular')) {
    body = _fixture('popular');
  } else if (path.contains('/x/web-interface/ranking/v2')) {
    body = _fixture('ranking');
  } else if (path.contains('/x/web-interface/archive/related')) {
    body = _fixture('related');
  } else if (path.contains('/x/space/wbi/arc/search')) {
    if (_bulkArcMode) {
      final pn = int.tryParse(uri.queryParameters['pn'] ?? '1') ?? 1;
      body = jsonEncode({'code': 0, 'data': {'list': {'vlist': _bulkVlist(pn)}}});
    } else {
      body = _fixture('space_arc');
    }
  } else if (path.contains('/x/v2/reply')) {
    body = _fixture('reply');
  } else if (path.contains('/x/passport-login/web/qrcode/generate')) {
    body = _fixture('qr_generate');
  } else if (path.contains('/x/passport-login/web/qrcode/poll')) {
    body = _fixture('qr_poll');
    headers['set-cookie'] =
        'SESSDATA=fake; Path=/; Domain=.bilibili.com\nbili_jct=csrf123; Path=/';
  } else if (uri.host == 'lrclib.net') {
    body = _fixture('lrclib');
  }
  return {'status': 200, 'headers': headers, 'body': body};
}

void _expectNoError(Object? value) {
  if (value is Map && value.containsKey('error')) {
    fail('unexpected error: ${value['error']}');
  }
}

void main() {
  late LuaPluginRuntime rt;
  late Directory dir;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('bili-contract-');
    rt = LuaPluginRuntime(
      manifest: _manifest,
      sources: _loadSources(),
      dataDirectory: dir.path,
      httpHandler: _handler,
      networkGranted: true,
      timeout: const Duration(seconds: 60),
    );
    await rt.start();
  });

  tearDownAll(() async {
    rt.close();
    await dir.delete(recursive: true);
  });

  test('decode sources + describe', () async {
    final result = await rt.invoke('describe') as Map;
    _expectNoError(result);
    final providers = result['providers'] as List;
    expect(providers.length, 1);
    final provider = providers.first as Map;
    expect(provider['id'], 'bilibili');
    expect(provider['name'], '哔哩哔哩');
    expect((provider['auth'] as List), contains('qr'));
    expect((provider['auth'] as List), contains('cookie'));
  });

  test('search maps titles/covers/durations, wbi signed', () async {
    final result = await rt.invoke('search', {'query': '周杰伦', 'limit': 20, 'offset': 0}) as Map;
    _expectNoError(result);
    final songs = result['songs'] as List;
    expect(songs.length, 2);
    final first = songs.first as Map;
    expect(first['id'], 'BV1GJ411x7h7');
    expect(first['title'], '【无损音质】周杰伦歌曲精选100首');
    expect(first['coverUrl'], 'https://i0.hdslb.com/bfs/archive/test1.jpg');
    expect(first['durationMs'], 259000);
    expect((first['artists'] as List).first['name'], '音乐收藏家');
  });

  test('song returns detail with cid/extra', () async {
    final result = await rt.invoke('song', {'id': 'BV1GJ411x7h7'}) as Map;
    _expectNoError(result);
    expect(result['id'], 'BV1GJ411x7h7');
    expect(result['durationMs'], 259000);
    final extra = result['extra'] as Map;
    expect(extra['cid'], '1001');
    expect(extra['parts'], 1);
  });

  test('stream picks FLAC and carries Referer', () async {
    final result = await rt.invoke('stream', {'id': 'BV1GJ411x7h7', 'quality': 'original'}) as Map;
    _expectNoError(result);
    expect(result['contentType'], 'audio/mp4');
    expect(result['bitRate'], 1500000);
    final headers = result['headers'] as Map;
    expect(headers['Referer'], 'https://www.bilibili.com/');
    expect((result['url'] as String).startsWith('https://'), isTrue);
  });

  test('lyrics builds synced lines[] from B站 ai-zh subtitle', () async {
    final result = await rt.invoke('lyrics', {'id': 'BV1GJ411x7h7'}) as List;
    expect(result.length, 1);
    final entry = result.first as Map;
    expect(entry['synced'], isTrue);
    expect(entry.containsKey('lrc'), isFalse, reason: '主源只给 lines, 不给 lrc');
    final lines = entry['lines'] as List;
    expect(lines.length, 3);
    final first = lines.first as Map;
    expect(first['text'], '稻香', reason: '♪ 应被 gsub 清掉, 首尾空格也去掉');
    expect(first['startMs'], 0);
    expect((lines[1] as Map)['startMs'], 3500);
    expect((lines[2] as Map)['text'], '跌倒了就不敢继续往前走');
  });

  test('session / cookie: loginCookie maps nav profile', () async {
    final cookie = 'SESSDATA=fake; bili_jct=csrf123';
    final result = await rt.invoke('loginCookie', {'cookie': cookie}) as Map;
    _expectNoError(result);
    expect(result['id'], '12345');
    expect(result['name'], '测试UP');
  });

  test('playlists/favorites mark the default folder', () async {
    final lists = await rt.invoke('playlists', {'limit': 20, 'offset': 0}) as List;
    expect(lists.length, 2);
    expect((lists.first as Map)['isFavorites'], isTrue);
    expect((lists.last as Map)['isFavorites'], isFalse);
    final favs = await rt.invoke('favorites', {'limit': 20, 'offset': 0}) as List;
    expect(favs.length, 2);
    expect((favs.first as Map)['id'], 'BV1GJ411x7h7');
  });

  test('setFavorite writes with csrf', () async {
    final result = await rt.invoke('setFavorite', {'id': 'BV1GJ411x7h7', 'favorite': true});
    expect(result, isTrue);
  });

  test('homeFeed/charts/recommendations/comments shapes', () async {
    final home = await rt.invoke('homeFeed') as Map;
    expect((home['featuredSongs'] as List).length, 2);
    final charts = await rt.invoke('charts') as List;
    expect((charts.first as Map)['id'], 'rank:all');
    final recs = await rt.invoke('recommendations', {'limit': 10}) as List;
    expect(recs.length, 2);
    final comments = await rt.invoke('comments', {'id': 'BV1GJ411x7h7', 'limit': 20, 'offset': 0}) as Map;
    final latest = comments['latest'] as List;
    expect(latest.length, 2);
    expect(comments['total'], 2);
    // 真实 /x/v2/reply 的 content 是对象；正文必须取 content.message。
    expect(latest.first['content'], '好听！');
    expect(latest.last['content'], '支持');
  });

  test('artistSongs wbi signed with wts (UP 主页投稿，缺 wts 会 412)', () async {
    _requestUrls.clear();
    final raw = await rt.invoke('artistSongs', {'id': '888', 'limit': 20, 'offset': 0});
    // A Lua empty table arrives as {}; non-empty rows as [].
    final rows = raw is List ? raw : <dynamic>[];
    expect(rows.length, 2);
    expect((rows.first as Map)['id'], 'BV1arc0001');
    // UP 主页 vlist 用 length("MM:SS")，必须映射成毫秒，否则时长不显示。
    expect((rows.first as Map)['durationMs'], 390000);   // 6:30
    expect((rows[1] as Map)['durationMs'], 135000);      // 2:15
    final arcUrl = _requestUrls.firstWhere(
      (u) => u.contains('/x/space/wbi/arc/search'),
      orElse: () => fail('artistSongs did not call /x/space/wbi/arc/search'),
    );
    expect(arcUrl, contains('mid=888'));
    expect(arcUrl, contains('wts='));
    expect(arcUrl, contains('w_rid='));
  });

  test('artist / artistAlbums: UP 主页不再报 unsupported (资料加载失败)', () async {
    final artist = await rt.invoke('artist', {'id': '888'}) as Map;
    _expectNoError(artist);
    expect(artist['id'], '888');
    expect(artist['name'], '音乐收藏家');
    expect(artist['coverUrl'], 'https://i0.hdslb.com/bfs/face/creator.jpg');
    expect(artist['albumCount'], 0);
    final albums = await rt.invoke('artistAlbums', {
      'id': '888', 'limit': 30, 'offset': 0,
    });
    expect(albums, isEmpty);
  });

  test('QR generate -> URL -> poll 803 with set-cookie', () async {
    final key = await rt.invoke('qrKey');
    expect(key, 'ABCDEF123456');
    final details = (await rt.invoke('qrUrl', {'key': key})).toString();
    expect(details, contains('qrcode_key=ABCDEF123456'));
    expect(details, contains('from=main_web'));
    // Must be a BARE URL: a Lua table toString breaks QrImageView on 2.0.210.
    expect(details, startsWith('https://'));
    expect(details, isNot(contains('{hint')));
    final status = await rt.invoke('qrCheck', {'key': key});
    expect(status, 803);
  });

  test('budget gate: synced lines[] returned fast', () async {
    // 主源返回 lines[] 交给宿主合成时间轴, 整条链路必须远低于 10s 网关预算.
    final stopwatch = Stopwatch()..start();
    final result = await rt.invoke('lyrics', {'id': 'BV1GJ411x7h7'}) as List;
    stopwatch.stop();
    expect(result.first['lines'], isA<List>());
    expect(stopwatch.elapsedMilliseconds, lessThan(20000));
  });

  test('budget gate: 100 songs map without instruction overflow', () async {
    final rows = List.generate(100, (i) => {
      'bvid': 'BV1test$i',
      'title': '歌曲 $i',
      'author': 'UP$i',
      'mid': i,
      'pic': '//i0.hdslb.com/bfs/x/$i.jpg',
      'duration': '3:00',
    });
    final encoded = jsonEncode({'code': 0, 'data': {'result': rows}});
    expect(encoded.length, greaterThan(5000));
    final result = await rt.invoke('search', {'query': 'bulk', 'limit': 50, 'offset': 0}) as Map;
    _expectNoError(result);
    expect((result['songs'] as List).length, 2);
  });

  test('unknown operation returns structured error, no crash', () async {
    final result = await rt.invoke('noSuchOp') as Map;
    expect(result.containsKey('error'), isTrue);
  });

  // ---- T4: 4 new contract assertions (total 19) ----

  test('T4#16 search leaves albums and playlists empty', () async {
    final result = await rt.invoke('search', {'query': '周杰伦', 'limit': 20, 'offset': 0}) as Map;
    _expectNoError(result);
    final albums = result['albums'];
    final playlists = result['playlists'];
    expect(albums is List ? albums.isEmpty : (albums as Map).isEmpty, isTrue);
    expect(playlists is List ? playlists.isEmpty : (playlists as Map).isEmpty, isTrue);
  });

  test('T4#17 search artists carry UP row shape with albumCount 0', () async {
    final result = await rt.invoke('search', {'query': '周杰伦', 'limit': 20, 'offset': 0}) as Map;
    _expectNoError(result);
    final artists = (result['artists'] as List).cast<Map>();
    expect(artists.isNotEmpty, isTrue);
    final first = artists.first;
    for (final key in ['id', 'name', 'coverUrl', 'description', 'albumCount']) {
      expect(first.containsKey(key), isTrue, reason: 'missing $key');
    }
    expect(first['id'], '1745584728');
    expect(first['name'], '周杰伦');
    expect(first['albumCount'], 0);
  });

  test('T4#18 artistSongs aggregates two pages into 100 rows at limit=100', () async {
    _bulkArcMode = true;
    try {
      final result = await rt.invoke('artistSongs', {'id': '888', 'limit': 100, 'offset': 0});
      final rows = result is List ? result : <dynamic>[];
      expect(rows.length, 100);
      expect((rows.first as Map)['id'], 'BVbulk1_0');
      expect((rows.last as Map)['id'], 'BVbulk2_49');
    } finally {
      _bulkArcMode = false;
    }
  });

  test('T4#19 -352 maps to 401 prompt, -412 maps to 429 throttle', () async {
    _forcedGatewayCode = -352;
    Map? a;
    try {
      a = await rt.invoke('lyrics', {'id': 'BV1GJ411x7h7'}) as Map?;
    } finally {
      _forcedGatewayCode = null;
    }
    expect(a != null && a.containsKey('error'), isTrue);
    expect(a!['error']['code'], 40);
    expect(a['error']['httpStatus'], 401);

    _forcedGatewayCode = -412;
    Map? b;
    try {
      b = await rt.invoke('lyrics', {'id': 'BV1GJ411x7h7'}) as Map?;
    } finally {
      _forcedGatewayCode = null;
    }
    expect(b != null && b.containsKey('error'), isTrue);
    expect(b!['error']['httpStatus'], 429);
  });

  test('cover fix: playlist without own cover falls back to first video cover', () async {
    _favFoldersNoCover = true;
    try {
      final lists = await rt.invoke('playlists', {'limit': 20, 'offset': 0}) as List;
      expect(lists.length, 2);
      // fav_resources first media pic = //i0.hdslb.com/bfs/archive/a.jpg -> https
      expect((lists.first as Map)['coverUrl'],
             'https://i0.hdslb.com/bfs/archive/a.jpg');
      expect((lists.last as Map)['coverUrl'],
             'https://i0.hdslb.com/bfs/archive/a.jpg');
    } finally {
      _favFoldersNoCover = false;
    }
  });
}
