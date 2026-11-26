// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:image_gallery_saver_plus/image_gallery_saver_plus.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:roadchitra_example/reports/road_hazard_report.dart';
import 'package:roadchitra_example/road_hazard/detection_tracker.dart';
import 'package:roadchitra_example/road_hazard/feature_tools.dart';
import 'package:share_plus/share_plus.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

class SingleImageScreen extends StatefulWidget {
  const SingleImageScreen({super.key});

  @override
  State<SingleImageScreen> createState() => _SingleImageScreenState();
}

class _SingleImageScreenState extends State<SingleImageScreen> {
  static const _modelPath = 'assets/models/roadchitra.tflite';
  static const _sessionFile = 'road_hazard_sessions.json';
  static const _hazardLabels = {
    'potholes',
    'corragation',
    'corrugation',
    'ruts',
  };

  final _picker = ImagePicker();
  final RoadHazardDetectionTracker _tracker = RoadHazardDetectionTracker();
  late final YOLO _yolo;

  List<YOLOResult> _detections = const [];
  Uint8List? _annotatedImage;
  bool _isModelReady = false;
  bool _isInferring = false;
  String? _modelError;
  String? _sessionCode;
  String? _versionLabel;
  double _confidence = 0.3;
  final Set<String> _savedTrackIds = {};
  List<Map<String, dynamic>> _eventRows = [];

