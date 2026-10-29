import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'controllers/translation_controller.dart';
import 'ml/hand_sign_classifier.dart';
import 'route_observer.dart';
import 'screens/auth/change_password_screen.dart';
import 'screens/auth/forgot_password_screen.dart';
import 'screens/auth/login_screen.dart';
import 'screens/auth/register_screen.dart';
import 'screens/main/main_shell.dart';
import 'services/auth_service.dart';
import 'services/backup_service.dart';
import 'services/connectivity_service.dart';
import 'services/db_service.dart';
import 'services/gemini_service.dart';
import 'services/gesture_image_service.dart';
import 'services/settings_service.dart';
import 'services/speech_service.dart';
import 'services/supabase_service.dart';
import 'services/sync_service.dart';
import 'services/tts_service.dart';
import 'theme/app_theme.dart';
import 'widgets/hand_landmark.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Lock the whole app to portrait. This also stops the OS from
  // reporting orientation changes to the camera stack, which prevents
  // the recorded .mp4 from rotating when the phone is tilted.
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  try {
    await dotenv.load(fileName: 'assets/.env');
  } catch (_) {
    // .env carries the bundled recognition-service key.
  }
  await SignAssets.load();

  final db = DbService();
  await db.database;
  final conn = ConnectivityService();
  final supabase = SupabaseService();
  await supabase.init();
  final settings = AppSettings();
  await settings.init();
  final auth = AuthService(db, supabase, conn);
  await auth.init();
  final gemini = GeminiService();
  final images = GestureImageService(
    db: db,
    supabase: supabase,
    gemini: gemini,
    auth: auth,
  );
  final sync = SyncService(
    db: db,
    supabase: supabase,
    connectivity: conn,
    settings: settings,
    images: images,
  );
  sync.attachAuth(auth);
  final backup = BackupService(db);
  final tts = TtsService();
  final handMl = HandSignClassifier()..load();

  final router = GoRouter(
    initialLocation: '/main',
    refreshListenable: auth,
    observers: [routeObserver],
    redirect: (context, state) {
      final loggedIn = auth.currentUser != null;
      final onAuthRoute =
          state.matchedLocation == '/login' ||
          state.matchedLocation == '/register' ||
          state.matchedLocation == '/forgot-password';
      final onPasswordRoute = state.matchedLocation == '/change-password';

      if (!auth.isInitialized) return null;
      if (!loggedIn) return onAuthRoute ? null : '/login';
      if (auth.requiresPasswordChange) {
        return onPasswordRoute ? null : '/change-password';
      }
      if (onAuthRoute) return '/main';
      return null;
    },
    routes: [
      GoRoute(path: '/login', builder: (context, state) => const LoginScreen()),
      GoRoute(
        path: '/register',
        builder: (context, state) => const RegisterScreen(),
      ),
      GoRoute(
        path: '/forgot-password',
        builder: (context, state) => const ForgotPasswordScreen(),
      ),
      GoRoute(
        path: '/change-password',
        builder: (context, state) => const ChangePasswordScreen(forced: true),
      ),
      GoRoute(path: '/main', builder: (context, state) => const MainShell()),
    ],
  );

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<ConnectivityService>.value(value: conn),
        Provider<DbService>.value(value: db),
        Provider<SupabaseService>.value(value: supabase),
        ChangeNotifierProvider<SyncService>.value(value: sync),
        Provider<BackupService>.value(value: backup),
        ChangeNotifierProvider<AppSettings>.value(value: settings),
        Provider<GeminiService>.value(value: gemini),
        Provider<GestureImageService>.value(value: images),
        Provider<TtsService>.value(value: tts),
        ChangeNotifierProvider(create: (_) => SpeechService()),
        ChangeNotifierProvider<AuthService>.value(value: auth),
        ChangeNotifierProvider(
          create: (_) => TranslationController(
            db: db,
            gemini: gemini,
            tts: tts,
            auth: auth,
            ml: handMl,
            settings: settings,
          ),
        ),
        Provider<HandSignClassifier>.value(value: handMl),
      ],
      child: ThandoSignApp(router: router),
    ),
  );
}

class ThandoSignApp extends StatelessWidget {
  const ThandoSignApp({super.key, required this.router});

  final GoRouter router;

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'ThandoSign',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme(),
      routerConfig: router,
    );
  }
}
