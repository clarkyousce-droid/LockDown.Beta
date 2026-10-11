import 'dart:async';
import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'themes.dart';

const String _rtdbUrl =
    'https://lockdown-f23c9-default-rtdb.firebaseio.com';

class Room {
  String id;
  String name;
  int maxDevices;
  int timerMinutes;
  String joinCode;
  String ownerId;
  List<String> members;
  // Shared session state (synced via Firestore so EVERY member sees it).
  bool sessionActive;
  int? sessionEndsAtMillis;

  /// Never allows an empty code: empty/missing/short values get a fresh
  /// `LCK-XXXX` so `QrImageView` never receives invalid (blank) data.
  static String normalizeJoinCode(String? code) {
    final c = (code ?? '').trim().toUpperCase();
    if (c.length >= 4) return c;
    return 'LCK-${1000 + Random().nextInt(9000)}';
  }

  Room({
    this.id = '',
    required this.name,
    this.maxDevices = 5,
    this.timerMinutes = 30,
    String? joinCode,
    this.ownerId = '',
    List<String>? members,
    this.sessionActive = false,
    this.sessionEndsAtMillis,
  })  : joinCode = normalizeJoinCode(joinCode),
        members = members ?? [];

  String get formattedTimer {
    final h = timerMinutes ~/ 60;
    final m = timerMinutes % 60;
    if (h > 0) {
      return '${h}h ${m}m';
    }
    return '${m}m';
  }

  /// True when Firestore says a session is running AND it hasn't expired yet.
  /// This is what ALL members (owner + joined) use to render the countdown.
  bool get isLive {
    if (!sessionActive || sessionEndsAtMillis == null) return false;
    return sessionEndsAtMillis! > DateTime.now().millisecondsSinceEpoch;
  }

  /// Remaining seconds for the shared session (0 when not live).
  int get remainingSeconds {
    if (!sessionActive || sessionEndsAtMillis == null) return 0;
    final diff =
        ((sessionEndsAtMillis! - DateTime.now().millisecondsSinceEpoch) / 1000)
            .ceil();
    return diff > 0 ? diff : 0;
  }

  String get formattedSessionRemaining {
    final s = remainingSeconds;
    return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
  }

  static int? _parseEndsAt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is Timestamp) return value.millisecondsSinceEpoch;
    return null;
  }

  factory Room.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>? ?? {};
    return Room(
      id: doc.id,
      name: (data['name'] as String?) ?? 'Unnamed Room',
      maxDevices: (data['maxDevices'] as num?)?.toInt() ?? 5,
      timerMinutes: (data['timerMinutes'] as num?)?.toInt() ?? 30,
      // Old room docs may lack joinCode -> normalize generates LCK-XXXX
      // instead of '' (which makes QrImageView render a blank box).
      joinCode: normalizeJoinCode(data['joinCode'] as String?),
      ownerId: (data['ownerId'] as String?) ?? '',
      members: ((data['members'] as List?) ?? []).map((e) => e.toString()).toList(),
      sessionActive: (data['sessionActive'] as bool?) ?? false,
      sessionEndsAtMillis: _parseEndsAt(data['sessionEndsAt']),
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'name': name,
      'maxDevices': maxDevices,
      'timerMinutes': timerMinutes,
      'joinCode': joinCode.trim().toUpperCase(),
      'ownerId': ownerId,
      'members': members,
      'sessionActive': sessionActive,
      'sessionEndsAt': sessionEndsAtMillis,
    };
  }
}

class RoomRepository {
  static final _db = FirebaseFirestore.instance;
  static CollectionReference<Map<String, dynamic>> get _rooms =>
      _db.collection('rooms');

  /// Live rooms for this user (owner OR member).
  static Stream<List<Room>> watchMyRooms(String uid) {
    if (uid.isEmpty) return Stream.value([]);
    return _rooms.where('members', arrayContains: uid).snapshots().map(
        (snap) => snap.docs.map((d) => Room.fromFirestore(d)).toList());
  }

  static Future<void> createRoom(Room room) async {
    final code = room.joinCode.trim().toUpperCase();
    final existing =
        await _rooms.where('joinCode', isEqualTo: code).limit(1).get();
    if (existing.docs.isNotEmpty) {
      throw Exception('Join code $code is already taken. Regenerate.');
    }
    await _rooms.add(room.toFirestore());
  } 

  static Future<void> updateRoom(Room room) async {
    if (room.id.isEmpty) throw Exception('Missing room id');
    await _rooms.doc(room.id).update(room.toFirestore());
  }

  /// Owner starts a shared session: all members see the same countdown
  /// because `sessionEndsAt` is stored in Firestore.
  static Future<void> startSession(String roomId, int durationMinutes) async {
    if (roomId.isEmpty) throw Exception('Missing room id');
    final minutes = durationMinutes > 0 ? durationMinutes : 30;
    final endsAt = DateTime.now().millisecondsSinceEpoch + minutes * 60 * 1000;
    await _rooms.doc(roomId).update({
      'sessionActive': true,
      'sessionEndsAt': endsAt,
    });
  }

  /// Owner stops the shared session for everyone.
  static Future<void> stopSession(String roomId) async {
    if (roomId.isEmpty) return;
    await _rooms.doc(roomId).update({
      'sessionActive': false,
      'sessionEndsAt': null,
    });
  }

  static Future<void> deleteRoom(String roomId) async {
    await _rooms.doc(roomId).delete();
  }

  /// Remove a member from a room (owner only, enforced by firestore.rules).
  static Future<void> removeMember(String roomId, String uid) async {
    if (roomId.isEmpty || uid.isEmpty) throw Exception('Missing room or user');
    await _rooms.doc(roomId).update({
      'members': FieldValue.arrayRemove([uid])
    });
  }

  /// Join by code: find room, then add uid to members.
  /// Enforces maxDevices — throws if the room is already full.
  static Future<Room?> joinByCode(String code, String uid) async {
    final normalized = code.trim().toUpperCase();
    if (normalized.isEmpty || uid.isEmpty) return null;
    final q =
        await _rooms.where('joinCode', isEqualTo: normalized).limit(1).get();
    if (q.docs.isEmpty) return null;
    final doc = q.docs.first;
    final room = Room.fromFirestore(doc);
    if (!room.members.contains(uid)) {
      if (room.members.length >= room.maxDevices) {
        throw Exception(
            'Room "${room.name}" is full (${room.members.length}/${room.maxDevices}).');
      }
      await doc.reference.update({
        'members': FieldValue.arrayUnion([uid])
      });
      room.members.add(uid);
    }
    return room;
  }

  /// Fetch user profiles for room members (uid -> {email, displayName, ...}).
  /// Uses individual doc gets (not a whereIn query) so a missing/denied
  /// profile never fails the whole list.
  static Future<Map<String, Map<String, dynamic>>> fetchMemberProfiles(
      List<String> uids) async {
    if (uids.isEmpty) return {};
    final result = <String, Map<String, dynamic>>{};
    final docs = await Future.wait(
      uids.map((uid) async {
        try {
          return await _db.collection('users').doc(uid).get();
        } catch (_) {
          return null;
        }
      }),
    );
    for (final d in docs) {
      if (d != null && d.exists) {
        final data = d.data();
        if (data != null) result[d.id] = data;
      }
    }
    return result;
  }
}

