import 'dart:async';
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

// ─── Constantes ──────────────────────────────────────────────────────────────

const _auditPath = r'C:\ProgramData\UsbipBrokerCpp\logs\audit.csv';
const _mutexName = 'Global\\UsbipMonitorTray';

// ─── Modelo ──────────────────────────────────────────────────────────────────

class AuditEntry {
  final String timestamp;
  final String station;
  final String hostIp;
  final String busid;
  final String vid;
  final String pid;
  final String description;
  final String comPort;

  const AuditEntry({
    required this.timestamp,
    required this.station,
    required this.hostIp,
    required this.busid,
    required this.vid,
    required this.pid,
    required this.description,
    required this.comPort,
  });
}

// ─── Instância única via Named Mutex Win32 ───────────────────────────────────

final _kernel32 = DynamicLibrary.open('kernel32.dll');

final _createMutexW = _kernel32
    .lookupFunction<
      IntPtr Function(Pointer, Int32, Pointer<Utf16>),
      int Function(Pointer, int, Pointer<Utf16>)
    >('CreateMutexW');

final _getLastError = _kernel32
    .lookupFunction<Uint32 Function(), int Function()>('GetLastError');

// ERROR_ALREADY_EXISTS = 183
bool _acquireSingleInstance() {
  final namePtr = _mutexName.toNativeUtf16();
  final handle = _createMutexW(nullptr, 0, namePtr);
  final lastError = _getLastError();
  malloc.free(namePtr);
  return handle != 0 && lastError != 183;
}

// ─── Parser CSV ──────────────────────────────────────────────────────────────

List<String> _parseCsvLine(String line) {
  final fields = <String>[];
  final buf = StringBuffer();
  bool inQ = false;
  for (int i = 0; i < line.length; i++) {
    final c = line[i];
    if (inQ) {
      if (c == '"' && i + 1 < line.length && line[i + 1] == '"') {
        buf.write('"');
        i++;
      } else if (c == '"') {
        inQ = false;
      } else {
        buf.write(c);
      }
    } else if (c == '"') {
      inQ = true;
    } else if (c == ',') {
      fields.add(buf.toString());
      buf.clear();
    } else {
      buf.write(c);
    }
  }
  fields.add(buf.toString());
  return fields;
}

List<AuditEntry> _loadEntries() {
  final file = File(_auditPath);
  if (!file.existsSync()) return [];
  final lines = file.readAsLinesSync();
  if (lines.length <= 1) return [];
  return lines
      .skip(1)
      .where((l) => l.trim().isNotEmpty)
      .map((l) {
        final cols = _parseCsvLine(l);
        if (cols.length < 8) return null;
        return AuditEntry(
          timestamp: cols[0],
          station: cols[1],
          hostIp: cols[2],
          busid: cols[3],
          vid: cols[4],
          pid: cols[5],
          description: cols[6],
          comPort: cols[7],
        );
      })
      .whereType<AuditEntry>()
      .toList()
      .reversed
      .toList();
}

// ─── Ícone da bandeja gerado em runtime ──────────────────────────────────────

Future<String> _makeTrayIconPath() async {
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec);

  canvas.drawRRect(
    RRect.fromRectAndRadius(
      const Rect.fromLTWH(0, 0, 32, 32),
      const Radius.circular(5),
    ),
    Paint()..color = const Color(0xFF1565C0),
  );

  final stroke = Paint()
    ..color = Colors.white
    ..strokeWidth = 2.0
    ..style = PaintingStyle.stroke;

  // Símbolo USB simplificado
  canvas.drawLine(const Offset(16, 5), const Offset(16, 20), stroke);
  canvas.drawLine(const Offset(10, 13), const Offset(22, 13), stroke);
  canvas.drawLine(const Offset(10, 13), const Offset(10, 19), stroke);
  canvas.drawLine(const Offset(22, 13), const Offset(22, 19), stroke);

  final dot = Paint()..color = Colors.white;
  canvas.drawCircle(const Offset(16, 5), 2.5, dot);
  canvas.drawCircle(const Offset(10, 21), 3.0, dot);
  canvas.drawCircle(const Offset(22, 21), 3.0, dot);

  final img = await rec.endRecording().toImage(32, 32);
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);

  final path = '${Directory.systemTemp.path}\\usbip_tray.png';
  await File(path).writeAsBytes(bytes!.buffer.asUint8List());
  return path;
}

