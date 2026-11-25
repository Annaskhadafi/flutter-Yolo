import 'package:flutter_test/flutter_test.dart';
import 'package:roadchitra_example/road_hazard/detection_tracker.dart';

void main() {
  test('keeps the same ID for a hazard that jitters between camera frames', () {
    final tracker = RoadHazardDetectionTracker();

    final first = tracker.update([
      const HazardDetection(
        label: 'Potholes',
        left: .20,
        top: .30,
        width: .2,
        height: .2,
      ),
    ]).single;
    final next = tracker.update([
      const HazardDetection(
        label: 'Potholes',
        left: .22,
        top: .29,
        width: .2,
        height: .2,
      ),
    ]).single;

    expect(next.id, first.id);
  });

  test('assigns distinct IDs to different objects and classes', () {
    final tracker = RoadHazardDetectionTracker();

    final results = tracker.update([
      const HazardDetection(
        label: 'Potholes',
        left: .1,
        top: .2,
        width: .1,
        height: .1,
      ),
      const HazardDetection(
        label: 'Potholes',
        left: .7,
        top: .7,
        width: .1,
        height: .1,
      ),
      const HazardDetection(
        label: 'Ruts',
        left: .1,
        top: .2,
        width: .1,
        height: .1,
      ),
    ]);

    expect(results.map((result) => result.id).toSet(), hasLength(3));
  });

  test('keeps ID across short detection gaps', () {
    final tracker = RoadHazardDetectionTracker();
    const hazard = HazardDetection(
      label: 'Potholes',
      left: .2,
      top: .3,
      width: .2,
      height: .2,
    );

    final first = tracker.update([hazard]).single;
    tracker.update(const []);
    tracker.update(const []);
    final returned = tracker.update([hazard]).single;

    expect(returned.id, first.id);
  });

  test('assigns a new ID after a track expires', () {
    final tracker = RoadHazardDetectionTracker(maxMissedFrames: 2);
    const hazard = HazardDetection(
      label: 'Potholes',
      left: .2,
      top: .3,
      width: .2,
      height: .2,
    );

    final first = tracker.update([hazard]).single;
    tracker.update(const []);
    tracker.update(const []);
    tracker.update(const []);
    final returned = tracker.update([hazard]).single;

    expect(returned.id, isNot(first.id));
  });
}
