// ignore_for_file: non_constant_identifier_names, prefer_final_fields, unnecessary_brace_in_string_interps

import 'dart:convert';
import 'dart:io';

import 'package:appsflyer_sdk/appsflyer_sdk.dart' show AppsFlyerOptions, AppsflyerSdk;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodCall, MethodChannel, SystemUiOverlayStyle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:timezone/data/latest.dart' as timezone_data;
import 'package:timezone/timezone.dart' as timezone;
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'main.dart' show MainHandler, WebPage, PortalView, ScreenPortal, GateVortex, ZxHubView, hvViewModel, crHarbor, MafiaHarbor;

/// FCM Background Handler — пиратская шхуна слушает трубу
@pragma('vm:entry-point')
Future<void> blackflag_bg_parrot(RemoteMessage msg_bottle) async {
  print("Bottle ID: ${msg_bottle.messageId}");
  print("Bottle Data: ${msg_bottle.data}");
}

/// Виджет-каюта с веб-вью — главный борт
class CaptainDeck extends StatefulWidget with WidgetsBindingObserver {
  String seaRoute;
  CaptainDeck(this.seaRoute, {super.key});

  @override
  State<CaptainDeck> createState() => _CaptainDeckState(seaRoute);
}

class _CaptainDeckState extends State<CaptainDeck> with WidgetsBindingObserver {
  _CaptainDeckState(this._currentRoute);

  late InAppWebViewController _helm;
  String? _parrotToken; // FCM token
  String? _shipId;      // device id
  String? _shipBuild;   // os build
  String? _shipKind;    // android/ios
  String? _shipOS;      // locale/lang
  String? _appSextant;  // timezone name (оставляем как в исходнике)
  bool _cannonArmed = true; // push enabled
  bool _crewBusy = false;
  var _gateOpen = true;
  String _currentRoute;
  DateTime? _lastDockTime;