  @override
  void initState() {
    super.initState();
    _yolo = YOLO(modelPath: _modelPath, task: YOLOTask.detect);
    _loadVersion();
    _initializeYOLO();
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(
          () => _versionLabel = 'v${info.version} (${info.buildNumber})',
        );
      }
    } catch (_) {}
  }

  Future<void> _initializeYOLO() async {
    try {
      await _yolo.loadModel();
      if (mounted) setState(() => _isModelReady = true);
    } catch (error) {
      if (mounted) {
        setState(() => _modelError = 'Model RoadChitra gagal dimuat: $error');
      }
      _showSnackBar('Model RoadChitra gagal dimuat: $error');
    }
  }

  Future<void> _pickAndPredict() async {
    if (!_isModelReady || _isInferring) return;
    final file = await _picker.pickImage(source: ImageSource.gallery);
    if (file == null || !mounted) return;
    setState(() => _isInferring = true);
    _tracker.clear();
    _savedTrackIds.clear();
    _eventRows = [];
    final id = 'RH-IMG-${DateTime.now().toUtc().microsecondsSinceEpoch}';
    final timestamp = DateTime.now();
    try {
      final result = await _yolo.predict(
        await file.readAsBytes(),
        confidenceThreshold: _confidence,
      );
      final rows = (result['detections'] as List? ?? const [])
          .whereType<Map>()
          .map(YOLOResult.fromMap)
          .where(
            (detection) =>
                _hazardLabels.contains(
                  detection.className.trim().toLowerCase(),
                ) &&
                detection.confidence >= _confidence,
          )
          .toList(growable: false);
      final annotated = result['annotatedImage'];
      if (rows.isNotEmpty && annotated is! Uint8List) {
        throw StateError(
          'Model tidak menghasilkan gambar evidence ber-overlay.',
        );
      }
      final directory = Directory(
        '${(await getApplicationDocumentsDirectory()).path}/road-hazard-evidence',
      );
      final tracked = _tracker.update(
        rows
            .map(
              (detection) => HazardDetection(
                label: detection.className,
                left: detection.normalizedBox.left,
                top: detection.normalizedBox.top,
                width: detection.normalizedBox.width,
                height: detection.normalizedBox.height,
              ),
            )
            .toList(),
      );
      final sessionRows = <Map<String, dynamic>>[];
      for (var i = 0; i < tracked.length; i++) {
        final item = tracked[i];
        if (!_savedTrackIds.add(item.id)) continue;
        final evidence = File('${directory.path}/$id-${item.id}.png');
        await directory.create(recursive: true);
        await evidence.writeAsBytes(annotated as Uint8List, flush: true);
        sessionRows.add(
          photoImportEvent(
            id: item.id,
            label: rows[i].className,
            confidence: rows[i].confidence,
            timestamp: timestamp,
            photoPath: evidence.path,
          ),
        );
      }
      final counts = _categoryCounts(sessionRows);
      if (sessionRows.isEmpty && rows.isEmpty && (annotated is! Uint8List)) {
        throw StateError('Model tidak mengembalikan gambar hasil inferensi.');
      }
      final session = <String, dynamic>{
        'code': id,
        'source': 'image',
        'site': 'Local device',
        'roadSection': 'Photo inspection',
        'startTime': timestamp.toIso8601String(),
        'endTime': timestamp.toIso8601String(),
        'durationSeconds': 0,
        'distanceMeters': 0,
        'totalHazards': sessionRows.length,
        'potholesCount': counts['Potholes'],
        'corrugationCount': counts['Corragation'],
        'rutsCount': counts['Ruts'],
        'severity': _severityFor(sessionRows.length),
        'events': sessionRows,
        'summaryNotes': 'Photo inspection; evidence includes detector overlay.',
      };
      final historyFile = File(
        '${(await getApplicationDocumentsDirectory()).path}/$_sessionFile',
      );
      await saveHistorySession(historyFile, session);
      if (!mounted) return;
      setState(() {
        _detections = rows;
        _annotatedImage = annotated as Uint8List?;
        _sessionCode = id;
        _eventRows = sessionRows;
      });
      _showSnackBar('Foto disimpan ke riwayat: ${sessionRows.length} hazard.');
    } catch (error) {
      _showSnackBar('Analisis foto gagal: $error');
    } finally {
      if (mounted) setState(() => _isInferring = false);
    }
  }

  Map<String, int> _categoryCounts(Iterable<Map<String, dynamic>> events) =>
      historyHazardTotals([
        {'events': events.toList()},
      ]);

  String _severityFor(int count) => count >= 12
      ? 'CRITICAL'
      : count >= 7
      ? 'HIGH'
      : count >= 3
      ? 'MEDIUM'
      : 'LOW';

  Future<void> _savePhotoEvidence() async {
    final bytes = _annotatedImage;
    if (bytes == null) return;
    try {
      final result = await ImageGallerySaverPlus.saveImage(
        bytes,
        name: 'ChitraVision-${_sessionCode ?? 'photo'}',
        quality: 100,
      );
      final saved = result is Map && result['isSuccess'] == true;
      _showSnackBar(
        saved ? 'Evidence tersimpan di galeri.' : 'Gagal menyimpan evidence.',
      );
    } catch (error) {
      _showSnackBar('Gagal menyimpan evidence: $error');
    }
  }

  Future<void> _editPhotoNote(Map<String, dynamic> event) async {
    final controller = TextEditingController(
      text: event['notes'] as String? ?? '',
    );
    final note = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          'Catatan: ${event['id'] ?? ''} · ${event['label'] ?? 'Hazard'}',
        ),
        content: TextField(controller: controller, maxLines: 4, maxLength: 300),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Simpan'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (note == null || _sessionCode == null) return;
    if (note.isEmpty) {
      event.remove('notes');
    } else {
      event['notes'] = note;
    }
    try {
      final file = File(
        '${(await getApplicationDocumentsDirectory()).path}/$_sessionFile',
      );
      final sessions = await loadHistorySessions(file);
      final index = sessions.indexWhere((row) => row['code'] == _sessionCode);
      if (index < 0) throw StateError('Sesi foto tidak ditemukan di riwayat.');
      sessions[index]['events'] = _eventRows;
      await saveHistorySession(file, sessions[index]);
      if (mounted) setState(() {});
    } catch (error) {
      _showSnackBar('Gagal menyimpan catatan: $error');
    }
  }

  Future<void> _exportPdf() async {
    final code = _sessionCode;
    if (code == null) return;
    try {
      final file = File(
        '${(await getApplicationDocumentsDirectory()).path}/$_sessionFile',
      );
      final sessions = await loadHistorySessions(file);
      final session = sessions.firstWhere((row) => row['code'] == code);
      final savedEvents = (session['events'] as List? ?? const [])
          .whereType<Map>()
          .map((event) => Map<String, dynamic>.from(event))
          .toList();
      final reportEvents = savedEvents.map((event) {
        final path = event['photoPath'] as String?;
        final image = path == null ? null : File(path);
        return RoadHazardReportEvent(
          id: event['id'] as String? ?? '',
          label: event['label'] as String? ?? 'Other',
          confidence: (event['confidence'] as num?)?.toDouble() ?? 0,
          timestamp:
              DateTime.tryParse(event['time'] as String? ?? '') ??
              DateTime.now(),
          photoBytes: image != null && image.existsSync()
              ? image.readAsBytesSync()
              : null,
        );
      }).toList();
      final totals = _categoryCounts(_eventRows);
      final bytes = await RoadHazardReportExporter().toPdf(
        RoadHazardReport(
          sessionCode: session['code'] as String? ?? code,
          siteName: 'Local device',
          inspectorName: 'Photo inspection',
          roadSection: session['roadSection'] as String? ?? 'Photo inspection',
          startTime: timestampOf(session, 'startTime'),
          endTime: timestampOf(session, 'endTime'),
          durationSeconds: 0,
          distanceMeters: 0,
          potholesCount: totals['Potholes'] ?? 0,
          corrugationCount: totals['Corragation'] ?? 0,
          rutsCount: totals['Ruts'] ?? 0,
          severity: _severityFor(reportEvents.length),
          summaryNotes: session['summaryNotes'] as String?,
          events: reportEvents,
        ),
      );
      final output = File('${(await getTemporaryDirectory()).path}/$code.pdf');
      await output.writeAsBytes(bytes, flush: true);
      await SharePlus.instance.share(
        ShareParams(files: [XFile(output.path)], subject: '$code.pdf'),
      );
    } catch (error) {
      _showSnackBar('Gagal membuat PDF: $error');
    }
  }

  DateTime timestampOf(Map<String, dynamic> session, String key) =>
      DateTime.tryParse(session[key] as String? ?? '') ?? DateTime.now();

  void _showSnackBar(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  void dispose() {
    unawaited(_yolo.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Chitra Vision · Photo Inspection')),
      body: Stack(
        children: [
          Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    FilledButton.icon(
                      onPressed: (_isModelReady && !_isInferring)
                          ? _pickAndPredict
                          : null,
                      icon: const Icon(Icons.photo_library_outlined),
                      label: const Text('Pilih Foto & Analisis'),
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Confidence ${(100 * _confidence).round()}%',
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: Slider(
                            value: _confidence,
                            min: 0.1,
                            max: 0.9,
                            divisions: 16,
                            onChanged: _isInferring
                                ? null
                                : (value) =>
                                      setState(() => _confidence = value),
                          ),
                        ),
                      ],
                    ),
                    if (_isInferring) const LinearProgressIndicator(),
                    if (!_isModelReady && _modelError == null)
                      const Text('Menyiapkan model RoadChitra…'),
                    if (_modelError != null)
                      Text(
                        _modelError!,
                        style: const TextStyle(color: Colors.redAccent),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  children: [
                    if (_annotatedImage != null) ...[
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: InteractiveViewer(
                          child: Image.memory(
                            _annotatedImage!,
                            fit: BoxFit.contain,
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: OutlinedButton.icon(
                          onPressed: _savePhotoEvidence,
                          icon: const Icon(Icons.save_alt),
                          label: const Text('Simpan Evidence ke Galeri'),
                        ),
                      ),
                    ],
                    if (_detections.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          'Deteksi (${_detections.length})',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                    ..._detections.map((detection) {
                      final index = _detections.indexOf(detection);
                      final event = index < _eventRows.length
                          ? _eventRows[index]
                          : null;
                      return ListTile(
                        leading: const Icon(Icons.crop_din),
                        title: Text(
                          event == null
                              ? detection.className
                              : '${event['id']} · ${detection.className}',
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '${(detection.confidence * 100).toStringAsFixed(1)}%',
                            ),
                            if (event != null)
                              IconButton(
                                tooltip: 'Catatan hazard',
                                onPressed: () =>
                                    unawaited(_editPhotoNote(event)),
                                icon: const Icon(Icons.edit_note),
                              ),
                          ],
                        ),
                      );
                    }),
                    if (_sessionCode != null)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: FilledButton.icon(
                          onPressed: _exportPdf,
                          icon: const Icon(Icons.picture_as_pdf),
                          label: const Text('Ekspor PDF dengan Foto Evidence'),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (_versionLabel != null)
            Positioned(
              left: 8,
              bottom: 8,
              child: SafeArea(child: Text(_versionLabel!)),
            ),
        ],
      ),
    );
  }
}
