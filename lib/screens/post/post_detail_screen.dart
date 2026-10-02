import 'package:flutter/material.dart';

import '../../models/post.dart';
import '../../widgets/post_card.dart';

class PostDetailScreen extends StatelessWidget {
  const PostDetailScreen({super.key, required this.post});
  final Post post;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Post', style: TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: SingleChildScrollView(
        child: PostCard(
          post: post,
          onDeleted: () => Navigator.of(context).pop(),
        ),
      ),
    );
  }
}
