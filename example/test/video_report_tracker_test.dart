import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:roadchitra_example/reports/road_hazard_report.dart';
import 'package:roadchitra_example/road_hazard/detection_tracker.dart';

void main() {
  group('RoadHazardDetectionTracker', () {
    test('captured ID is excluded from uncaptured on subsequent frames', () {
      final tracker = RoadHazardDetectionTracker(maxMissedFrames: 5);

      const frame1 = [
        HazardDetection(
          label: 'potholes',
          left: 0.2,
          top: 0.3,
          width: 0.15,
          height: 0.15,
        ),
      ];
      final tracked1 = tracker.update(frame1);
      expect(tracked1, hasLength(1));
      final id = tracked1.first.id;
      expect(tracker.uncaptured(tracked1), hasLength(1));

      tracker.markCaptured(id);
      expect(tracker.isCaptured(id), isTrue);

      const frame2 = [
        HazardDetection(
          label: 'potholes',
          left: 0.21,
          top: 0.31,
          width: 0.15,
          height: 0.15,
        ),
      ];
      final tracked2 = tracker.update(frame2);
      expect(tracked2.first.id, equals(id));
      expect(tracker.uncaptured(tracked2), isEmpty);
    });
  });

  group('RoadHazardReportExporter', () {
    test('includes formatted timestamp and videoOffset in Excel and PDF', () async {
      final startTime = DateTime(2026, 11, 25, 8, 0, 0);
      final eventOffset = const Duration(minutes: 1, seconds: 24);
      final report = RoadHazardReport(
        sessionCode: 'RH-VID-TEST',
        siteName: 'Video upload',
        inspectorName: 'Field inspector',
        roadSection: 'Hauling Road',
        startTime: startTime,
        endTime: startTime.add(const Duration(minutes: 5)),
        durationSeconds: 300,
        distanceMeters: 0,
        potholesCount: 1,
        corrugationCount: 0,
        rutsCount: 0,
        severity: 'LOW',
        events: [
          RoadHazardReportEvent(
            id: 'RH-1',
            label: 'potholes',
            confidence: 0.91,
            timestamp: startTime.add(eventOffset),
            videoOffset: eventOffset,
          ),
        ],
      );

      final exporter = RoadHazardReportExporter();
      final xlsxBytes = exporter.toXlsx(report);
      expect(xlsxBytes, isNotEmpty);

      final excel = Excel.decodeBytes(xlsxBytes);
      final sheet = excel['Road Hazard'];
      final headerRow = sheet.rows[16]
          .map((cell) => cell?.value?.toString())
          .toList();
      expect(headerRow, contains('Video Offset'));

      final eventRow = sheet.rows[17]
          .map((cell) => cell?.value?.toString())
          .toList();
      expect(eventRow[0], equals('RH-1'));
      expect(eventRow[3], equals('2026-11-25 08:01:24'));
      expect(eventRow[4], equals('00:01:24'));

      final pdfBytes = await exporter.toPdf(report);
      expect(pdfBytes, isNotEmpty);
    });
  });
}
