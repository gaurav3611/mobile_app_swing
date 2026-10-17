import 'package:flutter_test/flutter_test.dart';
import 'package:swinglab_recorder/protocol.dart';

List<int> hex(String h) => [for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)];

/// n readings 20 ms apart, with one swing in the middle: peak rotation around y, and a turn around z.
List<Sample> recording(double peak, double gz, {int n = 100}) => [
      for (var i = 0; i < n; i++)
        () {
          final k = i > 40 && i < 60 ? _sin((i - 40) / 20) : 0.0;
          return Sample(i, 1000000000000 + i * 20, i * 20,
              decodePacket(encodePacket([0.02, 0.01, 1.0], [-0.25 * peak * k, peak * k, gz * k]))!);
        }(),
    ];
double _sin(double x) => x <= 0 || x >= 1 ? 0 : (x < 0.5 ? x * 2 : (1 - x) * 2);   // a simple rise and fall

void main() {
  test('reads the example packet of the kit to the same numbers as diagrams/packet.svg', () {
    final r = decodePacket(hex('35057203121040fd060b4c010000'))!;
    expect(r.raw, [1333, 882, 4114, -704, 2822, 332, 0]);
    expect(r.axG.toStringAsFixed(3), '0.325');
    expect(r.gyDps.toStringAsFixed(1), '172.1');
    expect(r.speedKmh.toStringAsFixed(1), '9.5');
  });

  test('turns away a packet that is too short', () {
    expect(decodePacket(List.filled(10, 0)), isNull);
  });

  test('a packet built for the simulated bat reads back to the same values', () {
    final r = decodePacket(encodePacket([1.5, -2.0, 0.25], [1000, -400, 12.5]))!;
    expect([r.axG, r.ayG, r.azG], [1.5, -2.0, 0.25]);
    expect(r.gxDps, closeTo(1000, 0.05));
    expect(r.gyDps, closeTo(-400, 0.05));
    expect(r.gzDps, closeTo(12.5, 0.05));
  });

  test('the first guess follows its rules: slow, leg side, off side, straight, too short', () {
    expect(classify(recording(200, 0)).label, 'defensive_shot');
    expect(classify(recording(1100, 170)).label, 'pull_shot');
    expect(classify(recording(1100, -170)).label, 'cut_shot');
    expect(classify(recording(1100, 0)).label, 'drive_shot');
    expect(classify(recording(1100, 170, n: 5)).label, 'unknown');
  });

  test('a recording becomes a CSV with a header and one complete row per reading', () {
    final rows = toCsv(recording(1100, 170)).trim().split('\r\n').map((l) => l.split(',')).toList();
    expect(rows.first, csvColumns);
    expect(rows.length, 101);
    expect(rows.every((r) => r.length == csvColumns.length), isTrue);
    expect(rows[1][1], '2001-09-09T01:46:40.000Z');
    expect(rows[1][12], '82');   // ax_raw: 0.02 g is 82 counts
  });

  test('file names are numbered per type, cleaned up, marked when simulated, and never reuse a number', () {
    expect(fileName('pull_shot', 1), 'pull_shot_001.csv');
    expect(fileName('Pull Shot', 12), 'pull_shot_012.csv');
    expect(fileName('cut_shot', 3, simulated: true), 'sim_cut_shot_003.csv');
    expect(nextNumber(['pull_shot_001.csv', 'pull_shot_007.csv', 'sim_pull_shot_020.csv', 'cut_shot_009.csv'], 'pull_shot'), 8);
    expect(nextNumber(['pull_shot_001.csv', 'sim_pull_shot_020.csv'], 'pull_shot', simulated: true), 21);
    expect(nextNumber([], 'drive_shot'), 1);
  });
}
