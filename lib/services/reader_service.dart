import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart' as c;
import 'package:image/image.dart' as im;
import 'package:pointycastle/export.dart' as pc;
import 'package:web_socket_channel/io.dart';

import 'aedex_api.dart';

class ReaderException implements Exception {
  final String message;
  const ReaderException(this.message);

  @override
  String toString() => message;
}

class LoginRequiredException extends ReaderException {
  const LoginRequiredException(super.message);
}

class ReaderSessionExpired extends ReaderException {
  const ReaderSessionExpired(super.message);
}

/// Firma las llamadas del lector. Las claves salen de data-t/data-s (lector de
/// la ficha) o de token+seed (lector de las imágenes).
class ReaderSigner {
  final String sessionKey;
  final List<int> _key;
  final String proofName;
  final String liveName;
  final String buildName;
  final String buildId;
  final String livePath;

  ReaderSigner._(
    this.sessionKey,
    this._key,
    this.proofName,
    this.liveName,
    this.buildName,
    this.buildId,
    this.livePath,
  );

  factory ReaderSigner(String prefix, String t, String s) {
    final sessionKey = c.sha256.convert(utf8.encode('$t:$s')).toString();
    final key = c.sha256.convert(utf8.encode('$sessionKey:p')).bytes;
    return ReaderSigner._(
      sessionKey,
      key,
      '$prefix-sig-${sessionKey.substring(7, 15)}',
      '$prefix-live-${sessionKey.substring(15, 23)}',
      '$prefix-build-${sessionKey.substring(23, 31)}',
      sessionKey.substring(31, 43),
      sessionKey.substring(43, 51),
    );
  }

  (String, String) proof(String scope, String subject, int time) {
    final mac = c.Hmac(c.sha256, _key)
        .convert(utf8.encode('$scope.$subject.$time'))
        .toString();
    return (proofName, '$time.${mac.substring(0, 40)}');
  }
}

/// ECDSA P-256 con exportación SPKI y firma raw r||s, como WebCrypto.
class EcdsaP256 {
  final pc.ECPublicKey publicKey;
  final pc.ECPrivateKey privateKey;

  EcdsaP256._(this.publicKey, this.privateKey);

  factory EcdsaP256() {
    final fortuna = pc.FortunaRandom()..seed(pc.KeyParameter(_randomSeed()));
    final generator = pc.ECKeyGenerator()
      ..init(pc.ParametersWithRandom(
        pc.ECKeyGeneratorParameters(pc.ECCurve_prime256v1()),
        fortuna,
      ));
    final pair = generator.generateKeyPair();
    return EcdsaP256._(
      pair.publicKey as pc.ECPublicKey,
      pair.privateKey as pc.ECPrivateKey,
    );
  }

  String get publicKeySpki {
    final point = publicKey.Q!.getEncoded(false);
    final algorithmIdentifier = <int>[
      0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
      0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07,
    ];
    final spki = <int>[
      0x30, 0x59,
      ...algorithmIdentifier,
      0x03, 0x42, 0x00,
      ...point,
    ];
    return base64Url.encode(spki).replaceAll('=', '');
  }

  static Uint8List _randomSeed() {
    final seed = Uint8List(32);
    final random = Random.secure();
    for (var i = 0; i < seed.length; i++) {
      seed[i] = random.nextInt(256);
    }
    return seed;
  }

  String sign(String challenge) {
    final signer = pc.ECDSASigner(pc.SHA256Digest());
    final fortuna = pc.FortunaRandom()..seed(pc.KeyParameter(_randomSeed()));
    signer.init(
      true,
      pc.ParametersWithRandom(
        pc.PrivateKeyParameter<pc.ECPrivateKey>(privateKey),
        fortuna,
      ),
    );
    final signature = signer.generateSignature(
      Uint8List.fromList(utf8.encode(challenge)),
    ) as pc.ECSignature;
    final out = Uint8List(64);
    out.setRange(0, 32, _bigIntTo32(signature.r));
    out.setRange(32, 64, _bigIntTo32(signature.s));
    return base64Url.encode(out).replaceAll('=', '');
  }

