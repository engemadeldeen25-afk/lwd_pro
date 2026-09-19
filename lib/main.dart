import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:csv/csv.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:intl/intl.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LWDProApp());
}

// ============================================================
//  APP
// ============================================================
class LWDProApp extends StatelessWidget {
  const LWDProApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LWD PRO',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0A0E1A),
        primaryColor: const Color(0xFF1E88E5),
        cardColor: const Color(0xFF151B2E),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0A0E1A),
          elevation: 0,
        ),
      ),
      home: const HomePage(),
    );
  }
}

// ============================================================
//  DATA MODELS
// ============================================================
class LWDReading {
  final double evd;
  final double deflection;
  final double accel;
  final double velocity;
  final double angle;
  final DateTime time;
  LWDReading({
    required this.evd,
    required this.deflection,
    required this.accel,
    required this.velocity,
    required this.angle,
    required this.time,
  });
}

class TestPoint {
  final int id;
  final DateTime time;
  final double evd;
  final double deflection;
  final double latitude;
  final double longitude;
  final bool passed;
  TestPoint({
    required this.id,
    required this.time,
    required this.evd,
    required this.deflection,
    required this.latitude,
    required this.longitude,
    required this.passed,
  });
}

// ============================================================
//  HOME PAGE
// ============================================================
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // BLE state
  BluetoothDevice? _device;
  BluetoothCharacteristic? _rx;
  StreamSubscription<List<int>>? _sub;
  bool _scanning = false;
  bool _connected = false;
  String _status = "Disconnected";

  // Live data
  LWDReading _live = LWDReading(
    evd: 0, deflection: 0, accel: 0, velocity: 0, angle: 0,
    time: DateTime.now(),
  );
  final List<double> _waveform = List.filled(60, 0);

  // Tests
  final List<TestPoint> _tests = [];
  int _nextId = 1;

  // Calibration / settings
  double _calFactor = 1.0;
  String _calDate = 'Never';
  double _targetEvd = 40.0;
  final String _password = 'admin123';
  late SharedPreferences _prefs;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _device?.disconnect();
    super.dispose();
  }

  // ============================================================
  //  INIT & PERMISSIONS
  // ============================================================
  Future<void> _init() async {
    // Request permissions one by one
    await Permission.location.request();
    await Permission.bluetoothScan.request();
    await Permission.bluetoothConnect.request();

    final scan = await Permission.bluetoothScan.status;
    final connect = await Permission.bluetoothConnect.status;
    final loc = await Permission.location.status;

    print("=== Permissions ===");
    print("BluetoothScan: $scan");
    print("BluetoothConnect: $connect");
    print("Location: $loc");

    if (!scan.isGranted || !connect.isGranted) {
      if (mounted) setState(() => _status = "Permissions denied");
      return;
    }

    _prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _calFactor = _prefs.getDouble('cal') ?? 1.0;
      _calDate = _prefs.getString('calDate') ?? 'Never';
      _targetEvd = _prefs.getDouble('target') ?? 40.0;
    });

    await Future.delayed(const Duration(milliseconds: 800));
    _startScan();
  }

  // ============================================================
  //  SCAN
  // ============================================================
  Future<void> _startScan() async {
    if (_scanning) return;

    if (!await FlutterBluePlus.isOn) {
      if (mounted) {
        setState(() => _status = "Bluetooth OFF");
        _snack("Please enable Bluetooth");
      }
      return;
    }

    setState(() {
      _scanning = true;
      _status = "Scanning...";
    });

    try { await FlutterBluePlus.stopScan(); } catch (_) {}
    await Future.delayed(const Duration(milliseconds: 500));

    BluetoothDevice? foundDevice;

    final sub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        final name = r.device.platformName;
        final advName = r.advertisementData.advName;
        if (name.contains("LWD") || advName.contains("LWD")) {
          if (foundDevice == null) {
            foundDevice = r.device;
            print("=== FOUND TARGET: ${r.device.remoteId} ===");
          }
        }
      }
    });

    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
    } catch (e) {
      print("=== Scan error: $e ===");
    }

    await Future.delayed(const Duration(seconds: 11));
    await sub.cancel();
    try { await FlutterBluePlus.stopScan(); } catch (_) {}

    if (!mounted) return;
    setState(() => _scanning = false);

    if (foundDevice != null) {
      _connect(foundDevice!);
    } else {
      setState(() => _status = "Not found");
      _snack("No LWD device found - tap scan again");
    }
  }

  // ============================================================
  //  CONNECT (with retry)
  // ============================================================
  Future<void> _connect(BluetoothDevice device) async {
    setState(() => _status = "Connecting...");
    print("=== Connecting to ${device.remoteId} ===");

    for (int attempt = 1; attempt <= 3; attempt++) {
      try {
        print("=== Attempt $attempt ===");
        await device.connect(timeout: const Duration(seconds: 15));
        print("=== Connected ===");

        await Future.delayed(const Duration(milliseconds: 700));

        final services = await device.discoverServices();
        print("=== ${services.length} services found ===");

        BluetoothCharacteristic? target;
        for (final s in services) {
          print("  Service: ${s.uuid}");
          for (final c in s.characteristics) {
            print("    Char: ${c.uuid}");
            final u = c.uuid.toString().toLowerCase().replaceAll('-', '');
            if (u == "6e400002b5a3f393e0a9e50e24dcca9e") {
              target = c;
              print("    ^^ TARGET MATCH ^^");
            }
          }
        }

        if (target == null) throw Exception("Characteristic not found");

        _device = device;
        _rx = target;

        await target.setNotifyValue(true);
        print("=== Notifications enabled ===");

        _sub = target.onValueReceived.listen((v) {
          final t = utf8.decode(v, allowMalformed: true);
          print("=== RX: $t ===");
          _onData(t);
        });

        setState(() {
          _connected = true;
          _status = "Online";
        });
        print("=== ONLINE ===");
        return;
      } catch (e) {
        print("=== Attempt $attempt failed: $e ===");
        if (attempt < 3) {
          try { await device.disconnect(); } catch (_) {}
          await Future.delayed(const Duration(seconds: 2));
        }
      }
    }

    if (!mounted) return;
    setState(() {
      _connected = false;
      _status = "Failed";
    });
    _snack("Connection failed - try again");
  }

  Future<void> _disconnect() async {
    await _sub?.cancel();
    _sub = null;
    try { await _device?.disconnect(); } catch (_) {}
    _device = null;
    _rx = null;
    if (!mounted) return;
    setState(() {
      _connected = false;
      _status = "Disconnected";
    });
  }

  // ============================================================
  //  DATA PARSING
  // ============================================================
  void _onData(String raw) {
    try {
      final t = raw.trim();
      if (!t.startsWith("{")) return;
      final m = jsonDecode(t) as Map<String, dynamic>;

      final evd = (m["evd"] ?? 0).toDouble() * _calFactor;
      final def = (m["def"] ?? 0).toDouble();
      final acc = (m["acc"] ?? 0).toDouble();
      final vel = (m["vel"] ?? 0).toDouble();
      final ang = (m["angle"] ?? 0).toDouble();

      if (!mounted) return;
      setState(() {
        _live = LWDReading(
          evd: evd, deflection: def, accel: acc, velocity: vel, angle: ang,
          time: DateTime.now(),
        );
        if (def > 0) {
          _waveform.add(def);
          if (_waveform.length > 60) _waveform.removeAt(0);
        }
      });

      if (def > 0.1 && evd > 0.5) _recordTest(evd, def);
    } catch (_) {}
  }

  Future<void> _recordTest(double evd, double def) async {
    if (_tests.isNotEmpty &&
        DateTime.now().difference(_tests.last.time).inSeconds < 2) {
      return;
    }
    double lat = 0, lng = 0;
    try {
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 2),
      );
      lat = pos.latitude;
      lng = pos.longitude;
    } catch (_) {}

    final p = TestPoint(
      id: _nextId++,
      time: DateTime.now(),
      evd: evd,
      deflection: def,
      latitude: lat,
      longitude: lng,
      passed: evd >= _targetEvd,
    );
    if (!mounted) return;
    setState(() => _tests.add(p));
  }

  // ============================================================
  //  CALIBRATION
  // ============================================================
  void _showCalDialog() {
    final pass = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF151B2E),
        title: const Text('🔐 Enter Password'),
        content: TextField(
          controller: pass,
          obscureText: true,
          decoration: const InputDecoration(hintText: 'Password'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              if (pass.text == _password) {
                Navigator.pop(ctx);
                _showCalEditor();
              } else {
                _snack('Wrong password');
              }
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showCalEditor() {
    final factor = TextEditingController(text: _calFactor.toStringAsFixed(3));
    final target = TextEditingController(text: _targetEvd.toStringAsFixed(1));
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF151B2E),
        title: const Text('Calibration'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: factor,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'EVD Multiplier'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: target,
              keyboardType: TextInputType.number,
              decoration:
                  const InputDecoration(labelText: 'Target EVD (MN/m²)'),
            ),
            const SizedBox(height: 12),
            Text('Last update: $_calDate',
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              final f = double.tryParse(factor.text);
              final t = double.tryParse(target.text);
              if (f != null && f > 0 && t != null && t > 0) {
                await _prefs.setDouble('cal', f);
                await _prefs.setDouble('target', t);
                await _prefs.setString(
                    'calDate',
                    DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now()));
                if (!mounted) return;
                setState(() {
                  _calFactor = f;
                  _targetEvd = t;
                  _calDate = _prefs.getString('calDate')!;
                });
                Navigator.pop(ctx);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  // ============================================================
  //  EXPORT CSV
  // ============================================================
  Future<void> _export() async {
    if (_tests.isEmpty) {
      _snack('No tests to export');
      return;
    }

    final rows = <List<dynamic>>[
      ['Test #', 'Date', 'Time', 'EVD (MN/m²)', 'Deflection (mm)',
       'Latitude', 'Longitude', 'Status'],
    ];
    for (final t in _tests) {
      rows.add([
        t.id,
        DateFormat('yyyy-MM-dd').format(t.time),
        DateFormat('HH:mm:ss').format(t.time),
        t.evd.toStringAsFixed(1),
        t.deflection.toStringAsFixed(3),
        t.latitude.toStringAsFixed(6),
        t.longitude.toStringAsFixed(6),
        t.passed ? 'PASS' : 'FAIL',
      ]);
    }

    final csv = const ListToCsvConverter().convert(rows);
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File(
          '${dir.path}/LWD_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.csv');
      await f.writeAsString(csv);
      await Share.shareXFiles([XFile(f.path)],
          subject: 'LWD Test Report');
      _snack('Report exported');
    } catch (e) {
      _snack('Export failed: $e');
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  // ============================================================
  //  UI
  // ============================================================
  @override
  Widget build(BuildContext context) {
    final passed = _live.evd >= _targetEvd;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: const [
            Icon(Icons.science, color: Color(0xFF00E5FF)),
            SizedBox(width: 8),
            Text('LWD PRO',
                style: TextStyle(
                    fontWeight: FontWeight.bold, letterSpacing: 1.2)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.lock, color: Colors.amber),
            onPressed: _showCalDialog,
            tooltip: 'Calibration',
          ),
          Container(
            margin: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: _connected
                  ? Colors.green.shade800
                  : Colors.red.shade800,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(_status,
                style: const TextStyle(
                    fontSize: 10, fontWeight: FontWeight.bold)),
          ),
          IconButton(
            icon: _scanning
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.bluetooth_searching),
            onPressed: (_connected || _scanning) ? null : _startScan,
          ),
          IconButton(
            icon: const Icon(Icons.power_settings_new),
            onPressed: _connected ? _disconnect : null,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildLiveCard(passed),
            const SizedBox(height: 12),
            _buildChartCard(),
            const SizedBox(height: 12),
            _buildStatsCard(),
            const SizedBox(height: 12),
            _buildActions(),
          ],
        ),
      ),
    );
  }

  Widget _buildLiveCard(bool passed) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF151B2E), Color(0xFF1E2740)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF2A3654), width: 1),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _metric('EVD MODULUS',
                  _live.evd.toStringAsFixed(1), 'MN/m²',
                  const Color(0xFF00E5FF), 42),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _metric('DEFLECTION',
                      _live.deflection.toStringAsFixed(3), 'mm',
                      Colors.orangeAccent, 26),
                  const SizedBox(height: 8),
                  _metric('ACCELERATION',
                      _live.accel.toStringAsFixed(2), 'g',
                      Colors.purpleAccent, 18),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color:
                      passed ? Colors.green.shade800 : Colors.red.shade800,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  children: [
                    Icon(
                      passed ? Icons.check_circle : Icons.cancel,
                      color: Colors.white,
                      size: 18,
                    ),
                    const SizedBox(width: 6),
                    Text(passed ? 'PASS' : 'FAIL',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.white)),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: LinearProgressIndicator(
                        value: (_live.evd / 80).clamp(0.0, 1.0),
                        minHeight: 8,
                        backgroundColor: Colors.grey.shade900,
                        valueColor: AlwaysStoppedAnimation(
                          passed ? Colors.green : Colors.red,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('0',
                            style: TextStyle(
                                fontSize: 9, color: Colors.grey.shade500)),
                        Text(
                            'Target ${_targetEvd.toStringAsFixed(0)}',
                            style: TextStyle(
                                fontSize: 9, color: Colors.grey.shade500)),
                        Text('80',
                            style: TextStyle(
                                fontSize: 9, color: Colors.grey.shade500)),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _smallInfo(
                  Icons.speed, '${_live.velocity.toStringAsFixed(3)} m/s'),
              _smallInfo(
                  Icons.straighten, '${_live.angle.toStringAsFixed(1)}°'),
              _smallInfo(
                  Icons.timer, DateFormat('HH:mm:ss').format(_live.time)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _metric(String label, String value, String unit, Color color,
      double size) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(
                color: Colors.grey.shade500,
                fontSize: 10,
                letterSpacing: 1)),
        const SizedBox(height: 4),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(value,
                style: TextStyle(
                    fontSize: size,
                    fontWeight: FontWeight.bold,
                    color: color)),
            const SizedBox(width: 4),
            Text(unit,
                style:
                    TextStyle(color: Colors.grey.shade500, fontSize: 12)),
          ],
        ),
      ],
    );
  }

  Widget _smallInfo(IconData icon, String text) {
    return Row(
      children: [
        Icon(icon, size: 14, color: Colors.grey.shade500),
        const SizedBox(width: 4),
        Text(text,
            style:
                TextStyle(color: Colors.grey.shade400, fontSize: 11)),
      ],
    );
  }

  Widget _buildChartCard() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF151B2E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF2A3654)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('DEFLECTION WAVEFORM',
              style: TextStyle(
                  color: Colors.grey, fontSize: 10, letterSpacing: 1)),
          const SizedBox(height: 8),
          SizedBox(
            height: 140,
            child: LineChart(
              LineChartData(
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  horizontalInterval: 0.5,
                  getDrawingHorizontalLine: (_) => FlLine(
                    color: Colors.grey.shade900,
                    strokeWidth: 1,
                  ),
                ),
                titlesData: const FlTitlesData(show: false),
                borderData: FlBorderData(show: false),
                minX: 0,
                maxX: 59,
                minY: -0.2,
                maxY: 2.5,
                lineBarsData: [
                  LineChartBarData(
                    spots: _waveform
                        .asMap()
                        .entries
                        .map((e) => FlSpot(e.key.toDouble(), e.value))
                        .toList(),
                    isCurved: true,
                    curveSmoothness: 0.3,
                    color: const Color(0xFF00E5FF),
                    barWidth: 2.5,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(
                      show: true,
                      gradient: LinearGradient(
                        colors: [
                          const Color(0xFF00E5FF).withOpacity(0.3),
                          const Color(0xFF00E5FF).withOpacity(0.0),
                        ],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsCard() {
    final passed = _tests.where((t) => t.passed).length;
    final failed = _tests.length - passed;
    final avg = _tests.isEmpty
        ? 0.0
        : _tests.map((t) => t.evd).reduce((a, b) => a + b) / _tests.length;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF151B2E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF2A3654)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('TEST SUMMARY',
              style: TextStyle(
                  color: Colors.grey, fontSize: 10, letterSpacing: 1)),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _stat('TOTAL', '${_tests.length}', Colors.white),
              _stat('PASS', '$passed', Colors.green),
              _stat('FAIL', '$failed', Colors.red),
              _stat('AVG', avg.toStringAsFixed(1),
                  const Color(0xFF00E5FF)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stat(String label, String value, Color color) {
    return Column(
      children: [
        Text(value,
            style: TextStyle(
                fontSize: 22, fontWeight: FontWeight.bold, color: color)),
        Text(label,
            style: TextStyle(color: Colors.grey.shade600, fontSize: 10)),
      ],
    );
  }

  Widget _buildActions() {
    return Row(
      children: [
        Expanded(
          child: ElevatedButton.icon(
            onPressed: _export,
            icon: const Icon(Icons.file_download),
            label: const Text('EXPORT REPORT'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1E88E5),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: ElevatedButton.icon(
            onPressed: () {
              setState(() {
                _tests.clear();
                _nextId = 1;
                _waveform.fillRange(0, _waveform.length, 0);
              });
            },
            icon: const Icon(Icons.clear_all),
            label: const Text('CLEAR DATA'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red.shade900,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
      ],
    );
  }
}