// SSwinGG recorder: connects to the bat sensor over Bluetooth, records each shot between
// Start and Stop, or by itself with auto record, and saves every reading as a CSV file, one
// folder per shot type. The packet, the shot guess, the CSV and the file names are in
// protocol.dart. The web app's shot metrics and the swing detector are in analysis.dart.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'analysis.dart';
import 'protocol.dart';

void main() => runApp(const RecorderApp());

// The "Ground" look, the same as the web app's (its dashboard-page.css): warm ivory, white cards
// with a hairline border, forest green for the main action, ochre for a warning, red for stop.
class Ground {
  static const page = Color(0xFFF7F5EE);
  static const surface = Color(0xFFFFFFFF);
  static const sage = Color(0xFFF0F3EC);
  static const border = Color(0xFFDCDFD4);
  static const line = Color(0xFFC9D3C4);
  static const ink = Color(0xFF17241C);
  static const muted = Color(0xFF5A695F);
  static const forest = Color(0xFF1E5B3A);
  static const field = Color(0xFF3A8A3F);
  static const ochre = Color(0xFFA8620F);
  static const red = Color(0xFFB42318);
  static const serif = 'serif'; // Noto Serif on Android: titles and large figures
  static const figures = [FontFeature.tabularFigures()];
}

class RecorderApp extends StatelessWidget {
  const RecorderApp({super.key});

  @override
  Widget build(BuildContext context) {
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(6));
    return MaterialApp(
      title: 'SSwinGG recorder',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: const ColorScheme.light(
          primary: Ground.forest,
          onPrimary: Colors.white,
          primaryContainer: Color(0xFFE3EEE6),
          onPrimaryContainer: Ground.forest,
          secondary: Ground.field,
          onSecondary: Colors.white,
          tertiary: Ground.ochre,
          error: Ground.red,
          surface: Ground.surface,
          onSurface: Ground.ink,
          onSurfaceVariant: Ground.muted,
          outline: Ground.border,
          outlineVariant: Ground.border,
        ),
        scaffoldBackgroundColor: Ground.page,
        dividerColor: Ground.border,
        appBarTheme: const AppBarTheme(
          backgroundColor: Ground.surface,
          foregroundColor: Ground.ink,
          elevation: 0,
          scrolledUnderElevation: 0,
          titleTextStyle: TextStyle(fontFamily: Ground.serif, fontSize: 21, fontWeight: FontWeight.w700, color: Ground.ink),
        ),
        cardTheme: CardThemeData(
          color: Ground.surface,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: Ground.border)),
        ),
        filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(shape: shape)),
        outlinedButtonTheme: OutlinedButtonThemeData(
            style: OutlinedButton.styleFrom(shape: shape, foregroundColor: Ground.ink, side: const BorderSide(color: Ground.border))),
        textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(shape: shape)),
        inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder(), enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Ground.border))),
        switchTheme: SwitchThemeData(trackOutlineColor: WidgetStateProperty.all(Ground.line)),
      ),
      themeMode: ThemeMode.light,
      home: const RecorderPage(),
    );
  }
}

class RecorderPage extends StatefulWidget {
  const RecorderPage({super.key});

  @override
  State<RecorderPage> createState() => _RecorderPageState();
}

class _RecorderPageState extends State<RecorderPage> {
  // ---- connection
  BluetoothDevice? _device;
  StreamSubscription<List<int>>? _dataSub;
  StreamSubscription<BluetoothConnectionState>? _stateSub;
  Timer? _simTimer;
  bool _scanning = false;
  List<ScanResult> _found = [];
  String _status = 'Not connected';
  String? _battery;                                    // the battery line under the status, while connected
  int? _batteryPercent;                                // the last percent the bat sent

  // ---- live readings
  Reading? _latest;
  int _count = 0, _inSecond = 0, _perSecond = 0, _malformed = 0;

  // ---- recording
  List<Sample>? _recording;
  final Stopwatch _clock = Stopwatch();
  DateTime? _startedAt;
  bool _recordingSimulated = false;
  String _shotType = 'auto';
  String? _result;
  List<File> _files = [];
  Directory? _folder;

  // ---- auto record, and the web app's metrics for every shot of this session
  final SwingDetector _detector = SwingDetector();
  final Stopwatch _streamClock = Stopwatch()..start();
  final List<Shot> _shots = [];
  SessionSummary? _summary;
  bool _recordingAuto = false;