  Uint8List _bigIntTo32(BigInt value) {
    final hex = value.toRadixString(16).padLeft(64, '0');
    return Uint8List.fromList(
      List.generate(
        32,
        (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
      ),
    );
  }
}

/// Cap proof-of-work del sitio: FNV-1a + xorshift32 + SHA-256.
class CapSolver {
  static int _fnv1a(String value) {
    var hash = 0x811c9dc5;
    for (final byte in utf8.encode(value)) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash;
  }

  static String prng(String seed, int length) {
    var state = _fnv1a(seed);
    final buffer = StringBuffer();
    while (buffer.length < length) {
      state = (state ^ ((state << 13) & 0xFFFFFFFF)) & 0xFFFFFFFF;
      state = (state ^ (state >> 17)) & 0xFFFFFFFF;
      state = (state ^ ((state << 5) & 0xFFFFFFFF)) & 0xFFFFFFFF;
      buffer.write(state.toRadixString(16).padLeft(8, '0'));
    }
    return buffer.toString().substring(0, length);
  }

  static int solve(String salt, String target) {
    for (var nonce = 0; ; nonce++) {
      final digest = c.sha256.convert(utf8.encode('$salt$nonce')).toString();
      if (digest.startsWith(target)) return nonce;
    }
  }
}

class Slice {
  final int sx, sy, sw, sh, dx, dy;

  const Slice(this.sx, this.sy, this.sw, this.sh, this.dx, this.dy);
}

class PageMeta {
  final Uint8List key;
  final int xor;
  final int gutter;
  final int cleanLen;

  const PageMeta({
    required this.key,
    required this.xor,
    required this.gutter,
    required this.cleanLen,
  });
}

/// Descifra el trailer que el lector añade al final de la imagen y reconstruye
/// el plan de 64 teselas.
class PageCrypto {
  static PageMeta? extractTrailer(Uint8List bytes, Uint8List mask) {
    if (bytes.length < 9 || mask.isEmpty) return null;

    final trailerLength = (bytes[bytes.length - 2] << 8) | bytes[bytes.length - 1];
    // El trailer es pequeño (metadatos): el WASM acepta longitudes < 513.
    if (trailerLength == 0 || trailerLength >= 513) return null;
    if (bytes.length < trailerLength + 2) return null;

    final start = bytes.length - trailerLength - 2;
    final plain = Uint8List(trailerLength);
    for (var i = 0; i < trailerLength; i++) {
      plain[i] = bytes[start + i] ^ mask[i % mask.length];
    }

    if (plain[0] != 0xAE ||
        plain[1] != 0xDE ||
        plain[2] != 0x58 ||
        plain[3] != 0x01) {
      return null;
    }

    final keyLength = plain[6];
    if (keyLength == 0 || keyLength + 7 > trailerLength) return null;

    return PageMeta(
      key: plain.sublist(7, 7 + keyLength),
      xor: plain[4],
      gutter: plain[5],
      cleanLen: bytes.length - trailerLength - 2,
    );
  }

  static Uint8List xorBytes(Uint8List bytes, int key, int length) {
    final safeLength = length.clamp(0, bytes.length).toInt();
    final out = Uint8List.fromList(bytes.sublist(0, safeLength));
    if (key != 0) {
      for (var i = 0; i < out.length; i++) {
        out[i] ^= key;
      }
    }
    return out;
  }

  static int javaHashBytes(List<int> bytes) {
    var hash = 0;
    for (final byte in bytes) {
      hash = (hash * 31 + (byte & 0xFF)) & 0xFFFFFFFF;
    }
    return hash.toSigned(32);
  }

