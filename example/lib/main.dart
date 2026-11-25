// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

import 'package:app_links/app_links.dart';
import 'package:material_ui/material_ui.dart';
import 'package:roadchitra_example/presentation/screens/camera_inference_screen.dart';
import 'package:roadchitra_example/presentation/screens/road_hazard_screen.dart';
import 'package:roadchitra_example/presentation/screens/single_image_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  AppLinks();
  runApp(const YOLOExampleApp());
}

class YOLOExampleApp extends StatelessWidget {
  const YOLOExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ultralytics YOLO',
      themeMode: ThemeMode.dark,
      theme: ThemeData.dark(useMaterial3: true),
      initialRoute: '/',
      routes: {
        '/': (_) => const RoadHazardScreen(),
        '/camera': (_) => const CameraInferenceScreen(),
        '/single': (_) => const SingleImageScreen(),
      },
    );
  }
}
