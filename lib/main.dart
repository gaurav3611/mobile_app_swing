// SwingLab recorder: connects to the bat sensor over Bluetooth, records each shot between
// Start and Stop, and saves every reading as a CSV file, one folder per shot type.
// The packet, the shot guess, the CSV and the file names are in protocol.dart.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'protocol.dart';

void main() => runApp(const RecorderApp());

class RecorderApp extends StatelessWidget {
  const RecorderApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'SwingLab recorder',
        theme: ThemeData(colorSchemeSeed: const Color(0xFF1C7541), useMaterial3: true),
        darkTheme: ThemeData(colorSchemeSeed: const Color(0xFF1C7541), brightness: Brightness.dark, useMaterial3: true),
        home: const RecorderPage(),
      );
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
    if (rec != null) rec.add(Sample(rec.length, DateTime.now().millisecondsSinceEpoch, _clock.elapsedMilliseconds, r));
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
      // The sensor advertises the service id, so only SwingLab sensors are listed.
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
          '${interrupted ? 'interrupted' : 'complete'},${samples.length},$duration,${_startedAt!.toUtc().toIso8601String()},$_recordingSimulated\r\n',
          mode: FileMode.append, flush: true);

      _result = 'Saved $label/$name: ${samples.length} readings in ${(duration / 1000).toStringAsFixed(1)} s'
          '${interrupted ? ', stopped early because the sensor disconnected' : ''}. '
          '${_shotType == 'auto' ? 'Detected' : 'Guess'}: ${guess.label.replaceAll('_', ' ')} (${guess.reason}).';
      await _loadFiles();
    } catch (e) {
      _result = 'Could not save the recording: $e';
    }
    if (mounted) setState(() {});
  }

  /// Android: /storage/emulated/0/Android/data/com.swinglab.swinglab_recorder/files/recordings
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
      appBar: AppBar(title: const Text('SwingLab recorder')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _section('Sensor', [
            Text(_status),
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
                style: rec != null ? FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error) : null,
                onPressed: !_connected ? null : (rec == null ? _start : () => _finish()),
                child: Text(rec == null ? 'Start' : 'Stop', style: const TextStyle(fontSize: 22)),
              ),
            ),
            if (rec != null) Text('Recording: ${(_clock.elapsedMilliseconds / 1000).toStringAsFixed(1)} s, ${rec.length} readings'),
            if (_result != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_result!)),
          ]),
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

  Widget _section(String title, List<Widget> children) => Card(
        margin: const EdgeInsets.only(bottom: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title.toUpperCase(), style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 8),
            ...children,
          ]),
        ),
      );

  Widget _tile(String label, String value) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(border: Border.all(color: Theme.of(context).dividerColor), borderRadius: BorderRadius.circular(6)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          Text(value, style: const TextStyle(fontFamily: 'monospace', fontSize: 17, fontWeight: FontWeight.w600)),
        ]),
      );
}
