import 'package:flutter/material.dart';
import 'glass_container.dart';

class StudyTimelineCard extends StatelessWidget {
  final Map<String, dynamic> session;
  final bool isActive;

  const StudyTimelineCard({super.key, required this.session, this.isActive = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final subject = session['subject_tag'] ?? 'Unknown';
    final chapter = session['chapter_name'] ?? 'General Session';
    final lecture = session['lecture_number']?.toString() ?? '1';
    final startedAt = DateTime.parse(session['started_at']).toLocal();
    final endedAt = session['ended_at'] != null ? DateTime.parse(session['ended_at']).toLocal() : null;
    
    String durationText = "Active Now";
    if (endedAt != null) {
      final diff = endedAt.difference(startedAt);
      durationText = "${diff.inMinutes} mins";
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0),
      child: GlassContainer(
        padding: const EdgeInsets.all(16.0),
        blur: 15,
        opacity: isDark ? 0.05 : 0.4,
        borderRadius: BorderRadius.circular(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: isDark ? Colors.white.withValues(alpha: 0.1) : Colors.black.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    subject,
                    style: TextStyle(
                      color: isDark ? Colors.white70 : Colors.black87,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    chapter,
                    style: TextStyle(
                      color: isDark ? Colors.white : Colors.black87,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              "Lecture #$lecture",
              style: TextStyle(
                color: isDark ? Colors.white70 : Colors.black54,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      isActive ? Icons.circle : Icons.access_time, 
                      size: 12, 
                      color: isActive ? Colors.green : (isDark ? Colors.white54 : Colors.black54),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      durationText,
                      style: TextStyle(
                        color: isDark ? Colors.white54 : Colors.black54,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
                Text(
                  "Target: JEE",
                  style: TextStyle(
                    color: isDark ? Colors.white30 : Colors.black38,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            )
          ],
        ),
      ),
    );
  }
}
