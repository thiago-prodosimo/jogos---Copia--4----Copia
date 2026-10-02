import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show DeviceOrientation, SystemChrome, SystemNavigator, SystemUiMode, rootBundle;
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const NesWebViewApp());
}

class NesWebViewApp extends StatelessWidget {
  const NesWebViewApp({super.key, this.home});

  final Widget? home;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'NES Web',
    home: home ?? const NesWebViewPage(),
  );
}

class NesWebViewPage extends StatefulWidget {
  const NesWebViewPage({super.key});

  @override
  State<NesWebViewPage> createState() => _NesWebViewPageState();
}

class _NesWebViewPageState extends State<NesWebViewPage> {
  late final WebViewController _controller;
  LocalAssetServer? _assetServer;
  int _progress = 0;
  bool _starting = true;
  WebResourceError? _error;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'AppMode',
        onMessageReceived: (message) {
          if (message.message == 'play') {
            unawaited(_enterGameMode());
          } else if (message.message == 'catalog') {
            unawaited(_leaveGameMode());
          }
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) => setState(() => _progress = progress),
          onWebResourceError: (error) {
            if (error.isForMainFrame ?? true) setState(() => _error = error);
          },
        ),
      );
    _configureAndroidFilePicker();
    unawaited(_startWebApp());
  }

  /// O WebView Android não abre inputs `type=file` automaticamente. Esta ponte
  /// devolve à página HTML a URI da ROM escolhida pelo usuário.
  void _configureAndroidFilePicker() {
    final platformController = _controller.platform;
    if (platformController is AndroidWebViewController) {
      platformController.setOnShowFileSelector(_selectRomFile);
    }
  }

  Future<List<String>> _selectRomFile(FileSelectorParams params) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['nes'],
      allowMultiple: params.mode == FileSelectorMode.openMultiple,
      withData: false,
    );

    if (result == null) return const [];

    return result.files
        .map((file) => file.path)
        .whereType<String>()
        .map((path) => Uri.file(path).toString())
        .toList(growable: false);
  }

  Future<void> _startWebApp() async {
    try {
      _assetServer ??= await LocalAssetServer.start();
      await _controller.loadRequest(_assetServer!.url.resolve('index.html'));
      if (mounted) setState(() => _starting = false);
    } catch (error) {
      if (mounted) {
        setState(() {
          _starting = false;
          _error = WebResourceError(
            errorCode: -1,
            description: 'Não foi possível iniciar os arquivos locais: $error',
            errorType: WebResourceErrorType.unknown,
            isForMainFrame: true,
          );
        });
      }
    }
  }

  void _retry() {
    setState(() {
      _error = null;
      _progress = 0;
    });
    unawaited(_startWebApp());
  }

  /// Intercepta o voltar nativo para fechar a camada HTML atual, ou fechar o app se estiver no início.
  Future<void> _handleSystemBack() async {
    if (_starting || _error != null) return;

    try {
      final result = await _controller.runJavaScriptReturningResult('''
        (() => {
          const emulator = document.getElementById('emulatorView');
          if (emulator && !emulator.classList.contains('hidden')) {
            window.closeEmulatorPage?.();
            return true;
          }

          const gameModal = document.getElementById('gameModal');
          if (gameModal && !gameModal.classList.contains('hidden')) {
            window.closeGameModal?.();
            return true;
          }

          const myList = document.getElementById('myListSection');
          if (myList && !myList.classList.contains('hidden')) {
            window.showHome?.();
            return true;
          }

          const searchResults = document.getElementById('searchResultsSection');
          if (searchResults && !searchResults.classList.contains('hidden')) {
            window.clearSearch?.();
            return true;
          }

          return false;
        })();
      ''');

      if (result == false || result == 'false') {
        await SystemNavigator.pop();
      }
    } catch (_) {
      await SystemNavigator.pop();
    }
  }

  Future<void> _enterGameMode() async {
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  Future<void> _leaveGameMode() async {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
  }

  @override
  void dispose() {
    unawaited(_leaveGameMode());
    unawaited(_assetServer?.close() ?? Future<void>.value());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(_handleSystemBack());
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF030712),
        body: SafeArea(
          child: _starting
              ? const Center(
                  child: Image(
                    image: AssetImage('assets/loading/carregamento.logo.gif'),
                    fit: BoxFit.contain,
                  ),
                )
              : error == null
              ? Stack(
                  children: [
                    WebViewWidget(controller: _controller),
                    if (_progress < 100)
                      LinearProgressIndicator(value: _progress / 100),
                  ],
                )
              : Semantics(
                  label: 'Não foi possível abrir o emulador',
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.error_outline,
                            color: Colors.white,
                            size: 48,
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            'Não foi possível abrir o emulador.',
                            style: TextStyle(color: Colors.white, fontSize: 18),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            error.description,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white70),
                          ),
                          const SizedBox(height: 20),
                          FilledButton.icon(
                            onPressed: _retry,
                            icon: const Icon(Icons.refresh),
                            label: const Text('Tentar novamente'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

/// Expõe os assets do app em loopback para que o `fetch` do JavaScript use
/// uma origem HTTP, em vez de URLs `file://` bloqueadas pelo WebView Android.
class LocalAssetServer {
  LocalAssetServer._(this._server);

  final HttpServer _server;
  final Map<String, Uint8List> _shellCache = {};

  Uri get url =>
      Uri.parse('http://${_server.address.address}:${_server.port}/');

  static Future<LocalAssetServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final assetServer = LocalAssetServer._(server);
    unawaited(assetServer._warmShellCache());
    unawaited(assetServer._serveRequests());
    return assetServer;
  }

  Future<void> _warmShellCache() async {
    await Future.wait(
      [
        'index.html',
        'styles.css',
        'jsnes.min.js',
        'Jogosnes/jogos.json',
      ].map(_loadCachedAsset),
    );
  }

  bool _shouldCache(String path) =>
      path.endsWith('.html') ||
      path.endsWith('.css') ||
      path.endsWith('.js') ||
      path.endsWith('.json');

  Future<Uint8List> _loadCachedAsset(String path) async {
    final cached = _shellCache[path];
    if (cached != null) return cached;

    final asset = await rootBundle.load('assets/web/$path');
    final bytes = asset.buffer.asUint8List(
      asset.offsetInBytes,
      asset.lengthInBytes,
    );
    _shellCache[path] = bytes;
    return bytes;
  }

  Future<void> _serveRequests() async {
    await for (final request in _server) {
      final rawPath = request.uri.path == '/'
          ? 'index.html'
          : request.uri.path.substring(1);
      String decodedPath = rawPath;
      try {
        decodedPath = Uri.decodeComponent(rawPath);
      } catch (_) {}

      if (decodedPath.split('/').any((segment) => segment == '..')) {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
        continue;
      }

      try {
        late final Uint8List bytes;
        if (_shouldCache(decodedPath)) {
          bytes = await _loadCachedAsset(decodedPath);
        } else {
          final asset = await rootBundle.load('assets/web/$decodedPath');
          bytes = asset.buffer.asUint8List(
            asset.offsetInBytes,
            asset.lengthInBytes,
          );
        }
        request.response.headers.contentType = _contentTypeFor(decodedPath);
        request.response.headers.set(
          HttpHeaders.cacheControlHeader,
          _shouldCache(decodedPath) ? 'public, max-age=3600' : 'no-store',
        );
        request.response.add(bytes);
      } catch (_) {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    }
  }

  Future<void> close() => _server.close(force: true);

  ContentType _contentTypeFor(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.html')) return ContentType.html;
    if (lower.endsWith('.json')) return ContentType.json;
    if (lower.endsWith('.js')) return ContentType('application', 'javascript');
    if (lower.endsWith('.css')) return ContentType('text', 'css');
    if (lower.endsWith('.nes')) return ContentType('application', 'octet-stream');
    if (lower.endsWith('.png')) return ContentType('image', 'png');
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return ContentType('image', 'jpeg');
    if (lower.endsWith('.gif')) return ContentType('image', 'gif');
    if (lower.endsWith('.webp')) return ContentType('image', 'webp');
    return ContentType.binary;
  }
}
