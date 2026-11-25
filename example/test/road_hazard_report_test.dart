import 'dart:convert';

import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:roadchitra_example/reports/road_hazard_report.dart';

void main() {
  final report = RoadHazardReport(
    sessionCode: 'RH-TEST-001',
    siteName: 'Test Site',
    inspectorName: 'Tester',
    roadSection: 'Hauling Road',
    startTime: DateTime.utc(2026, 1, 1),
    endTime: DateTime.utc(2026, 1, 1, 0, 5),
    durationSeconds: 300,
    distanceMeters: 1250,
    potholesCount: 2,
    corrugationCount: 1,
    rutsCount: 0,
    severity: 'MEDIUM',
    summaryNotes: 'Check drainage near the bend.',
    events: [
      RoadHazardReportEvent(
        id: 'event-1',
        label: 'Potholes',
        confidence: 0.93,
        timestamp: DateTime.utc(2026, 1, 1),
        latitude: -6.2,
        longitude: 106.8,
        notes: 'Large depression',
      ),
    ],
  );

  test('XLSX export is a workbook with report rows', () {
    final bytes = RoadHazardReportExporter().toXlsx(report);
    final workbook = Excel.decodeBytes(bytes);
    expect(workbook.tables.keys, contains('Road Hazard'));
    expect(workbook.tables['Road Hazard']!.rows.length, greaterThan(5));
  });

  test('PDF export generates a non-empty PDF document', () async {
    final bytes = await RoadHazardReportExporter().toPdf(report);
    expect(bytes.length, greaterThan(1000));
    expect(String.fromCharCodes(bytes.take(8)), startsWith('%PDF-'));
  });

  test('PDF embeds captured event photos', () async {
    final photoReport = RoadHazardReport(
      sessionCode: report.sessionCode,
      siteName: report.siteName,
      inspectorName: report.inspectorName,
      roadSection: report.roadSection,
      startTime: report.startTime,
      endTime: report.endTime,
      durationSeconds: report.durationSeconds,
      distanceMeters: report.distanceMeters,
      potholesCount: report.potholesCount,
      corrugationCount: report.corrugationCount,
      rutsCount: report.rutsCount,
      severity: report.severity,
      events: [
        RoadHazardReportEvent(
          id: 'photo-event',
          label: 'Potholes',
          confidence: .9,
          timestamp: DateTime.utc(2026),
          photoBytes: base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC',
          ),
        ),
      ],
    );
    final bytes = await RoadHazardReportExporter().toPdf(photoReport);
    expect(String.fromCharCodes(bytes), contains('/Subtype/Image'));
    expect(photoReport.events.single.id, 'photo-event');
  });

  test('PDF export generates a non-empty PDF document', () async {
    final bytes = await RoadHazardReportExporter().toPdf(report);
    expect(bytes.length, greaterThan(1000));
    expect(String.fromCharCodes(bytes.take(8)), startsWith('%PDF-'));
  });

  test(
    'exports an empty inspection and escaped user-provided labels',
    () async {
      final emptyReport = RoadHazardReport(
        sessionCode: 'RH-EMPTY',
        siteName: 'Site (A) & B',
        inspectorName: 'Inspector',
        roadSection: 'Road (North)',
        startTime: DateTime.utc(2026, 1, 1),
        endTime: DateTime.utc(2026, 1, 1),
        durationSeconds: 0,
        distanceMeters: 0,
        potholesCount: 0,
        corrugationCount: 0,
        rutsCount: 0,
        severity: 'LOW',
        events: [],
      );
      final workbook = Excel.decodeBytes(
        RoadHazardReportExporter().toXlsx(emptyReport),
      );
      expect(workbook.tables['Road Hazard']!.rows.length, greaterThan(1));
      final pdf = await RoadHazardReportExporter().toPdf(emptyReport);
      expect(pdf, isNotEmpty);
    },
  );
}
