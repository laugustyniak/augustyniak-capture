import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/auth_gateway.dart';
import '../domain/auth_identity.dart';

class AuthController extends ChangeNotifier {
  AuthController(this._gateway);

  final AuthGateway _gateway;
  StreamSubscription<AuthIdentity?>? _subscription;
  AuthIdentity? _identity;
  bool _isBusy = false;
  bool _disposed = false;
  String? _error;

  AuthIdentity? get identity => _identity;
  bool get isSignedIn => _identity != null;
  bool get isBusy => _isBusy;
  String? get error => _error;

  void initialize() {
    if (_subscription != null) return;
    _identity = _gateway.currentIdentity;
    _subscription = _gateway.identityChanges.listen((AuthIdentity? identity) {
      _identity = identity;
      _error = null;
      if (!_disposed) notifyListeners();
    });
  }

  Future<void> signInWithGoogle() async {
    if (_isBusy) return;
    _setBusy(true);
    _error = null;
    try {
      final bool opened = await _gateway.signInWithGoogle();
      if (!opened) _error = 'Could not open the Google sign-in page.';
    } catch (_) {
      _error = 'Google sign-in could not be started.';
    } finally {
      _setBusy(false);
    }
  }

  Future<void> signOut() async {
    if (_isBusy) return;
    _setBusy(true);
    _error = null;
    try {
      await _gateway.signOut();
    } catch (_) {
      _error = 'Sign out failed. Try again.';
    } finally {
      _setBusy(false);
    }
  }

  void _setBusy(bool value) {
    _isBusy = value;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