  // ---- settings, kept in settings.json
  bool _autoRecord = false;

  late final Timer _screenTimer, _rateTimer;

  bool get _connected => _device != null || _simTimer != null;

  @override
  void initState() {
    super.initState();
    // The screen is redrawn ten times a second. Every reading is still recorded, however fast they come.
    _screenTimer = Timer.periodic(const Duration(milliseconds: 100), (_) => mounted ? setState(() {}) : null);
    _rateTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _perSecond = _inSecond;
      _inSecond = 0;
    });
    _loadFiles();
    _loadSettings();
  }

  Future<File> _settingsFile() async => File('${(await getApplicationDocumentsDirectory()).path}/settings.json');

  Future<void> _loadSettings() async {
    try {
      final saved = jsonDecode(await (await _settingsFile()).readAsString()) as Map<String, dynamic>;
      if (mounted) {
        setState(() {
          _autoRecord = saved['autoRecord'] == true;
        });
      }
    } catch (_) {
      // No settings saved yet: keep the defaults.
    }
  }

  Future<void> _saveSettings() async {
    try {
      await (await _settingsFile()).writeAsString(jsonEncode({'autoRecord': _autoRecord}));
    } catch (_) {
      // The setting still applies until the app closes.
    }
  }

  @override
  void dispose() {
    _screenTimer.cancel();
    _rateTimer.cancel();
    _simTimer?.cancel();
    _dataSub?.cancel();
    _stateSub?.cancel();
    _device?.disconnect();
    super.dispose();
  }

  /// Every packet passes through here, real or simulated.
  void _onPacket(List<int> bytes) {
    final r = decodePacket(bytes);
    if (r == null) {
      _malformed++;
      return;
    }
    _latest = r;
    _count++;
    _inSecond++;
    final rec = _recording;
    if (rec != null) {
      rec.add(Sample(rec.length, DateTime.now().millisecondsSinceEpoch, _clock.elapsedMilliseconds, r));
    } else if (_autoRecord) {
      final swing = _detector.push(Sample(0, DateTime.now().millisecondsSinceEpoch, _streamClock.elapsedMilliseconds, r));
      if (swing != null) _saveAutoShot(swing);
    }
  }

  /// A swing the detector found is saved like one recorded with Start and Stop.
  void _saveAutoShot(List<Sample> swing) {
    final first = swing.first;
    _recording = [
      for (var i = 0; i < swing.length; i++) Sample(i, swing[i].timeMs, swing[i].elapsedMs - first.elapsedMs, swing[i].reading)
    ];
    _recordingSimulated = _simTimer != null;
    _recordingAuto = true;
    _startedAt = DateTime.fromMillisecondsSinceEpoch(first.timeMs);
    _finish();
  }

  // ------------------------------------------------------------------ Bluetooth

  Future<void> _scan() async {
    setState(() {
      _found = [];
      _scanning = true;
      _status = 'Looking for the sensor...';
    });
    final sub = FlutterBluePlus.onScanResults.listen((results) => setState(() => _found = results));
    FlutterBluePlus.cancelWhenScanComplete(sub);
    try {
      if (Platform.isAndroid && FlutterBluePlus.adapterStateNow == BluetoothAdapterState.off) await FlutterBluePlus.turnOn();
      // The sensor advertises the service id, so only SSwinGG sensors are listed.
      await FlutterBluePlus.startScan(withServices: [Guid(serviceUuid)], timeout: const Duration(seconds: 10));
      await FlutterBluePlus.isScanning.where((scanning) => !scanning).first;
      _status = _found.isEmpty ? 'No sensor found. Is it switched on and blinking slowly?' : 'Tap the sensor to connect';
    } catch (e) {
      _status = 'Could not scan: $e. Check that Bluetooth is on and the app may use it.';
    }
    if (mounted) setState(() => _scanning = false);
  }

  Future<void> _connect(BluetoothDevice device) async {
    await FlutterBluePlus.stopScan();
    setState(() => _status = 'Connecting...');
    try {
      // The Bluetooth package is free for personal and educational use. See README.md.
      await device.connect(license: License.nonprofit, timeout: const Duration(seconds: 15));
      final services = await device.discoverServices();
      final service = services.firstWhere((s) => s.uuid == Guid(serviceUuid),
          orElse: () => throw StateError('the sensor service is missing. Is the bat running stage 5 or 8?'));
      final characteristic = service.characteristics.firstWhere((c) => c.uuid == Guid(sensorUuid),
          orElse: () => throw StateError('the sensor value is missing'));
      await _dataSub?.cancel();                          // never two subscriptions at once
      _dataSub = characteristic.onValueReceived.listen(_onPacket);
      device.cancelWhenDisconnected(_dataSub!);
      await characteristic.setNotifyValue(true);
      _battery = 'Battery: reading...';
      _batteryPercent = null;
      await _subscribeBattery(device, services);
      await _stateSub?.cancel();
      _stateSub = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) _onDisconnected();
      });
      _device = device;
      _found = [];
      _status = 'Connected to ${device.platformName.isEmpty ? 'the sensor' : device.platformName}';
    } catch (e) {
      _status = 'Could not connect: $e';
      await device.disconnect();
    }
    if (mounted) setState(() {});
  }

  /// The standard Bluetooth battery level. Only there when the firmware has HAS_BATTERY_SENSE 1.
  Future<void> _subscribeBattery(BluetoothDevice device, List<BluetoothService> services) async {
    final level = services
        .where((s) => s.uuid == Guid('180f'))
        .expand((s) => s.characteristics)
        .where((c) => c.uuid == Guid('2a19'))
        .firstOrNull;
    if (level == null) {
      _battery = 'Battery: not sent by this bat. Upload the firmware with HAS_BATTERY_SENSE 1.';
      return;
    }
    device.cancelWhenDisconnected(level.onValueReceived.listen((v) {
      if (v.isEmpty) return;
      // 0 is what the firmware sends when it sees no battery voltage.
      _batteryPercent = v[0] == 0 ? null : v[0];
      _battery = v[0] == 0
          ? 'Battery: no reading. Is the switch on, and are R1, R2 and C1 fitted?'
          : 'Battery ${v[0]}%${v[0] <= 10 ? ', charge it soon' : ''}';
      if (mounted) setState(() {});
    }));
    // The battery is extra. A failure here must not drop the sensor connection.
    try {
      await level.read();                              // the first value
      await level.setNotifyValue(true);                // later ones
    } catch (e) {
      if (_batteryPercent == null) _battery = 'Battery: could not read it ($e)';
    }
  }

  Future<void> _disconnect() async {
    if (_simTimer != null) {
      _stopSimulation();
      return;
    }
    await _device?.disconnect();                        // _onDisconnected does the rest
  }

  void _onDisconnected() {
    if (_device == null) return;
    _stateSub?.cancel();
    _stateSub = null;
    _dataSub = null;
    _device = null;
    _battery = null;
    _batteryPercent = null;
    _detector.reset();
    _status = 'Disconnected';
    if (_recording != null) _finish(interrupted: true); // keep what was recorded
    if (mounted) setState(() {});
  }

  // ------------------------------------------------------------------ simulated bat

  void _startSimulation() {
    var tick = 0;
    _simTimer = Timer.periodic(const Duration(milliseconds: 20), (_) {
      final phase = (tick % 150) / 150;                  // one swing every 3 seconds
      final k = phase > 0.4 && phase < 0.6 ? math.sin((phase - 0.4) / 0.2 * math.pi) : 0.0;
      final side = [1, -1, 0][(tick ~/ 150) % 3];        // leg side, off side, straight, in turn
      _onPacket(encodePacket([0.02 + 1.5 * k, 0.01 + 2 * k, 1 + 0.5 * k], [-250 * k, 1100 * k, side * 170 * k]));
      tick++;
    });
    setState(() => _status = 'Simulated bat. These numbers are made up, not measured.');
  }

  void _stopSimulation() {
    _simTimer?.cancel();
    _simTimer = null;
    _detector.reset();
    _status = 'Not connected';
    if (_recording != null) _finish(interrupted: true);
    setState(() {});
  }

  // ------------------------------------------------------------------ recording

  void _start() {
    if (!_connected || _recording != null) return;
    setState(() {
      _recording = [];
      _recordingSimulated = _simTimer != null;
      _recordingAuto = false;
      _startedAt = DateTime.now();
      _clock
        ..reset()
        ..start();
      _result = null;
    });
  }

  Future<void> _finish({bool interrupted = false}) async {
    final samples = _recording;
    if (samples == null) return;
    _recording = null;
    _clock.stop();
    final auto = _recordingAuto;
    _shots.add(analyzeSwing([for (final s in samples) s.reading], _shots.length + 1));
    _summary = summariseSession(_shots);
    final guess = classify(samples);
    final label = _shotType == 'auto' ? guess.label : _shotType;
    try {
      final root = await _recordingsFolder();
      final folder = Directory('${root.path}/$label');
      await folder.create(recursive: true);
      final existing = folder.listSync().map((f) => f.uri.pathSegments.last);
      final name = fileName(label, nextNumber(existing, label, simulated: _recordingSimulated), simulated: _recordingSimulated);
      final file = File('${folder.path}/$name');
      await file.writeAsString(toCsv(samples), flush: true);

      // One line per recording in index.csv: what was saved, and how the type was found.
      final index = File('${root.path}/index.csv');
      if (!await index.exists()) {
        await index.writeAsString('file,shot_type,chosen_by,guess,reason,status,readings,duration_ms,started_iso,simulated\r\n');
      }
      final duration = samples.isEmpty ? 0 : samples.last.elapsedMs;
      await index.writeAsString(
          '$label/$name,$label,${_shotType == 'auto' ? 'detected' : 'chosen'},${guess.label},"${guess.reason}",'
          '${interrupted ? 'interrupted' : (auto ? 'auto' : 'complete')},${samples.length},$duration,${_startedAt!.toUtc().toIso8601String()},$_recordingSimulated\r\n',
          mode: FileMode.append, flush: true);

      _result = '${auto ? 'Auto record: shot ${_shots.length} saved' : 'Saved'} $label/$name: ${samples.length} readings in ${(duration / 1000).toStringAsFixed(1)} s'
          '${interrupted ? ', stopped early because the sensor disconnected' : ''}. '
          '${_shotType == 'auto' ? 'Detected' : 'Guess'}: ${guess.label.replaceAll('_', ' ')} (${guess.reason}).';
      await _loadFiles();
    } catch (e) {
      _result = 'Could not save the recording: $e';
    }
    if (mounted) setState(() {});
  }

  /// Android: /storage/emulated/0/Android/data/com.sswingg.sswingg_recorder/files/recordings
  Future<Directory> _recordingsFolder() async {
    final base = await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
    return _folder = Directory('${base.path}/recordings');
  }

  Future<void> _loadFiles() async {
    final root = await _recordingsFolder();
    if (!await root.exists()) return;
    final files = root.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.csv') && !f.path.endsWith('/index.csv')).toList()
      ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    if (mounted) setState(() => _files = files);
  }

  Future<void> _share(List<File> files) => SharePlus.instance.share(ShareParams(files: [for (final f in files) XFile(f.path)]));

  Future<void> _delete(File file) async {
    final name = file.uri.pathSegments.last;
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete $name?'),
        content: const Text('The file is removed from the phone. Its line in index.csv stays.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (sure == true) {
      await file.delete();
      await _loadFiles();
    }
  }

  // ------------------------------------------------------------------ screen

  @override
  Widget build(BuildContext context) {
    final r = _latest;
    final rec = _recording;
    String g(double? v) => v == null ? '-' : v.toStringAsFixed(2);
    String d(double? v) => v == null ? '-' : v.toStringAsFixed(0);
    return Scaffold(
      appBar: AppBar(
        title: const Text('SSwinGG recorder'),
        actions: [
          if (_device != null && _batteryPercent != null)
            Padding(
              padding: const EdgeInsets.only(right: 14),
              child: Row(children: [
                Icon(_batteryIcon(_batteryPercent!), size: 20, color: _batteryPercent! <= 10 ? Ground.red : Ground.forest),
                Text('$_batteryPercent%',
                    style: TextStyle(
                        fontWeight: FontWeight.w700, fontFeatures: Ground.figures, color: _batteryPercent! <= 10 ? Ground.red : Ground.ink)),
              ]),
            ),
        ],
        // Two thin rules, like the creases, as under the web app's header.
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(4),
          child: Column(children: [Divider(height: 1, thickness: 1, color: Ground.line), SizedBox(height: 2), Divider(height: 1, thickness: 1, color: Ground.line)]),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _section('Sensor', [
            Text(_status),
            if (_device != null && _battery != null) _batteryRow(),
            if (_connected) Text('$_perSecond readings a second${_malformed > 0 ? ', $_malformed bad packets' : ''}', style: _muted(context)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton(onPressed: _connected || _scanning ? null : _scan, child: Text(_scanning ? 'Looking...' : 'Find sensor')),
              OutlinedButton(onPressed: _connected && rec == null ? _disconnect : null, child: const Text('Disconnect')),
              OutlinedButton(onPressed: _connected || _scanning ? null : _startSimulation, child: const Text('Simulated bat')),
            ]),
            for (final result in _found)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(result.device.platformName.isEmpty ? result.device.remoteId.str : result.device.platformName),
                subtitle: Text('${result.device.remoteId.str}, signal ${result.rssi} dBm'),
                trailing: const Text('Connect'),
                onTap: () => _connect(result.device),
              ),
          ]),
          _section('Settings', [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Auto record'),
              subtitle: const Text('Saves each swing by itself when the bat moves fast and then goes still. Start and Stop still work.'),
              value: _autoRecord,
              onChanged: (on) {
                setState(() => _autoRecord = on);
                _detector.reset();
                _saveSettings();
              },
            ),
          ]),
          _section('Live readings', [
            GridView.count(
              crossAxisCount: 3,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              childAspectRatio: 1.9,
              mainAxisSpacing: 6,
              crossAxisSpacing: 6,
              children: [
                _tile('ax, g', g(r?.axG)), _tile('ay, g', g(r?.ayG)), _tile('az, g', g(r?.azG)),
                _tile('gx, deg/s', d(r?.gxDps)), _tile('gy, deg/s', d(r?.gyDps)), _tile('gz, deg/s', d(r?.gzDps)),
                _tile('Speed, km/h', r == null ? '-' : r.speedKmh.toStringAsFixed(1)), _tile('Total, g', g(r?.totalG)), _tile('Readings', '$_count'),
                _tile('Direction', r == null ? '-' : _directionText[directionOf(r.gzDps)]!),
              ],
            ),
          ]),
          _section('Record a shot', [
            DropdownButtonFormField<String>(
              initialValue: _shotType,
              decoration: const InputDecoration(labelText: 'Shot type'),
              items: [
                const DropdownMenuItem(value: 'auto', child: Text('Detect automatically')),
                for (final t in shotTypes) DropdownMenuItem(value: t, child: Text(t.replaceAll('_', ' '))),
              ],
              onChanged: rec != null ? null : (v) => setState(() => _shotType = v!),
            ),
            const SizedBox(height: 6),
            Text('Automatic detection is only a first guess, not a tested classifier. To collect data for training one, choose the type yourself.',
                style: _muted(context)),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 64,
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: rec != null ? Ground.red : Ground.field),
                onPressed: !_connected ? null : (rec == null ? _start : () => _finish()),
                child: Text(rec == null ? 'Start' : 'Stop', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
              ),
            ),
            if (rec != null) Text('Recording: ${(_clock.elapsedMilliseconds / 1000).toStringAsFixed(1)} s, ${rec.length} readings'),
            if (rec == null && _autoRecord && _connected) const Text('Auto record is on: swing the bat and each shot is saved by itself.'),
            if (_result != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_result!)),
          ]),
          if (_shots.isNotEmpty) _lastShot(_shots.last),
          if (_summary != null) _session(_summary!),
          _section('Recordings', [
            Text(_folder == null ? '' : 'Saved in ${_folder!.path}', style: _muted(context)),
            if (_files.isEmpty) const Text('Nothing recorded yet.'),
            if (_files.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                    onPressed: () => _share([..._files, if (File('${_folder!.path}/index.csv').existsSync()) File('${_folder!.path}/index.csv')]),
                    child: const Text('Share all files')),
              ),
            for (final f in _files)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(f.uri.pathSegments.last, style: const TextStyle(fontFamily: 'monospace')),
                subtitle: Text('${f.parent.uri.pathSegments.where((s) => s.isNotEmpty).last}, ${f.lastModifiedSync().toLocal().toString().substring(0, 19)}'),
                trailing: Wrap(children: [
                  IconButton(tooltip: 'Share', icon: const Icon(Icons.share), onPressed: () => _share([f])),
                  IconButton(tooltip: 'Delete', icon: const Icon(Icons.delete_outline), onPressed: () => _delete(f)),
                ]),
              ),
          ]),
        ],
      ),
    );
  }

  TextStyle? _muted(BuildContext context) => Theme.of(context).textTheme.bodySmall;

  IconData _batteryIcon(int percent) => percent > 80
      ? Icons.battery_full
      : percent > 50
          ? Icons.battery_5_bar
          : percent > 20
              ? Icons.battery_3_bar
              : Icons.battery_1_bar;

  /// Shown every time a bat is connected: its percent, or why there is none.
  Widget _batteryRow() {
    final percent = _batteryPercent;
    final low = percent != null && percent <= 10;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
          color: low ? const Color(0xFFFBE9E7) : Ground.sage,
          borderRadius: BorderRadius.circular(6),
          border: Border(left: BorderSide(color: low ? Ground.red : Ground.forest, width: 4))),
      child: Row(children: [
        Icon(percent == null ? Icons.battery_unknown : _batteryIcon(percent), color: low ? Ground.red : Ground.forest),
        const SizedBox(width: 8),
        Expanded(
            child: Text(_battery!,
                style: TextStyle(fontWeight: percent == null ? FontWeight.w400 : FontWeight.w700, fontFeatures: Ground.figures))),
      ]),
    );
  }

  static const _directionText = {'leg': 'Leg side', 'off': 'Off side', 'straight': 'Straight'};

  Widget _grid(List<Widget> tiles) => GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        childAspectRatio: 2.4,
        mainAxisSpacing: 6,
        crossAxisSpacing: 6,
        children: tiles,
      );

  /// The web app's four tiles with their badges, and the shot's other numbers.
  Widget _lastShot(Shot s) {
    final (score, label) = swingScore(s.peakSpeed, s.accuracy.toDouble());
    return _section('Shot ${s.number}', [
      _grid([
        _tile('Bat speed, km/h', s.peakSpeed.toStringAsFixed(1), speedBadge(s)),
        _tile('Impact, g', s.peakImpact.toStringAsFixed(1), impactBadge(s)),
        _tile('Control', '${s.controlScore}', controlBadge(s)),
        _tile('Follow-through', s.followGrade, followBadge(s)),
        _tile('Accuracy', '${s.accuracy}%', (s.grade.toUpperCase(), '')),
        _tile('Direction', _directionText[s.direction]!),
        _tile('Score', '$score', (label, '')),
        _tile('Readings', '${s.dataPoints}'),
      ]),
    ]);
  }

  Widget _session(SessionSummary sum) {
    final (score, label) = swingScore(sum.bestSpeed, sum.avgAccuracy);
    final a = sum.analysis;
    return _section('Session', [
      _grid([
        _tile('Shots', '${sum.shots}'),
        _tile('Session score', '$score', (label, '')),
        _tile('Average speed, km/h', sum.avgSpeed.toStringAsFixed(1)),
        _tile('Best speed, km/h', sum.bestSpeed.toStringAsFixed(1)),
        _tile('Average accuracy', '${sum.avgAccuracy.round()}%'),
        _tile('Overall', '${sum.overallScore}'),
      ]),
      const SizedBox(height: 8),
      for (final line in a.strengths) Text('Strength: $line'),
      for (final line in a.tips) Text('Tip: $line'),
      for (final line in a.corrections) Text('Fix: $line'),
      const SizedBox(height: 4),
      Text(a.summary, style: const TextStyle(fontWeight: FontWeight.w600)),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          onPressed: _recording != null ? null : () => setState(() {
            _shots.clear();
            _summary = null;
          }),
          child: const Text('New session'),
        ),
      ),
    ]);
  }

  Widget _section(String title, List<Widget> children) => Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text(title, style: const TextStyle(fontFamily: Ground.serif, fontSize: 18, fontWeight: FontWeight.w600, color: Ground.ink)),
              const SizedBox(width: 10),
              const Expanded(child: Divider(color: Ground.border, thickness: 1)),
            ]),
            const SizedBox(height: 10),
            ...children,
          ]),
        ),
      );

  Widget _tile(String label, String value, [KpiBadge? badge]) {
    final colours = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: Ground.sage, borderRadius: BorderRadius.circular(6)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
        Text(label.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, letterSpacing: 0.6, color: Ground.muted)),
        Text(value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontFamily: Ground.serif, fontSize: 19, fontWeight: FontWeight.w600, color: Ground.ink, fontFeatures: Ground.figures)),
        if (badge != null)
          Text(badge.$1,
              style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                  color: badge.$2 == 'danger' ? colours.error : (badge.$2 == 'warn' ? colours.tertiary : colours.primary))),
      ]),
    );
  }
}