  static List<Slice> slicesFromKeyBytes(
    List<int> keyBytes,
    int width,
    int height,
    int gutter,
  ) {
    final random = _Mulberry32(javaHashBytes(keyBytes));
    final columns = _boundaries(random, width);
    final rows = _boundaries(random, height);
    final columnOrder = _permutation(random);
    final rowOrder = _permutation(random);
    final sourceColumns = _offsets(columns, columnOrder);
    final sourceRows = _offsets(rows, rowOrder);

    final result = <Slice>[];
    for (var row = 0; row < 8; row++) {
      for (var column = 0; column < 8; column++) {
        final tileWidth = columns[column + 1] - columns[column];
        final tileHeight = rows[row + 1] - rows[row];
        final columnPosition = columnOrder.indexOf(column);
        final rowPosition = rowOrder.indexOf(row);
        result.add(
          Slice(
            sourceColumns[columnPosition] + gutter * (2 * columnPosition + 1),
            sourceRows[rowPosition] + gutter * (2 * rowPosition + 1),
            tileWidth,
            tileHeight,
            columns[column],
            rows[row],
          ),
        );
      }
    }
    return result;
  }

  static List<int> _boundaries(_Mulberry32 random, int total) {
    final bounds = List<int>.filled(9, 0);
    bounds[8] = total;
    final base = total ~/ 8;
    var position = 0;

    for (var i = 0; i < 7; i++) {
      final max = total - position - (7 - i) * 16;
      var step = base + ((random.next() * 0.7 - 0.35) * base).round();
      step = step.clamp(16, max < 16 ? 16 : max).toInt();
      position += step;
      bounds[i + 1] = position;
    }
    return bounds;
  }

  static List<int> _permutation(_Mulberry32 random) {
    final order = List<int>.generate(8, (i) => i);
    for (var i = 7; i >= 1; i--) {
      final j = (random.next() * (i + 1)).floor();
      final value = order[i];
      order[i] = order[j];
      order[j] = value;
    }
    return order;
  }

  static List<int> _offsets(List<int> bounds, List<int> order) {
    final offsets = List<int>.filled(9, 0);
    for (var i = 0; i < 8; i++) {
      offsets[i + 1] =
          offsets[i] + bounds[order[i] + 1] - bounds[order[i]];
    }
    return offsets;
  }
}

class _Mulberry32 {
  int _state;

  _Mulberry32(int seed) : _state = seed;

  double next() {
    _state = (_state + 0x6d2b79f5) & 0xFFFFFFFF;
    var t = _state;
    t = ((t ^ (t >> 15)) * (t | 1)) & 0xFFFFFFFF;
    t = (t ^ (t + (((t ^ (t >> 7)) * (t | 61)) & 0xFFFFFFFF))) & 0xFFFFFFFF;
    return ((t ^ (t >> 14)) & 0xFFFFFFFF) / 4294967296.0;
  }
}

class ReaderSession {
  final String origin;
  final String token;
  final String seed;
  final String liveKey;
  final int clockOffset;
  final List<String> handles;
  final ReaderSigner signer;

  String? liveToken;
  DateTime? liveExpiry;

  ReaderSession({
    required this.origin,
    required this.token,
    required this.seed,
    required this.liveKey,
    required this.clockOffset,
    required this.handles,
  }) : signer = ReaderSigner('bv', token, seed);

  int now() => DateTime.now().millisecondsSinceEpoch + clockOffset;
}

class ReaderService {
  final AedexApi api;

  ReaderService(this.api);

  AedexHttp get http => api.http;

