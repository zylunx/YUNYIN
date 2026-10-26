import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_js/flutter_js.dart';

/// 一个 LX 音乐源在宿主侧的运行时封装。
///
/// 通过 flutter_js（Android/Linux/Windows 走 QuickJS，iOS/macOS 走 JSC）执行任意 LX 源 JS，
/// 并在 JS 上下文里注入 [globalThis.lx] 契约（request / on / send / env / utils）。
/// 源在启动时会调用 `lx.send('inited', { sources })` 声明自己支持的平台与能力，
/// 宿主据此登记；之后通过 `lx.on('request', handler)` 接收 musicUrl / lyric / pic 分发。
///
/// JS 与 Dart 之间的通信全部走 flutter_js 的 `sendMessage` / `onMessage` 通道：
/// - `lx_request`：JS 把 HTTP 请求交给 Dart（Dio）执行，结果再由 `__lxResolve` 回填。
/// - `lx_send`：JS 上报事件（主要是 `inited`）。
/// - `lx_result`：JS 把 request 处理函数的返回值交回 Dart。
class LxRuntime {
  LxRuntime(this.id, this.name, this.platform, {required this.code});

  /// 源的唯一标识（来自文件名或导入时生成）。
  final String id;

  /// 展示名。
  final String name;

  /// 设备平台字符串（wy/tx/... 源用来拼 User-Agent），如 windows / android。
  final String platform;

  /// 源的 JS 源码。
  final String code;

  JavascriptRuntime? _rt;
  bool _loaded = false;
  bool get loaded => _loaded;

  /// 源自报的平台定义：platform -> { name, type, actions, qualitys }。
  Map<String, dynamic>? definition;

  final Map<int, Completer<dynamic>> _resultCompleters = {};
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(seconds: 20),
    validateStatus: (_) => true,
  ));

  int _seq = 0;
  final Completer<Map<String, dynamic>> _inited = Completer();

  /// 加载并执行源码。必须在调用 [dispatch] 之前 await 完成。
  Future<void> load() async {
    if (_loaded) return;
    final rt = getJavascriptRuntime();
    _rt = rt;
    rt.onMessage('lx_request', _onHttpRequest);
    rt.onMessage('lx_send', _onSend);
    rt.onMessage('lx_result', _onResult);
    // flutter_js 的 evaluate 是同步的（返回 JsEvalResult），不需要 await。
    rt.evaluate(_preamble);
    rt.evaluate("globalThis.lx.env = { platform: '$platform' };");
    rt.evaluate(code, sourceUrl: '$id.js');
    // 等待源上报 inited；超时也继续（个别源可能不报，但多数会）。
    try {
      definition = await _inited.future.timeout(const Duration(seconds: 5));
    } catch (_) {
      definition ??= {};
    }
    _loaded = true;
  }

  void _onSend(dynamic args) {
    final map = _asMap(args);
    if (map == null) return;
    final event = '${map['event']}';
    if (event == 'inited' && !_inited.isCompleted) {
      _inited.complete(Map<String, dynamic>.from(map['payload'] as Map? ?? const {}));
    }
  }

  void _onResult(dynamic args) {
    final map = _asMap(args);
    if (map == null) return;
    final rid = (map['rid'] as num?)?.toInt() ?? -1;
    final c = _resultCompleters.remove(rid);
    if (c == null) return;
    if (map['ok'] == true) {
      c.complete(map['result']);
    } else {
      c.completeError(map['error']?.toString() ?? 'lx source error');
    }
  }

  Future<void> _onHttpRequest(dynamic args) async {
    final map = _asMap(args);
    if (map == null) return;
    final rid = (map['rid'] as num?)?.toInt() ?? -1;
    final url = '${map['url']}';
    final options = Map<String, dynamic>.from(map['options'] as Map? ?? {});
    try {
      final method = (options['method'] as String?)?.toUpperCase() ?? 'GET';
      final headers = <String, String>{};
      final rawHeaders = options['headers'] as Map? ?? {};
      rawHeaders.forEach((k, v) => headers['$k'] = '$v');
      final timeoutMs = (options['timeout'] as num?)?.toInt();
      final resp = await _dio.request<dynamic>(
        url,
        data: options['body'],
        options: Options(
          method: method,
          headers: headers,
          receiveTimeout: timeoutMs == null ? null : Duration(milliseconds: timeoutMs),
          sendTimeout: timeoutMs == null ? null : Duration(milliseconds: timeoutMs),
        ),
      );
      final body = resp.data is String ? resp.data as String : jsonEncode(resp.data);
      final respHeaders = <String, String>{};
      resp.headers.forEach((k, v) => respHeaders[k.toLowerCase()] = v.join(','));
      final payload = jsonEncode({
        'statusCode': resp.statusCode ?? 0,
        'body': body,
        'headers': respHeaders,
      });
      _rt?.evaluate('__lxResolve($rid, null, $payload)');
    } catch (e) {
      final err = jsonEncode({'message': e.toString()});
      _rt?.evaluate('__lxResolve($rid, $err, null)');
    }
  }

  /// 触发一次源内注册的 request 处理函数（action = musicUrl / lyric / pic）。
  /// [info] 与 LX 源期望的结构一致：{ musicInfo, type }。
  Future<dynamic> dispatch(String action, String source, Map<String, dynamic> info) {
    if (_rt == null) throw StateError('LxRuntime 未加载');
    final rid = ++_seq;
    final completer = Completer<dynamic>();
    _resultCompleters[rid] = completer;
    final payload = jsonEncode({'action': action, 'source': source, 'info': info, '__rid': rid});
    _rt!.evaluate('__lxDispatch(${jsonEncode('request')}, $payload)');
    return completer.future;
  }

  /// 释放运行时引用。
  ///
  /// 注：flutter_js 0.8.x 未在文档中公开 dispose()，这里只断开引用交给 GC。
  /// 若你使用的版本提供了 `JavascriptRuntime.dispose()`，可在此改为 `_rt?.dispose()`。
  void dispose() {
    _rt = null;
    _loaded = false;
  }

  Map<String, dynamic>? _asMap(dynamic args) {
    if (args is Map) return args.cast<String, dynamic>();
    if (args is String) {
      try {
        final decoded = jsonDecode(args);
        if (decoded is Map) return decoded.cast<String, dynamic>();
      } catch (_) {}
    }
    return null;
  }
}

