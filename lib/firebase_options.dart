// Generated from android/app/google-services.json (project: lockdown-f23c9).
// For full multi-platform support run:
//   flutterfire configure --project=lockdown-f23c9
// Web appId below reuses the Android appId as a fallback — for production,
// register a Web app in Firebase console and replace `web.appId`.

import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) return web;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        throw UnsupportedError(
            'iOS not configured. Run `flutterfire configure --project=lockdown-f23c9`.');
      case TargetPlatform.macOS:
        throw UnsupportedError(
            'macOS not configured. Run `flutterfire configure --project=lockdown-f23c9`.');
      case TargetPlatform.windows:
        throw UnsupportedError(
            'Windows not configured. Run `flutterfire configure --project=lockdown-f23c9`.');
      case TargetPlatform.linux:
        throw UnsupportedError('Firebase is not supported on Linux.');
      default:
        return web;
    }
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyAd2zhqjH61U9FS58xN4ftAjFWriL71Uno',
    appId: '1:785534550683:android:596448356101725040bc3e',
    messagingSenderId: '785534550683',
    projectId: 'lockdown-f23c9',
    storageBucket: 'lockdown-f23c9.firebasestorage.app',
    databaseURL: 'https://lockdown-f23c9-default-rtdb.firebaseio.com',
  );

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyAd2zhqjH61U9FS58xN4ftAjFWriL71Uno',
    appId: '1:785534550683:android:596448356101725040bc3e',
    messagingSenderId: '785534550683',
    projectId: 'lockdown-f23c9',
    authDomain: 'lockdown-f23c9.firebaseapp.com',
    storageBucket: 'lockdown-f23c9.firebasestorage.app',
    databaseURL: 'https://lockdown-f23c9-default-rtdb.firebaseio.com',
  );
}