  Future<ReaderSession> openChapter(String slug, String chapter) async {
    final chapterUrl = '${AedexHttp.base}/comic/$slug/$chapter';
    final html = await http.get(Uri.parse(chapterUrl));
    if (!html.ok) {
      throw ReaderException('No se pudo abrir el capítulo (HTTP ${html.status})');
    }

    final t = RegExp(r'data-t="([0-9a-f]{32})"')
        .firstMatch(html.text)
        ?.group(1);
    final s = RegExp(r'data-s="([0-9a-f]{32})"')
        .firstMatch(html.text)
        ?.group(1);
    if (t == null || s == null) {
      throw const ReaderException('No se encontraron las claves del lector');
    }

    final ax = ReaderSigner('ax', t, s);
    final system = await api.system();
    final ecdsa = EcdsaP256();
    final chapterNumber = double.tryParse(chapter)
            ?.toString()
            .replaceFirst(RegExp(r'\.0$'), '') ??
        chapter;

    String? capToken = await _solveCap(system);
    await _redeemPass(capToken, system.capSitekey, ax);

    HttpResult? response;
    for (var attempt = 0; attempt < 2; attempt++) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final proof = ax.proof('c', '$slug/$chapterNumber', now);
      response = await http.postJson(
        Uri.parse('${AedexHttp.base}/lector/capitulo'),
        {'slug': slug, 'chapter': chapterNumber, 'modo': 'gratis'},
        lector: true,
        headers: {
          'X-Catharsis-Ws-Pub': ecdsa.publicKeySpki,
          ax.buildName: ax.buildId,
          proof.$1: proof.$2,
        },
      );

      if (response.status == 403 && attempt == 0) {
        capToken = await _solveCap(system);
        await _redeemPass(capToken, system.capSitekey, ax);
        continue;
      }
      break;
    }

    if (response == null || !response.ok) {
      final body = response?.text ?? '';
      if (body.contains('LOGIN_REQUIRED')) {
        throw const LoginRequiredException(
          'Máximo 3 capítulos como invitado. Inicia sesión para seguir.',
        );
      }
      throw ReaderException(
        'El lector respondió HTTP ${response?.status}. $body',
      );
    }

    final data = jsonDecode(response.text) as Map<String, dynamic>;
    var ready = data;

    if (data['ws_required'] == true) {
      ready = await _wsCountdown(
        (data['ws_url'] ?? '').toString(),
        (data['ws_ticket'] ?? '').toString(),
        ecdsa,
      );
    }

    final redirectUrl = (ready['redirect_url'] ?? '').toString();
    final redirectData = (ready['redirect_data'] ?? '').toString();
    if (redirectUrl.isEmpty || redirectData.isEmpty) {
      throw const ReaderException('El lector no devolvió la redirección');
    }

    final reader = await http.postForm(
      Uri.parse(redirectUrl),
      'data=${Uri.encodeQueryComponent(redirectData)}',
      headers: {
        'Referer': chapterUrl,
        'Origin': AedexHttp.base,
        ...AedexHttp.lectoHeaders,
      },
    );
    if (!reader.ok) {
      throw ReaderException('No se pudo abrir el lector (HTTP ${reader.status})');
    }

    final seed = _parseSeed(reader.text);
    final context = _parseContext(reader.text);
    if (seed == null || context == null) {
      throw ReaderException(
        'No se pudo leer el contexto del lector '
        '(HTTP ${reader.status}, ${reader.uri})',
      );
    }

