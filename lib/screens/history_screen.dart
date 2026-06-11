import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final _supabase = Supabase.instance.client;
  List<dynamic> _sessions = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _fetchHistory();
  }

  Future<void> _fetchHistory() async {
    try {
      final response = await _supabase
          .from('focus_sessions')
          .select('*')
          .order('started_at', ascending: false)
          .limit(50);
      
      setState(() {
        _sessions = response;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint("Error fetching history: $e");
      setState(() {
        _isLoading = false;
      });
    }
  }

  String _formatDuration(String? started, String? ended) {
    if (started == null || ended == null) return "Unknown Duration";
    final start = DateTime.parse(started);
    final end = DateTime.parse(ended);
    final diff = end.difference(start);
    return "${diff.inMinutes} mins";
  }

  String _formatDate(String? timestamp) {
    if (timestamp == null) return "Unknown Date";
    final date = DateTime.parse(timestamp).toLocal();
    return "${date.day}/${date.month}/${date.year} ${date.hour}:${date.minute.toString().padLeft(2, '0')}";
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        title: const Text('Study History Timeline', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: const Color(0xFF1E293B),
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _fetchHistory,
          )
        ],
      ),
      body: _isLoading 
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF10B981)))
          : _sessions.isEmpty
              ? const Center(child: Text("No sessions found.", style: TextStyle(color: Colors.white70)))
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _sessions.length,
                  itemBuilder: (context, index) {
                    final session = _sessions[index];
                    final subject = session['subject_tag'] ?? 'Unknown';
                    final activity = session['activity_type'] ?? 'General';
                    final chapter = session['chapter_name'] ?? 'No Chapter Assigned';
                    final status = session['status'];
                    
                    return Card(
                      color: const Color(0xFF1E293B),
                      margin: const EdgeInsets.only(bottom: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF10B981).withValues(alpha: 0.2),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    activity,
                                    style: const TextStyle(color: Color(0xFF10B981), fontWeight: FontWeight.bold),
                                  ),
                                ),
                                Text(
                                  _formatDate(session['started_at']),
                                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                                )
                              ],
                            ),
                            const SizedBox(height: 16),
                            Text(
                              subject,
                              style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              chapter,
                              style: const TextStyle(color: Colors.white70, fontSize: 14),
                            ),
                            if (activity == 'Lecture' && session['lecture_number'] != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 4.0),
                                child: Text(
                                  "Lecture #${session['lecture_number']}",
                                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                                ),
                              ),
                            const SizedBox(height: 16),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    const Icon(Icons.timer_outlined, color: Colors.white54, size: 16),
                                    const SizedBox(width: 4),
                                    Text(
                                      status == 'active' ? 'Active Now' : _formatDuration(session['started_at'], session['ended_at']),
                                      style: TextStyle(color: status == 'active' ? Colors.redAccent : Colors.white54),
                                    ),
                                  ],
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: Colors.black26,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    "Target: ${session['target_exam'] ?? 'N/A'}",
                                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                                  ),
                                )
                              ],
                            )
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
