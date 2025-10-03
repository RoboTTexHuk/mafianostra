import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform, HttpHeaders, HttpClient;
import 'dart:math';

import 'package:appsflyer_sdk/appsflyer_sdk.dart' as af_core;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel, SystemChrome, SystemUiOverlayStyle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as r;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';
import 'package:mafianostra/pushmafia.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz_zone;

// ============================================================================
// Константы
// ============================================================================
const String _kLoadedEventPrefKey = "loaded_event_sent_once";
const String kStatUrl = "https://cfd.mafiaexplorer.cfd/stat";
const String _kCachedFcmTokenKey = "cached_fcm_token";

// Лёгкие синглтоны (замена GetIt)
final FlutterSecureStorage mafSecureStorage = const FlutterSecureStorage();
final Logger mafLogger = Logger();
final Connectivity mafConnectivity = Connectivity();

// ============================================================================
// Сеть/данные
// ============================================================================
class MafiaWire {
  Future<bool> isNetUp() async {
    final c = await mafConnectivity.checkConnectivity();
    return c != ConnectivityResult.none;
  }

  Future<void> postJson(String u, Map<String, dynamic> d) async {
    try {
      await http.post(
        Uri.parse(u),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode(d),
      );
    } catch (e) {
      mafLogger.e("postJson-err: $e");
    }
  }
}

// ============================================================================
// Досье устройства/приложения
// ============================================================================
class MafiaDeviceDossier {
  String? deviceId;
  String? sessionId = "mafia-one-off";
  String? platform;
  String? osVersion;
  String? appVersion;
  String? language;
  String? timezone;
  bool pushEnabled = true;

  Future<void> assemble() async {
    final di = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      final x = await di.androidInfo;
      deviceId = x.id;
      platform = "android";
      osVersion = x.version.release;
    } else if (Platform.isIOS) {
      final x = await di.iosInfo;
      deviceId = x.identifierForVendor;
      platform = "ios";
      osVersion = x.systemVersion;
    }
    final appInfo = await PackageInfo.fromPlatform();
    appVersion = appInfo.version;
    language = Platform.localeName.split('_')[0];
    timezone = tz_zone.local.name;
    sessionId = "sitdown-${DateTime.now().millisecondsSinceEpoch}";
  }

  Map<String, dynamic> toMap({String? fcm}) => {
    "fcm_token": fcm ?? 'missing_token',
    "device_id": deviceId ?? 'missing_id',
    "app_name": "mafiaexplorer",
    "instance_id": sessionId ?? 'missing_session',
    "platform": platform ?? 'missing_system',
    "os_version": osVersion ?? 'missing_build',
    "app_version": appVersion ?? 'missing_app',
    "language": language ?? 'en',
    "timezone": timezone ?? 'UTC',
    "push_enabled": pushEnabled,
  };
}

// ============================================================================
// AppsFlyer (мафиозные имена)
// ============================================================================
class MafiaConsigliere with ChangeNotifier {
  af_core.AppsFlyerOptions? _cfg;
  af_core.AppsflyerSdk? _sdk;

  String afId = "";
  String afPayload = "";

  void summon(VoidCallback nudge) {
    final cfg = af_core.AppsFlyerOptions(
      afDevKey: "qsBLmy7dAXDQhowM8V3ca4",
      appId: "6752954951",
      showDebug: true,
      timeToWaitForATTUserAuthorization: 0,
    );
    _cfg = cfg;
    _sdk = af_core.AppsflyerSdk(cfg);

    _sdk?.initSdk(
      registerConversionDataCallback: true,
      registerOnAppOpenAttributionCallback: true,
      registerOnDeepLinkingCallback: true,
    );
    _sdk?.startSDK(
      onSuccess: () => mafLogger.i("Consigliere up"),
      onError: (int c, String m) => mafLogger.e("Consigliere err $c: $m"),
    );
    _sdk?.onInstallConversionData((res) {
      afPayload = res.toString();
      nudge();
      notifyListeners();
    });
    _sdk?.getAppsFlyerUID().then((v) {
      afId = v.toString();
      nudge();
      notifyListeners();
    });
  }
}

// ============================================================================
// Riverpod провайдер
// ============================================================================
final mafiaDeviceProvider = r.FutureProvider<MafiaDeviceDossier>((ref) async {
  final dossier = MafiaDeviceDossier();
  await dossier.assemble();
  return dossier;
});

// Provider (package:provider) -- ChangeNotifierProvider
final mafiaConsigliereProvider = p.ChangeNotifierProvider<MafiaConsigliere>(
  create: (_) => MafiaConsigliere(),
);

