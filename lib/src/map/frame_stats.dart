import 'package:flutter/scheduler.dart';

/// How long recent frames took, kept so it can be shown on the map.
///
/// Both halves matter and they fail differently. Build is the Dart work of
/// deciding what to draw, and raster is the GPU drawing it; a map that is
/// doing too much per frame shows up in the first, and one that is asking the
/// GPU for too much shows up in the second.
class FrameStats {
  /// How many frames to average over.
  static const window = 60;

  final _build = <double>[];
  final _raster = <double>[];

  /// Starts collecting.
  FrameStats() {
    SchedulerBinding.instance.addTimingsCallback(_record);
  }

  /// Stops collecting.
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_record);
  }

  void _record(List<FrameTiming> timings) {
    for (final timing in timings) {
      _push(_build, timing.buildDuration.inMicroseconds / 1000);
      _push(_raster, timing.rasterDuration.inMicroseconds / 1000);
    }
  }

  static void _push(List<double> into, double value) {
    into.add(value);
    if (into.length > window) into.removeAt(0);
  }

  /// The average time spent working out what to draw, in milliseconds.
  double get build => _average(_build);

  /// The average time spent drawing it, in milliseconds.
  double get raster => _average(_raster);

  /// The slowest frame in the window, which is what a stutter looks like.
  double get worst {
    var worst = 0.0;
    for (var i = 0; i < _build.length; i++) {
      final total = _build[i] + _raster[i];
      if (total > worst) worst = total;
    }
    return worst;
  }

  /// How many frames have been measured.
  int get frames => _build.length;

  static double _average(List<double> values) {
    if (values.isEmpty) return 0;
    var sum = 0.0;
    for (final value in values) {
      sum += value;
    }
    return sum / values.length;
  }
}
