import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../components/animated_mesh_background.dart';
import '../components/glass_container.dart';

// ── Subject accent colours ────────────────────────────────────────────────
const Color _physicsColor = Color(0xFF38BDF8);
const Color _chemistryColor = Color(0xFF34D399);
const Color _mathsColor = Color(0xFFA78BFA);

Color _subjectColor(String subject) {
  switch (subject) {
    case 'Chemistry':
      return _chemistryColor;
    case 'Maths':
      return _mathsColor;
    case 'Physics':
    default:
      return _physicsColor;
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final _supabase = Supabase.instance.client;

  List<Map<String, dynamic>> _allSessions = [];
  List<Map<String, dynamic>> _filteredSessions = [];

  bool _isLoading = true;
  String _selectedFilter = 'All'; // All | Physics | Chemistry | Maths
  static const List<String> _filterOptions = [
    'All',
    'Physics',
    'Chemistry',
    'Maths',
  ];

  @override
  void initState() {
    super.initState();
    _fetchHistory();
  }

  // ── Data fetching ─────────────────────────────────────────────────────────

  Future<void> _fetchHistory() async {
    if (!mounted) return;
    setState(() => _isLoading = true);

    try {
      final response = await _supabase
          .from('focus_sessions')
          .select(
            'id, subject_tag, activity_type, chapter_name, lecture_number, '
            'started_at, ended_at, status, avg_focus_score, peak_focus_score',
          )
          .order('started_at', ascending: false)
          .limit(50);

      if (mounted) {
        setState(() {
          _allSessions = List<Map<String, dynamic>>.from(response);
          _applyFilter(_selectedFilter);
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error fetching history: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _applyFilter(String filter) {
    _selectedFilter = filter;
    if (filter == 'All') {
      _filteredSessions = List.from(_allSessions);
    } else {
      _filteredSessions = _allSessions
          .where((s) => (s['subject_tag'] as String? ?? '') == filter)
          .toList();
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  String _formatDuration(String? started, String? ended) {
    if (started == null || ended == null) return '—';
    try {
      final start = DateTime.parse(started);
      final end = DateTime.parse(ended);
      final diff = end.difference(start);
      if (diff.inHours > 0) {
        return '${diff.inHours}h ${diff.inMinutes.remainder(60)}m';
      }
      return '${diff.inMinutes} min';
    } catch (_) {
      return '—';
    }
  }

  String _formatDate(String? timestamp) {
    if (timestamp == null) return '—';
    try {
      final date = DateTime.parse(timestamp).toLocal();
      final months = [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
      ];
      return '${date.day} ${months[date.month - 1]}  '
          '${date.hour.toString().padLeft(2, '0')}:'
          '${date.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return '—';
    }
  }

  Color _scoreColor(double? score) {
    if (score == null) return Colors.grey;
    if (score >= 80) return const Color(0xFF34D399);
    if (score >= 60) return const Color(0xFFFBBF24);
    return Colors.redAccent;
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? Colors.white : Colors.black87;
    final secondaryColor = isDark ? Colors.white54 : Colors.black54;

    return AnimatedMeshBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
          leading: IconButton(
            icon: Icon(Icons.arrow_back_ios_new_rounded,
                color: primaryColor, size: 18),
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: Text(
            'Study History',
            style: GoogleFonts.playfairDisplay(
              color: primaryColor,
              fontSize: 22,
              fontWeight: FontWeight.w600,
            ),
          ),
          actions: [
            IconButton(
              icon: Icon(Icons.refresh_rounded, color: secondaryColor, size: 20),
              onPressed: _fetchHistory,
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: RefreshIndicator(
          onRefresh: _fetchHistory,
          color: const Color(0xFF38BDF8),
          backgroundColor:
              isDark ? const Color(0xFF1E293B) : Colors.white,
          child: CustomScrollView(
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            slivers: [
              // ── Filter chips ────────────────────────────────────────────
              SliverToBoxAdapter(
                child: Padding(
                  padding:
                      const EdgeInsets.fromLTRB(20, 8, 20, 4),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    physics: const BouncingScrollPhysics(),
                    child: Row(
                      children: _filterOptions.map((filter) {
                        final isSelected = _selectedFilter == filter;
                        final accent = filter == 'All'
                            ? const Color(0xFF94A3B8)
                            : _subjectColor(filter);

                        return Padding(
                          padding: const EdgeInsets.only(right: 10),
                          child: GestureDetector(
                            onTap: () {
                              setState(() => _applyFilter(filter));
                            },
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 250),
                              curve: Curves.easeOutCubic,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 18, vertical: 9),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? accent.withValues(alpha: 0.15)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: isSelected
                                      ? accent.withValues(alpha: 0.6)
                                      : (isDark
                                          ? Colors.white12
                                          : Colors.black12),
                                  width: 1.5,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (filter != 'All') ...[
                                    Container(
                                      width: 7,
                                      height: 7,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: accent,
                                      ),
                                    ),
                                    const SizedBox(width: 7),
                                  ],
                                  Text(
                                    filter,
                                    style: GoogleFonts.inter(
                                      fontSize: 13,
                                      fontWeight: isSelected
                                          ? FontWeight.w700
                                          : FontWeight.w500,
                                      color: isSelected
                                          ? accent
                                          : secondaryColor,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ),
              ),

              // ── Session count label ──────────────────────────────────────
              SliverToBoxAdapter(
                child: Padding(
                  padding:
                      const EdgeInsets.fromLTRB(20, 12, 20, 8),
                  child: Text(
                    _isLoading
                        ? 'Loading...'
                        : '${_filteredSessions.length} session${_filteredSessions.length != 1 ? "s" : ""}',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      color: secondaryColor,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ),

              // ── Body ─────────────────────────────────────────────────────
              if (_isLoading)
                const SliverFillRemaining(
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_filteredSessions.isEmpty)
                SliverFillRemaining(
                  child: _buildEmptyState(isDark),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 40),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        return _buildSessionCard(
                          _filteredSessions[index],
                          isDark,
                          primaryColor,
                          secondaryColor,
                        );
                      },
                      childCount: _filteredSessions.length,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Session card ──────────────────────────────────────────────────────────

  Widget _buildSessionCard(
    Map<String, dynamic> session,
    bool isDark,
    Color primaryColor,
    Color secondaryColor,
  ) {
    final subject = session['subject_tag'] as String? ?? 'Unknown';
    final activity = session['activity_type'] as String? ?? 'General';
    final chapter = session['chapter_name'] as String? ?? '';
    final lectureNum = session['lecture_number'] as int?;
    final status = session['status'] as String? ?? '';
    final avgScore =
        (session['avg_focus_score'] as num?)?.toDouble();
    final peakScore =
        (session['peak_focus_score'] as num?)?.toDouble();
    final subjectColor = _subjectColor(subject);
    final isActive = status == 'active';

    final duration = isActive
        ? 'Active Now'
        : _formatDuration(
            session['started_at'] as String?,
            session['ended_at'] as String?,
          );

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: GlassContainer(
        blur: 15,
        opacity: isDark ? 0.06 : 0.35,
        borderRadius: const BorderRadius.all(Radius.circular(20)),
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Row 1: activity badge + date ──────────────────────────────
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Activity badge
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 5),
                  decoration: BoxDecoration(
                    color: subjectColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    activity,
                    style: GoogleFonts.inter(
                      color: subjectColor,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                ),
                // Date
                Text(
                  _formatDate(session['started_at'] as String?),
                  style: GoogleFonts.inter(
                    color: secondaryColor,
                    fontSize: 12,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 14),

            // ── Row 2: subject dot + name + chapter ───────────────────────
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 10,
                  height: 10,
                  margin: const EdgeInsets.only(top: 5, right: 12),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: subjectColor,
                    boxShadow: [
                      BoxShadow(
                        color: subjectColor.withValues(alpha: 0.5),
                        blurRadius: 6,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        subject,
                        style: TextStyle(
                          color: primaryColor,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (chapter.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          chapter,
                          style: TextStyle(
                            color: secondaryColor,
                            fontSize: 14,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      if (activity == 'Lecture' &&
                          lectureNum != null &&
                          lectureNum > 0) ...[
                        const SizedBox(height: 3),
                        Text(
                          'Lecture #$lectureNum',
                          style: TextStyle(
                            color: secondaryColor.withValues(alpha: 0.7),
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),

            const SizedBox(height: 16),

            // ── Divider ───────────────────────────────────────────────────
            Divider(
              color: isDark ? Colors.white10 : Colors.black12,
              height: 1,
            ),

            const SizedBox(height: 14),

            // ── Row 3: duration + score ───────────────────────────────────
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Duration
                Row(
                  children: [
                    Icon(
                      Icons.timer_outlined,
                      color: isActive
                          ? Colors.redAccent
                          : secondaryColor,
                      size: 15,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      duration,
                      style: TextStyle(
                        color: isActive
                            ? Colors.redAccent
                            : secondaryColor,
                        fontSize: 13,
                        fontWeight: isActive
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                  ],
                ),

                // Avg focus score chip
                if (avgScore != null)
                  Row(
                    children: [
                      // Avg
                      _buildScoreChip(
                        label: 'Avg',
                        value: avgScore,
                        isDark: isDark,
                      ),
                      if (peakScore != null) ...[
                        const SizedBox(width: 8),
                        _buildScoreChip(
                          label: 'Peak',
                          value: peakScore,
                          isDark: isDark,
                        ),
                      ],
                    ],
                  )
                else if (isActive)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.redAccent.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: Colors.redAccent.withValues(alpha: 0.4)),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.fiber_manual_record,
                            color: Colors.redAccent, size: 8),
                        SizedBox(width: 6),
                        Text(
                          'LIVE',
                          style: TextStyle(
                            color: Colors.redAccent,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScoreChip({
    required String label,
    required double value,
    required bool isDark,
  }) {
    final color = _scoreColor(value);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label ',
            style: TextStyle(
              color: color.withValues(alpha: 0.7),
              fontSize: 10,
              fontWeight: FontWeight.w500,
            ),
          ),
          Text(
            '${value.toStringAsFixed(0)}%',
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  // ── Empty state ───────────────────────────────────────────────────────────

  Widget _buildEmptyState(bool isDark) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('📚', style: TextStyle(fontSize: 56)),
          const SizedBox(height: 16),
          Text(
            'No sessions yet.',
            style: GoogleFonts.playfairDisplay(
              fontSize: 22,
              color: isDark ? Colors.white70 : Colors.black54,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Start your first focus session!',
            style: GoogleFonts.inter(
              fontSize: 14,
              color: isDark ? Colors.white38 : Colors.black38,
            ),
          ),
        ],
      ),
    );
  }
}