// ============================================================================
// Новый лоадер: Mafia + “пули”
// ============================================================================
class MafiaPulseLoader extends StatefulWidget {
  const MafiaPulseLoader({Key? key}) : super(key: key);

  @override
  State<MafiaPulseLoader> createState() => _MafiaPulseLoaderState();
}

class _MafiaPulseLoaderState extends State<MafiaPulseLoader> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<Color?> _tone;
  final List<_BulletHole> _holes = [];
  Timer? _spawnTimer;
  final Random _rng = Random();

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    _tone = ColorTween(
      begin: const Color(0xFFFFD700), // Gold
      end: Colors.white,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));

    _spawnTimer = Timer.periodic(const Duration(milliseconds: 500), (t) {
      if (!mounted) return;
      final size = MediaQuery.of(context).size;
      if (size.width == 0 || size.height == 0) return;
      final x = _rng.nextDouble() * size.width;
      final y = _rng.nextDouble() * size.height;
      setState(() {
        _holes.add(_BulletHole(Offset(x, y)));
        if (_holes.length > 40) {
          _holes.removeAt(0);
        }
      });
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _spawnTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AnimatedBuilder(
        animation: _tone,
        builder: (context, _) {
          return Container(
            color: Colors.black,
            alignment: Alignment.center,
            child: CustomPaint(
              painter: _BulletPainter(_holes),
              child: SizedBox.expand(
                child: Center(
                  child: Text(
                    "Mafia",
                    style: TextStyle(
                      fontSize: 42,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 6,
                      color: _tone.value,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _BulletHole {
  final Offset position;
  _BulletHole(this.position);
}

class _BulletPainter extends CustomPainter {
  final List<_BulletHole> holes;
  _BulletPainter(this.holes);

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()..color = Colors.white.withOpacity(0.9);
    final rim = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = Colors.white.withOpacity(0.6);

    for (final h in holes) {
      const r = 4.0;
      canvas.drawCircle(h.position, r, fill);
      canvas.drawCircle(h.position, r + 1.5, rim);
    }
  }

  @override
  bool shouldRepaint(covariant _BulletPainter oldDelegate) => oldDelegate.holes != holes;
}

// ============================================================================
// FCM бекграунд
// ============================================================================
@pragma('vm:entry-point')
Future<void> mafiaBgFcm(RemoteMessage m) async {
  mafLogger.i("bg-ping: ${m.messageId}");
  mafLogger.i("bg-payload: ${m.data}");
}

// ============================================================================
// FCM Token Bridge: токен ТОЛЬКО из нативного канала
// ============================================================================
class MafiaFCMTokenBridge extends ChangeNotifier {
  String? _token;
  StreamSubscription<String>? _sub;

  // Очередь колбэков, если ensureToken вызван до прихода setToken
  final List<void Function(String)> _waiters = [];

  String? get token => _token;

  MafiaFCMTokenBridge() {
    // Инициализируем обработчик канала один раз
    const MethodChannel('com.example.fcm/token').setMethodCallHandler((call) async {
      if (call.method == 'setToken') {
        final String s = call.arguments as String;
        if (s.isNotEmpty) {
          _setTokenInternal(s);
        }
      }
    });
    // Пытаемся восстановить кэш (не источник истины, но помогает при рестарте)
    _restoreCachedToken();
  }

  Future<void> _restoreCachedToken() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final cached = sp.getString(_kCachedFcmTokenKey);
      if (cached != null && cached.isNotEmpty) {
        _setTokenInternal(cached, notifyNative: false);
      } else {
        final ss = await mafSecureStorage.read(key: _kCachedFcmTokenKey);
        if (ss != null && ss.isNotEmpty) {
          _setTokenInternal(ss, notifyNative: false);
        }
      }
    } catch (_) {}
  }

  void _setTokenInternal(String token, {bool notifyNative = true}) async {
    _token = token;
    // Кэшируем
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kCachedFcmTokenKey, token);
      await mafSecureStorage.write(key: _kCachedFcmTokenKey, value: token);
    } catch (_) {}
    // Уведомляем ожидающих
    for (final w in List.of(_waiters)) {
      try {
        w(token);
      } catch (e) {
        mafLogger.w("waiter-cb error: $e");
      }
    }
    _waiters.clear();
    notifyListeners();
  }

  // Запрашиваем разрешение, но НЕ получаем токен из Firebase — только ждём нативный setToken
  Future<void> ensureToken(Function(String token) onToken) async {
    try {
      await FirebaseMessaging.instance.requestPermission(alert: true, badge: true, sound: true);

      // Если токен уже установлен ранее — сразу отдаём
      if (_token != null && _token!.isNotEmpty) {
        onToken(_token!);
        return;
      }

      // Иначе — добавляем слушателя до момента прихода нативного токена
      _waiters.add(onToken);
    } catch (e) {
      mafLogger.e("FCM ensureToken error: $e");
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

// ============================================================================
// Экран-запуска (без BLoC)
// ============================================================================
class MafiaVestibule extends StatefulWidget {
  const MafiaVestibule({Key? key}) : super(key: key);

  @override
  State<MafiaVestibule> createState() => _MafiaVestibuleState();
}

class _MafiaVestibuleState extends State<MafiaVestibule> {
  final MafiaFCMTokenBridge _tokenBridge = MafiaFCMTokenBridge();
  bool _once = false;
  Timer? _fallback;
  bool _muteLoader = false;

  @override
  void initState() {
    super.initState();

    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.black,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
    ));

    // Гарантированно получаем FCM токен (только из нативного канала) и идём дальше
    _tokenBridge.ensureToken((sig) {
      _go(sig);
    });

    // Фоллбек через 8 секунд — переходим дальше даже без токена
    _fallback = Timer(const Duration(seconds: 8), () => _go(''));

    // Скрыть лоадер-крышку через 2 сек (визуальный эффект)
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _muteLoader = true);
    });
  }

  void _go(String sig) {
    if (_once) return;
    _once = true;
    _fallback?.cancel();
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (context) => MafiaHarbor(signal: sig),
      ),
    );
  }

  @override
  void dispose() {
    _fallback?.cancel();
    _tokenBridge.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          if (!_muteLoader) const MafiaPulseLoader(),
          if (_muteLoader) const Center(child: MafiaPulseLoader()),
        ],
      ),
    );
  }
}

