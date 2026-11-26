import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:roadchitra_example/road_hazard/feature_tools.dart';

void main() {
  test('history search filters by text, severity, and source', () {
    final sessions = [
      {
        'code': 'RH-01',
        'roadSection': 'Hauling North',
        'severity': 'HIGH',
        'source': 'video',
        'startTime': '2026-01-01T00:00:00Z',
      },
      {
        'code': 'RH-02',
        'roadSection': 'Access South',
        'severity': 'LOW',
        'source': 'image',
        'startTime': '2026-01-02T00:00:00Z',
      },
    ];
    expect(
      filterRoadHazardHistory(
        sessions,
        query: 'north',
        severity: 'HIGH',
        source: 'video',
      ),
      hasLength(1),
    );
    expect(
      filterRoadHazardHistory(
        sessions,
        query: 'rh-02',
        severity: 'ALL',
        source: 'ALL',
      ),
      hasLength(1),
    );
    expect(
      filterRoadHazardHistory(
        sessions,
        query: 'north',
        severity: 'LOW',
        source: 'ALL',
      ),
      isEmpty,
    );
  });

  test('sorts history newest first and keeps null or invalid dates safely', () {
    final result = sortRoadHazardHistory([
      {'code': 'old', 'startTime': '2026-01-01T00:00:00Z'},
      {'code': 'bad', 'startTime': null},
      {'code': 'new', 'startTime': '2026-02-01T00:00:00Z'},
    ]);
    expect(result.map((row) => row['code']), ['new', 'old', 'bad']);
  });

  test(
    'history session save replaces matching code and preserves unrelated rows',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'road-history-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/sessions.json');
      await saveHistorySession(file, {'code': 'RH-1', 'events': []});
      await saveHistorySession(file, {'code': 'RH-2', 'events': []});
      await saveHistorySession(file, {
        'code': 'RH-1',
        'events': [
          {'id': 'E1'},
        ],
      });
      final sessions = await loadHistorySessions(file);
      expect(sessions, hasLength(2));
      expect((sessions.first['events'] as List).single['id'], 'E1');
    },
  );

  test(
    'history totals aggregate hazard categories without requiring every field',
    () {
      final totals = historyHazardTotals([
        {
          'events': [
            {'label': 'Potholes'},
            {'label': 'Ruts'},
          ],
        },
        {
          'events': [
            {'label': 'potholes'},
            {'label': 'Corrugation'},
          ],
        },
        {'events': null},
      ]);
      expect(totals, {'Potholes': 2, 'Corragation': 1, 'Ruts': 1, 'Total': 4});
    },
  );

  test(
    'history session can be converted into a report with evidence image bytes',
    () {
      final event = photoImportEvent(
        id: 'RH-IMG-1',
        label: 'Potholes',
        confidence: .93,
        timestamp: DateTime.utc(2026),
        photoPath: '/tmp/RH-IMG-1.png',
      );
      final session = {
        'code': 'RH-PHOTO-SESSION',
        'source': 'image',
        'roadSection': 'Hauling North',
        'startTime': '2026-01-01T00:00:00Z',
        'endTime': '2026-01-01T00:00:00Z',
        'durationSeconds': 0,
        'events': [event],
      };
      expect(session['source'], 'image');
      expect(
        (session['events'] as List).single['photoPath'],
        contains('RH-IMG-1'),
      );
      expect(historyHazardTotals([session])['Total'], 1);
    },
  );

  test('history CSV emits one row per event and escapes delimiters', () {
    final csv = roadHazardHistoryCsv([
      {
        'code': 'RH-1',
        'source': 'image',
        'roadSection': 'North, ramp',
        'startTime': '2026-01-01T00:00:00Z',
        'severity': 'HIGH',
        'events': [
          {
            'id': 'RH-1',
            'label': 'Potholes',
            'confidence': .9,
            'time': '2026-01-01T00:00:01Z',
            'videoOffsetMs': 0,
            'photoPath': '/evidence/a.png',
          },
          {
            'id': 'RH-2',
            'label': 'Ruts',
            'confidence': .8,
            'time': '2026-01-01T00:00:02Z',
            'videoOffsetMs': 1000,
            'photoPath': null,
          },
        ],
      },
    ]);
    expect(csv, contains('"North, ramp"'));
    expect(csv, contains('RH-1,Potholes'));
    expect(csv, contains('RH-2,Ruts'));
  });

  test(
    'photo import event serializes evidence fields for saved session history',
    () {
      final event = photoImportEvent(
        id: 'RH-PHOTO-1',
        label: 'Potholes',
        confidence: .94,
        timestamp: DateTime.utc(2026),
        photoPath: '/evidence/RH-PHOTO-1.png',
        latitude: -6.2,
        longitude: 106.8,
      );
      expect(event['id'], 'RH-PHOTO-1');
      expect(event['photoPath'], contains('RH-PHOTO-1'));
      expect(event['latitude'], -6.2);
    },
  );
}