/// 内置到每个 LX 源上下文的契约与最小垫片。
///
/// 说明：flutter_js 已把 fetch/xhr 桥接到 Dart HTTP，但 LX 源使用的是 `lx.request`
/// 回调式接口，这里改为走消息通道，由 Dart 侧用 Dio 执行，便于完整控制请求头/超时/返回头。
/// 另外补一份最小 Buffer / base64 / URLSearchParams 垫片，覆盖星海等源对 Node API 的使用。
const String _preamble = r'''
(function () {
  var __reqMap = {};
  var __handlers = {};
  var __seq = 1;

  var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

  function utf8ToBytes(str) {
    var bytes = [], i;
    for (i = 0; i < str.length; i++) {
      var c = str.charCodeAt(i);
      if (c < 0x80) bytes.push(c);
      else if (c < 0x800) bytes.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f));
      else if (c < 0xd800 || c >= 0xe000) bytes.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
      else { i++; c = 0x10000 + ((c & 0x3ff) << 10 | (str.charCodeAt(i) & 0x3ff)); bytes.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 0x3f), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f)); }
    }
    return bytes;
  }
  function bytesToUtf8(bytes) {
    var out = '', i = 0;
    while (i < bytes.length) {
      var c = bytes[i++];
      if (c < 0x80) out += String.fromCharCode(c);
      else if (c >= 0xc0 && c < 0xe0) out += String.fromCharCode(((c & 0x1f) << 6) | (bytes[i++] & 0x3f));
      else if (c >= 0xe0 && c < 0xf0) out += String.fromCharCode(((c & 0x0f) << 12) | ((bytes[i++] & 0x3f) << 6) | (bytes[i++] & 0x3f));
      else out += String.fromCharCode(((c & 0x07) << 18) | ((bytes[i++] & 0x3f) << 12) | ((bytes[i++] & 0x3f) << 6) | (bytes[i++] & 0x3f));
    }
    return out;
  }
  function b64FromBytes(bytes) {
    var o = '', i;
    for (i = 0; i < bytes.length; i += 3) {
      var b1 = bytes[i], b2 = i + 1 < bytes.length ? bytes[i + 1] : 0, b3 = i + 2 < bytes.length ? bytes[i + 2] : 0;
      var e1 = b1 >> 2, e2 = ((b1 & 3) << 4) | (b2 >> 4), e3 = ((b2 & 15) << 2) | (b3 >> 6), e4 = b3 & 63;
      if (i + 1 >= bytes.length) e3 = e4 = 64; else if (i + 2 >= bytes.length) e4 = 64;
      o += B64[e1] + B64[e2] + B64[e3] + B64[e4];
    }
    return o;
  }
  function b64ToBytes(s) {
    var lookup = {}, i;
    for (i = 0; i < B64.length; i++) lookup[B64[i]] = i;
    var bytes = [], pad = 0;
    s = s.replace(/=+$/, function () { pad++; return ''; });
    for (i = 0; i < s.length; i += 4) {
      var c1 = lookup[s[i]] || 0, c2 = lookup[s[i + 1]] || 0, c3 = lookup[s[i + 2]] || 0, c4 = lookup[s[i + 3]] || 0;
      bytes.push((c1 << 2) | (c2 >> 4), ((c2 & 15) << 4) | (c3 >> 2), ((c3 & 3) << 6) | c4);
    }
    while (pad-- > 0) bytes.pop();
    return bytes;
  }

  var Buffer = {
    isBuffer: function () { return false; },
    from: function (data, enc) {
      if (typeof data === 'string') {
        if (enc === 'base64') return b64ToBytes(data);
        return utf8ToBytes(data);
      }
      return data;
    }
  };

  var utils = {
    buffer: {
      from: function (s, enc) { return Buffer.from(s, enc); },
      bufToString: function (b, enc) {
        if (enc === 'base64') return b64FromBytes(b);
        return bytesToUtf8(b);
      }
    }
  };

  function URLSearchParamsPoly(seed) {
    var _m = {};
    function parse(str) { str = (str || '').replace(/^\?/, ''); str.split('&').forEach(function (kv) { if (!kv) return; var i = kv.indexOf('='); var k = i < 0 ? kv : kv.slice(0, i); var v = i < 0 ? '' : kv.slice(i + 1); _m[decodeURIComponent(k)] = decodeURIComponent(v); }); }
    if (typeof seed === 'string') parse(seed);
    else if (seed && typeof seed === 'object') Object.keys(seed).forEach(function (k) { _m[k] = seed[k]; });
    this.set = function (k, v) { _m[k] = '' + v; };
    this.get = function (k) { return _m[k]; };
    this.toString = function () { return Object.keys(_m).map(function (k) { return encodeURIComponent(k) + '=' + encodeURIComponent(_m[k]); }).join('&'); };
  }
  if (typeof URLSearchParams === 'undefined') globalThis.URLSearchParams = URLSearchParamsPoly;

  if (typeof btoa === 'undefined') globalThis.btoa = function (s) { return b64FromBytes(utf8ToBytes(s)); };
  if (typeof atob === 'undefined') globalThis.atob = function (s) { return bytesToUtf8(b64ToBytes(s)); };

  var EVENT_NAMES = { request: 'request', inited: 'inited', updateAlert: 'updateAlert' };

  globalThis.lx = {
    EVENT_NAMES: EVENT_NAMES,
    env: { platform: 'unknown' },
    utils: utils,
    request: function (url, options, callback) {
      options = options || {};
      var rid = __seq++;
      __reqMap[rid] = callback;
      sendMessage('lx_request', JSON.stringify({ rid: rid, url: url, options: options }));
    },
    on: function (event, handler) { __handlers[event] = handler; },
    send: function (event, payload) { sendMessage('lx_send', JSON.stringify({ event: event, payload: payload })); }
  };

  globalThis.__lxResolve = function (rid, err, resp) {
    var cb = __reqMap[rid];
    if (!cb) return;
    delete __reqMap[rid];
    cb(err, resp);
  };

  globalThis.__lxDispatch = function (event, payloadJson) {
    var payload = JSON.parse(payloadJson);
    var handler = __handlers[event];
    if (!handler) return;
    Promise.resolve().then(function () { return handler(payload); }).then(function (res) {
      sendMessage('lx_result', JSON.stringify({ rid: payload.__rid, ok: true, result: res }));
    }).catch(function (e) {
      sendMessage('lx_result', JSON.stringify({ rid: payload.__rid, ok: false, error: (e && e.message) || String(e) }));
    });
  };
})();
''';