// ============================================================================
// MVVM (ViewModel + Courier/Presenter)
// ============================================================================
class MafiaViewModel with ChangeNotifier {
  final MafiaDeviceDossier dossier;
  final MafiaConsigliere consigliere;

  MafiaViewModel({required this.dossier, required this.consigliere});

  Map<String, dynamic> emitDevice(String? token) => dossier.toMap(fcm: token);

  Map<String, dynamic> emitAF(String? token) {
    return {
      "content": {
        "af_data": consigliere.afPayload,
        "af_id": consigliere.afId,
        "fb_app_name": "mafiaexplorer",
        "app_name": "mafiaexplorer",
        "deep": null,
        "bundle_identifier": "com.npstgl.ghoo.mafianostra",
        "app_version": "1.0.0",
        "apple_id": "6752954951",
        "fcm_token": token ?? "no_token",
        "device_id": dossier.deviceId ?? "no_device",
        "instance_id": dossier.sessionId ?? "no_instance",
        "platform": dossier.platform ?? "no_type",
        "os_version": dossier.osVersion ?? "no_os",
        "app_version": dossier.appVersion ?? "no_app",
        "language": dossier.language ?? "en",
        "timezone": dossier.timezone ?? "UTC",
        "push_enabled": dossier.pushEnabled,
        "useruid": consigliere.afId,
      },
    };
  }
}

class MafiaCourier {
  final MafiaViewModel model;
  final InAppWebViewController Function() webGetter;

  MafiaCourier({required this.model, required this.webGetter});

  Future<void> pushDeviceLocalStorage(String? token) async {
    final m = model.emitDevice(token);
    await webGetter().evaluateJavascript(source: '''
localStorage.setItem('app_data', JSON.stringify(${jsonEncode(m)}));
''');
  }

  Future<void> pushAfSendRaw(String? token) async {
    final payload = model.emitAF(token);
    final jsonString = jsonEncode(payload);
    mafLogger.i("SendRawData: $jsonString");
    await webGetter().evaluateJavascript(
      source: "sendRawData(${jsonEncode(jsonString)});",
    );
  }
}

// ============================================================================
// Главный WebView экран
// ============================================================================
Future<String> mafiaResolveFinalUrl(String startUrl, {int maxHops = 10}) async {
  final client = HttpClient();
  client.userAgent = 'Mozilla/5.0 (Flutter; dart:io HttpClient)';

  try {
    var current = Uri.parse(startUrl);
    for (int i = 0; i < maxHops; i++) {
      final req = await client.getUrl(current);
      req.followRedirects = false;
      final res = await req.close();

      if (res.isRedirect) {
        final loc = res.headers.value(HttpHeaders.locationHeader);
        if (loc == null || loc.isEmpty) break;

        final next = Uri.parse(loc);
        current = next.hasScheme ? next : current.resolveUri(next);
        continue;
      }
      return current.toString();
    }
    return current.toString();
  } catch (e) {
    debugPrint("mafiaResolveFinalUrl error: $e");
    return startUrl;
  } finally {
    client.close(force: true);
  }
}

