import 'package:flutter_test/flutter_test.dart';
import 'package:swinglab_recorder/analysis.dart';
import 'package:swinglab_recorder/protocol.dart';

// The same readings were run through the web app's swing-analysis.ts. The expected numbers below
// are what it computed, so this test fails if the two apps ever disagree.
List<int> rough(int i) => [
      for (var k = 0; k < 3; k++) ((i * (k + 3) * 37) % 4000) - 2000,
      for (var k = 0; k < 3; k++) ((i * (k + 5) * 53) % 20000) - 10000,
      0,
    ];
List<int> smooth(int i) => [500, 300, 4096 + i * 20, 2000 + i * 50, 30 + (i % 5), -800 - i * 10, 0];
Shot shot(int from, int n, int number, [List<int> Function(int) gen = rough]) =>
    analyzeSwing([for (var j = 0; j < n; j++) Reading(gen(from + j))], number);

Sample at(double kmh) => Sample(0, 0, 0, Reading([0, 0, 4096, 0, 0, (kmh / 0.0534 * countsPerDps).round(), 0]));
List<int> feed(SwingDetector d, List<double> speeds) =>
    [for (final kmh in speeds) d.push(at(kmh))].whereType<List<Sample>>().map((s) => s.length).toList();
List<double> still(int n) => List.filled(n, 0);
List<double> moving(int n, double kmh) => List.filled(n, kmh);

void main() {
  test('shot metrics match the web app', () {
    final shots = [shot(0, 60, 1), shot(100, 40, 2), shot(0, 50, 3, smooth)];
    final expected = [
      [56.40473632679581, 0.8457279333832408, 0, 25, 'off', 'WEAK', 'poor', 'MODERATE', 'GENTLE', 'IMPROVE'],
      [35.78112447101773, 0.8389632466464981, 0, 25, 'leg', 'WEAK', 'poor', 'SOFT', 'GENTLE', 'IMPROVE'],
      [15.088576575286218, 1.24740751363214, 98, 64, 'off', 'WEAK', 'good', 'SOFT', 'GENTLE', 'EXCELLENT'],
    ];
    for (var i = 0; i < shots.length; i++) {
      final s = shots[i], e = expected[i];
      expect(s.peakSpeed, closeTo(e[0] as double, 1e-9));
      expect(s.peakImpact, closeTo(e[1] as double, 1e-9));
      expect([s.controlScore, s.accuracy, s.direction, s.followGrade, s.grade, speedBadge(s).$1, impactBadge(s).$1, controlBadge(s).$1],
          e.sublist(2));
    }

    final sum = summariseSession(shots);
    expect(sum.avgSpeed, closeTo(35.75814579103326, 1e-9));
    expect(sum.bestSpeed, closeTo(56.40473632679581, 1e-9));
    expect([sum.avgAccuracy, sum.overallScore], [38, 37]);
    expect(sum.analysis.tips.last, 'The last shot went to the off side. Keep the head still through the drive.');
    expect(sum.analysis.corrections.length, 2);
    expect(sum.analysis.summary, 'Work on the basics first: grip, backlift and follow-through.');
    expect(swingScore(sum.bestSpeed, sum.avgAccuracy), (49, 'GOOD FORM'));
  });

  test('the swing detector finds the same swings as the web app', () {
    expect(feed(SwingDetector(), [...still(100), ...moving(30, 40), ...still(30)]), [104]);
    expect(feed(SwingDetector(), [...still(60), ...moving(30, 11), ...still(30)]), isEmpty);
    expect(feed(SwingDetector(), [...still(60), ...moving(5, 60), ...still(30)]), isEmpty);
    expect(feed(SwingDetector(), [...still(60), ...moving(30, 40), ...still(26), ...moving(20, 30), ...still(30)]), [104]);
    final cut = feed(SwingDetector(), [...still(60), ...moving(200, 40), ...still(80), ...moving(30, 40), ...still(30)]);
    expect(cut.length, 2);
    expect(cut.first, 50 + 149);
  });
}
