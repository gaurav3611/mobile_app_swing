// The web app's swing arithmetic, from angular-cricket-frontend/src/app/analysis/swing-analysis.ts
// in https://github.com/gaurav3611/Cric-Pro-FE, ported line by line so both apps show the same
// numbers. test/analysis_test.dart checks them against values the web app computed.
// Also the swing detector for auto record, with the same rules as the web app's swing-detector.ts.

import 'dart:math' as math;

import 'protocol.dart';

class Shot {
  Shot(this.number, this.peakSpeed, this.peakImpact, this.controlScore, this.accuracy, this.direction, this.followGrade,
      this.grade, this.dataPoints);
  final int number;
  final double peakSpeed;   // km/h
  final double peakImpact;  // g
  final int controlScore;
  final int accuracy;
  final String direction;   // leg, off, straight
  final String followGrade; // STRONG, DECENT, WEAK
  final String grade;       // excellent, good, average, poor
  final int dataPoints;
}

String directionOf(double gz) => gz > 1 ? 'leg' : (gz < -1 ? 'off' : 'straight');

Shot analyzeSwing(List<Reading> data, int shotNumber) {
  var peakSpeed = 0.0, peakImpact = 0.0, lastGZ = 0.0;
  final gyVals = <double>[];
  for (final s in data) {
    if (s.speedKmh > peakSpeed) peakSpeed = s.speedKmh;
    if (s.totalG > peakImpact) peakImpact = s.totalG;
    gyVals.add(s.gyDps);
    lastGZ = s.gzDps;
  }

  // Control: how little the rotation around y varied over the shot.
  final mean = gyVals.isEmpty ? 0.0 : gyVals.reduce((a, b) => a + b) / gyVals.length;
  final variance = gyVals.isEmpty ? 0.0 : gyVals.map((v) => math.pow(v - mean, 2).toDouble()).reduce((a, b) => a + b) / gyVals.length;
  final controlScore = math.max(0.0, math.min(100.0, 100 - math.sqrt(variance) * 20));

  // Accuracy: half the control score, plus points for impact and for speed.
  final accuracy = math.min(
      100,
      (controlScore * 0.5 + (peakImpact > 15 ? 30 : (peakImpact > 8 ? 20 : 10)) + (peakSpeed > 60 ? 20 : (peakSpeed > 30 ? 15 : 5)))
          .round());

  final followGrade = peakImpact > 20 ? 'STRONG' : (peakImpact > 12 ? 'DECENT' : 'WEAK');
  final grade = accuracy >= 80 ? 'excellent' : (accuracy >= 60 ? 'good' : (accuracy >= 40 ? 'average' : 'poor'));
  return Shot(shotNumber, peakSpeed, peakImpact, controlScore.round(), accuracy, directionOf(lastGZ), followGrade, grade, data.length);
}

class CoachAnalysis {
  CoachAnalysis(this.tips, this.corrections, this.strengths, this.summary);
  final List<String> tips, corrections, strengths;
  final String summary;
}

/// The remarks under a session's numbers, from the web app's fixed thresholds. Nothing is learned.
CoachAnalysis coachAnalysis(double peakSpeed, double peakImpact, double controlScore, double lastShotGZ) {
  final tips = <String>[], corrections = <String>[], strengths = <String>[];

  if (peakSpeed > 80) {
    strengths.add('Best bat speed is above 80 km/h.');
    tips.add('Work on timing, so that the fastest shots are also the accurate ones.');
  } else if (peakSpeed > 60) {
    strengths.add('Best bat speed is above 60 km/h.');
    tips.add('Turn the shoulders further through the shot to add bat speed.');
  } else if (peakSpeed > 40) {
    tips.add('Best bat speed is between 40 and 60 km/h. Wrist-snap drills help to raise it.');
  } else {
    tips.add('Best bat speed is 40 km/h or less. Work on a full backlift and follow-through.');
  }

  if (peakImpact > 25) {
    strengths.add('Average impact is above 25 g, which is firm contact.');
  } else if (peakImpact > 15) {
    tips.add('Average impact is between 15 and 25 g. Aim for the middle of the bat.');
  } else {
    tips.add('Average impact is 15 g or less. Play the ball later for firmer contact.');
  }

  if (controlScore > 80) {
    strengths.add('Average accuracy is above 80%.');
  } else if (controlScore > 60) {
    strengths.add('Average accuracy is above 60%.');
    tips.add('Loosen the grip a little to steady the swing.');
  } else {
    corrections.add('Relax the grip. A tight grip makes the swing jerky.');
    corrections.add('Keep the bat straight in the backlift.');
  }

  if (lastShotGZ > 1) {
    tips.add('The last shot went to the leg side.');
  } else if (lastShotGZ < -1) {
    tips.add('The last shot went to the off side. Keep the head still through the drive.');
  } else {
    tips.add('The last shot was straight.');
  }

  final s = (peakSpeed / 100) * 40 + (peakImpact / 30) * 30 + (controlScore / 100) * 30;
  final summary = s > 85
      ? 'Excellent session.'
      : (s > 70
          ? 'Strong session.'
          : (s > 50 ? 'Solid session. The tips above show where to improve.' : 'Work on the basics first: grip, backlift and follow-through.'));
  return CoachAnalysis(tips, corrections, strengths, summary);
}

