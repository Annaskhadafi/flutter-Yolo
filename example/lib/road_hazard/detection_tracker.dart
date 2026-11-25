class HazardDetection {
  const HazardDetection({
    required this.label,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final String label;
  final double left;
  final double top;
  final double width;
  final double height;
}

class TrackedHazard extends HazardDetection {
  const TrackedHazard({
    required super.label,
    required super.left,
    required super.top,
    required super.width,
    required super.height,
    required this.id,
  });

  final String id;
}

class RoadHazardDetectionTracker {
  RoadHazardDetectionTracker({this.maxMissedFrames = 15});

  final int maxMissedFrames;
  final Map<String, TrackedHazard> _active = {};
  final Map<String, int> _missedFrames = {};
  int _nextId = 0;

  void clear() {
    _active.clear();
    _missedFrames.clear();
  }

  Set<String> get activeIds => _active.keys.toSet();

  List<TrackedHazard> update(List<HazardDetection> detections) {
    final unmatched = _active.keys.toSet();
    final current = <String, TrackedHazard>{};
    final tracked = <TrackedHazard>[];

    for (final detection in detections) {
      TrackedHazard? best;
      var bestDistance = double.infinity;
      for (final id in unmatched) {
        final candidate = _active[id]!;
        if (candidate.label.toLowerCase() != detection.label.toLowerCase()) {
          continue;
        }
        final distance = _centerDistanceSquared(candidate, detection);
        if (_intersectionOverUnion(candidate, detection) < 0.05 &&
            distance > 0.18 * 0.18) {
          continue;
        }
        if (distance < bestDistance) {
          best = candidate;
          bestDistance = distance;
        }
      }

      final id = best?.id ?? 'RH-${++_nextId}';
      unmatched.remove(id);
      _missedFrames.remove(id);
      final result = TrackedHazard(
        id: id,
        label: detection.label,
        left: detection.left,
        top: detection.top,
        width: detection.width,
        height: detection.height,
      );
      current[id] = result;
      tracked.add(result);
    }

    for (final id in unmatched) {
      final missed = (_missedFrames[id] ?? 0) + 1;
      if (missed > maxMissedFrames) {
        _active.remove(id);
        _missedFrames.remove(id);
      } else {
        _missedFrames[id] = missed;
        current[id] = _active[id]!;
      }
    }

    _active
      ..clear()
      ..addAll(current);
    return tracked;
  }

  double _centerDistanceSquared(HazardDetection a, HazardDetection b) {
    final dx = a.left + a.width / 2 - (b.left + b.width / 2);
    final dy = a.top + a.height / 2 - (b.top + b.height / 2);
    return dx * dx + dy * dy;
  }

  double _intersectionOverUnion(HazardDetection a, HazardDetection b) {
    final left = a.left > b.left ? a.left : b.left;
    final top = a.top > b.top ? a.top : b.top;
    final rightA = a.left + a.width;
    final rightB = b.left + b.width;
    final bottomA = a.top + a.height;
    final bottomB = b.top + b.height;
    final right = rightA < rightB ? rightA : rightB;
    final bottom = bottomA < bottomB ? bottomA : bottomB;
    final intersection =
        (right - left).clamp(0.0, double.infinity) *
        (bottom - top).clamp(0.0, double.infinity);
    final union = a.width * a.height + b.width * b.height - intersection;
    return union <= 0 ? 0 : intersection / union;
  }
}
