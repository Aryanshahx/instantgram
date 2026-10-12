class ChatThread {
  ChatThread({
    required this.id,
    required this.name,
    required this.avatarUrl,
    required this.messages,
  });

  final String id;
  final String name;
  final String avatarUrl;
  final List<ChatMessage> messages;

  ChatMessage? get last => messages.isEmpty ? null : messages.last;
}

class ChatMessage {
  ChatMessage({required this.text, required this.fromMe, DateTime? sentAt})
    : sentAt = sentAt ?? DateTime.now();

  final String text;
  final bool fromMe;
  final DateTime sentAt;
}
