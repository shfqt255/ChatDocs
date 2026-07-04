import 'dart:io';
import 'package:chatdocsflutter/Api_Handling/api_service.dart';
import 'package:chatdocsflutter/screen/chat_screen.dart';
import 'package:chatdocsflutter/provider/provider.dart';
import 'package:chatdocsflutter/theme/palette.dart';
import 'package:chatdocsflutter/user_authentication/user_auth.dart';
import 'package:chatdocsflutter/widgets/common_widgets.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class DocumentsScreen extends StatelessWidget {
  const DocumentsScreen({super.key});

  Future<void> _pickAndUpload(BuildContext context) async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'docx', 'txt'],
    );
    if (result == null || result.files.single.path == null) return;

    final file = File(result.files.single.path!);
    if (!context.mounted) return;
    await context.read<DocProvider>().uploadDocument(file);
  }

  Future<void> _confirmDelete(BuildContext context, DocumentSummary doc) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Palette.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text(
          'remove this document?',
          style: TextStyle(color: Palette.ink, fontSize: 16),
        ),
        content: Text(
          '"${doc.filename}" and its conversation history will be removed. this can\'t be undone.',
          style: const TextStyle(color: Palette.inkMuted, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text(
              'cancel',
              style: TextStyle(color: Palette.inkMuted),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              'remove',
              style: TextStyle(
                color: Palette.error,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true && context.mounted) {
      await context.read<DocProvider>().deleteDocument(doc.docId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final docProvider = context.watch<DocProvider>();
    final auth = context.watch<UserAuth>();
    final api = context.read<ApiService>();

    return Scaffold(
      backgroundColor: Palette.bg,
      appBar: AppBar(
        backgroundColor: Palette.bg,
        elevation: 0,
        title: const Text(
          'ChatDocs',
          style: TextStyle(color: Palette.ink, fontWeight: FontWeight.w700),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout, color: Palette.inkMuted),
            tooltip: 'log out',
            onPressed: () => auth.signOut(),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: docProvider.uploadPhase == UploadPhase.uploading
            ? null
            : () => _pickAndUpload(context),
        backgroundColor: Palette.ink,
        icon: docProvider.uploadPhase == UploadPhase.uploading
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Icon(Icons.add, color: Colors.white),
        label: const Text('upload', style: TextStyle(color: Colors.white)),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (docProvider.uploadError != null) ...[
                ErrorBanner(message: docProvider.uploadError!),
                const SizedBox(height: 12),
              ],
              if (docProvider.docsListError != null) ...[
                ErrorBanner(message: docProvider.docsListError!),
                const SizedBox(height: 12),
              ],
              Expanded(child: _buildList(context, docProvider, api)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildList(
    BuildContext context,
    DocProvider docProvider,
    ApiService api,
  ) {
    if (docProvider.isLoadingDocuments) {
      return const Center(child: InlineSpinner());
    }

    if (docProvider.documents.isEmpty) {
      return Center(
        child: Text(
          'nothing uploaded yet\ntap upload to add a document',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Palette.inkMuted.withOpacity(0.8),
            fontSize: 14,
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => docProvider.refreshDocuments(),
      child: ListView.separated(
        itemCount: docProvider.documents.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, i) {
          final doc = docProvider.documents[i];
          final deleting = docProvider.isDeleting(doc.docId);

          return Material(
            color: Palette.surface,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ChatScreen(
                      api: api,
                      docId: doc.docId,
                      filename: doc.filename,
                    ),
                  ),
                );
              },
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Palette.border),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.description_outlined,
                      size: 20,
                      color: Palette.slate,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            doc.filename,
                            style: const TextStyle(
                              color: Palette.ink,
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            '${doc.chunkCount} chunk${doc.chunkCount == 1 ? '' : 's'}',
                            style: const TextStyle(
                              color: Palette.inkMuted,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    deleting
                        ? const InlineSpinner(size: 16)
                        : IconButton(
                            icon: const Icon(
                              Icons.delete_outline,
                              size: 20,
                              color: Palette.inkMuted,
                            ),
                            tooltip: 'remove document',
                            onPressed: () => _confirmDelete(context, doc),
                          ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