  // Внешние гавани (tg/wa/bnl)
  final Set<String> _harborHosts = {
    't.me', 'telegram.me', 'telegram.dog',
    'wa.me', 'api.whatsapp.com', 'chat.whatsapp.com',
    'bnl.com', 'www.bnl.com',
  };
  final Set<String> _harborSchemes = {'tg', 'telegram', 'whatsapp', 'bnl'};

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState tide) {
    if (tide == AppLifecycleState.paused) {
      _lastDockTime = DateTime.now();
    }
    if (tide == AppLifecycleState.resumed) {
      if (Platform.isIOS && _lastDockTime != null) {
        final now = DateTime.now();
        final drift = now.difference(_lastDockTime!);
        if (drift > const Duration(minutes: 25)) {
          _hardReloadToHarbor();
        }
      }
      _lastDockTime = null;
    }
  }

  void _hardReloadToHarbor() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(
          builder: (context) => MafiaHarbor(signal: ""),
        ),
            (route) => false,
      );
    });
  }

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);

    FirebaseMessaging.onBackgroundMessage(blackflag_bg_parrot);

    _rigParrotFCM();
    _scanShipGizmo();
    _wireForedeckFCM();
    _bindBellFromCrowNest();

    Future.delayed(const Duration(seconds: 2), () {
      // поздняя инициализация по курсу
    });
    Future.delayed(const Duration(seconds: 6), () {
      // резерв
    });
  }

  void _wireForedeckFCM() {
    FirebaseMessaging.onMessage.listen((RemoteMessage bottle) {
      if (bottle.data['uri'] != null) {
        _sailTo(bottle.data['uri'].toString());
      } else {
        _returnToCourse();
      }
    });

    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage bottle) {
      if (bottle.data['uri'] != null) {
        _sailTo(bottle.data['uri'].toString());
      } else {
        _returnToCourse();
      }
    });
  }

  void _sailTo(String new_lane) async {
    if (_helm != null) {
      await _helm.loadUrl(urlRequest: URLRequest(url: WebUri(new_lane)));
    }
  }

  void _returnToCourse() async {
    Future.delayed(const Duration(seconds: 3), () {
      if (_helm != null) {
        _helm.loadUrl(urlRequest: URLRequest(url: WebUri(_currentRoute)));
      }
    });
  }

  Future<void> _rigParrotFCM() async {
    FirebaseMessaging deck = FirebaseMessaging.instance;
    NotificationSettings sails = await deck.requestPermission(alert: true, badge: true, sound: true);
    _parrotToken = await deck.getToken();
  }

  AppsflyerSdk? _afSpyglass;
  String _afChest = "";
  String _afId = "";



  Future<void> _scanShipGizmo() async {
    try {
      final spy = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final a = await spy.androidInfo;
        _shipId = a.id;
        _shipKind = "android";
        _shipBuild = a.version.release;
      } else if (Platform.isIOS) {
        final i = await spy.iosInfo;
        _shipId = i.identifierForVendor;
        _shipKind = "ios";
        _shipBuild = i.systemVersion;
      }
      final pkg = await PackageInfo.fromPlatform();
      _shipOS = Platform.localeName.split('_')[0];
      _appSextant = timezone.local.name;
    } catch (e) {
      debugPrint("Ship Gizmo Error: $e");
    }
  }

  /// Привязываем колокол — обработчик взаимодействия нотификаций из платформы
  void _bindBellFromCrowNest() {
    MethodChannel('com.example.fcm/notification').setMethodCallHandler((MethodCall call) async {
      if (call.method == "onNotificationTap") {
        final Map<String, dynamic> bottle = Map<String, dynamic>.from(call.arguments);
        print("URI from mast: ${bottle['uri']}");
        if (bottle["uri"] != null && !bottle["uri"].toString().contains("Нет URI")) {
          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute(builder: (context) => CaptainDeck(bottle["uri"])),
                (route) => false,
          );
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    _bindBellFromCrowNest(); // держим крепко, как в оригинале

    final isNight = MediaQuery.of(context).platformBrightness == Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: isNight ? SystemUiOverlayStyle.dark : SystemUiOverlayStyle.light,
      child: Scaffold(
        body: Stack(
          children: [
            InAppWebView(
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
              ),
              initialUrlRequest: URLRequest(url: WebUri.uri(Uri.parse(_currentRoute))),
              onWebViewCreated: (controller) {
                _helm = controller;
                // Загружаем стартовый маршрут


                _helm.addJavaScriptHandler(
                  handlerName: 'onServerResponse',
                  callback: (args) {
                    print("JS Args: $args");
                    try {
                      return args.reduce((v, e) => v + e);
                    } catch (_) {
                      return args.toString();
                    }
                  },
                );
              },
              onLoadStart: (controller, uri) async {
                if (uri != null) {
                  if (_looksLikeBottleMail(uri)) {
                    try { await controller.stopLoading(); } catch (_) {}
                    final mailto = _craftMailto(uri);
                    await _openMailInWeb(mailto);
                    return;
                  }
                  final s = uri.scheme.toLowerCase();
                  if (s != 'http' && s != 'https') {
                    try { await controller.stopLoading(); } catch (_) {}
                  }
                }
              },
              onLoadStop: (controller, uri) async {
                await controller.evaluateJavascript(source: "console.log('Ahoy from JS!');");
              },
              shouldOverrideUrlLoading: (controller, nav) async {
                final uri = nav.request.url;
                if (uri == null) return NavigationActionPolicy.ALLOW;

                if (_looksLikeBottleMail(uri)) {
                  final mailto = _craftMailto(uri);
                  await _openMailInWeb(mailto);
                  return NavigationActionPolicy.CANCEL;
                }

                final sch = uri.scheme.toLowerCase();
                if (sch == 'mailto') {
                  await _openMailInWeb(uri);
                  return NavigationActionPolicy.CANCEL;
                }

                if (_isOuterHarbor(uri)) {
                  await _openInHarbor(_mapOuterToHttp(uri));
                  return NavigationActionPolicy.CANCEL;
                }

                if (sch != 'http' && sch != 'https') {
                  return NavigationActionPolicy.CANCEL;
                }

                return NavigationActionPolicy.ALLOW;
              },
              onCreateWindow: (controller, req) async {
                final u = req.request.url;
                if (u == null) return false;

                if (_looksLikeBottleMail(u)) {
                  final m = _craftMailto(u);
                  await _openMailInWeb(m);
                  return false;
                }

                final sch = u.scheme.toLowerCase();
                if (sch == 'mailto') {
                  await _openMailInWeb(u);
                  return false;
                }

                if (_isOuterHarbor(u)) {
                  await _openInHarbor(_mapOuterToHttp(u));
                  return false;
                }

                if (sch == 'http' || sch == 'https') {
                  controller.loadUrl(urlRequest: URLRequest(url: u));
                }
                return false;
              },
            ),

            // Индикатор загрузки — в оригинале он был спрятан из-за Visibility, починим
            if (_crewBusy)
              Positioned.fill(
                child: Container(
                  color: Colors.black87,
                  child: Center(
                    child: CircularProgressIndicator(
                      backgroundColor: Colors.grey.shade800,
                      valueColor: const AlwaysStoppedAnimation<Color>(Colors.amber),
                      strokeWidth: 6,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // =========================
  // Пиратские утилиты
  // =========================

  bool _looksLikeBottleMail(Uri u) {
    final s = u.scheme;
    if (s.isNotEmpty) return false;
    final raw = u.toString();
    return raw.contains('@') && !raw.contains(' ');
  }

  Uri _craftMailto(Uri u) {
    final full = u.toString();
    final bits = full.split('?');
    final who = bits.first;
    final qp = bits.length > 1 ? Uri.splitQueryString(bits[1]) : <String, String>{};
    return Uri(
      scheme: 'mailto',
      path: who,
      queryParameters: qp.isEmpty ? null : qp,
    );
  }

  bool _isOuterHarbor(Uri u) {
    final sch = u.scheme.toLowerCase();
    if (_harborSchemes.contains(sch)) return true;

    if (sch == 'http' || sch == 'https') {
      final h = u.host.toLowerCase();
      if (_harborHosts.contains(h)) return true;
    }
    return false;
  }

  Uri _mapOuterToHttp(Uri u) {
    final sch = u.scheme.toLowerCase();

    if (sch == 'tg' || sch == 'telegram') {
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

    if (sch == 'whatsapp') {
      final qp = u.queryParameters;
      final phone = qp['phone'];
      final text = qp['text'];
      if (phone != null && phone.isNotEmpty) {
        return Uri.https('wa.me', '/${_digitsOnly(phone)}', {
          if (text != null && text.isNotEmpty) 'text': text,
        });
      }
      return Uri.https('wa.me', '/', {if (text != null && text.isNotEmpty) 'text': text});
    }

    if (sch == 'bnl') {
      final newPath = u.path.isNotEmpty ? u.path : '';
      return Uri.https('bnl.com', '/$newPath', u.queryParameters.isEmpty ? null : u.queryParameters);
    }

    return u;
  }

  Future<bool> _openMailInWeb(Uri m) async {
    final g = _gmailCourse(m);
    return await _openInHarbor(g);
  }

  Uri _gmailCourse(Uri m) {
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

  Future<bool> _openInHarbor(Uri u) async {
    try {
      if (await launchUrl(u, mode: LaunchMode.inAppBrowserView)) return true;
      return await launchUrl(u, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('openInHarbor squall: $e; url=$u');
      try {
        return await launchUrl(u, mode: LaunchMode.externalApplication);
      } catch (_) {
        return false;
      }
    }
  }

  String _digitsOnly(String s) => s.replaceAll(RegExp(r'[^0-9+]'), '');
}