// ─── Ponto de entrada ────────────────────────────────────────────────────────

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Garante instância única na máquina via mutex com prefixo Global\
  if (!_acquireSingleInstance()) {
    exit(0);
  }

  await windowManager.ensureInitialized();

  const opts = WindowOptions(
    size: Size(940, 540),
    center: true,
    title: 'USB/IP Monitor \u2013 COM \u00d7 Esta\u00e7\u00e3o',
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.normal,
  );

  await windowManager.waitUntilReadyToShow(opts, () async {
    await windowManager.setPreventClose(true);
    await windowManager.setMinimumSize(const Size(680, 380));
    await windowManager.hide();
  });

  runApp(const _App());
}

// ─── App ─────────────────────────────────────────────────────────────────────

class _App extends StatelessWidget {
  const _App();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'USB/IP Monitor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1565C0)),
        useMaterial3: true,
      ),
      home: const _HomePage(),
    );
  }
}

// ─── Página principal ────────────────────────────────────────────────────────

class _HomePage extends StatefulWidget {
  const _HomePage();

  @override
  State<_HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<_HomePage>
    with TrayListener, WindowListener {
  List<AuditEntry> _entries = [];
  String _statusLine = 'Aguardando dados...';
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    trayManager.addListener(this);
    windowManager.addListener(this);
    _initTray();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _initTray() async {
    final iconPath = await _makeTrayIconPath();
    await trayManager.setIcon(iconPath);
    await trayManager.setToolTip(
      'USB/IP Monitor \u2013 COM \u00d7 Esta\u00e7\u00e3o',
    );
    await _rebuildTrayMenu();
  }

  Future<void> _rebuildTrayMenu() async {
    final visible = await windowManager.isVisible();
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(
            key: 'toggle',
            label: visible ? 'Ocultar janela' : 'Mostrar janela',
          ),
          MenuItem.separator(),
          MenuItem(key: 'refresh', label: 'Atualizar agora'),
          MenuItem.separator(),
          MenuItem(key: 'exit', label: 'Sair do monitor'),
        ],
      ),
    );
  }

  void _refresh() {
    final entries = _loadEntries();
    if (!mounted) return;
    setState(() {
      _entries = entries;
      if (entries.isEmpty) {
        _statusLine = File(_auditPath).existsSync()
            ? 'Nenhum registro no log de auditoria.'
            : 'Arquivo n\u00e3o encontrado: $_auditPath';
      } else {
        final now = DateTime.now();
        final hms =
            '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
        _statusLine =
            '${entries.length} registro(s)  \u2022  \u00faltima leitura \u00e0s $hms';
      }
    });
  }

  Future<void> _toggleWindow() async {
    if (await windowManager.isVisible()) {
      await windowManager.hide();
    } else {
      await windowManager.show();
      await windowManager.focus();
    }
    await _rebuildTrayMenu();
  }

  Future<void> _exitApp() async {
    await trayManager.destroy();
    await windowManager.setPreventClose(false);
    await windowManager.close();
  }

  // ── TrayListener ─────────────────────────────────────────────────────────

  @override
  void onTrayIconMouseDown() => _toggleWindow();

  @override
  void onTrayIconRightMouseDown() {
    _rebuildTrayMenu().then((_) => trayManager.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem item) {
    switch (item.key) {
      case 'toggle':
        _toggleWindow();
      case 'refresh':
        _refresh();
      case 'exit':
        _exitApp();
    }
  }

  // ── WindowListener ────────────────────────────────────────────────────────

  @override
  void onWindowClose() {
    // Esconde para a bandeja em vez de encerrar o processo
    windowManager.hide().then((_) => _rebuildTrayMenu());
  }

  // ── UI ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF1565C0),
        foregroundColor: Colors.white,
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.usb, size: 18),
            SizedBox(width: 8),
            Text('USB/IP Monitor', style: TextStyle(fontSize: 15)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, size: 18),
            tooltip: 'Atualizar',
            onPressed: _refresh,
          ),
          IconButton(
            icon: const Icon(Icons.minimize, size: 18),
            tooltip: 'Minimizar para a bandeja',
            onPressed: () =>
                windowManager.hide().then((_) => _rebuildTrayMenu()),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _entries.isEmpty
                ? _EmptyState(message: _statusLine)
                : _AuditTable(entries: _entries),
          ),
          _StatusBar(line: _statusLine),
        ],
      ),
    );
  }
}

