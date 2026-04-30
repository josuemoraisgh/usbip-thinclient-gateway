import 'dart:async';
import 'dart:ffi' hide Size;
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

// ─── Constantes ──────────────────────────────────────────────────────────────

const _statePath = r'C:\ProgramData\UsbipBrokerCpp\state.txt';
const _auditPath = r'C:\ProgramData\UsbipBrokerCpp\logs\audit.csv';
const _mutexName = 'Local\\UsbipMonitorTray';

// ─── Modelo ──────────────────────────────────────────────────────────────────

class ConnectedDevice {
  final String timestamp;
  final String station;
  final String hostIp;
  final String busid;
  final String vid;
  final String pid;
  final String description;
  final String comPort;

  const ConnectedDevice({
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

List<ConnectedDevice> _loadConnectedDevices() {
  final file = File(_statePath).existsSync()
      ? File(_statePath)
      : File(_auditPath);
  if (!file.existsSync()) return [];
  final lines = file.readAsLinesSync();
  if (lines.length <= 1) return [];
  final entries = lines
      .skip(1)
      .where((l) => l.trim().isNotEmpty)
      .map((l) {
        final cols = _parseCsvLine(l);
        if (cols.length < 8) return null;
        return ConnectedDevice(
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
      .whereType<ConnectedDevice>()
      .toList();
  if (file.path == _statePath) {
    return entries;
  }
  final seen = <String>{};
  final latest = <ConnectedDevice>[];
  for (final entry in entries.reversed) {
    final key = '${entry.hostIp}/${entry.busid}';
    if (seen.add(key)) {
      latest.add(entry);
    }
  }
  return latest.reversed.toList();
}

// ─── Ponto de entrada ────────────────────────────────────────────────────────

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Garante uma instância por sessão de usuário.
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
    await windowManager.setPreventClose(false);
    await windowManager.setMinimumSize(const Size(680, 380));
    await windowManager.show();
    await windowManager.focus();
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

class _HomePageState extends State<_HomePage> with WindowListener {
  List<ConnectedDevice> _entries = [];
  String _statusLine = 'Aguardando dados...';
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    windowManager.removeListener(this);
    super.dispose();
  }

  void _refresh() {
    final entries = _loadConnectedDevices();
    if (!mounted) return;
    setState(() {
      _entries = entries;
      if (entries.isEmpty) {
        _statusLine = File(_statePath).existsSync() || File(_auditPath).existsSync()
            ? 'Nenhum dispositivo conectado agora.'
            : 'Aguardando estado atual do broker.';
      } else {
        final now = DateTime.now();
        final hms =
            '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
        _statusLine =
            '${entries.length} conectado(s) agora  \u2022  atualizado \u00e0s $hms';
      }
    });
  }

  // ── WindowListener ────────────────────────────────────────────────────────

  @override
  void onWindowMinimize() => windowManager.close();

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
            tooltip: 'Fechar janela',
            onPressed: () => windowManager.close(),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _entries.isEmpty
                ? _EmptyState(message: _statusLine)
                : _ConnectedTable(entries: _entries),
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

// ─── Tabela de conexões atuais ───────────────────────────────────────────────

class _Col {
  final String label;
  final double width;
  const _Col(this.label, this.width);
}

class _ConnectedTable extends StatelessWidget {
  final List<ConnectedDevice> entries;
  const _ConnectedTable({required this.entries});

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
