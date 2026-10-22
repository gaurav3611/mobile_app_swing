// The sensor protocol and the recording logic, with no Flutter code in it, so it can be
// tested on a computer (test/protocol_test.dart). The screen is in main.dart.
//
// The packet is the kit's: 14 bytes, seven signed 16-bit numbers, low byte first:
// ax, ay, az, gx, gy, gz, temperature. See stages/08_sswingg_bat/swing_packet.h in
// https://github.com/gaurav3611/Cric-Pro-Hardware.

import 'dart:math' as math;
import 'dart:typed_data';

const serviceUuid = '4fafc201-1fb5-459e-8fcc-c5c9c331914b';
const sensorUuid = 'beb5483e-36e1-4688-b7f5-ea07361b26a8';
const countsPerG = 4096.0;     // the sensor's 8 g range
const countsPerDps = 16.4;     // the sensor's 2000 degrees per second range

const shotTypes = ['pull_shot', 'drive_shot', 'cut_shot', 'defensive_shot', 'other'];

/// One reading of the sensor.
class Reading {
  Reading(this.raw);

  /// ax, ay, az, gx, gy, gz, temperature, exactly as the sensor sent them.
  final List<int> raw;

  double get axG => raw[0] / countsPerG;
  double get ayG => raw[1] / countsPerG;
  double get azG => raw[2] / countsPerG;
  double get gxDps => raw[3] / countsPerDps;
  double get gyDps => raw[4] / countsPerDps;
  double get gzDps => raw[5] / countsPerDps;
  double get totalG => math.sqrt(axG * axG + ayG * ayG + azG * azG);

  /// Bat speed by the dashboard's formula: rotation at a point 0.85 m from the wrists,
  /// a dead zone of 5 degrees per second, and at most 180 km/h.
  double get speedKmh {
    var rotation = math.sqrt(gxDps * gxDps + gyDps * gyDps + gzDps * gzDps);
    if (rotation < 5) rotation = 0;
    return math.min(rotation * (math.pi / 180) * 0.85 * 3.6, 180);
  }
}

/// One packet to one reading, or null when it is too short to be one.
Reading? decodePacket(List<int> bytes) {
  if (bytes.length < 14) return null;
  final data = ByteData.sublistView(Uint8List.fromList(bytes));
  return Reading([for (var i = 0; i < 7; i++) data.getInt16(i * 2, Endian.little)]);
}

/// A packet for the simulated bat, from values in g and degrees per second.
List<int> encodePacket(List<double> accelG, List<double> gyroDps) {
  final data = ByteData(14);
  for (var i = 0; i < 3; i++) {
    data.setInt16(i * 2, (accelG[i] * countsPerG).round().clamp(-32768, 32767), Endian.little);
    data.setInt16(6 + i * 2, (gyroDps[i] * countsPerDps).round().clamp(-32768, 32767), Endian.little);
  }
  return data.buffer.asUint8List();
}

/// A reading as it was recorded: its place, when the phone received it, and the reading.
class Sample {
  Sample(this.index, this.timeMs, this.elapsedMs, this.reading);
  final int index;
  final int timeMs;      // milliseconds since 1970, when the phone received it. The sensor sends no time.
  final int elapsedMs;   // milliseconds since Start, from a steady clock
  final Reading reading;
}

class Guess {
  const Guess(this.label, this.reason);
  final String label;
  final String reason;
}

/// A first guess at the type of shot. It is NOT a trained or tested classifier: no labelled
/// recordings exist yet. It uses the dashboard's side rule, rotation around z:
///   slow swing, peak under 20 km/h           defensive_shot
///   fast, turning to the leg side             pull_shot
///   fast, turning to the off side             cut_shot
///   fast, neither                             drive_shot
/// To collect training data, choose the type by hand instead.
Guess classify(List<Sample> samples) {
  if (samples.length < 10) return Guess('unknown', 'only ${samples.length} readings');
  var peak = 0.0, peakAt = 0;
  for (var i = 0; i < samples.length; i++) {
    final speed = samples[i].reading.speedKmh;
    if (speed > peak) {
      peak = speed;
      peakAt = i;
    }
  }
  if (peak < 20) return Guess('defensive_shot', 'peak bat speed ${peak.toStringAsFixed(1)} km/h, under 20');
  final t = samples[peakAt].elapsedMs;
  final near = samples.where((s) => (s.elapsedMs - t).abs() <= 100).toList();   // 0.2 s around the peak
  final gz = near.map((s) => s.reading.gzDps).reduce((a, b) => a + b) / near.length;
  final why = 'peak ${peak.toStringAsFixed(1)} km/h, rotation around z ${gz >= 0 ? "+" : ""}${gz.toStringAsFixed(0)} deg/s at the peak';
  if (gz > 20) return Guess('pull_shot', '$why, leg side');
  if (gz < -20) return Guess('cut_shot', '$why, off side');
  return Guess('drive_shot', '$why, straight');
}

const csvColumns = [
  'sample_index', 'timestamp_iso', 'timestamp_ms', 'elapsed_ms',
  'ax_g', 'ay_g', 'az_g', 'gx_dps', 'gy_dps', 'gz_dps', 'accel_total_g', 'speed_kmh',
  'ax_raw', 'ay_raw', 'az_raw', 'gx_raw', 'gy_raw', 'gz_raw', 'temp_raw',
];

/// The recording as CSV: a header, then one row per reading.
String toCsv(List<Sample> samples) {
  final out = StringBuffer('${csvColumns.join(',')}\r\n');
  String f(double v) => v.toStringAsFixed(4);
  for (final s in samples) {
    final r = s.reading;
    out.write([
      s.index,
      DateTime.fromMillisecondsSinceEpoch(s.timeMs, isUtc: true).toIso8601String(),
      s.timeMs,
      s.elapsedMs,
      f(r.axG), f(r.ayG), f(r.azG), f(r.gxDps), f(r.gyDps), f(r.gzDps), f(r.totalG), f(r.speedKmh),
      ...r.raw,
    ].join(','));
    out.write('\r\n');
  }
  return out.toString();
}

/// pull_shot_001.csv, pull_shot_002.csv, ... A simulated recording starts with sim_.
String fileName(String label, int number, {bool simulated = false}) {
  final safe = label.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]+'), '_');
  return '${simulated ? 'sim_' : ''}${safe}_${number.toString().padLeft(3, '0')}.csv';
}

/// The next free number for a type, given the names of the files already there.
int nextNumber(Iterable<String> existingNames, String label, {bool simulated = false}) {
  final pattern = RegExp('^${simulated ? 'sim_' : ''}${RegExp.escape(label)}_(\\d+)\\.csv\$');
  var highest = 0;
  for (final name in existingNames) {
    final m = pattern.firstMatch(name);
    if (m != null) highest = math.max(highest, int.parse(m.group(1)!));
  }
  return highest + 1;
}