// ─── Estado vazio ─────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final String message;
  const _EmptyState({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.usb_off, size: 56, color: Colors.grey),
          const SizedBox(height: 12),
          Text(
            message,
            style: const TextStyle(color: Colors.grey, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

// ─── Barra de status ──────────────────────────────────────────────────────────

class _StatusBar extends StatelessWidget {
  final String line;
  const _StatusBar({required this.line});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFFF5F5F5),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: Row(
        children: [
          const Icon(Icons.circle, size: 8, color: Colors.green),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              line,
              style: const TextStyle(fontSize: 11, color: Color(0xFF666666)),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Tabela de auditoria ──────────────────────────────────────────────────────

class _Col {
  final String label;
  final double width;
  const _Col(this.label, this.width);
}

class _AuditTable extends StatelessWidget {
  final List<AuditEntry> entries;
  const _AuditTable({required this.entries});

  static const _cols = [
    _Col('Data/Hora', 148),
    _Col('Esta\u00e7\u00e3o', 118),
    _Col('IP', 128),
    _Col('COM', 68),
    _Col('VID:PID', 88),
    _Col('Descri\u00e7\u00e3o', 240),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Cabeçalho fixo
        Container(
          color: const Color(0xFFE3F2FD),
          child: Row(
            children: _cols
                .map(
                  (c) => _Cell(
                    c.label,
                    c.width,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                )
                .toList(),
          ),
        ),
        // Linhas com scroll vertical
        Expanded(
          child: ListView.builder(
            itemCount: entries.length,
            itemBuilder: (_, i) {
              final e = entries[i];
              final unknownCom = e.comPort == '?';
              return Container(
                decoration: BoxDecoration(
                  color: unknownCom
                      ? const Color(0xFFFFF9C4)
                      : (i.isOdd ? const Color(0xFFFAFAFA) : Colors.white),
                  border: const Border(
                    bottom: BorderSide(color: Color(0xFFEEEEEE)),
                  ),
                ),
                child: Row(
                  children: [
                    _Cell(
                      e.timestamp,
                      _cols[0].width,
                      style: const TextStyle(
                        fontFamily: 'Courier New',
                        fontSize: 11,
                      ),
                    ),
                    _Cell(e.station, _cols[1].width),
                    _Cell(
                      e.hostIp,
                      _cols[2].width,
                      style: const TextStyle(
                        fontFamily: 'Courier New',
                        fontSize: 12,
                      ),
                    ),
                    _Cell(
                      e.comPort,
                      _cols[3].width,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontFamily: 'Courier New',
                        color: unknownCom
                            ? Colors.orange
                            : const Color(0xFF1565C0),
                      ),
                    ),
                    _Cell(
                      '${e.vid}:${e.pid}',
                      _cols[4].width,
                      style: const TextStyle(
                        fontFamily: 'Courier New',
                        fontSize: 11,
                      ),
                    ),
                    _Cell(
                      e.description,
                      _cols[5].width,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _Cell extends StatelessWidget {
  final String text;
  final double width;
  final TextStyle? style;
  const _Cell(this.text, this.width, {this.style});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        child: Text(
          text,
          overflow: TextOverflow.ellipsis,
          style: style ?? const TextStyle(fontSize: 12),
        ),
      ),
    );
  }
}
