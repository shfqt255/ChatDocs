import 'package:chatdocsflutter/Api_Handling/api_service.dart';
import 'package:flutter/foundation.dart';

enum ChatHistoryPhase { loading, loaded, error }

enum AskPhase { idle, asking }

// one instance of this belongs to one open chat screen, scoped to a single
// document. loads existing history for that document on creation, then
// appends new messages locally as they're sent/received, so the thread
// reads top to bottom without re-fetching after every message.
class ChatProvider extends ChangeNotifier {
  final ApiService api;
  final String docId;
  final String filename;

  // set once dispose() runs. every callback that resumes after an await
  // checks this before touching state or calling notifyListeners() -
  // without it, closing the chat screen while a request is still in
  // flight (e.g. history still loading) throws "a ChangeNotifier was
  // used after being disposed" once that request finally resolves.
  bool _disposed = false;

  ChatProvider(this.api, {required this.docId, required this.filename}) {
    _loadHistory();
  }

  ChatHistoryPhase historyPhase = ChatHistoryPhase.loading;
  String? historyError;

  final List<ChatMessage> messages = [];

  AskPhase askPhase = AskPhase.idle;
  String? askError;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _loadHistory() async {
    historyPhase = ChatHistoryPhase.loading;
    _safeNotify();

    try {
      final history = await api.getChatHistory(docId);
      if (_disposed) return;
      messages
        ..clear()
        ..addAll(history);
      historyPhase = ChatHistoryPhase.loaded;
      _safeNotify();
    } catch (e) {
      if (_disposed) return;
      historyPhase = ChatHistoryPhase.error;
      historyError = e.toString().replaceFirst('Exception: ', '');
      _safeNotify();
    }
  }

  Future<void> askQuestion(String question) async {
    askPhase = AskPhase.asking;
    askError = null;
    // show the user's own message immediately - it was genuinely sent,
    // no reason to wait for the round trip to display it.
    messages.add(ChatMessage(role: 'user', content: question));
    _safeNotify();

    try {
      final result = await api.askQuestion(docId: docId, question: question);
      if (_disposed) return;
      messages.add(
        ChatMessage(
          role: 'assistant',
          content: result.answer,
          provider: result.provider,
          sources: result.sources,
        ),
      );
      askPhase = AskPhase.idle;
      _safeNotify();
    } catch (e) {
      // the failed question stays visible in the thread; the error is
      // whatever the server actually returned, shown alongside it.
      if (_disposed) return;
      askPhase = AskPhase.idle;
      askError = e.toString().replaceFirst('Exception: ', '');
      _safeNotify();
    }
  }
}
