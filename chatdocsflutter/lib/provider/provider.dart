import 'dart:async';
import 'dart:io';
import 'package:chatdocsflutter/Api_Handling/api_service.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

enum UploadPhase { idle, uploading, error }

// holds document list state: upload, list, delete.
// chat state lives separately in ChatProvider, scoped per document.
class DocProvider extends ChangeNotifier {
  final ApiService api;
  final Uuid _uuid = const Uuid();

  // guards against calling notifyListeners() after this provider has
  // been disposed - a background poll (Timer) can still be "in flight"
  // after the widget tree that created this provider is gone.
  bool _disposed = false;

  DocProvider(this.api) {
    refreshDocuments();
  }

  UploadPhase uploadPhase = UploadPhase.idle;
  String? uploadError;

  bool isLoadingDocuments = true;
  List<DocumentSummary> documents = [];
  String? docsListError;

  final Set<String> _deletingIds = {};
  bool isDeleting(String docId) => _deletingIds.contains(docId);

  Timer? _pollTimer;

  @override
  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    super.dispose();
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> refreshDocuments() async {
    isLoadingDocuments = true;
    docsListError = null;
    _safeNotify();

    try {
      final result = await api.listDocuments();
      if (_disposed) return;
      documents = result;
      isLoadingDocuments = false;
      _safeNotify();
    } catch (e) {
      if (_disposed) return;
      isLoadingDocuments = false;
      docsListError = e.toString().replaceFirst('Exception: ', '');
      _safeNotify();
    }
  }

  Future<void> uploadDocument(File file) async {
    uploadPhase = UploadPhase.uploading;
    uploadError = null;
    _safeNotify();

    // generated client-side so the caller never has to type or remember
    // an id, and so two uploads never accidentally collide.
    final docId = _uuid.v4();

    try {
      // this now returns almost immediately - the server just
      // acknowledges receipt and starts ingesting in the background.
      await api.uploadDocument(file: file, docId: docId);
      if (_disposed) return;
      _pollUploadStatus(docId);
    } catch (e) {
      if (_disposed) return;
      uploadPhase = UploadPhase.error;
      uploadError = e.toString().replaceFirst('Exception: ', '');
      _safeNotify();
    }
  }

  // polls GET /upload/{doc_id}/status every 3 seconds until the server
  // reports done or error. this is what actually finds out whether the
  // large document finished processing, since /upload itself no longer
  // waits around for that.
  void _pollUploadStatus(String docId) {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      if (_disposed) {
        timer.cancel();
        return;
      }

      try {
        final status = await api.getUploadStatus(docId);
        if (_disposed) {
          timer.cancel();
          return;
        }

        if (status.isDone) {
          timer.cancel();
          uploadPhase = UploadPhase.idle;
          _safeNotify();
          await refreshDocuments();
        } else if (status.isError) {
          timer.cancel();
          uploadPhase = UploadPhase.error;
          uploadError = status.error ?? 'upload failed';
          _safeNotify();
        }
        // otherwise still "processing" - keep polling, no ui change needed
      } catch (e) {
        timer.cancel();
        if (_disposed) return;
        uploadPhase = UploadPhase.error;
        uploadError = e.toString().replaceFirst('Exception: ', '');
        _safeNotify();
      }
    });
  }

  Future<bool> deleteDocument(String docId) async {
    _deletingIds.add(docId);
    _safeNotify();

    try {
      await api.deleteDocument(docId);
      if (_disposed) return true;
      _deletingIds.remove(docId);
      _safeNotify();
      await refreshDocuments();
      return true;
    } catch (e) {
      if (_disposed) return false;
      _deletingIds.remove(docId);
      // the caller (documents_screen) reads this to show what the
      // server actually said, right after the failed attempt.
      docsListError = e.toString().replaceFirst('Exception: ', '');
      _safeNotify();
      return false;
    }
  }
}