Future<void> mafiaPostStat({
  required String event,
  required int timeStart,
  required String url,
  required int timeFinish,
  required String appSid,
  int? firstPageLoadTs,
}) async {
  try {
    final finalUrl = await mafiaResolveFinalUrl(url);
    final payload = {
      "event": event,
      "timestart": timeStart,
      "timefinsh": timeFinish,
      "url": finalUrl,
      "appleID": "6752954951",
      "open_count": "$appSid/$timeStart",
    };

    print("loadingstatinsic $payload");
    final res = await http.post(
      Uri.parse("$kStatUrl/$appSid"),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode(payload),
    );
    print(" ur _loaded$kStatUrl/$appSid");
    debugPrint("_postStat status=${res.statusCode} body=${res.body}");
  } catch (e) {
    debugPrint("_postStat error: $e");
  }
}

class MafiaHarbor extends StatefulWidget {
  final String? signal;
  const MafiaHarbor({super.key, required this.signal});

  @override
  State<MafiaHarbor> createState() => _MafiaHarborState();
}

class _MafiaHarborState extends State<MafiaHarbor> with WidgetsBindingObserver {
  late InAppWebViewController _dock;
  bool _spin = false;
  final String _axis = "https://cfd.mafiaexplorer.cfd/";
  final MafiaDeviceDossier _gear = MafiaDeviceDossier();
  final MafiaConsigliere _capo = MafiaConsigliere();

  int _tick = 0;
  DateTime? _sleepAt;
  bool _veil = false;
  double _meter = 0.0;
  late Timer _meterT;
  final int _warm = 6;
  bool _startCover = true;

  bool _loadedEventSent = false;

  int? firstPageLoadTs;

  Future<void> _loadLoadedFlag() async {
    final sp = await SharedPreferences.getInstance();
    _loadedEventSent = sp.getBool(_kLoadedEventPrefKey) ?? false;
  }