class DashboardScreen extends StatefulWidget {
  final String email;
  const DashboardScreen({super.key, required this.email});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with WidgetsBindingObserver {
  int _selectedIndex = 0;

  String get _uid => FirebaseAuth.instance.currentUser?.uid ?? '';
  List<Room> _rooms = [];
  Room? _selectedRoom;
  StreamSubscription<List<Room>>? _roomsSub;
  bool _roomsLoading = true;
  String? _roomsError;

  // Presence heartbeat (keeps isOnline/lastSeen fresh).
  Timer? _presenceTimer;

  // Realtime Database presence (instant offline via onDisconnect).
  // Firestore alone can't detect force-kill; RTDB onDisconnect can.
  FirebaseDatabase? _rtdb;
  DatabaseReference? _rtdbStatusRef;

  FirebaseDatabase? _resolveRtdb() {
    if (_rtdb != null) return _rtdb;
    try {
      if (_rtdbUrl.isNotEmpty) {
        _rtdb = FirebaseDatabase.instanceFor(
          app: Firebase.app(),
          databaseURL: _rtdbUrl,
        );
      } else {
        _rtdb = FirebaseDatabase.instance;
      }
    } catch (e) {
      debugPrint(
          'RTDB not configured (add DB URL or google-services.json entry): $e');
      _rtdb = null;
    }
    return _rtdb;
  }

  /// Sets up /status/{uid} = {state, last_changed} with onDisconnect
  /// so force-kill / network drop flips to offline within seconds.
  Future<void> _setupRealtimePresence() async {
    final uid = _uid;
    if (uid.isEmpty) return;
    try {
      final rtdb = _resolveRtdb();
      if (rtdb == null) return;
      final ref = rtdb.ref('status/$uid');
      _rtdbStatusRef = ref;
      // Must register onDisconnect BEFORE going online.
      await ref.onDisconnect().set({
        'state': 'offline',
        'last_changed': ServerValue.timestamp,
      });
      await ref.set({
        'state': 'online',
        'last_changed': ServerValue.timestamp,
      });
    } catch (e) {
      debugPrint('RTDB presence setup failed (Firestore fallback active): $e');
    }
  }

  Future<void> _setRtdbState(String state) async {
    try {
      final ref = _rtdbStatusRef ?? _resolveRtdb()?.ref('status/$_uid');
      if (ref == null || _uid.isEmpty) return;
      _rtdbStatusRef = ref;
      await ref
          .set({'state': state, 'last_changed': ServerValue.timestamp}).timeout(
              const Duration(seconds: 5));
    } catch (e) {
      debugPrint('RTDB state $state failed: $e');
    }
  }

  /// Stream of /status/{uid} for instant online dot.
  /// Returns empty stream if RTDB isn't configured — caller falls back
  /// to Firestore _isOnlineFromData.
  Stream<DatabaseEvent> _rtdbStatusStream(String uid) {
    try {
      final rtdb = _resolveRtdb();
      if (rtdb == null || uid.isEmpty || uid.contains('@')) {
        return const Stream.empty();
      }
      return rtdb.ref('status/$uid').onValue;
    } catch (_) {
      return const Stream.empty();
    }
  }

  /// RTDB is source of truth when present; otherwise use Firestore fallback.
  bool _onlineFromRtdb(DatabaseEvent? event, bool firestoreOnline) {
    try {
      final val = event?.snapshot.value;
      if (val is Map) {
        final state = val['state']?.toString();
        if (state == 'online') return true;
        if (state == 'offline') return false;
      }
    } catch (_) {}
    return firestoreOnline;
  }

  /// Big, unmissable owner notification (banner + snackbar + sound).
  /// Only shown to the room owner, never to the member themselves.
  /// [soundAsset] defaults to the selected leave/offline sound; pass
  /// 'assets/sounds/ding.mp3' for joins. [color]/[icon] default to red alert.
  void _showOwnerBigAlert(String title, String body,
      {String? soundAsset, Color? color, IconData? icon}) {
    if (!mounted) return;
    setState(() => _ownerBanner = '$title: $body');
    // Owner-only audible alert (owner phone, foreground).
    if (soundAsset != null) {
      _playSpecificSound(soundAsset);
    } else {
      _playOwnerAlertSound();
    }
    HapticFeedback.vibrate();
    final alertColor = color ?? Colors.redAccent;
    final alertIcon = icon ?? Icons.warning_amber_rounded;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: alertColor,
        duration: const Duration(seconds: 6),
        behavior: SnackBarBehavior.floating,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        content: Row(
          children: [
            Icon(alertIcon, color: Colors.white, size: 32),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title,
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 16)),
                  const SizedBox(height: 2),
                  Text(body,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 13)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Shows "Alice left Room" (owner-only) with the real account name.
  /// The users/{uid} doc survives leaving, so we fetch it for the
  /// displayName/email. Falls back to the last-known tile name, then
  /// "User ab12" so it never shows a bare uid.
  Future<void> _alertMembersLeft(Room room, Set<String> leftUids) async {
    final others = leftUids.where((u) => u != _uid).toList();
    // Always clean presence tracking for departed members.
    for (final uid in others) {
      _onlineCache.remove(uid);
      _offlineAlerted.remove('${room.id}:$uid');
      _autoKicked.remove('${room.id}:$uid');
    }
    if (others.isEmpty) return;
    final isOwnerView = room.ownerId.isEmpty || room.ownerId == _uid;
    if (!isOwnerView) return;

    String fallbackName(String uid) {
      final cached = (_knownNames[uid] ?? '').trim();
      if (cached.isNotEmpty) return cached;
      if (uid.contains('@')) return uid.split('@').first;
      return 'User ${uid.length >= 4 ? uid.substring(0, 4) : uid}';
    }

    try {
      final profiles =
          await RoomRepository.fetchMemberProfiles(others);
      if (!mounted) return;
      final names = others.map((uid) {
        final data = profiles[uid] ?? {};
        final stored = (data['displayName'] as String?)?.trim() ?? '';
        final email = (data['email'] as String?)?.trim() ?? '';
        String resolved;
        if (stored.isNotEmpty) {
          resolved = stored;
        } else if (email.contains('@')) {
          resolved = email.split('@').first;
        } else {
          resolved = fallbackName(uid);
        }
        _knownNames[uid] = resolved;
        final shownEmail = email.isNotEmpty ? ' ($email)' : '';
        return '"$resolved"$shownEmail';
      }).toList();
      _showOwnerBigAlert(
        others.length == 1 ? 'Member left' : 'Members left',
        '${names.join(', ')} left "${room.name}" (or was removed).',
      );
    } catch (e) {
      debugPrint('Resolve left-member name failed: $e');
      if (!mounted) return;
      final names =
          others.map((uid) => '"${fallbackName(uid)}"').toList();
      _showOwnerBigAlert(
        others.length == 1 ? 'Member left' : 'Members left',
        '${names.join(', ')} left "${room.name}" (or was removed).',
      );
    }
  }

  /// Shows "Alice joined Room" (owner-only) + ding.mp3 chime.
  /// Called when Firestore members gain new uids (not on first load).
  Future<void> _alertMembersJoined(Room room, Set<String> joinedUids) async {
    final others = joinedUids.where((u) => u != _uid).toList();
    if (others.isEmpty) return;
    final isOwnerView = room.ownerId.isEmpty || room.ownerId == _uid;
    if (!isOwnerView) return;

    String fallbackName(String uid) {
      final cached = (_knownNames[uid] ?? '').trim();
      if (cached.isNotEmpty) return cached;
      if (uid.contains('@')) return uid.split('@').first;
      return 'User ${uid.length >= 4 ? uid.substring(0, 4) : uid}';
    }

    try {
      final profiles =
          await RoomRepository.fetchMemberProfiles(others);
      if (!mounted) return;
      final names = others.map((uid) {
        final data = profiles[uid] ?? {};
        final stored = (data['displayName'] as String?)?.trim() ?? '';
        final email = (data['email'] as String?)?.trim() ?? '';
        String resolved;
        if (stored.isNotEmpty) {
          resolved = stored;
        } else if (email.contains('@')) {
          resolved = email.split('@').first;
        } else {
          resolved = fallbackName(uid);
        }
        _knownNames[uid] = resolved;
        return '"$resolved"';
      }).toList();
      _showOwnerBigAlert(
        others.length == 1 ? 'Member joined' : 'Members joined',
        '${names.join(', ')} joined "${room.name}".',
        soundAsset: 'assets/sounds/ding.mp3',
        color: Colors.green,
        icon: Icons.person_add_alt_rounded,
      );
    } catch (e) {
      debugPrint('Resolve joined-member name failed: $e');
      if (!mounted) return;
      final names =
          others.map((uid) => '"${fallbackName(uid)}"').toList();
      _showOwnerBigAlert(
        others.length == 1 ? 'Member joined' : 'Members joined',
        '${names.join(', ')} joined "${room.name}".',
        soundAsset: 'assets/sounds/ding.mp3',
        color: Colors.green,
        icon: Icons.person_add_alt_rounded,
      );
    }
  }

  /// Called from each member tile after online status resolves.
  /// Fires once per online->offline transition, owner-only.
  /// Safe to call during build: all UI work is deferred to post-frame.
  /// If the shared session is LIVE, an offline member is auto-kicked
  /// after a short grace period (covers kill / background / force-close).
  void _maybeAlertOffline({
    required Room room,
    required String uid,
    required String displayName,
    required bool online,
  }) {
    final isOwnerView = room.ownerId.isEmpty || room.ownerId == _uid;
    if (!isOwnerView || uid == _uid) return;
    final wasOnline = _onlineCache[uid] ?? true;
    _onlineCache[uid] = online;
    final key = '${room.id}:$uid';
    if (!online && wasOnline && !_offlineAlerted.contains(key)) {
      _offlineAlerted.add(key);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _showOwnerBigAlert(
          'Member offline',
          '"$displayName" went offline / left the app in "${room.name}".',
        );
      });
      // Auto-kick during a live session (owner device performs the kick).
      if (room.isLive) {
        _scheduleAutoKick(room, uid, displayName);
      }
    } else if (online) {
      if (_offlineAlerted.contains(key)) {
        _offlineAlerted.remove(key);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (_ownerBanner != null) setState(() => _ownerBanner = null);
        });
      }
      // Came back (rejoined) — allow a future auto-kick if they drop again.
      _autoKicked.remove(key);
    }
  }

  /// Owner-side auto-kick: 20s grace, then remove from Firestore members.
  /// Re-validates before kicking so brief backgrounding won't kick.
  void _scheduleAutoKick(Room room, String uid, String displayName) {
    final key = '${room.id}:$uid';
    if (_autoKicked.contains(key)) return;
    _autoKicked.add(key);
    Future.delayed(const Duration(seconds: 20), () async {
      if (!mounted) return;
      // Fresh room state (session may have ended, member may be back).
      Room? fresh;
      for (final r in _rooms) {
        if (r.id == room.id) {
          fresh = r;
          break;
        }
      }
      if (fresh == null || !fresh.isLive) {
        _autoKicked.remove(key);
        return;
      }
      if (!fresh.members.contains(uid)) return; // already left/kicked
      // Came back online while we waited? Don't kick.
      if (_onlineCache[uid] == true) {
        _autoKicked.remove(key);
        return;
      }
      // Only the owner can kick (rules enforce this too).
      if (fresh.ownerId.isNotEmpty && fresh.ownerId != _uid) {
        _autoKicked.remove(key);
        return;
      }
      if (uid == fresh.ownerId || uid == _uid) {
        _autoKicked.remove(key);
        return;
      }
      try {
        await RoomRepository.removeMember(fresh.id, uid);
        if (!mounted) return;
        _showOwnerBigAlert(
          'Member auto-removed',
          '"$displayName" was offline during the live session in "${fresh.name}" and was removed.',
        );
      } catch (e) {
        debugPrint('Auto-kick failed: $e');
        _autoKicked.remove(key);
      }
    });
  }

  /// Central offline sweep — runs on ANY tab (not just Security).
  /// Tile-based `_maybeAlertOffline` only fires when the Security list
  /// is built, so background-kills were missed when the owner sat on
  /// Home/Settings. This checks every live room the owner owns.
  /// Throttled to ~20s to avoid excess Firestore reads.
  Future<void> _sweepOfflineMembersForAutoKick() async {
    if (!mounted) return;
    if (DateTime.now().difference(_lastPresenceSweep).inSeconds < 20) return;
    _lastPresenceSweep = DateTime.now();
    for (final room in _rooms) {
      if (!room.isLive) continue;
      final isOwner = room.ownerId.isEmpty || room.ownerId == _uid;
      if (!isOwner) continue;
      try {
        final profiles = await RoomRepository.fetchMemberProfiles(room.members);
        if (!mounted) return;
        for (final uid in room.members) {
          if (uid == _uid || uid == room.ownerId) continue;
          final data = profiles[uid] ?? {};
          // Resolve name for alerts (same logic as tiles).
          final stored = (data['displayName'] as String?)?.trim() ?? '';
          final email = (data['email'] as String?)?.trim() ?? '';
          String displayName;
          if (stored.isNotEmpty) {
            displayName = stored;
          } else if (email.contains('@')) {
            displayName = email.split('@').first;
          } else {
            displayName = (_knownNames[uid] ?? '').trim().isNotEmpty
                ? _knownNames[uid]!
                : (uid.contains('@')
                    ? uid.split('@').first
                    : 'User ${uid.length >= 4 ? uid.substring(0, 4) : uid}');
          }
          if (stored.isNotEmpty) _knownNames[uid] = stored;

          // Firestore fallback first...
          bool online = _isOnlineFromData(data);
          // ...then try RTDB instant status (kill/background in seconds).
          try {
            final rtdb = _resolveRtdb();
            if (rtdb != null && !uid.contains('@')) {
              final snap = await rtdb
                  .ref('status/$uid')
                  .get()
                  .timeout(const Duration(seconds: 5));
              final val = snap.value;
              if (val is Map) {
                final state = val['state']?.toString();
                if (state == 'online') online = true;
                if (state == 'offline') online = false;
              }
            }
          } catch (_) {}

          final wasOnline = _onlineCache[uid] ?? true;
          _onlineCache[uid] = online;
          final key = '${room.id}:$uid';
          if (!online &&
              wasOnline &&
              !_offlineAlerted.contains(key)) {
            _offlineAlerted.add(key);
            _showOwnerBigAlert(
              'Member offline',
              '"$displayName" went offline / left the app in "${room.name}".',
            );
            _scheduleAutoKick(room, uid, displayName);
          } else if (online) {
            _offlineAlerted.remove(key);
            _autoKicked.remove(key);
          }
        }
      } catch (e) {
        debugPrint('Presence sweep failed for ${room.name}: $e');
      }
    }
  }

  // Theme Customization State from themes.dart
  // Persisted per-account in users/{uid}.themeName so the user never
  // has to re-pick it in Settings after relogin / reinstall / new device.
  AppThemeOption _currentTheme = AppThemes.availableThemes.first;
  Color get _currentAccentColor => _currentTheme.accentColor;

  static AppThemeOption _themeByName(String? name) {
    if (name == null || name.isEmpty) return AppThemes.availableThemes.first;
    for (final t in AppThemes.availableThemes) {
      if (t.name == name) return t;
    }
    return AppThemes.availableThemes.first;
  }

  /// Loads the saved theme for this account (Firestore is source of truth).
  Future<void> _loadSavedTheme() async {
    final uid = _uid;
    if (uid.isEmpty) return;
    try {
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get()
          .timeout(const Duration(seconds: 5));
      final saved = (snap.data()?['themeName'] as String?)?.trim();
      if (saved != null && saved.isNotEmpty && mounted) {
        final resolved = _themeByName(saved);
        if (resolved.name != _currentTheme.name) {
          setState(() => _currentTheme = resolved);
        }
      }
    } catch (e) {
      debugPrint('Load saved theme failed: $e');
    }
  }

  /// Saves the picked theme to this account (merge, never overwrites profile).
  Future<void> _saveTheme(AppThemeOption theme) async {
    final uid = _uid;
    if (uid.isEmpty) return;
    try {
      await FirebaseFirestore.instance.collection('users').doc(uid).set(
        {'themeName': theme.name},
        SetOptions(merge: true),
      ).timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('Save theme failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Theme applied, but save failed. Deploy firestore.rules.')),
      );
    }
  }

  // Shared session UI state: Firestore is the source of truth.
  // _ticker only triggers a rebuild each second so every member's
  // countdown ticks down live. _expiredShown tracks rooms we already
  // showed the "Session Ended" dialog for.
  Timer? _ticker;
  final Set<String> _expiredShownFor = {};

  // Owner alerts: track online transitions + room leaves.
  final Map<String, bool> _onlineCache = {};
  final Set<String> _offlineAlerted = {};
  final Set<String> _autoKicked = {};
  DateTime _lastPresenceSweep = DateTime.fromMillisecondsSinceEpoch(0);
  final Map<String, Set<String>> _prevMembersByRoom = {};
  // Last-known display names (populated from member tiles) so a
  // "member left" alert can show "Alice" instead of "User ab12"
  // even if the profile fetch is slow.
  final Map<String, String> _knownNames = {};
  String? _ownerBanner;

  // Owner-only audible alert (owner phone, foreground only).
  final AudioPlayer _alertPlayer = AudioPlayer();
  bool _soundEnabled = true;

  // Selectable alert sounds — auto-listed from assets/sounds/.
  // Default is DefultLockdown.mp3. Just drop a new .mp3/.wav in that
  // folder and it appears in Settings automatically (no code change).
  // ding.mp3 is the join chime — excluded from this leave/offline list.
  String _selectedAlertSound = 'assets/sounds/DefultLockdown.mp3';
  // Cached so Settings FutureBuilder doesn't restart (and reset scroll)
  // on every setState — e.g. live-session ticker ticks every second.
  Future<List<String>>? _soundAssetsFuture;

  Future<List<String>> _loadSoundAssets() async {
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      final assets = manifest
          .listAssets()
          .where((a) =>
              a.startsWith('assets/sounds/') &&
              !a.endsWith('.gitkeep') &&
              !a.toLowerCase().endsWith('ding.mp3') &&
              (a.toLowerCase().endsWith('.mp3') ||
                  a.toLowerCase().endsWith('.wav') ||
                  a.toLowerCase().endsWith('.ogg') ||
                  a.toLowerCase().endsWith('.m4a')))
          .toList()
        ..sort();
      // If user had ding selected before, fall back to default.
      if (_selectedAlertSound.toLowerCase().endsWith('ding.mp3') &&
          assets.isNotEmpty) {
        _selectedAlertSound = assets.firstWhere(
          (a) => a.toLowerCase().contains('defultlockdown'),
          orElse: () => assets.first,
        );
      }
      return assets;
    } catch (e) {
      debugPrint('Load sound list failed: $e');
      return [_selectedAlertSound];
    }
  }

  String _soundDisplayName(String asset) {
    final file = asset.split('/').last;
    final noExt = file.replaceAll(
        RegExp(r'\.(mp3|wav|ogg|m4a)$', caseSensitive: false), '');
    return noExt.replaceAll(RegExp(r'[_\-]+'), ' ');
  }

  Future<void> _playOwnerAlertSound() async {
    if (!_soundEnabled) {
      debugPrint('Owner alert sound skipped (muted)');
      return;
    }
    try {
      await _alertPlayer.stop();
      await _alertPlayer.setVolume(1.0);
      await _alertPlayer.setReleaseMode(ReleaseMode.stop);
      // AssetSource takes path relative to assets/ root.
      final src =
          AssetSource(_selectedAlertSound.replaceFirst('assets/', ''));
      await _alertPlayer.play(src);
      debugPrint('Owner alert sound playing: $_selectedAlertSound');
    } catch (e) {
      debugPrint('Owner alert sound failed ($_selectedAlertSound): $e');
      // Fallback to default file if selected one is missing/corrupt.
      if (_selectedAlertSound != 'assets/sounds/DefultLockdown.mp3') {
        try {
          await _alertPlayer.play(
              AssetSource('sounds/DefultLockdown.mp3'));
        } catch (_) {}
      }
    }
  }

  Future<void> _previewAlertSound(String asset) async {
    try {
      await _alertPlayer.stop();
      await _alertPlayer.setVolume(1.0);
      await _alertPlayer.play(
          AssetSource(asset.replaceFirst('assets/', '')));
      debugPrint('Preview sound playing: $asset');
    } catch (e) {
      debugPrint('Preview sound failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Preview failed: $e')),
      );
    }
  }

  /// Plays any specific file in assets/sounds (e.g. ding.mp3 for joins).
  /// Respects the master [_soundEnabled] toggle.
  Future<void> _playSpecificSound(String asset) async {
    if (!_soundEnabled) {
      debugPrint('Alert sound skipped (muted): $asset');
      return;
    }
    try {
      await _alertPlayer.stop();
      await _alertPlayer.setVolume(1.0);
      await _alertPlayer.setReleaseMode(ReleaseMode.stop);
      await _alertPlayer.play(
          AssetSource(asset.replaceFirst('assets/', '')));
      debugPrint('Alert sound playing: $asset');
    } catch (e) {
      debugPrint('Alert sound failed ($asset): $e');
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Pre-configure alert player so first leave/offline alert plays instantly.
    _alertPlayer.setVolume(1.0).catchError((_) => null);
    _alertPlayer.setReleaseMode(ReleaseMode.stop).catchError((_) => null);
    // Load once — keeps Settings scroll stable across rebuilds.
    _soundAssetsFuture = _loadSoundAssets();
    // Backfill own profile (email/displayName) so members see a real
    // name instead of the "User xxxx" fallback, then mark online.
    _ensureOwnProfile();
    // Restore this account's saved theme so Settings pick persists.
    _loadSavedTheme();
    _updatePresence(true);
    _setupRealtimePresence();
    _presenceTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      _updatePresence(true);
      _setRtdbState('online');
    });
    // Rebuild once per second so the SHARED Firestore countdown ticks
    // for every member (owner + joined), not just the device that started it.
    // Also runs the offline sweep so background-kills kick on ANY tab.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final anyLive = _rooms.any((r) => r.isLive);
      _checkExpiredSessions();
      if (anyLive) {
        // Skip the rebuild while a dialog (e.g. the QR popup) is on
        // top so the tap + open animation never janks.
        final isTopRoute = ModalRoute.of(context)?.isCurrent ?? true;
        if (isTopRoute) setState(() {});
        _sweepOfflineMembersForAutoKick();
      }
    });
    _roomsSub = RoomRepository.watchMyRooms(_uid).listen((rooms) {
      if (!mounted) return;
      // Detect members who LEFT (were in prev list, gone now) and
      // who JOINED (in curr, not in prev). Skip both on first load
      // (prev empty) so app start doesn't ding.
      // Only the owner gets the big alert, now with the real acc name.
      for (final room in rooms) {
        final prev = _prevMembersByRoom[room.id] ?? <String>{};
        final curr = room.members.toSet();
        if (prev.isNotEmpty) {
          final left = prev.difference(curr);
          if (left.isNotEmpty) {
            _alertMembersLeft(room, left);
          }
          final joined = curr.difference(prev);
          if (joined.isNotEmpty) {
            _alertMembersJoined(room, joined);
          }
        }
        _prevMembersByRoom[room.id] = curr;
      }
      // Clean up tracking for deleted rooms.
      _prevMembersByRoom.removeWhere((id, _) =>
          rooms.every((r) => r.id != id));
      setState(() {
        _rooms = rooms;
        _roomsLoading = false;
        _roomsError = null;
        if (_selectedRoom != null) {
          final match = rooms.where((r) => r.id == _selectedRoom!.id);
          _selectedRoom = match.isNotEmpty ? match.first : null;
        }
        _selectedRoom ??= rooms.isNotEmpty ? rooms.first : null;
      });
      _checkExpiredSessions();
      _sweepOfflineMembersForAutoKick();
    }, onError: (e) {
      if (!mounted) return;
      setState(() {
        _roomsLoading = false;
        _roomsError = e.toString();
      });
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _presenceTimer?.cancel();
    // Best-effort offline mark (can't await in dispose).
    // Captures uid now — after sign-out _uid would be empty.
    final uid = _uid;
    if (uid.isNotEmpty) {
      FirebaseFirestore.instance.collection('users').doc(uid).set(
        {
          'isOnline': false,
          'lastSeen': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      ).catchError((e) {
        debugPrint('Presence offline (dispose) failed: $e');
        return null;
      });
      // RTDB onDisconnect already handles kill, but set explicitly too.
      _setRtdbState('offline');
      try {
        _rtdbStatusRef?.onDisconnect().cancel();
      } catch (_) {}
    }
    _roomsSub?.cancel();
    _ticker?.cancel();
    _alertPlayer.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Resumed = using app -> online. Anything else (backgrounded,
    // minimized, screen off, app killed/closed) -> offline immediately
    // so members don't see a stuck green dot.
    if (state == AppLifecycleState.resumed) {
      _updatePresence(true);
      _setRtdbState('online');
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      _updatePresence(false);
      _setRtdbState('offline');
    }
  }

  /// Ensures the current user's profile has email/displayName so other
  /// members see a real name instead of the "User xxxx" fallback.
  /// Only fills missing fields — never overwrites an existing displayName.
  Future<void> _ensureOwnProfile() async {
    final user = FirebaseAuth.instance.currentUser;
    final uid = user?.uid ?? '';
    if (uid.isEmpty) return;
    try {
      final ref =
          FirebaseFirestore.instance.collection('users').doc(uid);
      final snap = await ref.get();
      final data = snap.data() ?? {};
      final authEmail = user?.email ?? widget.email;
      final fallbackName = authEmail.contains('@')
          ? authEmail.split('@').first
          : 'User ${uid.length >= 4 ? uid.substring(0, 4) : uid}';
      final patch = <String, dynamic>{};
      if ((data['email'] as String?)?.isNotEmpty != true &&
          authEmail.isNotEmpty) {
        patch['email'] = authEmail;
      }
      if ((data['displayName'] as String?)?.isNotEmpty != true) {
        patch['displayName'] =
            (user?.displayName?.isNotEmpty == true)
                ? user!.displayName!
                : fallbackName;
      }
      if (patch.isNotEmpty) {
        await ref.set(patch, SetOptions(merge: true));
      }
    } catch (e) {
      debugPrint('Ensure own profile failed: $e');
    }
  }

  /// Best-effort presence write for the current user.
  /// Pass [uidOverride] on logout so the write still works even if
  /// FirebaseAuth has already cleared currentUser.
  Future<void> _updatePresence(bool online, {String? uidOverride}) async {
    final uid = uidOverride ?? _uid;
    if (uid.isEmpty) return;
    try {
      await FirebaseFirestore.instance.collection('users').doc(uid).set(
        {
          'isOnline': online,
          'lastSeen': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      ).timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('Presence update failed: $e');
    }
  }

  /// Owner starts the SHARED session (written to Firestore so every
  /// member in the room sees the same live countdown).
  Future<void> _startSession(Room room) async {
    // Owner-only: only the creator can start the session timer.
    if (room.ownerId.isNotEmpty && room.ownerId != _uid) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Only the room owner can start the session.')),
      );
      return;
    }
    try {
      _expiredShownFor.remove(room.id);
      await RoomRepository.startSession(room.id, room.timerMinutes);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Start session failed: $e')),
      );
    }
  }

  /// Owner stops the shared session for everyone in the room.
  Future<void> _stopSession(Room room) async {
    try {
      await RoomRepository.stopSession(room.id);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Stop session failed: $e')),
      );
    }
  }

  /// Scans rooms for newly-expired shared sessions and notifies once.
  /// The owner also clears the Firestore flag so members stop seeing it.
  /// Called every second from _ticker and on every rooms snapshot.
  void _checkExpiredSessions() {
    if (!mounted) return;
    for (final room in _rooms) {
      if (!room.sessionActive || room.sessionEndsAtMillis == null) continue;
      if (room.sessionEndsAtMillis! >
          DateTime.now().millisecondsSinceEpoch) {
        continue;
      }
      // Session just expired.
      if (_expiredShownFor.contains(room.id)) continue;
      _expiredShownFor.add(room.id);
      final isOwner = room.ownerId.isEmpty || room.ownerId == _uid;
      if (isOwner) {
        // Clear the flag for everyone; don't await (best-effort).
        RoomRepository.stopSession(room.id).catchError((e) {
          debugPrint('Auto-stop expired session failed: $e');
          return null;
        });
      }
      _showSessionExpiredDialog(room.name);
    }
  }

  void _showSessionExpiredDialog(String roomName) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF0F172A),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
          ),
          title: const Text(
            'Session Ended',
            style: TextStyle(color: Colors.orangeAccent, fontWeight: FontWeight.bold),
          ),
          content: Text(
            'The session for "$roomName" has automatically stopped because the timer ran out.',
            style: const TextStyle(color: Colors.grey, fontSize: 15),
          ),
          actions: [
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(),
              style: ElevatedButton.styleFrom(
                backgroundColor: _currentAccentColor,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: const Text('OK', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  /// Accounts currently in the room (owner + joined members).
  /// Each tile streams its user doc so the online dot updates live.
  Widget _buildRoomMembers(Room room) {
    if (room.members.isEmpty) {
      return Center(
        child: Text(
          'No accounts in this room yet.',
          style: TextStyle(color: Colors.grey[400], fontSize: 14),
        ),
      );
    }
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: room.members.length,
      separatorBuilder: (context, index) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final uid = room.members[index];
        return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          key: ValueKey('member:$uid'),
          stream: FirebaseFirestore.instance
              .collection('users')
              .doc(uid)
              .snapshots(),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              debugPrint(
                  'Member profile error uid=$uid: ${snapshot.error}');
            } else if (snapshot.hasData &&
                !(snapshot.data?.exists ?? false)) {
              debugPrint('Member profile missing uid=$uid (no users doc)');
            }
            final data = snapshot.data?.data() ?? {};
            // Legacy rooms may store an email directly in members.
            final isEmailEntry = uid.contains('@');
            final email = (data['email'] as String?) ??
                (isEmailEntry ? uid : '');
            final displayName = (data['displayName'] as String?) ??
                (email.contains('@') ? email.split('@').first : null) ??
                'User ${uid.length >= 4 ? uid.substring(0, 4) : uid}';
            // Cache for the "member left" alert after they disappear.
            if (displayName.trim().isNotEmpty &&
                !displayName.startsWith('User ')) {
              _knownNames[uid] = displayName;
            }
            final isOwner = uid == room.ownerId;
            final isYou = uid == _uid;
            final firestoreOnline = _isOnlineFromData(data);
            final amOwner =
                room.ownerId.isEmpty || room.ownerId == _uid;
            final canKick =
                amOwner && !isOwner && uid != _uid;
            final initial = displayName.isNotEmpty
                ? displayName[0].toUpperCase()
                : '?';
            // Nest RTDB status so the dot flips instantly on kill/logout,
            // falling back to Firestore when RTDB isn't configured.
            return StreamBuilder<DatabaseEvent>(
              stream: _rtdbStatusStream(uid),
              builder: (context, rtdbSnap) {
                final online = _onlineFromRtdb(
                    rtdbSnap.data, firestoreOnline);
                // Owner alert: fires once when a member goes offline.
                _maybeAlertOffline(
                  room: room,
                  uid: uid,
                  displayName: displayName,
                  online: online,
                );
                return Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                    color: isOwner
                        ? _currentAccentColor.withValues(alpha: 0.5)
                        : Colors.white.withValues(alpha: 0.1)),
              ),
              child: Row(
                children: [
                  Stack(
                    children: [
                      CircleAvatar(
                        radius: 22,
                        backgroundColor: isOwner
                            ? _currentAccentColor.withValues(alpha: 0.25)
                            : Colors.blueAccent.withValues(alpha: 0.2),
                        child: Text(
                          initial,
                          style: TextStyle(
                              color: _currentAccentColor,
                              fontWeight: FontWeight.bold,
                              fontSize: 18),
                        ),
                      ),
                      // Live online/offline dot.
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: Container(
                          width: 14,
                          height: 14,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: online ? Colors.greenAccent : Colors.grey,
                            border: Border.all(
                                color: const Color(0xFF0F172A), width: 2),
                          ),
                        ),
                      ),
                      if (isOwner)
                        const Positioned(
                          left: 0,
                          top: 0,
                          child: Icon(Icons.star_rounded,
                              size: 16, color: Colors.amber),
                        ),
                    ],
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                displayName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              online ? 'Online' : 'Offline',
                              style: TextStyle(
                                  color: online
                                      ? Colors.greenAccent
                                      : Colors.grey[500],
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          email.isNotEmpty ? email : 'uid: $uid',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              TextStyle(color: Colors.grey[400], fontSize: 12),
                        ),
                        if (snapshot.hasError)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              'sync error: ${snapshot.error}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Colors.redAccent, fontSize: 10),
                            ),
                          ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            if (isOwner)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: _currentAccentColor.withValues(
                                      alpha: 0.2),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  'OWNER',
                                  style: TextStyle(
                                      color: _currentAccentColor,
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold),
                                ),
                              ),
                            if (isOwner && isYou) const SizedBox(width: 6),
                            if (isYou)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: Colors.green.withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Text(
                                  'YOU',
                                  style: TextStyle(
                                      color: Colors.greenAccent,
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (canKick)
                    IconButton(
                      onPressed: () =>
                          _kickMember(room, uid, displayName),
                      icon: const Icon(Icons.person_remove_outlined,
                          color: Colors.redAccent, size: 22),
                      tooltip: 'Remove $displayName',
                    ),
                ],
              ),
                );
              },
            );
          },
        );
      },
    );
  }

  /// Online only if isOnline flag is true AND lastSeen is fresh (<2 min).
  /// This fixes the stuck-green-dot bug when the app is swiped away:
  /// the flag may still be true, but a stale lastSeen forces offline.
  bool _isOnlineFromData(Map<String, dynamic> data) {
    if (data['isOnline'] != true) return false;
    final lastSeen = data['lastSeen'];
    if (lastSeen is Timestamp) {
      try {
        final seen = lastSeen.toDate();
        return DateTime.now().difference(seen).inMinutes < 2;
      } catch (_) {
        return false;
      }
    }
    // Old docs without lastSeen: trust the flag.
    return true;
  }

  Future<void> _signOutAndGoHome() async {
    // Capture uid BEFORE sign-out, otherwise _uid becomes ''.
    final uid = _uid;
    try {
      await _roomsSub?.cancel();
    } catch (_) {}
    _ticker?.cancel();
    _presenceTimer?.cancel();
    // Mark offline BEFORE signing out so other members see it instantly.
    if (uid.isNotEmpty) {
      try {
        await _updatePresence(false, uidOverride: uid);
      } catch (_) {}
      try {
        await _setRtdbState('offline');
        await _rtdbStatusRef?.onDisconnect().cancel();
      } catch (_) {}
      _rtdbStatusRef = null;
    }
    try {
      await FirebaseAuth.instance.signOut();
    } catch (e) {
      debugPrint('Sign out failed: $e');
    }
    if (!mounted) return;
    try {
      Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);
    } catch (_) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  void _showSwitchAccountDialog() {
    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xFF0F172A),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
          ),
          title: const Text(
            'Switch Account',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          content: const Text(
            'Are you sure you want to switch to another account?',
            style: TextStyle(color: Colors.grey, fontSize: 15),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                _signOutAndGoHome();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: _currentAccentColor,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: const Text('Yes, Switch', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  void _showAddRoomDialog() {
    // Empty by default — user types anything they want (with hints + presets).
    final nameController = TextEditingController();
    final maxDevicesController = TextEditingController();
    final hoursController = TextEditingController();
    final minutesController = TextEditingController();
    final codeController = TextEditingController(text: 'LCK-${1000 + Random().nextInt(9000)}');

    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xFF0F172A),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
          ),
          title: const Text(
            'Add New Room',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameController,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'Room Name',
                    labelStyle: TextStyle(color: Colors.grey[400]),
                    prefixIcon: Icon(Icons.room_outlined, color: _currentAccentColor),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: _currentAccentColor, width: 2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                // Join Code generator section
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: codeController,
                        readOnly: true,
                        style: TextStyle(color: _currentAccentColor, fontWeight: FontWeight.bold, letterSpacing: 1.5),
                        decoration: InputDecoration(
                          labelText: 'Join Code',
                          labelStyle: TextStyle(color: Colors.grey[400]),
                          prefixIcon: Icon(Icons.qr_code_rounded, color: _currentAccentColor),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: _currentAccentColor, width: 2),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      onPressed: () {
                        codeController.text = 'LCK-${1000 + Random().nextInt(9000)}';
                      },
                      icon: const Icon(Icons.refresh_rounded, size: 16),
                      label: const Text('Generate'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _currentAccentColor,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: maxDevicesController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'Max Connected Devices (1-100)',
                    hintText: 'e.g. 5',
                    hintStyle: TextStyle(color: Colors.grey[600], fontSize: 13),
                    labelStyle: TextStyle(color: Colors.grey[400], fontSize: 13),
                    prefixIcon: Icon(Icons.devices_rounded, color: _currentAccentColor),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: _currentAccentColor, width: 2),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  'Auto-Stop Timer (1 min - 7 days)',
                  style: TextStyle(color: Colors.grey[400], fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: hoursController,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          labelText: 'Hours',
                          hintText: '0',
                          hintStyle: TextStyle(color: Colors.grey[600]),
                          labelStyle: TextStyle(color: Colors.grey[400]),
                          prefixIcon: const Icon(Icons.hourglass_empty_rounded, color: Colors.orangeAccent),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: _currentAccentColor, width: 2),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: minutesController,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          labelText: 'Minutes',
                          hintText: 'e.g. 5',
                          hintStyle: TextStyle(color: Colors.grey[600]),
                          labelStyle: TextStyle(color: Colors.grey[400]),
                          prefixIcon: const Icon(Icons.timer_outlined, color: Colors.orangeAccent),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: _currentAccentColor, width: 2),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              onPressed: () async {
                final name = nameController.text.trim();
                if (name.isEmpty) {
                  ScaffoldMessenger.of(dialogContext).showSnackBar(
                    const SnackBar(content: Text('Enter a room name')),
                  );
                  return;
                }
                if (_uid.isEmpty) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text(
                              'Not signed in with Firebase — cannot create shared room.')),
                    );
                  }
                  return;
                }
                // Anything the user wants: 1-100 devices, 1 min - 7 days.
                final maxDevices =
                    int.tryParse(maxDevicesController.text.trim());
                if (maxDevices == null ||
                    maxDevices < 1 ||
                    maxDevices > 100) {
                  ScaffoldMessenger.of(dialogContext).showSnackBar(
                    const SnackBar(
                        content: Text('Enter max devices (1-100)')),
                  );
                  return;
                }
                final hours =
                    int.tryParse(hoursController.text.trim()) ?? 0;
                final minutes =
                    int.tryParse(minutesController.text.trim()) ?? 0;
                final totalMinutes = (hours * 60) + minutes;
                if (totalMinutes < 1 || totalMinutes > 10080) {
                  ScaffoldMessenger.of(dialogContext).showSnackBar(
                    const SnackBar(
                        content: Text(
                            'Enter timer duration (1 min - 7 days)')),
                  );
                  return;
                }
                final joinCode =
                    codeController.text.trim().toUpperCase();

                final newRoom = Room(
                  name: name,
                  maxDevices: maxDevices,
                  timerMinutes: totalMinutes,
                  joinCode: joinCode,
                  ownerId: _uid,
                  members: [_uid],
                );
                Navigator.of(dialogContext).pop();
                try {
                  await RoomRepository.createRoom(newRoom);
                  if (!mounted) return;
                  setState(() => _selectedIndex = 0);
                } catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Create failed: $e')),
                  );
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: _currentAccentColor,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: const Text('Add', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  void _showEditRoomDialog(int index) {
    final room = _rooms[index];
    // Owner-only edit (firestore.rules also enforces this).
    if (room.ownerId.isNotEmpty && room.ownerId != _uid) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Only the room owner can edit this room.')),
      );
      return;
    }
    final nameController = TextEditingController(text: room.name);
    final maxDevicesController = TextEditingController(text: room.maxDevices.toString());
    final codeController = TextEditingController(text: room.joinCode);
    
    final existingHours = room.timerMinutes ~/ 60;
    final existingMinutes = room.timerMinutes % 60;
    final hoursController = TextEditingController(text: existingHours.toString());
    final minutesController = TextEditingController(text: existingMinutes.toString());

    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xFF0F172A),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
          ),
          title: const Text(
            'Edit Room',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameController,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'Room Name',
                    labelStyle: TextStyle(color: Colors.grey[400]),
                    prefixIcon: Icon(Icons.room_outlined, color: _currentAccentColor),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: _currentAccentColor, width: 2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                // Join Code section
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: codeController,
                        readOnly: true,
                        style: TextStyle(color: _currentAccentColor, fontWeight: FontWeight.bold, letterSpacing: 1.5),
                        decoration: InputDecoration(
                          labelText: 'Join Code',
                          labelStyle: TextStyle(color: Colors.grey[400]),
                          prefixIcon: Icon(Icons.qr_code_rounded, color: _currentAccentColor),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: _currentAccentColor, width: 2),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      onPressed: () {
                        codeController.text = 'LCK-${1000 + Random().nextInt(9000)}';
                      },
                      icon: const Icon(Icons.refresh_rounded, size: 16),
                      label: const Text('Generate'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _currentAccentColor,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: maxDevicesController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'Max Connected Devices (1-100)',
                    hintText: 'e.g. 5',
                    hintStyle: TextStyle(color: Colors.grey[600], fontSize: 13),
                    labelStyle: TextStyle(color: Colors.grey[400], fontSize: 13),
                    prefixIcon: Icon(Icons.devices_rounded, color: _currentAccentColor),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: _currentAccentColor, width: 2),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  'Auto-Stop Timer (1 min - 7 days)',
                  style: TextStyle(color: Colors.grey[400], fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: hoursController,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          labelText: 'Hours',
                          hintText: '0',
                          hintStyle: TextStyle(color: Colors.grey[600]),
                          labelStyle: TextStyle(color: Colors.grey[400]),
                          prefixIcon: const Icon(Icons.hourglass_empty_rounded, color: Colors.orangeAccent),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: _currentAccentColor, width: 2),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: minutesController,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          labelText: 'Minutes',
                          hintText: 'e.g. 5',
                          hintStyle: TextStyle(color: Colors.grey[600]),
                          labelStyle: TextStyle(color: Colors.grey[400]),
                          prefixIcon: const Icon(Icons.timer_outlined, color: Colors.orangeAccent),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: _currentAccentColor, width: 2),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              onPressed: () async {
                final name = nameController.text.trim();
                if (name.isEmpty) {
                  ScaffoldMessenger.of(dialogContext).showSnackBar(
                    const SnackBar(content: Text('Enter a room name')),
                  );
                  return;
                }
                final maxDevices =
                    int.tryParse(maxDevicesController.text.trim());
                if (maxDevices == null ||
                    maxDevices < 1 ||
                    maxDevices > 100) {
                  ScaffoldMessenger.of(dialogContext).showSnackBar(
                    const SnackBar(
                        content: Text('Enter max devices (1-100)')),
                  );
                  return;
                }
                final hours =
                    int.tryParse(hoursController.text.trim()) ?? 0;
                final minutes =
                    int.tryParse(minutesController.text.trim()) ?? 0;
                final totalMinutes = (hours * 60) + minutes;
                if (totalMinutes < 1 || totalMinutes > 10080) {
                  ScaffoldMessenger.of(dialogContext).showSnackBar(
                    const SnackBar(
                        content: Text(
                            'Enter timer duration (1 min - 7 days)')),
                  );
                  return;
                }
                final joinCode =
                    codeController.text.trim().toUpperCase();

                final updatedRoom = Room(
                  id: room.id,
                  name: name,
                  maxDevices: maxDevices,
                  timerMinutes: totalMinutes,
                  joinCode: joinCode,
                  ownerId: room.ownerId,
                  members: room.members,
                  // Preserve the shared session so editing doesn't kill it.
                  sessionActive: room.sessionActive,
                  sessionEndsAtMillis: room.sessionEndsAtMillis,
                );
                Navigator.of(dialogContext).pop();
                try {
                  await RoomRepository.updateRoom(updatedRoom);
                } catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Update failed: $e')),
                  );
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: _currentAccentColor,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: const Text('Save', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  Future<void> _deleteRoom(int index) async {
    final removed = _rooms[index];
    // Owner-only delete (matches firestore.rules).
    if (removed.ownerId.isNotEmpty && removed.ownerId != _uid) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Only the room owner can delete this room.')),
      );
      return;
    }
    // No local timer to stop — the shared session lives in Firestore
    // and dies with the room document.
    try {
      await RoomRepository.deleteRoom(removed.id);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Delete failed: $e')),
      );
    }
  }

  /// Owner-only kick: confirm, then arrayRemove the member.
  Future<void> _kickMember(Room room, String uid, String label) async {
    if (room.ownerId.isNotEmpty && room.ownerId != _uid) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Only the room owner can remove members.')),
      );
      return;
    }
    if (uid == room.ownerId || uid == _uid) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF0F172A),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
        ),
        title: const Text(
          'Remove member?',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: Text(
          'Remove "$label" from "${room.name}"? They can rejoin with the code.',
          style: const TextStyle(color: Colors.grey, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Remove',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await RoomRepository.removeMember(room.id, uid);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Removed "$label" from ${room.name}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Remove failed: $e')),
      );
    }
  }

  Future<void> _showJoinCodeModal(Room room) async {
    // Normalize first so QrImageView never gets blank data (blank = invisible).
    final code = Room.normalizeJoinCode(room.joinCode);
    debugPrint('Show QR dialog for code: "$code" len=${code.length}');

    // Backfill old docs in background (don't block QR display).
    if (code != room.joinCode.trim().toUpperCase() &&
        room.id.isNotEmpty &&
        (room.ownerId.isEmpty || room.ownerId == _uid)) {
      FirebaseFirestore.instance
          .collection('rooms')
          .doc(room.id)
          .update({'joinCode': code}).then((_) {
        room.joinCode = code;
      }).catchError((e) {
        debugPrint('Backfill joinCode failed: $e');
        return null;
      });
    }

    // Show loader briefly so tap feels responsive, then show QR.
    // Loader is a separate route that we always dismiss before showing QR.
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: SizedBox(
          width: 60,
          height: 60,
          child: Card(
            color: Color(0xFF0F172A),
            child: Padding(
              padding: EdgeInsets.all(14),
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
          ),
        ),
      ),
    );
    await Future.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;
    // Dismiss loader safely (only if something is on top of dashboard).
    try {
      final nav = Navigator.of(context);
      if (nav.canPop()) nav.pop();
    } catch (e) {
      debugPrint('Dismiss loader failed: $e');
    }
    await Future.delayed(const Duration(milliseconds: 100));
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF0F172A),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
          ),
          title: Text(
            room.name,
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Scan QR code or share code to join automatically:',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey, fontSize: 13),
                ),
                const SizedBox(height: 16),
                // FIX: QrImageView uses LayoutBuilder internally, which crashes
                // inside AlertDialog+SingleChildScrollView ("LayoutBuilder does
                // not support returning intrinsic dimensions") -> white box.
                // Wrapping in fixed SizedBox gives AlertDialog fixed intrinsics
                // so it never asks LayoutBuilder for them.
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: SizedBox(
                    width: 200,
                    height: 200,
                    child: QrImageView(
                      data: code,
                      version: QrVersions.auto,
                      errorCorrectionLevel: QrErrorCorrectLevel.L,
                      size: 200.0,
                      gapless: false,
                      backgroundColor: Colors.white,
                      errorStateBuilder: (ctx, err) {
                        debugPrint('QR encode FAILED for "$code": $err');
                        return SizedBox(
                          width: 200,
                          height: 200,
                          child: Center(
                            child: Text(
                              'QR FAILED\n$code\n$err',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  color: Colors.red, fontSize: 11),
                            ),
                          ),
                        );
                      },
                      eyeStyle: const QrEyeStyle(
                        eyeShape: QrEyeShape.square,
                        color: Color(0xFF0F172A),
                      ),
                      dataModuleStyle: const QrDataModuleStyle(
                        dataModuleShape: QrDataModuleShape.square,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: _currentAccentColor.withValues(alpha: 0.3)),
                  ),
                  child: Text(
                    code,
                    style: TextStyle(
                      color: _currentAccentColor,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 2.0,
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: code));
                Navigator.of(context).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Copied $code to clipboard!')),
                );
              },
              icon: const Icon(Icons.copy_rounded, size: 16),
              label: const Text('Copy Code'),
              style: ElevatedButton.styleFrom(
                backgroundColor: _currentAccentColor,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildHomeContent() {
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _currentAccentColor.withValues(alpha: 0.1),
              boxShadow: [
                BoxShadow(
                  color: _currentAccentColor.withValues(alpha: 0.2),
                  blurRadius: 40,
                  spreadRadius: 10,
                ),
              ],
            ),
            child: Icon(
              Icons.home_rounded,
              size: 64,
              color: _currentAccentColor,
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'Protected Rooms',
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: Colors.white,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 16),
          if (_roomsLoading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(color: Colors.cyanAccent),
            )
          else if (_roomsError != null)
            Text(
              'Failed to load rooms:\n$_roomsError',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.redAccent, fontSize: 13),
            )
          else if (_uid.isEmpty)
            const Text(
              'Not signed in with Firebase.\nSign in again to see shared rooms.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, fontSize: 14),
            )
          else if (_rooms.isEmpty)
            Text(
              'No rooms added yet.\nTap "+ Add Room" below to get started.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey[400], fontSize: 14),
            )
          else
            SizedBox(
                  height: 190,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: _rooms.length,
                    itemBuilder: (context, index) {
                      final room = _rooms[index];
                      final isOwner =
                          room.ownerId.isEmpty || room.ownerId == _uid;
                      return GestureDetector(
                        onTap: () {
                          setState(() {
                            _selectedRoom = room;
                            _selectedIndex = 1; // Jump to Security section
                          });
                        },
                        child: Container(
                          width: 180,
                          margin: const EdgeInsets.symmetric(horizontal: 8),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.05),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  // QR Code Button on the Left Side
                                  IconButton(
                                    onPressed: () => _showJoinCodeModal(room),
                                    icon: Icon(Icons.qr_code_2_rounded, color: _currentAccentColor, size: 22),
                                    tooltip: 'Show QR Code',
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(),
                                  ),
                                  // Options Menu (Edit/Delete) — owner only
                                  if (isOwner)
                                    SizedBox(
                                      height: 24,
                                      width: 24,
                                      child: PopupMenuButton<String>(
                                        padding: EdgeInsets.zero,
                                        icon: const Icon(Icons.more_vert_rounded, color: Colors.grey, size: 18),
                                        color: const Color(0xFF0F172A),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(12),
                                          side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
                                        ),
                                        onSelected: (value) {
                                          if (value == 'edit') {
                                            _showEditRoomDialog(index);
                                          } else if (value == 'delete') {
                                            _deleteRoom(index);
                                          }
                                        },
                                        itemBuilder: (BuildContext context) => [
                                          PopupMenuItem<String>(
                                            value: 'edit',
                                            child: Row(
                                              children: [
                                                Icon(Icons.edit_outlined, size: 16, color: _currentAccentColor),
                                                const SizedBox(width: 8),
                                                Text('Edit', style: TextStyle(color: Colors.white, fontSize: 13)),
                                              ],
                                            ),
                                          ),
                                          PopupMenuItem<String>(
                                            value: 'delete',
                                            child: Row(
                                              children: [
                                                Icon(Icons.delete_outline, size: 16, color: Colors.redAccent),
                                                const SizedBox(width: 8),
                                                Text('Delete', style: TextStyle(color: Colors.white, fontSize: 13)),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    )
                                  else
                                    const SizedBox(
                                      height: 24,
                                      width: 24,
                                      child: Tooltip(
                                        message: 'Only the owner can edit',
                                        child: Icon(Icons.lock_outline,
                                            color: Colors.grey, size: 16),
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                room.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  Icon(Icons.devices_rounded, size: 13, color: _currentAccentColor.withValues(alpha: 0.8)),
                                  const SizedBox(width: 4),
                                  Text(
                                    'Max: ${room.maxDevices}',
                                    style: TextStyle(color: Colors.grey[400], fontSize: 12),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  const Icon(Icons.timer_outlined, size: 13, color: Colors.orangeAccent),
                                  const SizedBox(width: 4),
                                  Text(
                                    'Timer: ${room.formattedTimer}',
                                    style: TextStyle(color: Colors.grey[400], fontSize: 12),
                                  ),
                                ],
                              ),
                              if (room.isLive) ...[
                                const SizedBox(height: 4),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.orangeAccent.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(color: Colors.orangeAccent.withValues(alpha: 0.4)),
                                  ),
                                  child: Text(
                                    'LIVE ${room.formattedSessionRemaining}',
                                    style: const TextStyle(color: Colors.orangeAccent, fontSize: 11, fontWeight: FontWeight.bold),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
        ],
      ),
    );
  }

  Widget _buildSecurityContent() {
    if (_roomsLoading) {
      return const Center(
          child: CircularProgressIndicator(color: Colors.cyanAccent));
    }
    if (_roomsError != null) {
      return Center(
        child: Text('Failed to load rooms:\n$_roomsError',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.redAccent)),
      );
    }
    if (_uid.isEmpty) {
      return const Center(
        child: Text(
            'Not signed in with Firebase.\nSign in again to see shared rooms.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey)),
      );
    }
    if (_rooms.isEmpty) {
      return SingleChildScrollView(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.security_rounded, size: 64, color: _currentAccentColor),
            const SizedBox(height: 24),
            const Text(
              'Security Dashboard',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white),
            ),
            const SizedBox(height: 12),
            Text(
              'No rooms created yet. Add a room from the Home section to see room members.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey[400], fontSize: 14),
            ),
          ],
        ),
      );
    }

    Room? activeRoomNullable;
    if (_selectedRoom != null) {
      final m = _rooms.where((r) => r.id == _selectedRoom!.id);
      activeRoomNullable = m.isNotEmpty ? m.first : null;
    }
    final Room activeRoom = activeRoomNullable ?? _rooms.first;
    final bool isOwner =
        activeRoom.ownerId.isEmpty || activeRoom.ownerId == _uid;
    // Shared Firestore session — true for EVERY member when live.
    final bool isThisRoomActive = activeRoom.isLive;

    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
        // BIG owner notification: shown when a member goes offline/left.
        if (_ownerBanner != null && isOwner)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 12),
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: Colors.redAccent.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                  color: Colors.redAccent.withValues(alpha: 0.6),
                  width: 2),
              boxShadow: [
                BoxShadow(
                  color: Colors.redAccent.withValues(alpha: 0.3),
                  blurRadius: 20,
                ),
              ],
            ),
            child: Row(
              children: [
                const Icon(Icons.emergency_rounded,
                    color: Colors.redAccent, size: 36),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _ownerBanner!,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () =>
                      setState(() => _ownerBanner = null),
                  icon: const Icon(Icons.close_rounded,
                      color: Colors.white70),
                  tooltip: 'Dismiss',
                ),
              ],
            ),
          ),
        // Header: wraps on narrow phones so Start/Stop never overflows.
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Security & Room Members',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: Colors.white),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Room: ${activeRoom.name} (Code: ${activeRoom.joinCode})',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: _currentAccentColor, fontSize: 13),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                DropdownButton<String>(
                  value: _rooms.any((r) => r.id == activeRoom.id)
                      ? activeRoom.id
                      : null,
                  dropdownColor: const Color(0xFF0F172A),
                  style: const TextStyle(color: Colors.white),
                  icon:
                      Icon(Icons.arrow_drop_down, color: _currentAccentColor),
                  items: _rooms.map((Room room) {
                    return DropdownMenuItem<String>(
                      value: room.id,
                      child: Text(room.name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white)),
                    );
                  }).toList(),
                  onChanged: (String? newId) {
                    if (newId == null) return;
                    final m = _rooms.where((r) => r.id == newId);
                    if (m.isNotEmpty) {
                      setState(() {
                        _selectedRoom = m.first;
                      });
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Start / Stop Session Button — owner controls, EVERYONE sees countdown.
            // Full-width on its own row: no Row overflow on 360px phones.
            SizedBox(
              width: double.infinity,
              height: 44,
              child: ElevatedButton.icon(
                onPressed: !isOwner
                    ? () {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                              content: Text(isThisRoomActive
                                  ? 'Session running: ${activeRoom.formattedSessionRemaining} left (owner controls it).'
                                  : 'Only the room owner can start the session.')),
                        );
                      }
                    : () {
                        if (isThisRoomActive) {
                          _stopSession(activeRoom);
                        } else {
                          _startSession(activeRoom);
                        }
                      },
                icon: Icon(
                    isOwner
                        ? (isThisRoomActive
                            ? Icons.stop_rounded
                            : Icons.play_arrow_rounded)
                        : (isThisRoomActive
                            ? Icons.timer_rounded
                            : Icons.lock_outline),
                    size: 18),
                label: Text(
                  isThisRoomActive
                      ? (isOwner
                          ? 'Stop (${activeRoom.formattedSessionRemaining})'
                          : activeRoom.formattedSessionRemaining)
                      : 'Start Session',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 13),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: !isOwner
                      ? Colors.grey[700]
                      : (isThisRoomActive
                          ? Colors.redAccent
                          : Colors.green[700]),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        // Wraps on narrow phones: Members + badges flow to next line
        // instead of overflowing 172px when session is active.
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.group_rounded,
                    color: Colors.greenAccent, size: 18),
                const SizedBox(width: 8),
                Text(
                  'Members: ${activeRoom.members.length}',
                  style: const TextStyle(
                      color: Colors.grey,
                      fontSize: 14,
                      fontWeight: FontWeight.w600),
                ),
              ],
            ),
            if (!isOwner)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.grey.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                  border:
                      Border.all(color: Colors.grey.withValues(alpha: 0.3)),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.lock_outline, size: 12, color: Colors.grey),
                    SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        'Owner controls session',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: Colors.grey,
                            fontSize: 11,
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ),
            if (isThisRoomActive)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.orangeAccent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: Colors.orangeAccent.withValues(alpha: 0.3)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.timer_rounded,
                        size: 12, color: Colors.orangeAccent),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        'Session Active (${activeRoom.formattedSessionRemaining} left)',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.orangeAccent,
                            fontSize: 11,
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),
        _buildRoomMembers(activeRoom),
        const SizedBox(height: 16),
      ],
      ),
    );
  }

  Widget _buildThemeChip(AppThemeOption themeOption) {
    final isSelected = _currentTheme.name == themeOption.name;
    return GestureDetector(
      onTap: () {
        if (_currentTheme.name == themeOption.name) return;
        setState(() {
          _currentTheme = themeOption;
        });
        // Persist per-account so relogin / new device restores it.
        _saveTheme(themeOption);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Theme saved: ${themeOption.name}')),
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? themeOption.accentColor.withValues(alpha: 0.2) : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? themeOption.accentColor : Colors.white.withValues(alpha: 0.1),
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: themeOption.accentColor,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              themeOption.name,
              style: TextStyle(
                color: isSelected ? Colors.white : Colors.grey[400],
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSettingsContent() {
    final codeController = TextEditingController();

    void showEnterCodeDialog() {
      showDialog(
        context: context,
        builder: (BuildContext dialogContext) {
          return AlertDialog(
            backgroundColor: const Color(0xFF0F172A),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
            ),
            title: const Text(
              'Enter Room Join Code',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
            content: TextField(
              controller: codeController,
              style: TextStyle(color: _currentAccentColor, fontWeight: FontWeight.bold, letterSpacing: 1.5),
              decoration: InputDecoration(
                labelText: 'e.g. LCK-4892',
                labelStyle: TextStyle(color: Colors.grey[400]),
                prefixIcon: Icon(Icons.qr_code_rounded, color: _currentAccentColor),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: _currentAccentColor, width: 2),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
              ),
              ElevatedButton(
                onPressed: () async {
                  final code = codeController.text.trim().toUpperCase();
                  Navigator.of(dialogContext).pop();
                  if (code.isEmpty) return;
                  if (_uid.isEmpty) {
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text(
                              'Not signed in with Firebase — cannot join shared room.')),
                    );
                    return;
                  }
                  try {
                    final joined =
                        await RoomRepository.joinByCode(code, _uid);
                    if (!mounted) return;
                    if (joined == null) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                            content: Text(
                                'Room not found for code $code. Check the code and try again.')),
                      );
                      return;
                    }
                    setState(() {
                      _selectedRoom = joined;
                      _selectedIndex = 0;
                    });
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                          content: Text(
                              'Successfully joined & viewing room: ${joined.name} ($code)!')),
                    );
                  } catch (e) {
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Join failed: $e')),
                    );
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: _currentAccentColor,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                child: const Text('Join Room', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
          ],
        );
      },
    );
    }

    void showScanQrDialog() async {
      final controller = MobileScannerController(
        detectionSpeed: DetectionSpeed.noDuplicates,
      );
      bool handled = false;

      String? extractJoinCode(String raw) {
        final text = raw.trim().toUpperCase();
        if (text.isEmpty) return null;
        final match =
            RegExp(r'LCK-[A-Z0-9]{3,}').firstMatch(text);
        if (match != null) return match.group(0);
        // Fallback: raw QR content is the code itself.
        if (text.length <= 32 && !text.contains(' ')) return text;
        return null;
      }

      Future<void> joinWithCode(String code) async {
        if (handled) return;
        handled = true;
        try {
          controller.stop();
        } catch (_) {}
        if (!mounted) return;
        Navigator.of(context, rootNavigator: true).pop();
        if (_uid.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text(
                    'Not signed in with Firebase — cannot join shared room.')),
          );
          return;
        }
        try {
          final joined = await RoomRepository.joinByCode(code, _uid);
          if (!mounted) return;
          if (joined == null) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                  content: Text(
                      'Room not found for code $code. Check the code and try again.')),
            );
            return;
          }
          setState(() {
            _selectedRoom = joined;
            _selectedIndex = 0;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text(
                    'Joined room: ${joined.name} ($code)!')),
          );
        } catch (e) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Join failed: $e')),
          );
        }
      }

      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext dialogContext) {
          return AlertDialog(
            backgroundColor: const Color(0xFF0F172A),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
            ),
            title: const Text(
              'Scan Room QR Code',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: SizedBox(
                    height: 260,
                    width: 260,
                    child: MobileScanner(
                      controller: controller,
                      onDetect: (capture) {
                        for (final barcode in capture.barcodes) {
                          final raw = barcode.rawValue ?? '';
                          final code = extractJoinCode(raw);
                          if (code != null) {
                            joinWithCode(code);
                            break;
                          }
                        }
                      },
                      errorBuilder: (ctx, err, _) => Container(
                        color: Colors.black54,
                        alignment: Alignment.center,
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          err.errorCode == MobileScannerErrorCode
                                  .permissionDenied
                              ? 'Camera permission denied.\nAllow camera access in Settings to scan.'
                              : 'Camera unavailable.\nEnter the code manually instead.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: Colors.grey, fontSize: 12),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Align QR code within frame\nto join room automatically',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ],
            ),
            actions: [
              IconButton(
                onPressed: () {
                  try {
                    controller.toggleTorch();
                  } catch (_) {}
                },
                icon: const Icon(Icons.flash_on_rounded,
                    color: Colors.grey),
                tooltip: 'Toggle flash',
              ),
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child:
                    const Text('Cancel', style: TextStyle(color: Colors.grey)),
              ),
              ElevatedButton.icon(
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                  showEnterCodeDialog();
                },
                icon: const Icon(Icons.keyboard_rounded, size: 16),
                label: const Text('Enter Code Manually'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _currentAccentColor,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ],
          );
        },
      );
      try {
        await controller.dispose();
      } catch (_) {}
    }

    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        children: [
          // Section 1: Room Connection Settings Card
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxWidth: 500),
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _currentAccentColor.withValues(alpha: 0.1),
                    boxShadow: [
                      BoxShadow(
                        color: _currentAccentColor.withValues(alpha: 0.2),
                        blurRadius: 30,
                        spreadRadius: 8,
                      ),
                    ],
                  ),
                  child: Icon(
                    Icons.settings_rounded,
                    size: 48,
                    color: _currentAccentColor,
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  'Room Connection Settings',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    letterSpacing: 1.0,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Join another secure room by scanning its QR code or entering its room code.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey[400],
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 48,
                        child: ElevatedButton.icon(
                          onPressed: showScanQrDialog,
                          icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
                          label: const Text(
                            'Scan QR',
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _currentAccentColor,
                            foregroundColor: Colors.black,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: SizedBox(
                        height: 48,
                        child: ElevatedButton.icon(
                          onPressed: showEnterCodeDialog,
                          icon: const Icon(Icons.keyboard_rounded, size: 18),
                          label: const Text(
                            'Enter Code',
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.white.withValues(alpha: 0.08),
                            foregroundColor: Colors.white,
                            side: BorderSide(color: Colors.white.withValues(alpha: 0.15)),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Section 2: Theme Customization Card (Separated & Scrollable)
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxWidth: 500),
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.palette_rounded, color: _currentAccentColor, size: 22),
                    const SizedBox(width: 10),
                    const Text(
                      'Theme Customization',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'Choose your preferred accent theme for the dashboard.',
                  style: TextStyle(fontSize: 13, color: Colors.grey[400]),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: AppThemes.availableThemes.map((theme) => _buildThemeChip(theme)).toList(),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Section 3: Alert Sound (owner phone only)
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxWidth: 500),
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.music_note_rounded,
                        color: _currentAccentColor, size: 22),
                    const SizedBox(width: 10),
                    const Text(
                      'Alert Sound',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'Owner alert when a member leaves or goes offline.',
                  style: TextStyle(fontSize: 13, color: Colors.grey[400]),
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  value: _soundEnabled,
                  onChanged: (v) =>
                      setState(() => _soundEnabled = v),
                  title: const Text('Play alert sound',
                      style: TextStyle(color: Colors.white, fontSize: 14)),
                  activeThumbColor: _currentAccentColor,
                  contentPadding: EdgeInsets.zero,
                ),
                const Divider(color: Colors.white10),
                FutureBuilder<List<String>>(
                  future: _soundAssetsFuture,
                  builder: (context, snap) {
                    if (snap.connectionState == ConnectionState.waiting) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Center(
                            child: CircularProgressIndicator(strokeWidth: 2)),
                      );
                    }
                    final sounds = snap.data ?? [];
                    if (sounds.isEmpty) {
                      return Text(
                        'No sounds found. Add .mp3 files to assets/sounds/.',
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey[500]),
                      );
                    }
                    // Auto-fallback if previously selected file was deleted.
                    if (!sounds.contains(_selectedAlertSound)) {
                      final def = sounds.firstWhere(
                        (a) => a
                            .toLowerCase()
                            .contains('defultlockdown'),
                        orElse: () => sounds.first,
                      );
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted && _selectedAlertSound != def) {
                          setState(() => _selectedAlertSound = def);
                        }
                      });
                    }
                    return Column(
                      children: sounds.map((asset) {
                        final name = _soundDisplayName(asset);
                        final isDefault = asset
                            .toLowerCase()
                            .contains('defultlockdown');
                        final selected = _selectedAlertSound == asset;
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(
                            color: selected
                                ? _currentAccentColor.withValues(alpha: 0.12)
                                : Colors.white.withValues(alpha: 0.03),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: selected
                                  ? _currentAccentColor.withValues(alpha: 0.5)
                                  : Colors.white.withValues(alpha: 0.08),
                            ),
                          ),
                          child: ListTile(
                            leading: Icon(
                              selected
                                  ? Icons.radio_button_checked_rounded
                                  : Icons.radio_button_unchecked_rounded,
                              color: selected
                                  ? _currentAccentColor
                                  : Colors.grey[500],
                            ),
                            title: Text(
                              name,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14),
                            ),
                            subtitle: Text(
                              selected
                                  ? (isDefault
                                      ? 'Default • Selected'
                                      : 'Selected')
                                  : (isDefault
                                      ? 'Default • Tap to select'
                                      : 'Tap to select'),
                              style: TextStyle(
                                  color: selected
                                      ? _currentAccentColor
                                      : Colors.grey[500],
                                  fontSize: 11),
                            ),
                            trailing: IconButton(
                              icon: Icon(
                                  Icons.play_circle_outline_rounded,
                                  color: _currentAccentColor,
                                  size: 28),
                              tooltip: 'Preview $name',
                              onPressed: () =>
                                  _previewAlertSound(asset),
                            ),
                            onTap: () => setState(
                                () => _selectedAlertSound = asset),
                          ),
                        );
                      }).toList(),
                    );
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 30),
        ],
      ),
    );
  }

  /// Save a new display name to FirebaseAuth + users/{uid} so room
  /// members see the real name instead of "User ab12".
  Future<void> _saveDisplayName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty || _uid.isEmpty) return;
    try {
      final authUser = FirebaseAuth.instance.currentUser;
      if (authUser != null && authUser.displayName != trimmed) {
        await authUser.updateDisplayName(trimmed);
      }
      await FirebaseFirestore.instance.collection('users').doc(_uid).set(
        {
          'displayName': trimmed,
          'lastSeen': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Display name updated to "$trimmed"')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Update failed: $e')),
      );
    }
  }

  void _showEditDisplayNameDialog(String currentName) {
    final controller = TextEditingController(text: currentName);
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF0F172A),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
        ),
        title: const Text(
          'Edit Display Name',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: TextField(
          controller: controller,
          textCapitalization: TextCapitalization.words,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            labelText: 'Display Name',
            labelStyle: TextStyle(color: Colors.grey[400]),
            prefixIcon:
                Icon(Icons.badge_outlined, color: _currentAccentColor),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide:
                  BorderSide(color: Colors.white.withValues(alpha: 0.1)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: _currentAccentColor, width: 2),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              _saveDisplayName(controller.text);
              controller.dispose();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: _currentAccentColor,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child:
                const Text('Save', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _buildProfileContent() {
    if (_uid.isEmpty) {
      return const Center(
        child: Text('Not signed in.', style: TextStyle(color: Colors.grey)),
      );
    }
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(_uid)
          .snapshots(),
      builder: (context, snapshot) {
        final data = snapshot.data?.data() ?? {};
        final authUser = FirebaseAuth.instance.currentUser;
        final storedName = (data['displayName'] as String?)?.trim() ?? '';
        final authName = (authUser?.displayName?.trim().isNotEmpty == true)
            ? authUser!.displayName!.trim()
            : '';
        final email = (data['email'] as String?)?.trim().isNotEmpty == true
            ? (data['email'] as String).trim()
            : (authUser?.email ?? widget.email);
        final displayName = storedName.isNotEmpty
            ? storedName
            : (authName.isNotEmpty
                ? authName
                : (email.contains('@')
                    ? email.split('@').first
                    : widget.email));
        final initial = displayName.isNotEmpty
            ? displayName[0].toUpperCase()
            : '?';

        return SingleChildScrollView(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircleAvatar(
                radius: 48,
                backgroundColor:
                    _currentAccentColor.withValues(alpha: 0.2),
                child: Text(
                  initial,
                  style: TextStyle(
                      color: _currentAccentColor,
                      fontWeight: FontWeight.bold,
                      fontSize: 36),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: Text(
                      displayName,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () =>
                        _showEditDisplayNameDialog(displayName),
                    icon: Icon(Icons.edit_outlined,
                        color: _currentAccentColor, size: 20),
                    tooltip: 'Edit display name',
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                email,
                style: TextStyle(fontSize: 14, color: Colors.grey[400]),
              ),
              const SizedBox(height: 8),
              const Text(
                'Active Session • Secure Environment',
                style: TextStyle(fontSize: 13, color: Colors.grey),
              ),
              if (storedName.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12, left: 24, right: 24),
                  child: Text(
                    'Tip: tap the edit icon to set a real name so room members can identify you.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 12, color: Colors.orangeAccent[200]),
                  ),
                ),
              const SizedBox(height: 32),
              SizedBox(
                width: 260,
                height: 50,
                child: ElevatedButton.icon(
                  onPressed: _showSwitchAccountDialog,
                  icon: const Icon(Icons.switch_account_rounded),
                  label: const Text(
                    'Switch Account',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _currentAccentColor,
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final String userName = widget.email.contains('@')
        ? widget.email.split('@')[0].toUpperCase()
        : widget.email;

    // Shared live session visible to EVERYONE in the room (not just owner).
    Room? liveRoom;
    for (final r in _rooms) {
      if (r.isLive) {
        liveRoom = r;
        break;
      }
    }

    final List<String> navTitles = ['Home', 'Security', 'Settings', 'Profile'];
    final List<IconData> navIcons = [Icons.home_rounded, Icons.security_rounded, Icons.settings_rounded, Icons.person_rounded];

    return Scaffold(
      floatingActionButton: _selectedIndex == 0
          ? FloatingActionButton.extended(
              onPressed: _showAddRoomDialog,
              backgroundColor: _currentAccentColor,
              foregroundColor: Colors.black,
              icon: const Icon(Icons.add),
              label: const Text('Add Room', style: TextStyle(fontWeight: FontWeight.bold)),
            )
          : null,
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              _currentTheme.backgroundTint,
              const Color(0xFF090D16),
              const Color(0xFF020617),
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // Top Bar with User Name at top left, Global Live Timer in center, and Logout on right
              Padding(
                padding: const EdgeInsets.all(20.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // User Name at top left
                    Flexible(
                      flex: 2,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.blueAccent.withValues(alpha: 0.15),
                              border: Border.all(
                                  color: _currentAccentColor.withValues(
                                      alpha: 0.3)),
                            ),
                            child: Icon(Icons.person,
                                color: _currentAccentColor, size: 20),
                          ),
                          const SizedBox(width: 12),
                          Flexible(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text(
                                  'Welcome back,',
                                  style: TextStyle(
                                      color: Colors.grey, fontSize: 13),
                                ),
                                Text(
                                  userName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 18,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),

                    // Global Live Session Timer — shared via Firestore, so
                    // owner AND members all see the same countdown.
                    if (liveRoom != null)
                      Flexible(
                        flex: 2,
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 8),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.orangeAccent.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                                color: Colors.orangeAccent.withValues(
                                    alpha: 0.4)),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.orangeAccent.withValues(
                                    alpha: 0.2),
                                blurRadius: 10,
                              ),
                            ],
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.timer_rounded,
                                  size: 16, color: Colors.orangeAccent),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  '${liveRoom.name}: ${liveRoom.formattedSessionRemaining}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      color: Colors.orangeAccent,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                    // Logout button
                    IconButton(
                      onPressed: _signOutAndGoHome,
                      icon: const Icon(Icons.logout_rounded, color: Colors.redAccent),
                      tooltip: 'Log Out',
                    ),
                  ],
                ),
              ),

              // Main Content Body with Vertical Navigation on the Right.
              // Nav is vertically centered (middle-right); content stays
              // top-aligned so tabs scroll correctly.
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // Main Content Area — top-aligned so tabs scroll
                    // correctly. Center used to break Expanded inside
                    // Security tab and swallow scroll gestures on mobile.
                    Expanded(
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: ConstrainedBox(
                          constraints:
                              const BoxConstraints(maxWidth: 640),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 24.0),
                            child: _selectedIndex == 0
                                ? _buildHomeContent()
                                : _selectedIndex == 1
                                    ? _buildSecurityContent()
                                    : _selectedIndex == 2
                                        ? _buildSettingsContent()
                                        : _selectedIndex == 3
                                            ? _buildProfileContent()
                                            : Container(),
                          ),
                        ),
                      ),
                    ),

                    // Vertical Navigation Bar — middle-right, vertically centered
                    Container(
                      width: 68,
                      margin:
                          const EdgeInsets.only(right: 14, top: 16, bottom: 16),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.03),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: List.generate(navTitles.length, (index) {
                          final isSelected = _selectedIndex == index;
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6.0, horizontal: 8.0),
                            child: InkWell(
                              onTap: () => setState(() => _selectedIndex = index),
                              borderRadius: BorderRadius.circular(14),
                              child: Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: isSelected ? _currentAccentColor : Colors.transparent,
                                  borderRadius: BorderRadius.circular(14),
                                  boxShadow: isSelected
                                      ? [
                                          BoxShadow(
                                            color: _currentAccentColor.withValues(alpha: 0.4),
                                            blurRadius: 10,
                                          )
                                        ]
                                      : [],
                                ),
                                child: Icon(
                                  navIcons[index],
                                  color: isSelected ? Colors.black : Colors.grey[400],
                                  size: 22,
                                ),
                              ),
                            ),
                          );
                        }),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
