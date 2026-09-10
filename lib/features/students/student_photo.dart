import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../app/bootstrap.dart';
import '../../data/db/database.dart';

/// A student's photo, and the way to set one.
///
/// Images are copied into the app's own media directory rather than referenced
/// where the picker found them: a photo left in the camera roll disappears when
/// the owner tidies their gallery, and the backup would not contain it either.
class StudentPhoto extends ConsumerWidget {
  const StudentPhoto({
    required this.student,
    required this.onChanged,
    this.radius = 32,
    super.key,
  });

  final Student student;
  final VoidCallback onChanged;
  final double radius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final path = student.photoPath;
    final exists = path != null && File(path).existsSync();

    return Stack(
      children: [
        CircleAvatar(
          radius: radius,
          backgroundImage: exists ? FileImage(File(path)) : null,
          child: exists
              ? null
              : Text(
                  student.name.characters.isEmpty
                      ? '?'
                      : student.name.characters.first,
                  style: theme.textTheme.headlineSmall,
                ),
        ),
        Positioned(
          right: 0,
          bottom: 0,
          child: Material(
            color: theme.colorScheme.primaryContainer,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => _pick(context, ref),
              child: const Padding(
                padding: EdgeInsets.all(5),
                child: Icon(Icons.photo_camera_outlined, size: 15),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _pick(BuildContext context, WidgetRef ref) async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;

    final picked = await ImagePicker().pickImage(
      source: source,
      // Enough for an ID card at 300dpi without making the backup heavy.
      maxWidth: 800,
      maxHeight: 800,
      imageQuality: 80,
    );
    if (picked == null) return;

    final paths = await ref.read(appPathsProvider.future);
    final dir = Directory('${paths.mediaDir.path}/students');
    await dir.create(recursive: true);

    final target = File('${dir.path}/${student.id}.jpg');
    await target.writeAsBytes(await picked.readAsBytes());

    await ref.read(studentsProvider).update(student, photoPath: target.path);
    onChanged();
  }
}
