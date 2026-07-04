import 'package:chatdocsflutter/Api_Handling/api_service.dart';
import 'package:chatdocsflutter/provider/chat_provider.dart';
import 'package:chatdocsflutter/theme/palette.dart';
import 'package:chatdocsflutter/widgets/common_widgets.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class ChatScreen extends StatelessWidget {
  final ApiService api;
  final String docId;
  final String filename;

  const ChatScreen({
    super.key,
    required this.api,
    required this.docId,
    required this.filename,
  });

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => ChatProvider(api, docId: docId, filename: filename),
      child: _ChatScreenBody(filename: filename),
    );
  }
}

class _ChatScreenBody extends StatefulWidget {
  final String filename;
  const _ChatScreenBody({required this.filename});

  @override
  State<_ChatScreenBody> createState() => _ChatScreenBodyState();
}

class _ChatScreenBodyState extends State<_ChatScreenBody> {
  final _questionController = TextEditingController();
  final _scrollController = ScrollController();

  void _submit(BuildContext context) {
    final q = _questionController.text.trim();
    if (q.isEmpty) return;
    _questionController.clear();
    context.read<ChatProvider>().askQuestion(q);
    // scroll to the newest message shortly after it's added
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatProvider>();

    return Scaffold(
      backgroundColor: Palette.bg,
      appBar: AppBar(
        backgroundColor: Palette.bg,
        elevation: 0,
        titleSpacing: 0,
        title: Text(
          widget.filename,
          style: const TextStyle(
            color: Palette.ink,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: _buildBody(chat)),
            _buildInputBar(context, chat),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(ChatProvider chat) {
    if (chat.historyPhase == ChatHistoryPhase.loading) {
      return const Center(child: InlineSpinner());
    }

    if (chat.historyPhase == ChatHistoryPhase.error) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ErrorBanner(
            message: chat.historyError ?? 'could not load conversation',
          ),
        ),
      );
    }

    if (chat.messages.isEmpty) {
      return Center(
        child: Text(
          'ask anything about this document',
          style: TextStyle(
            color: Palette.inkMuted.withOpacity(0.8),
            fontSize: 14,
          ),
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(16),
      itemCount: chat.messages.length + (chat.askError != null ? 1 : 0),
      itemBuilder: (context, i) {
        if (i == chat.messages.length) {
          return Padding(
            padding: const EdgeInsets.only(top: 8),
            child: ErrorBanner(message: chat.askError!),
          );
        }
        return _MessageBubble(message: chat.messages[i]);
      },
    );
  }

  Widget _buildInputBar(BuildContext context, ChatProvider chat) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: const BoxDecoration(
        color: Palette.surface,
        border: Border(top: BorderSide(color: Palette.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _questionController,
              style: const TextStyle(color: Palette.ink),
              onSubmitted: (_) => _submit(context),
              decoration: InputDecoration(
                hintText: 'ask a question',
                hintStyle: const TextStyle(color: Palette.inkMuted),
                filled: true,
                fillColor: Palette.bg,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            height: 46,
            width: 46,
            child: ElevatedButton(
              onPressed: chat.askPhase == AskPhase.asking
                  ? null
                  : () => _submit(context),
              style: ElevatedButton.styleFrom(
                backgroundColor: Palette.amber,
                disabledBackgroundColor: Palette.amber.withOpacity(0.5),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                padding: EdgeInsets.zero,
                elevation: 0,
              ),
              child: chat.askPhase == AskPhase.asking
                  ? const InlineSpinner()
                  : const Icon(
                      Icons.arrow_upward,
                      color: Colors.white,
                      size: 18,
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final ChatMessage message;
  const _MessageBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final isUser = message.isUser;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.8,
        ),
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isUser ? Palette.ink : Palette.surface,
          borderRadius: BorderRadius.circular(14).copyWith(
            bottomRight: isUser ? const Radius.circular(2) : null,
            bottomLeft: !isUser ? const Radius.circular(2) : null,
          ),
          border: isUser ? null : Border.all(color: Palette.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              message.content,
              style: TextStyle(
                color: isUser ? Colors.white : Palette.ink,
                fontSize: 14,
                height: 1.4,
              ),
            ),
            if (!isUser && message.provider != null) ...[
              const SizedBox(height: 8),
              _ProviderPill(provider: message.provider!),
            ],
          ],
        ),
      ),
    );
  }
}

// the signature element: a small pill naming which llm actually answered -
// the one thing structurally unique to how this app works.
class _ProviderPill extends StatelessWidget {
  final String provider;
  const _ProviderPill({required this.provider});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Palette.amberSoft,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.bolt, size: 11, color: Palette.amber),
          const SizedBox(width: 4),
          Text(
            provider,
            style: const TextStyle(
              color: Palette.amber,
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