    var handles = ((context['pages'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList();
    if (handles.isEmpty) {
      handles = RegExp(r'data-(?:cid|h)="([^"]+)"')
          .allMatches(reader.text)
          .map((m) => m.group(1)!)
          .toList();
    }
    if (handles.isEmpty) {
      throw const ReaderException('El capítulo no tiene páginas');
    }

    final token = (context['t'] ?? '').toString();
    final liveKey = (context['h'] ?? '').toString();
    final now = (context['now'] as num?)?.toInt() ??
        DateTime.now().millisecondsSinceEpoch;

    return ReaderSession(
      origin: reader.uri.origin,
      token: token,
      seed: seed,
      liveKey: liveKey,
      clockOffset: now - DateTime.now().millisecondsSinceEpoch,
      handles: handles,
    );
  }

  Future<String> _solveCap(SystemInfo system) async {
    if (system.capEndpoint.isEmpty) {
      throw const ReaderException('El sitio no publicó el endpoint de Cap');
    }
    final challengeResponse = await http.postJson(
      Uri.parse('${system.capEndpoint}challenge'),
      const <String, dynamic>{},
      lector: true,
    );
    if (!challengeResponse.ok) {
      throw ReaderException('Cap challenge HTTP ${challengeResponse.status}');
    }
    final challenge = jsonDecode(challengeResponse.text) as Map<String, dynamic>;
    final details = challenge['challenge'] as Map<String, dynamic>;
    final count = (details['c'] as num).toInt();
    final saltSize = (details['s'] as num).toInt();
    final difficulty = (details['d'] as num).toInt();
    final token = (challenge['token'] ?? '').toString();

    final solutions = <int>[];
    for (var i = 1; i <= count; i++) {
      final salt = CapSolver.prng('$token$i', saltSize);
      final target = CapSolver.prng('${token}${i}d', difficulty);
      solutions.add(CapSolver.solve(salt, target));
    }

    final redeemResponse = await http.postJson(
      Uri.parse('${system.capEndpoint}redeem'),
      {'token': token, 'solutions': solutions},
      lector: true,
    );
    if (!redeemResponse.ok) {
      throw ReaderException('Cap redeem HTTP ${redeemResponse.status}');
    }
    final redeemed = jsonDecode(redeemResponse.text) as Map<String, dynamic>;
    if (redeemed['success'] != true || redeemed['token'] == null) {
      throw const ReaderException('No se pudo resolver la verificación Cap');
    }
    return redeemed['token'].toString();
  }

  Future<void> _redeemPass(
    String capToken,
    String sitekey,
    ReaderSigner ax,
  ) async {
    final response = await http.postJson(
      Uri.parse('${AedexHttp.base}/lector/pase'),
      {'token': capToken, 'sitekey': sitekey},
      lector: true,
      headers: {ax.buildName: ax.buildId},
    );
    if (!response.ok) {
      throw ReaderException('No se pudo obtener el pase (HTTP ${response.status})');
    }
  }

  Future<Map<String, dynamic>> _wsCountdown(
    String wsUrl,
    String ticket,
    EcdsaP256 ecdsa,
  ) async {
    if (wsUrl.isEmpty || ticket.isEmpty) {
      throw const ReaderException('WebSocket del lector sin datos');
    }

    final uri = Uri.parse(wsUrl).replace(
      path: '/ws/free-reader',
      queryParameters: {'ticket': ticket},
    );

    final channel = IOWebSocketChannel.connect(
      uri,
      headers: {
        'Origin': AedexHttp.base,
        'User-Agent': AedexHttp.ua,
        'Cookie': http.cookieHeaderFor(Uri.parse(AedexHttp.base)),
      },
    );

    final completer = Completer<Map<String, dynamic>>();
    late StreamSubscription<dynamic> subscription;

    subscription = channel.stream.listen(
      (event) {
        Map<String, dynamic> frame;
        try {
          frame = Map<String, dynamic>.from(
            jsonDecode(event.toString()) as Map,
          );
        } catch (_) {
          return;
        }

        if (frame['type'] == 'countdown' && frame['challenge'] != null) {
          final challenge = frame['challenge'].toString();
          channel.sink.add(
            jsonEncode({
              'type': 'ack',
              'challenge': challenge,
              'sig': ecdsa.sign(challenge),
            }),
          );
        } else if (frame['type'] == 'ready') {
          if (!completer.isCompleted) completer.complete(frame);
          channel.sink.close();
        } else if (frame['type'] == 'error') {
          if (!completer.isCompleted) {
            completer.completeError(
              ReaderException((frame['code'] ?? frame['message'] ?? 'Error').toString()),
            );
          }
          channel.sink.close();
        }
      },
      onError: (Object error) {
        if (!completer.isCompleted) completer.completeError(error);
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.completeError(
            const ReaderException('La conexión de validación se cerró'),
          );
        }
      },
      cancelOnError: true,
    );

    try {
      return await completer.future.timeout(const Duration(seconds: 90));
    } finally {
      await subscription.cancel();
      await channel.sink.close();
    }
  }

  String? _parseSeed(String html) {
    return RegExp(r'id="bv-frame"[^>]*data-seed="([0-9a-f]{32})"')
            .firstMatch(html)
            ?.group(1) ??
        RegExp(r'data-seed="([0-9a-f]{32})"').firstMatch(html)?.group(1) ??
        RegExp(r'name="reader-token"\s+content="([^"]+)"')
            .firstMatch(html)
            ?.group(1) ??
        RegExp(r'content="([^"]+)"\s+name="reader-token"')
            .firstMatch(html)
            ?.group(1);
  }

  Map<String, dynamic>? _parseContext(String html) {
    final match = RegExp(
      r'window\.(?:readerContext|__BV_CTX__)\s*=\s*JSON\.parse\(atob\("([^"]+)"\)\)',
    ).firstMatch(html);
    if (match == null) return null;

    try {
      var encoded = match.group(1)!.replaceAll('-', '+').replaceAll('_', '/');
      while (encoded.length % 4 != 0) {
        encoded += '=';
      }
      final decoded = utf8.decode(base64.decode(encoded));
      return Map<String, dynamic>.from(jsonDecode(decoded) as Map);
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List> fetchPage(ReaderSession session, int index) async {
    final handle = session.handles[index];

    for (var attempt = 0; attempt < 3; attempt++) {
      final live = await _liveToken(session);
      final now = session.now();
      final proof = session.signer.proof('p', handle, now);
      final uri = Uri.parse(
        '${session.origin}/lector/p/$handle/',
      ).replace(queryParameters: {'q': 'hq'});

      final response = await http.get(
        uri,
        lector: true,
        keepBytes: true,
        headers: {
          session.signer.buildName: session.signer.buildId,
          proof.$1: proof.$2,
          session.signer.liveName: live,
        },
      );

      if (response.status == 429) {
        await Future.delayed(const Duration(seconds: 2));
        continue;
      }
      if (response.status == 403) {
        session.liveToken = null;
        await Future.delayed(const Duration(milliseconds: 400));
        continue;
      }
      if (response.status == 409) {
        throw const ReaderSessionExpired('La visita del lector caducó');
      }
      if (!response.ok || response.bytes == null) {
        throw ReaderException('Página ${index + 1}: HTTP ${response.status}');
      }

      final bytes = response.bytes!;
      final mask = Uint8List.fromList([
        ...c.sha256.convert(utf8.encode('${session.token}:m0:$handle')).bytes,
        ...c.sha256.convert(utf8.encode('${session.token}:m1:$handle')).bytes,
      ]);
      final meta = PageCrypto.extractTrailer(bytes, mask);

      final headerXor = int.tryParse(response.headers['x-page-xor'] ?? '') ?? 0;
      final headerGutter =
          int.tryParse(response.headers['x-tile-gutter'] ?? '') ?? 0;
      final headerKey = response.headers['x-page-key'] ?? '';

      final clean = PageCrypto.xorBytes(
        bytes,
        meta?.xor ?? headerXor,
        meta?.cleanLen ?? bytes.length,
      );
      final keyBytes = meta?.key ?? Uint8List.fromList(utf8.encode(headerKey));
      final gutter = meta?.gutter ?? headerGutter;

      return _decodePage(clean, keyBytes, gutter);
    }

    throw ReaderException('No se pudo descargar la página ${index + 1}');
  }

  Future<String> _liveToken(ReaderSession session) async {
    final cached = session.liveToken;
    final expiry = session.liveExpiry;
    if (cached != null &&
        expiry != null &&
        expiry.isAfter(DateTime.now().add(const Duration(seconds: 3)))) {
      return cached;
    }

    final proof = session.signer.proof('v', session.liveKey, session.now());
    final response = await http.postJson(
      Uri.parse('${session.origin}/lector/${session.signer.livePath}/'),
      {'h': session.liveKey},
      lector: true,
      headers: {
        session.signer.buildName: session.signer.buildId,
        proof.$1: proof.$2,
      },
    );

    if (response.status == 409) {
      throw const ReaderSessionExpired('La visita del lector caducó');
    }
    if (!response.ok) {
      throw ReaderException('Token de vida HTTP ${response.status}');
    }

    final data = jsonDecode(response.text) as Map<String, dynamic>;
    final token = (data['l'] ?? '').toString();
    final ttl = (data['ttl'] as num?)?.toInt() ?? 45000;
    if (token.isEmpty) {
      throw const ReaderException('Token de vida vacío');
    }

    session.liveToken = token;
    session.liveExpiry = DateTime.now().add(
      Duration(milliseconds: max(5000, ttl - 5000)),
    );
    return token;
  }

  Future<Uint8List> _decodePage(
    Uint8List clean,
    List<int> keyBytes,
    int gutter,
  ) async {
    // Skia limita las imágenes muy altas (webtoons de 10000 px) y puede
    // decodificarlas a otra resolución. package:image no tiene ese límite.
    // Se hace en un isolate para no bloquear la UI.
    try {
      return await Isolate.run(
        () => _decodePageWithImage(clean, keyBytes, gutter),
      );
    } catch (_) {}

    return _decodeWithUi(clean, keyBytes, gutter);
  }

  static Uint8List _decodePageWithImage(
    Uint8List clean,
    List<int> keyBytes,
    int gutter,
  ) {
    final decoded = im.decodeImage(clean);
    if (decoded == null) {
      throw const ReaderException('No se pudo decodificar la página');
    }
    var effectiveGutter = gutter;
    if (min(decoded.width, decoded.height) - 2 * 8 * effectiveGutter < 200) {
      effectiveGutter = 0;
    }
    final outWidth = decoded.width - 2 * 8 * effectiveGutter;
    final outHeight = decoded.height - 2 * 8 * effectiveGutter;
    if (outWidth <= 0 || outHeight <= 0) {
      throw const ReaderException('Dimensiones de página no válidas');
    }

    final output = im.Image(width: outWidth, height: outHeight);
    for (final slice in PageCrypto.slicesFromKeyBytes(
      keyBytes,
      outWidth,
      outHeight,
      effectiveGutter,
    )) {
      final tile = im.copyCrop(
        decoded,
        x: slice.sx,
        y: slice.sy,
        width: slice.sw,
        height: slice.sh,
      );
      im.compositeImage(output, tile, dstX: slice.dx, dstY: slice.dy);
    }
    return Uint8List.fromList(im.encodeJpg(output, quality: 95));
  }

  Future<Uint8List> _decodeWithUi(
    Uint8List clean,
    List<int> keyBytes,
    int gutter,
  ) async {
    final codec = await ui.instantiateImageCodec(clean);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final width = image.width;
    final height = image.height;

    var effectiveGutter = gutter;
    if (min(width, height) - 2 * 8 * effectiveGutter < 200) {
      effectiveGutter = 0;
    }
    final outWidth = width - 2 * 8 * effectiveGutter;
    final outHeight = height - 2 * 8 * effectiveGutter;
    if (outWidth <= 0 || outHeight <= 0) {
      image.dispose();
      throw const ReaderException('Dimensiones de página no válidas');
    }

    final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (byteData == null) {
      image.dispose();
      throw const ReaderException('No se pudo leer la imagen');
    }
    final source = byteData.buffer.asUint8List(byteData.offsetInBytes, byteData.lengthInBytes);
    final output = Uint8List(outWidth * outHeight * 4);

    for (final slice in PageCrypto.slicesFromKeyBytes(
      keyBytes,
      outWidth,
      outHeight,
      effectiveGutter,
    )) {
      for (var y = 0; y < slice.sh; y++) {
        final sourceIndex = ((slice.sy + y) * width + slice.sx) * 4;
        final destinationIndex = ((slice.dy + y) * outWidth + slice.dx) * 4;
        output.setRange(
          destinationIndex,
          destinationIndex + slice.sw * 4,
          source,
          sourceIndex,
        );
      }
    }

    image.dispose();

    final buffer = await ui.ImmutableBuffer.fromUint8List(output);
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: outWidth,
      height: outHeight,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    final resultCodec = await descriptor.instantiateCodec();
    final resultFrame = await resultCodec.getNextFrame();
    final png = await resultFrame.image.toByteData(format: ui.ImageByteFormat.png);
    resultFrame.image.dispose();

    if (png == null) {
      throw const ReaderException('No se pudo recomponer la página');
    }
    return png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
  }
}
