import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/db/database.dart';

/// Whether the app is currently showing the lock screen.
///
/// Locking is a UI gate over an already-open database, not an encryption
/// boundary — the data at rest is protected by the master passphrase regardless.
/// What this prevents is the realistic threat for a shared counter phone: someone
/// picking it up while the owner is away.
class LockController extends Notifier<bool> {
  Timer? _idleTimer;

  /// Long enough not to irritate a receptionist mid-task, short enough that an
  /// unattended phone does not stay open. The right value differs between a
  /// busy counter and a locked office, so it is a setting.
  static const defaultIdleMinutes = 3;
  int _idleMinutes = defaultIdleMinutes;

  Duration get idleTimeout => Duration(minutes: _idleMinutes);

  /// Applied from settings once the database is open.
  void setIdleMinutes(int minutes) {
    if (minutes <= 0) return;
    _idleMinutes = minutes;
    if (!state) _restartIdleTimer();
  }

  @override
  bool build() {
    ref.onDispose(() => _idleTimer?.cancel());
    return true;
  }

  void unlock() {
    state = false;
    _restartIdleTimer();
  }

  /// Records who unlocked, so the rest of the app can gate on their role.
  void unlockAs(AppUser user) {
    ref.read(currentUserProvider.notifier).signIn(user);
    unlock();
  }

  void lock() {
    _idleTimer?.cancel();
    ref.read(currentUserProvider.notifier).signOut();
    state = true;
  }

  /// Called on user interaction to push the idle deadline back.
  void noteActivity() {
    if (!state) _restartIdleTimer();
  }

  /// Called when the app leaves the foreground.
  void noteBackgrounded() => lock();

  void _restartIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(idleTimeout, lock);
  }
}

final lockControllerProvider =
    NotifierProvider<LockController, bool>(LockController.new);

/// Whoever is currently signed in, or null while locked.
///
/// Held separately from the lock flag because the role decides what the app
/// even shows — an owner and a receptionist see different home screens.
class CurrentUser extends Notifier<AppUser?> {
  @override
  AppUser? build() => null;

  void signIn(AppUser user) => state = user;
  void signOut() => state = null;
}

final currentUserProvider =
    NotifierProvider<CurrentUser, AppUser?>(CurrentUser.new);

/// Locks the app when it is backgrounded, so the task switcher and the next
/// person to pick up the phone never see a coaching centre's finances.
class LockOnBackground extends ConsumerStatefulWidget {
  const LockOnBackground({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<LockOnBackground> createState() => _LockOnBackgroundState();
}

class _LockOnBackgroundState extends ConsumerState<LockOnBackground>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      ref.read(lockControllerProvider.notifier).noteBackgrounded();
    }
  }

  @override
  Widget build(BuildContext context) => Listener(
        onPointerDown: (_) =>
            ref.read(lockControllerProvider.notifier).noteActivity(),
        child: widget.child,
      );
}