  Future<void> _saveLoadedFlag() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kLoadedEventPrefKey, true);
    _loadedEventSent = true;
  }

  Future<void> postLoadedOnce({required String url, required int timestart}) async {
    if (_loadedEventSent) {
      print("Loaded already sent, skipping");
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    await mafiaPostStat(
      event: "Loaded",
      timeStart: timestart,
      timeFinish: now,
      url: url,
      appSid: _capo.afId,
      firstPageLoadTs: firstPageLoadTs,
    );
    await _saveLoadedFlag();
  }

  final Set<String> _proto = {
    'tg', 'telegram',
    'whatsapp',
    'viber',
    'skype',
    'fb-messenger',
    'sgnl',
    'tel',
    'mailto',
    'bnl',
  };

  final Set<String> _dwell = {
    't.me', 'telegram.me', 'telegram.dog',
    'wa.me', 'api.whatsapp.com', 'chat.whatsapp.com',
    'm.me',
    'signal.me',
    'bnl.com', 'www.bnl.com',
  };

  MafiaCourier? _courier;
  MafiaViewModel? _viewModel;

  String currentUrl = "";
  var startload = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    firstPageLoadTs = DateTime.now().millisecondsSinceEpoch;

    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _startCover = false);
    });
    Future.delayed(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() {
        _veil = true;
      });
    });

    _bootStrap();
  }

  void _bootStrap() {
    _bootMeter();
    _armFcmBus();
    _capo.summon(() => setState(() {}));
    _bindNotifBridge();
    _prepGear();

    Future.delayed(const Duration(seconds: 6), () async {
      await _sendGear();
      await _sendCapo();
    });
  }

  void _armFcmBus() {
    FirebaseMessaging.onMessage.listen((msg) {
      final link = msg.data['uri'];
      if (link != null) {
        _hop(link.toString());
      } else {
        _spinUp();
      }
    });
    FirebaseMessaging.onMessageOpenedApp.listen((msg) {
      final link = msg.data['uri'];
      if (link != null) {
        _hop(link.toString());
      } else {
        _spinUp();
      }
    });
  }

  void _bindNotifBridge() {
    MethodChannel('com.example.fcm/notification').setMethodCallHandler((call) async {
      if (call.method == "onNotificationTap") {
        final Map<String, dynamic> payload = Map<String, dynamic>.from(call.arguments);
        final targetUrl = payload["uri"];
        if (payload["uri"] != null && !payload["uri"].contains("Нет URI")) {

          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute(builder: (context) => CaptainDeck(payload["uri"].toString())),
                (route) => false,
          );

        }
      }
    });
  }

  Future<void> _prepGear() async {
    try {
      await _gear.assemble();
      await _askPerm();
      _viewModel = MafiaViewModel(dossier: _gear, consigliere: _capo);
      _courier = MafiaCourier(model: _viewModel!, webGetter: () => _dock);
      await _loadLoadedFlag();
    } catch (e) {
      mafLogger.e("prep-gear-fail: $e");
    }
  }

  Future<void> _askPerm() async {
    FirebaseMessaging messaging = FirebaseMessaging.instance;
    await messaging.requestPermission(alert: true, badge: true, sound: true);
  }

  void _hop(String link) async {
    if (_dock != null) {
      await _dock.loadUrl(urlRequest: URLRequest(url: WebUri(link)));
    }
  }

  void _spinUp() async {
    Future.delayed(const Duration(seconds: 3), () {
      if (_dock != null) {
        _dock.loadUrl(urlRequest: URLRequest(url: WebUri(_axis)));
      }
    });
  }

  Future<void> _sendGear() async {
    mafLogger.i("TOKEN ship ${widget.signal}");
    if (!mounted) return;
    setState(() => _spin = true);
    try {
      await _courier?.pushDeviceLocalStorage(widget.signal);
    } finally {
      if (mounted) setState(() => _spin = false);
    }
  }

  Future<void> _sendCapo() async {
    await _courier?.pushAfSendRaw(widget.signal);
  }

  void _bootMeter() {
    int n = 0;
    _meter = 0.0;
    _meterT = Timer.periodic(const Duration(milliseconds: 100), (t) {
      if (!mounted) return;
      setState(() {
        n++;
        _meter = n / (_warm * 10);
        if (_meter >= 1.0) {
          _meter = 1.0;
          _meterT.cancel();
        }
      });
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.paused) {
      _sleepAt = DateTime.now();
    }
    if (s == AppLifecycleState.resumed) {
      if (Platform.isIOS && _sleepAt != null) {
        final now = DateTime.now();
        final dur = now.difference(_sleepAt!);
        if (dur > const Duration(minutes: 25)) {
          reframe();
        }
      }
      _sleepAt = null;
    }
  }

  void reframe() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(
          builder: (context) => MafiaHarbor(signal: widget.signal),
        ),
            (route) => false,
      );
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _meterT.cancel();
    super.dispose();
  }

  bool _isBareMail(Uri u) {
    final s = u.scheme;
    if (s.isNotEmpty) return false;
    final raw = u.toString();
    return raw.contains('@') && !raw.contains(' ');
  }

  Uri _mailize(Uri u) {
    final full = u.toString();
    final parts = full.split('?');
    final email = parts.first;
    final qp = parts.length > 1 ? Uri.splitQueryString(parts[1]) : <String, String>{};
    return Uri(
      scheme: 'mailto',
      path: email,
      queryParameters: qp.isEmpty ? null : qp,
    );
  }

  bool _isPlatformish(Uri u) {
    final s = u.scheme.toLowerCase();
    if (_proto.contains(s)) return true;

    if (s == 'http' || s == 'https') {
      final h = u.host.toLowerCase();
      if (_dwell.contains(h)) return true;
      if (h.endsWith('t.me')) return true;
      if (h.endsWith('wa.me')) return true;
      if (h.endsWith('m.me')) return true;
      if (h.endsWith('signal.me')) return true;
    }
    return false;
  }

  Uri _httpize(Uri u) {
    final s = u.scheme.toLowerCase();

    if (s == 'tg' || s == 'telegram') {
      final qp = u.queryParameters;
      final domain = qp['domain'];
      if (domain != null && domain.isNotEmpty) {
        return Uri.https('t.me', '/$domain', {
          if (qp['start'] != null) 'start': qp['start']!,
        });
      }
      final path = u.path.isNotEmpty ? u.path : '';
      return Uri.https('t.me', '/$path', u.queryParameters.isEmpty ? null : u.queryParameters);
    }

    if ((s == 'http' || s == 'https') && u.host.toLowerCase().endsWith('t.me')) {
      return u;
    }

    if (s == 'viber') {
      return u;
    }

    if (s == 'whatsapp') {
      final qp = u.queryParameters;
      final phone = qp['phone'];
      final text = qp['text'];
      if (phone != null && phone.isNotEmpty) {
        return Uri.https('wa.me', '/${_digits(phone)}', {
          if (text != null && text.isNotEmpty) 'text': text,
        });
      }
      return Uri.https('wa.me', '/', {if (text != null && text.isNotEmpty) 'text': text});
    }

    if ((s == 'http' || s == 'https') &&
        (u.host.toLowerCase().endsWith('wa.me') || u.host.toLowerCase().endsWith('whatsapp.com'))) {
      return u;
    }

    if (s == 'skype') {
      return u;
    }

    if (s == 'fb-messenger') {
      final path = u.pathSegments.isNotEmpty ? u.pathSegments.join('/') : '';
      final qp = u.queryParameters;
      final id = qp['id'] ?? qp['user'] ?? path;
      if (id.isNotEmpty) {
        return Uri.https('m.me', '/$id', u.queryParameters.isEmpty ? null : u.queryParameters);
      }
      return Uri.https('m.me', '/', u.queryParameters.isEmpty ? null : u.queryParameters);
    }

    if (s == 'sgnl') {
      final qp = u.queryParameters;
      final ph = qp['phone'];
      final un = u.queryParameters['username'];
      if (ph != null && ph.isNotEmpty) {
        return Uri.https('signal.me', '/#p/${_digits(ph)}');
      }
      if (un != null && un.isNotEmpty) {
        return Uri.https('signal.me', '/#u/$un');
      }
      final path = u.pathSegments.join('/');
      if (path.isNotEmpty) {
        return Uri.https('signal.me', '/$path', u.queryParameters.isEmpty ? null : u.queryParameters);
      }
      return u;
    }

    if (s == 'tel') {
      return Uri.parse('tel:${_digits(u.path)}');
    }

    if (s == 'mailto') {
      return u;
    }

    if (s == 'bnl') {
      final newPath = u.path.isNotEmpty ? u.path : '';
      return Uri.https('bnl.com', '/$newPath', u.queryParameters.isEmpty ? null : u.queryParameters);
    }

    return u;
  }

  Future<bool> _webMail(Uri mailto) async {
    final u = _gmailize(mailto);
    return await _webOpen(u);
  }

  Uri _gmailize(Uri m) {
    final qp = m.queryParameters;
    final params = <String, String>{
      'view': 'cm',
      'fs': '1',
      if (m.path.isNotEmpty) 'to': m.path,
      if ((qp['subject'] ?? '').isNotEmpty) 'su': qp['subject']!,
      if ((qp['body'] ?? '').isNotEmpty) 'body': qp['body']!,
      if ((qp['cc'] ?? '').isNotEmpty) 'cc': qp['cc']!,
      if ((qp['bcc'] ?? '').isNotEmpty) 'bcc': qp['bcc']!,
    };
    return Uri.https('mail.google.com', '/mail/', params);
  }

  Future<bool> _webOpen(Uri u) async {
    try {
      if (await launchUrl(u, mode: LaunchMode.inAppBrowserView)) return true;
      return await launchUrl(u, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('openInAppBrowser error: $e; url=$u');
      try {
        return await launchUrl(u, mode: LaunchMode.externalApplication);
      } catch (_) {
        return false;
      }
    }
  }

  String _digits(String s) => s.replaceAll(RegExp(r'[^0-9+]'), '');

  @override
  Widget build(BuildContext context) {
    // Повторная привязка канала уведомлений
    _bindNotifBridge();

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(

        backgroundColor: Colors.black,
        body: Stack(
          children: [
            if (_startCover)
              const MafiaPulseLoader()
            else
              Container(
                color: Colors.black,
                child: Stack(
                  children: [
                    InAppWebView(
                      key: ValueKey(_tick),
                      initialSettings: InAppWebViewSettings(
                        javaScriptEnabled: true,
                        disableDefaultErrorPage: true,
                        mediaPlaybackRequiresUserGesture: false,
                        allowsInlineMediaPlayback: true,
                        allowsPictureInPictureMediaPlayback: true,
                        useOnDownloadStart: true,
                        javaScriptCanOpenWindowsAutomatically: true,
                        useShouldOverrideUrlLoading: true,
                        supportMultipleWindows: true,
                        transparentBackground: true,
                      ),
                      initialUrlRequest: URLRequest(url: WebUri(_axis)),
                      onWebViewCreated: (c) {
                        _dock = c;

                        _viewModel ??= MafiaViewModel(dossier: _gear, consigliere: _capo);
                        _courier ??= MafiaCourier(model: _viewModel!, webGetter: () => _dock);

                        _dock.addJavaScriptHandler(
                          handlerName: 'onServerResponse',
                          callback: (args) {
                            print("JS args: $args");
                            try {
                              print("loader "+ args[0]['savedata'].toString() );
                              final saved = args.isNotEmpty &&
                                  args[0] is Map &&
                                  args[0]['savedata'].toString() == "false";
                              if (saved) {
    Navigator.pushAndRemoveUntil(
    context,
    MaterialPageRoute(builder: (context) => const MafiaHelpLite()),
    (route) => false,
    );
                              }
                            } catch (_) {}
                            if (args.isEmpty) return null;
                            try {
                              return args.reduce((curr, next) => curr + next);
                            } catch (_) {
                              return args.first;
                            }
                          },
                        );
                      },
                      onLoadStart: (c, u) async {
                        setState(() {
                          startload = DateTime.now().millisecondsSinceEpoch;
                        });
                        setState(() => _spin = true);
                        final v = u;
                        if (v != null) {
                          if (_isBareMail(v)) {
                            try {
                              await c.stopLoading();
                            } catch (_) {}
                            final mailto = _mailize(v);
                            await _webMail(mailto);
                            return;
                          }
                          final sch = v.scheme.toLowerCase();
                          if (sch != 'http' && sch != 'https') {
                            try {
                              await c.stopLoading();
                            } catch (_) {}
                          }
                        }
                      },
                      onLoadError: (controller, url, code, message) async {
                        final now = DateTime.now().millisecondsSinceEpoch;
                        final ev = "InAppWebViewError(code=$code, message=$message)";
                        await mafiaPostStat(
                          event: ev,
                          timeStart: now,
                          timeFinish: now,
                          url: url?.toString() ?? '',
                          appSid: _capo.afId,
                          firstPageLoadTs: firstPageLoadTs,
                        );
                        if (mounted) setState(() => _spin = false);
                      },
                      onReceivedHttpError: (controller, request, errorResponse) async {
                        final now = DateTime.now().millisecondsSinceEpoch;
                        final ev = "HTTPError(status=${errorResponse.statusCode}, reason=${errorResponse.reasonPhrase})";
                        await mafiaPostStat(
                          event: ev,
                          timeStart: now,
                          timeFinish: now,
                          url: request.url?.toString() ?? '',
                          appSid: _capo.afId,
                          firstPageLoadTs: firstPageLoadTs,
                        );
                      },
                      onReceivedError: (controller, request, error) async {
                        final now = DateTime.now().millisecondsSinceEpoch;
                        final desc = (error.description ?? '').toString();
                        final ev = "WebResourceError(code=${error}, message=$desc)";
                        await mafiaPostStat(
                          event: ev,
                          timeStart: now,
                          timeFinish: now,
                          url: request.url?.toString() ?? '',
                          appSid: _capo.afId,
                          firstPageLoadTs: firstPageLoadTs,
                        );
                      },
                      onLoadStop: (c, u) async {
                        await c.evaluateJavascript(source: "console.log('Harbor up!');");
                        print("Dock done $u");
                        await _sendGear();
                        await _sendCapo();

                        setState(() {
                          currentUrl = u.toString();
                        });

                        print("load url $currentUrl");

                        Future.delayed(const Duration(seconds: 20), () {
                          postLoadedOnce(
                            url: currentUrl.toString(),
                            timestart: startload,
                          );
                        });

                        if (mounted) setState(() => _spin = false);
                      },
                      shouldOverrideUrlLoading: (c, action) async {
                        final uri = action.request.url;
                        if (uri == null) return NavigationActionPolicy.ALLOW;

                        if (_isBareMail(uri)) {
                          final mailto = _mailize(uri);
                          await _webMail(mailto);
                          return NavigationActionPolicy.CANCEL;
                        }

                        final sch = uri.scheme.toLowerCase();

                        if (sch == 'mailto') {
                          await _webMail(uri);
                          return NavigationActionPolicy.CANCEL;
                        }

                        if (sch == 'tel') {
                          await launchUrl(uri, mode: LaunchMode.externalApplication);
                          return NavigationActionPolicy.CANCEL;
                        }

                        if (_isPlatformish(uri)) {
                          final web = _httpize(uri);
                          if (web.scheme == 'http' || web == uri) {
                            await _webOpen(web);
                          } else {
                            try {
                              if (await canLaunchUrl(uri)) {
                                await launchUrl(uri, mode: LaunchMode.externalApplication);
                              } else if (web != uri &&
                                  (web.scheme == 'http' || web.scheme == 'https')) {
                                await _webOpen(web);
                              }
                            } catch (_) {}
                          }
                          return NavigationActionPolicy.CANCEL;
                        }

                        if (sch != 'http' && sch != 'https') {
                          return NavigationActionPolicy.CANCEL;
                        }

                        return NavigationActionPolicy.ALLOW;
                      },
                      onCreateWindow: (c, req) async {
                        final uri = req.request.url;
                        if (uri == null) return false;

                        if (_isBareMail(uri)) {
                          final mailto = _mailize(uri);
                          await _webMail(mailto);
                          return false;
                        }

                        final sch = uri.scheme.toLowerCase();

                        if (sch == 'mailto') {
                          await _webMail(uri);
                          return false;
                        }

                        if (sch == 'tel') {
                          await launchUrl(uri, mode: LaunchMode.externalApplication);
                          return false;
                        }

                        if (_isPlatformish(uri)) {
                          final web = _httpize(uri);
                          if (web.scheme == 'http' || web.scheme == 'https') {
                            await _webOpen(web);
                          } else {
                            try {
                              if (await canLaunchUrl(uri)) {
                                await launchUrl(uri, mode: LaunchMode.externalApplication);
                              } else if (web != uri &&
                                  (web.scheme == 'http' || web.scheme == 'https')) {
                                await _webOpen(web);
                              }
                            } catch (_) {}
                          }
                          return false;
                        }

                        if (sch == 'http' || sch == 'https') {
                          c.loadUrl(urlRequest: URLRequest(url: uri));
                        }
                        return false;
                      },
                      onDownloadStartRequest: (c, req) async {
                        await _webOpen(req.url);
                      },
                    ),
                    Visibility(
                      visible: !_veil,
                      child: const MafiaPulseLoader(),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// Help-экраны
// ============================================================================
class MafiaHelp extends StatefulWidget {
  const MafiaHelp({super.key});

  @override
  State<MafiaHelp> createState() => _MafiaHelpState();
}

class _MafiaHelpState extends State<MafiaHelp> with WidgetsBindingObserver {
  InAppWebViewController? _ctrl;
  bool _spin = true;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            InAppWebView(
              initialFile: 'assets/index.html',
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                supportZoom: false,
                disableHorizontalScroll: false,
                disableVerticalScroll: false,
              ),
              onWebViewCreated: (c) => _ctrl = c,
              onLoadStart: (c, u) => setState(() => _spin = true),
              onLoadStop: (c, u) async => setState(() => _spin = false),
              onLoadError: (c, u, code, msg) => setState(() => _spin = false),
            ),
            if (_spin) const MafiaPulseLoader(),
          ],
        ),
      ),
    );
  }
}



class MafiaHelpLite extends StatefulWidget {
  const MafiaHelpLite({Key? key}) : super(key: key);

  @override
  State<MafiaHelpLite> createState() => _MafiaHelpLiteState();
}

class _MafiaHelpLiteState extends State<MafiaHelpLite> {
  InAppWebViewController? _wvc;
  bool _ld = true;

  Future<void> _tryGoBack() async {
    final ctrl = _wvc;
    if (ctrl == null) return;
    try {
      final canBack = await ctrl.canGoBack();
      if (canBack) {
        await ctrl.goBack();
      } else {
        // Нечего делать: истории назад нет — просто игнорируем нажатие
      }
    } catch (_) {
      // безопасно игнорируем возможные ошибки платформы
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        leadingWidth: 56,
        leading: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: InkWell(
            onTap: _tryGoBack,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white, // белая кнопка
                borderRadius: BorderRadius.circular(12),
              ),
              alignment: Alignment.center,
              child: const Icon(
                Icons.arrow_back_rounded,
                color: Colors.black, // стрелка контрастная
              ),
            ),
          ),
        ),
        // при желании можно добавить заголовок
        // title: const Text(''),
      ),
      body: SafeArea(
        child: Stack(
          children: [
            InAppWebView(
              initialFile: 'assets/mafia.html',
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                supportZoom: false,
                disableHorizontalScroll: false,
                disableVerticalScroll: false,
                transparentBackground: true,
                mediaPlaybackRequiresUserGesture: false,
                disableDefaultErrorPage: true,
                allowsInlineMediaPlayback: true,
                allowsPictureInPictureMediaPlayback: true,
                useOnDownloadStart: true,
                javaScriptCanOpenWindowsAutomatically: true,
              ),
              onWebViewCreated: (controller) {
                _wvc = controller;
              },
              onLoadStart: (controller, url) {
                setState(() => _ld = true);
              },
              onLoadStop: (controller, url) async {
                setState(() => _ld = false);
              },
              onLoadError: (controller, url, code, message) {
                setState(() => _ld = false);
              },
            ),
            if (_ld)
              const Positioned.fill(
                child: IgnorePointer(
                  ignoring: true,
                  child: MafiaPulseLoader(),
                ),
              ),
          ],
        ),
      ),
    );
  }
}


// ============================================================================
// main()
// ============================================================================
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(mafiaBgFcm);

  if (Platform.isAndroid) {
    await InAppWebViewController.setWebContentsDebuggingEnabled(true);
  }
  tz_data.initializeTimeZones();

  runApp(
    p.MultiProvider(
      providers: [
        mafiaConsigliereProvider,
      ],
      child: r.ProviderScope(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          home: const MafiaVestibule(),
        ),
      ),
    ),
  );
}