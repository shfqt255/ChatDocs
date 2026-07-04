import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// holds the current auth state and exposes login/signup/logout.
// api_service.dart reads the access token from here on every request.
class UserAuth extends ChangeNotifier {
  final SupabaseClient _client = Supabase.instance.client;

  User? _user;
  bool _isLoading = false;
  String? _errorMessage;

  UserAuth() {
    // keep state in sync if the session changes elsewhere (token refresh, etc.)
    _user = _client.auth.currentUser;
    _client.auth.onAuthStateChange.listen((data) {
      _user = data.session?.user;
      notifyListeners();
    });
  }

  User? get user => _user;
  bool get isLoggedIn => _user != null;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  // this is what api_service.dart sends as "Authorization: Bearer <token>"
  String? get accessToken => _client.auth.currentSession?.accessToken;

  Future<bool> signUp(String email, String password) async {
    return _run(() async {
      final res = await _client.auth.signUp(email: email, password: password);
      _user = res.user;
    });
  }

  Future<bool> signIn(String email, String password) async {
    return _run(() async {
      final res = await _client.auth.signInWithPassword(
        email: email,
        password: password,
      );
      _user = res.user;
    });
  }

  Future<void> signOut() async {
    await _client.auth.signOut();
    _user = null;
    notifyListeners();
  }

  Future<bool> _run(Future<void> Function() action) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await action();
      _isLoading = false;
      notifyListeners();
      return true;
    } on AuthException catch (e) {
      // this is supabase's own message, not something we made up
      _errorMessage = e.message;
      _isLoading = false;
      notifyListeners();
      return false;
    } catch (e) {
      _errorMessage = e.toString();
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }
}
