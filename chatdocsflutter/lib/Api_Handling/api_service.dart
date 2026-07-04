import 'dart:convert';
import 'dart:io';
import 'package:chatdocsflutter/user_authentication/user_auth.dart';
import 'package:http/http.dart' as http;

// same shape returned by /chat in app.py
class ChatResult {
  final String answer;
  final String provider;
  final List<dynamic> sources;

  ChatResult({
    required this.answer,
    required this.provider,
    required this.sources,
  });

  factory ChatResult.fromJson(Map<String, dynamic> json) {
    return ChatResult(
      answer: json['answer'] as String,
      provider: json['provider'] as String,
      sources: json['sources'] as List<dynamic>? ?? [],
    );
  }
}

// one entry from GET /documents - one per uploaded file, not per chunk
class DocumentSummary {
  final String docId;
  final String filename;
  final int chunkCount;

  DocumentSummary({
    required this.docId,
    required this.filename,
    required this.chunkCount,
  });

  factory DocumentSummary.fromJson(Map<String, dynamic> json) {
    return DocumentSummary(
      docId: json['doc_id'] as String,
      filename: json['filename'] as String? ?? 'unknown',
      chunkCount: json['chunk_count'] as int? ?? 0,
    );
  }
}

// one message from GET /chat/{doc_id}/history
class ChatMessage {
  final String role; // "user" or "assistant"
  final String content;
  final String? provider;
  final List<dynamic>? sources;

  ChatMessage({
    required this.role,
    required this.content,
    this.provider,
    this.sources,
  });

  bool get isUser => role == 'user';

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      role: json['role'] as String,
      content: json['content'] as String,
      provider: json['provider'] as String?,
      sources: json['sources'] as List<dynamic>?,
    );
  }
}

// one status snapshot from GET /upload/{doc_id}/status
class UploadStatus {
  final String state; // "processing" | "done" | "error"
  final int? chunks;
  final String? error;

  UploadStatus({required this.state, this.chunks, this.error});

  bool get isDone => state == 'done';
  bool get isError => state == 'error';

  factory UploadStatus.fromJson(Map<String, dynamic> json) {
    return UploadStatus(
      state: json['state'] as String,
      chunks: json['chunks'] as int?,
      error: json['error'] as String?,
    );
  }
}

class ApiService {
  static const String baseUrl ="YOUR_RAILWAY_URL";

  final UserAuth auth;

  ApiService(this.auth);

  Map<String, String> _authHeader() {
    final token = auth.accessToken;
    if (token == null) {
      throw Exception('not logged in');
    }
    return {'Authorization': 'Bearer $token'};
  }

  // POST /upload - matches app.py: file, doc_id (user_id comes from the
  // token). the server now returns immediately with just a "processing"
  // acknowledgement - it does NOT return chunk count here anymore, since
  // ingestion runs in the background. call getUploadStatus to find out
  // when it's actually done.
  Future<void> uploadDocument({
    required File file,
    required String docId,
  }) async {
    final uri = Uri.parse('$baseUrl/upload');
    final request = http.MultipartRequest('POST', uri);
    request.headers.addAll(_authHeader());
    request.fields['doc_id'] = docId;
    request.files.add(await http.MultipartFile.fromPath('file', file.path));

    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode != 200) {
      throw Exception(_extractError(response));
    }
    // response body is just {"status": "processing", "doc_id": "..."} -
    // nothing else to read here, the real result comes from polling.
  }

  // GET /upload/{doc_id}/status - poll this after uploadDocument returns
  Future<UploadStatus> getUploadStatus(String docId) async {
    final uri = Uri.parse('$baseUrl/upload/$docId/status');
    final response = await http.get(uri, headers: _authHeader());

    if (response.statusCode != 200) {
      throw Exception(_extractError(response));
    }

    return UploadStatus.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  // POST /chat - matches app.py: { "doc_id": "...", "question": "..." }
  Future<ChatResult> askQuestion({
    required String docId,
    required String question,
  }) async {
    final uri = Uri.parse('$baseUrl/chat');
    final response = await http.post(
      uri,
      headers: {..._authHeader(), 'Content-Type': 'application/json'},
      body: jsonEncode({'doc_id': docId, 'question': question}),
    );

    if (response.statusCode != 200) {
      throw Exception(_extractError(response));
    }

    return ChatResult.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  // GET /chat/{doc_id}/history
  Future<List<ChatMessage>> getChatHistory(String docId) async {
    final uri = Uri.parse('$baseUrl/chat/$docId/history');
    final response = await http.get(uri, headers: _authHeader());

    if (response.statusCode != 200) {
      throw Exception(_extractError(response));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final list = body['messages'] as List<dynamic>? ?? [];
    return list
        .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // GET /documents - one summary row per uploaded file for this user
  Future<List<DocumentSummary>> listDocuments() async {
    final uri = Uri.parse('$baseUrl/documents');
    final response = await http.get(uri, headers: _authHeader());

    if (response.statusCode != 200) {
      throw Exception(_extractError(response));
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final list = body['documents'] as List<dynamic>? ?? [];
    return list
        .map((e) => DocumentSummary.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // DELETE /document/{doc_id}
  Future<void> deleteDocument(String docId) async {
    final uri = Uri.parse('$baseUrl/document/$docId');
    final response = await http.delete(uri, headers: _authHeader());

    if (response.statusCode != 200) {
      throw Exception(_extractError(response));
    }
  }

  // only ever surfaces what the server actually said (HTTPException.detail)
  // or a bare status code - no invented client-side wording.
  String _extractError(http.Response response) {
    try {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      return body['detail']?.toString() ??
          'request failed (${response.statusCode})';
    } catch (_) {
      return 'request failed (${response.statusCode})';
    }
  }
}