class SessionSummary {
  SessionSummary(this.shots, this.avgSpeed, this.bestSpeed, this.avgAccuracy, this.overallScore, this.analysis);
  final int shots;
  final double avgSpeed, bestSpeed, avgAccuracy;
  final int overallScore;
  final CoachAnalysis analysis;
}

/// Sums up all shots of the session. Needs at least one shot. As in the web app, the coach is
/// given the average accuracy where it expects a control score.
SessionSummary summariseSession(List<Shot> shots) {
  var avgSpeed = 0.0, avgAccuracy = 0.0, bestSpeed = 0.0, totalImpact = 0.0;
  for (final s in shots) {
    avgSpeed += s.peakSpeed;
    avgAccuracy += s.accuracy;
    if (s.peakSpeed > bestSpeed) bestSpeed = s.peakSpeed;
    totalImpact += s.peakImpact;
  }
  avgSpeed /= shots.length;
  avgAccuracy /= shots.length;
  final overallScore = math.min(100, (avgSpeed * 0.4 + avgAccuracy * 0.6).round());
  final last = shots.last;
  final analysis = coachAnalysis(bestSpeed, totalImpact / shots.length, avgAccuracy,
      last.direction == 'leg' ? 2 : (last.direction == 'off' ? -2 : 0));
  return SessionSummary(shots.length, avgSpeed, bestSpeed, avgAccuracy, overallScore, analysis);
}

const _scoreLabels = ['NEEDS WORK', 'DEVELOPING', 'GOOD FORM', 'EXCELLENT', 'POWER HIT'];

/// The score in the web app's ring, from a speed and a second measure.
(int, String) swingScore(double speed, double metric2) {
  final score = math.min(100, (speed * 0.6 + metric2 * 0.4).round());
  return (score, _scoreLabels[math.min(4, score ~/ 20)]);
}

/// The badge under each of the web app's four tiles: its text, and '' for good, 'warn' or 'danger'.
typedef KpiBadge = (String, String);

KpiBadge speedBadge(Shot s) => s.peakSpeed > 80 ? ('POWER HIT', '') : (s.peakSpeed > 50 ? ('MODERATE', 'warn') : ('SOFT', 'warn'));
KpiBadge impactBadge(Shot s) => s.peakImpact > 20 ? ('HARD HIT', '') : ('GENTLE', 'warn');
KpiBadge controlBadge(Shot s) =>
    s.controlScore >= 75 ? ('EXCELLENT', '') : (s.controlScore >= 50 ? ('MODERATE', 'warn') : ('IMPROVE', 'danger'));
KpiBadge followBadge(Shot s) => (s.followGrade, s.followGrade == 'STRONG' ? '' : (s.followGrade == 'DECENT' ? 'warn' : 'danger'));

// ---------------------------------------------------------------------------- auto record

// Counted in readings. The bat sends 50 a second, so 50 readings are one second.
const _preRoll = 50;          // kept from before the start, so the backlift is in the shot
const _startKmh = 10.0;
const _stopKmh = 5.0;
const _quietReadings = 25;    // this long below _stopKmh ends the swing
const _maxReadings = 150;     // a swing is cut after 3 seconds
const _minPeakKmh = 12.0;     // slower movements are waggles, not shots
const _minMovingReadings = 15; // shorter than 0.3 s is a knock, not a shot
const _cooldownReadings = 50; // the bat settling after the follow-through is not a new shot

/// Finds swings in the stream of readings, so shots can be recorded without Start and Stop.
class SwingDetector {
  List<Sample> _before = [];
  List<Sample>? _swing;
  int _moving = 0, _quiet = 0, _cooldown = 0;
  double _peak = 0;

  /// Takes one reading. Returns the readings of a finished swing, or null.
  List<Sample>? push(Sample sample) {
    final speed = sample.reading.speedKmh;
    final swing = _swing;
    if (swing == null) {
      if (_cooldown > 0) {
        _cooldown--;
        return null;
      }
      _before.add(sample);
      if (_before.length > _preRoll) _before.removeAt(0);
      if (speed > _startKmh) {
        _swing = _before;
        _before = [];
        _moving = 1;
        _quiet = 0;
        _peak = speed;
      }
      return null;
    }

    swing.add(sample);
    _moving++;
    _peak = math.max(_peak, speed);
    _quiet = speed < _stopKmh ? _quiet + 1 : 0;
    if (_quiet < _quietReadings && _moving < _maxReadings) return null;

    final keep = _peak >= _minPeakKmh && _moving - _quiet >= _minMovingReadings;
    _swing = null;
    _cooldown = _cooldownReadings;
    return keep ? swing : null;
  }

  /// Forgets a swing in progress, for example when the sensor disconnects.
  void reset() {
    _before = [];
    _swing = null;
    _cooldown = 0;
  }
}
