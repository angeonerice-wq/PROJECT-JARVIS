import 'dart:async';
import 'dart:math' as math;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(const JarvisApp());
}

class JarvisApp extends StatelessWidget {
  const JarvisApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'JARVIS',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: const Color(0xFF0A0E1A),
        useMaterial3: true,
      ),
      home: const LoginScreen(),
    );
  }
}

enum UserRole { staff, sv }

extension UserRoleX on UserRole {
  String get label => this == UserRole.sv ? 'SV(スーパーバイザー)' : 'スタッフ';
}

UserRole? _parseUserRole(dynamic value) {
  return switch (value) {
    'staff' => UserRole.staff,
    'sv' => UserRole.sv,
    _ => null,
  };
}

/// ログイン中ユーザーのプロフィール(ロール・表示名・所属店舗)。
/// `users/{uid}` はクライアントから書き込めない(管理者のみが作成・変更する)ため、
/// ここでは読み取り専用のリアルタイム購読のみを行う。
class UserSession extends ChangeNotifier {
  UserSession._() {
    _authSub = FirebaseAuth.instance.authStateChanges().listen(_onAuthChanged);
  }
  static final UserSession instance = UserSession._();

  final _firestore = FirebaseFirestore.instance;
  StreamSubscription<User?>? _authSub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _profileSub;

  UserRole? role;
  String? displayName;
  String? storeId;

  void _onAuthChanged(User? user) {
    _profileSub?.cancel();
    if (user == null) {
      role = null;
      displayName = null;
      storeId = null;
      notifyListeners();
      return;
    }
    _profileSub =
        _firestore.collection('users').doc(user.uid).snapshots().listen((doc) {
      final data = doc.data();
      role = _parseUserRole(data?['role']);
      displayName = data?['displayName'] as String?;
      storeId = data?['storeId'] as String?;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _profileSub?.cancel();
    super.dispose();
  }
}

/// サインアウトしてログイン画面に戻る(設定タブ・ドロワー共通)。
Future<void> performLogout(BuildContext context) async {
  await FirebaseAuth.instance.signOut();
  if (!context.mounted) return;
  Navigator.of(context).pushAndRemoveUntil(
    MaterialPageRoute(builder: (_) => const LoginScreen()),
    (route) => false,
  );
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _obscurePassword = true;
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _handleLogin() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      setState(() => _errorMessage = 'メールアドレスとパスワードを入力してください。');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final credential = await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: email,
        password: password,
      );

      final profileDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(credential.user!.uid)
          .get();
      if (_parseUserRole(profileDoc.data()?['role']) == null) {
        await FirebaseAuth.instance.signOut();
        setState(() =>
            _errorMessage = 'アカウントの権限が設定されていません。管理者にお問い合わせください。');
        return;
      }

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const HomePage()),
      );
    } on FirebaseAuthException catch (e) {
      setState(() {
        _errorMessage = switch (e.code) {
          'user-not-found' || 'invalid-credential' || 'wrong-password' =>
            'メールアドレスまたはパスワードが正しくありません。',
          'invalid-email' => 'メールアドレスの形式が正しくありません。',
          'user-disabled' => 'このアカウントは無効化されています。',
          'too-many-requests' => '試行回数が多すぎます。しばらくしてから再度お試しください。',
          _ => 'ログインに失敗しました。(${e.code})',
        };
      });
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 48),
              const Center(child: JarvisLogo(size: 100)),
              const SizedBox(height: 16),
              Center(
                child: Text(
                  'JARVIS',
                  style: GoogleFonts.orbitron(
                    color: Colors.white,
                    fontSize: 30,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 6,
                    shadows: [
                      Shadow(
                        color: const Color(0xFF4FD8FF).withValues(alpha: 0.9),
                        blurRadius: 18,
                      ),
                      Shadow(
                        color: const Color(0xFF4FD8FF).withValues(alpha: 0.6),
                        blurRadius: 30,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Center(
                child: Text(
                  '業務報告支援AI',
                  style: TextStyle(color: Colors.grey[400], fontSize: 13.5),
                ),
              ),
              const SizedBox(height: 44),

              Text('メールアドレス', style: TextStyle(color: Colors.grey[400], fontSize: 12.5)),
              const SizedBox(height: 6),
              TextField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: '例:staff@example.com',
                  hintStyle: TextStyle(color: Colors.grey[600]),
                  prefixIcon: const Icon(Icons.mail_outline, color: Colors.white38, size: 20),
                  filled: true,
                  fillColor: const Color(0xFF141826),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 18),

              Text('パスワード', style: TextStyle(color: Colors.grey[400], fontSize: 12.5)),
              const SizedBox(height: 6),
              TextField(
                controller: _passwordController,
                obscureText: _obscurePassword,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: '••••••••',
                  hintStyle: TextStyle(color: Colors.grey[600]),
                  prefixIcon: const Icon(Icons.lock_outline, color: Colors.white38, size: 20),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePassword ? Icons.visibility_off : Icons.visibility,
                      color: Colors.white38,
                      size: 20,
                    ),
                    onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                  ),
                  filled: true,
                  fillColor: const Color(0xFF141826),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () {},
                  child: Text('パスワードをお忘れですか？',
                      style: TextStyle(color: Colors.grey[500], fontSize: 12.5)),
                ),
              ),
              if (_errorMessage != null) ...[
                const SizedBox(height: 4),
                Text(
                  _errorMessage!,
                  style: const TextStyle(color: Color(0xFFFF6B6B), fontSize: 12.5),
                ),
              ],
              const SizedBox(height: 12),

              SizedBox(
                height: 50,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _handleLogin,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00B8D4),
                    disabledBackgroundColor: const Color(0xFF00B8D4).withValues(alpha: 0.5),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    elevation: 0,
                  ),
                  child: _isLoading
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.4,
                            color: Colors.white,
                          ),
                        )
                      : const Text('ログイン',
                          style: TextStyle(
                              color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(height: 24),
              Center(
                child: Text(
                  'v0.1.0',
                  style: TextStyle(color: Colors.grey[700], fontSize: 11),
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}


class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _selectedIndex = 2; // 初期表示はJARVISタブ(ホームと同じ内容)

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      drawer: const _AppDrawer(),
      body: SafeArea(
        child: IndexedStack(
          index: _selectedIndex,
          children: const [
            _HomeTabBody(),
            HistoryTabBody(),
            _HomeTabBody(),
            SummaryTabBody(),
            SettingsTabBody(),
          ],
        ),
      ),
      bottomNavigationBar: BottomNavigationBar(
        backgroundColor: const Color(0xFF0A0E1A),
        type: BottomNavigationBarType.fixed,
        selectedItemColor: Colors.cyanAccent,
        unselectedItemColor: Colors.grey[600],
        selectedFontSize: 12,
        unselectedFontSize: 12,
        currentIndex: _selectedIndex,
        onTap: (index) => setState(() => _selectedIndex = index),
        items: [
          const BottomNavigationBarItem(icon: Icon(Icons.home), label: 'ホーム'),
          const BottomNavigationBarItem(icon: Icon(Icons.history), label: '履歴'),
          BottomNavigationBarItem(
              icon: SizedBox(
                height: 28,
                child: OverflowBox(
                  maxHeight: 64,
                  maxWidth: 64,
                  alignment: Alignment.bottomCenter,
                  child: const JarvisLogo(size: 54),
                ),
              ),
              label: 'JARVIS'),
          const BottomNavigationBarItem(icon: Icon(Icons.bar_chart), label: 'サマリー'),
          const BottomNavigationBarItem(icon: Icon(Icons.settings), label: '設定'),
        ],
      ),
    );
  }
}

class _AppDrawer extends StatelessWidget {
  const _AppDrawer();

  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor: const Color(0xFF0A0E1A),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  const CircleAvatar(
                    radius: 28,
                    backgroundColor: Color(0xFF3B82F6),
                    child: Icon(Icons.person, color: Colors.white, size: 28),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(UserSession.instance.displayName ?? '-',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.bold)),
                        const SizedBox(height: 2),
                        Text(UserSession.instance.role?.label ?? '-',
                            style: const TextStyle(color: Colors.grey, fontSize: 12.5)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(color: Colors.white10, height: 1),
            ListTile(
              leading: const Icon(Icons.logout, color: Color(0xFFEF4444)),
              title: const Text('ログアウト', style: TextStyle(color: Color(0xFFEF4444))),
              onTap: () {
                Navigator.of(context).pop();
                performLogout(context);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _HomeTabBody extends StatelessWidget {
  const _HomeTabBody();

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Builder(
                builder: (context) => InkWell(
                  onTap: () => Scaffold.of(context).openDrawer(),
                  borderRadius: BorderRadius.circular(20),
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.menu, color: Colors.white70, size: 26),
                  ),
                ),
              ),
              Stack(
                clipBehavior: Clip.none,
                    children: [
                      const Icon(Icons.notifications_none,
                          color: Colors.white70, size: 26),
                      Positioned(
                        right: -2,
                        top: -2,
                        child: Container(
                          padding: const EdgeInsets.all(3),
                          decoration: const BoxDecoration(
                            color: Colors.redAccent,
                            shape: BoxShape.circle,
                          ),
                          child: const Text('3',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold)),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 24),
              const Center(
                child: JarvisLogo(size: 118),
              ),
              const SizedBox(height: 12),
              Center(
                child: Text(
                  'JARVIS',
                  style: GoogleFonts.orbitron(
                    color: Colors.white,
                    fontSize: 34,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 6,
                    shadows: [
                      Shadow(
                        color: const Color(0xFF4FD8FF).withValues(alpha: 0.9),
                        blurRadius: 18,
                      ),
                      Shadow(
                        color: const Color(0xFF4FD8FF).withValues(alpha: 0.6),
                        blurRadius: 30,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Center(
                child: Text(
                  '何をしますか?',
                  style: TextStyle(color: Colors.grey[400], fontSize: 15),
                ),
              ),
              const SizedBox(height: 24),
              GridView.count(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisCount: 2,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                childAspectRatio: 2.15,
                children: [
                  CategoryCard(
                    title: '勤怠',
                    subtitle: '欠勤・遅刻の\n連絡はこちら',
                    icon: Icons.bedtime,
                    color: const Color(0xFF3B82F6),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const AttendanceChatScreen(),
                        ),
                      );
                    },
                  ),
                  CategoryCard(
                    title: '業務報告',
                    subtitle: '巡回・作業の\n報告はこちら',
                    icon: Icons.storefront,
                    color: const Color(0xFF22C55E),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const WorkReportChatScreen(),
                        ),
                      );
                    },
                  ),
                  CategoryCard(
                    title: '業務相談',
                    subtitle: '業務の相談や\n確認はこちら',
                    icon: Icons.chat_bubble,
                    color: const Color(0xFFA855F7),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const ConsultationChatScreen(),
                        ),
                      );
                    },
                  ),
                  CategoryCard(
                    title: 'タスク完了',
                    subtitle: '業務やタスクの\n完了報告はこちら',
                    icon: Icons.check_circle_outline,
                    color: const Color(0xFFF97316),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const TaskCompletionChatScreen(),
                        ),
                      );
                    },
                  ),
                  CategoryCard(
                    title: 'その他',
                    subtitle: '上記以外の\nご連絡はこちら',
                    icon: Icons.help_outline,
                    color: const Color(0xFF64748B),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const OtherChatScreen(),
                        ),
                      );
                    },
                  ),
                  CategoryCard(
                    title: '周知確認',
                    subtitle: '重要なお知らせの\n確認はこちら',
                    icon: Icons.campaign,
                    color: const Color(0xFF06B6D4),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const AnnouncementChatScreen(),
                        ),
                      );
                    },
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF141826),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('本日の状況',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.bold)),
                        Row(
                          children: [
                            Text('最終更新 09:30',
                                style: TextStyle(
                                    color: Colors.grey[500], fontSize: 12)),
                            const SizedBox(width: 4),
                            Icon(Icons.refresh,
                                color: Colors.grey[500], size: 14),
                          ],
                        ),
                      ],
                    ),
                    const Divider(color: Colors.white12, height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: const [
                        StatItem(
                            icon: Icons.people,
                            color: Colors.blueAccent,
                            label: '全体稼働',
                            value: '18/20名'),
                        StatItem(
                            icon: Icons.check_circle,
                            color: Colors.greenAccent,
                            label: '完了タスク',
                            value: '12件'),
                        StatItem(
                            icon: Icons.warning_amber,
                            color: Colors.amber,
                            label: '未確認',
                            value: '2件'),
                        StatItem(
                            icon: Icons.error_outline,
                            color: Colors.redAccent,
                            label: '要対応',
                            value: '1件'),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        );
  }
}


class CategoryCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const CategoryCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: color.withValues(alpha: 0.16),
            border: Border.all(color: color.withValues(alpha: 0.55), width: 1.4),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: color.withValues(alpha: 0.3),
                child: Icon(icon, color: Colors.white, size: 20),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const Icon(Icons.chevron_right, color: Colors.white70, size: 18),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 11, height: 1.3),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class StatItem extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final String value;

  const StatItem({
    super.key,
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(height: 6),
        Text(label, style: TextStyle(color: Colors.grey[400], fontSize: 11)),
        const SizedBox(height: 2),
        Text(value,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.bold)),
      ],
    );
  }
}


class SummaryRow extends StatelessWidget {
  final String label;
  final String value;
  const SummaryRow({super.key, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 60,
            child: Text(label, style: TextStyle(color: Colors.grey[500], fontSize: 13)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.4)),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// 業務報告
// ============================================================


class JarvisLogo extends StatelessWidget {
  final double size;
  const JarvisLogo({super.key, this.size = 85});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _JarvisLogoPainter(),
      ),
    );
  }
}

class _JarvisLogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    final glowPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          const Color(0xFF3FC7F5).withValues(alpha: 0.0),
          const Color(0xFF3FC7F5).withValues(alpha: 0.0),
          const Color(0xFF3FC7F5).withValues(alpha: 0.32),
          const Color(0xFF3FC7F5).withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.52, 0.67, 0.9],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius, glowPaint);

    final outerRingPaint = Paint()
      ..color = const Color(0xFF6FD9FF).withValues(alpha: 0.4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.011;
    canvas.drawCircle(center, radius * 0.74, outerRingPaint);

    const segmentCount = 8;
    const gapDegrees = 6.0;
    final sweepDegrees = (360 / segmentCount) - gapDegrees;
    final ringRadius = radius * 0.62;
    final strokeW = size.width * 0.065;

    // Mark30: なめらかなグラデーションではなく、機械のパネルのような不規則な明暗パターン
    // (8ブロック分の明るさを手動で指定。0=暗い、1=明るい)
    const brightnessPattern = [0.95, 0.55, 0.02, 1.0, 0.25, 0.7, 0.0, 0.4];

    for (int i = 0; i < segmentCount; i++) {
      final startAngle = (i * 360 / segmentCount - 90) * math.pi / 180;
      final sweepAngle = sweepDegrees * math.pi / 180;

      final brightness = brightnessPattern[i % brightnessPattern.length];

      final segColor = Color.lerp(
        const Color(0xFF0E6A8F), // 暗い側:落ち着いた濃い青
        const Color(0xFF7FF6FF), // 明るい側:ビビッドな明るい水色
        brightness,
      )!;

      final segmentPaint = Paint()
        ..color = segColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeW
        ..strokeCap = StrokeCap.butt;

      canvas.drawArc(
        Rect.fromCircle(center: center, radius: ringRadius),
        startAngle,
        sweepAngle,
        false,
        segmentPaint,
      );
    }

    final dotPaint = Paint()
      ..shader = RadialGradient(
        colors: const [
          Color(0xFFFFFFFF),
          Color(0xFF4EF0FF),
          Color(0xFF00D4F0),
          Color(0xFF00D4F0),
        ],
        stops: const [0.0, 0.3, 0.85, 1.0],
        center: Alignment.topLeft,
      ).createShader(Rect.fromCircle(center: center, radius: size.width * 0.13));
    canvas.drawCircle(center, size.width * 0.12, dotPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ============================================================
// 勤怠(欠勤・遅刻) 会話フロー
// ============================================================


enum Sender { jarvis, user }

class ChatMessage {
  final Sender sender;
  final String text;
  const ChatMessage(this.sender, this.text);
}

/// SVに渡す最終アクションの提案。
enum SuggestedAction { approveOnly, needsReschedule, escalate }

extension SuggestedActionX on SuggestedAction {
  String get label {
    switch (this) {
      case SuggestedAction.approveOnly:
        return '承認のみでOK';
      case SuggestedAction.needsReschedule:
        return '再調整が必要';
      case SuggestedAction.escalate:
        return '要エスカレーション';
    }
  }

  Color get color {
    switch (this) {
      case SuggestedAction.approveOnly:
        return const Color(0xFF22C55E);
      case SuggestedAction.needsReschedule:
        return const Color(0xFFF59E0B);
      case SuggestedAction.escalate:
        return const Color(0xFFEF4444);
    }
  }

  IconData get icon {
    switch (this) {
      case SuggestedAction.approveOnly:
        return Icons.check_circle;
      case SuggestedAction.needsReschedule:
        return Icons.sync_problem;
      case SuggestedAction.escalate:
        return Icons.priority_high;
    }
  }
}

class ChoiceButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  const ChoiceButton({
    super.key,
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: color.withValues(alpha: 0.6), width: 1.4),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Text(label,
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
            ],
          ),
        ),
      ),
    );
  }
}


class ChatBubble extends StatelessWidget {
  final ChatMessage message;
  const ChatBubble({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final isJarvis = message.sender == Sender.jarvis;
    return Align(
      alignment: isJarvis ? Alignment.centerLeft : Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
        decoration: BoxDecoration(
          color: isJarvis ? const Color(0xFF141826) : const Color(0xFF3B82F6),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isJarvis ? 4 : 16),
            bottomRight: Radius.circular(isJarvis ? 16 : 4),
          ),
          border: isJarvis ? Border.all(color: Colors.white10) : null,
        ),
        child: Text(
          message.text,
          style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.4),
        ),
      ),
    );
  }
}

// ============================================================
// 「自己申告を鵜呑みにしない」ための曖昧回答チェック
// ============================================================

/// 短すぎる、またはテンプレ的で中身のない回答かどうかを判定する。
/// 「完了しました」「大丈夫です」のような一言だけの返答は、
/// 文字数だけでは弾けないため、代表的なフレーズもあわせてチェックする。
bool isVagueAnswer(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return true;
  if (trimmed.length <= 4) return true;
  const vaguePhrases = [
    '完了しました',
    '完了です',
    '終わりました',
    '大丈夫です',
    '問題ありません',
    '特にありません',
    '特になし',
    'なし',
    'ないです',
    'はい',
    'OK',
    'ok',
    '了解',
    'やりました',
  ];
  return vaguePhrases.contains(trimmed);
}

// ============================================================
// 履歴の共有ストア(アプリ内メモリ上で保持。チャット完了時にここへ追加し、
// 履歴タブ・SVサマリー画面がこれを参照する)
// ============================================================

class HistoryEntry {
  final String? id;
  final String? staffId;
  final String? staffName;
  final String category;
  final String title;
  final DateTime timestamp;
  final SuggestedAction action;
  final List<MapEntry<String, String>> fields;
  final List<ChatMessage> history;

  HistoryEntry({
    this.id,
    this.staffId,
    this.staffName,
    required this.category,
    required this.title,
    DateTime? timestamp,
    required this.action,
    required this.fields,
    required this.history,
  }) : timestamp = timestamp ?? DateTime.now();

  IconData get icon => categoryStyle(category).icon;
  Color get color => categoryStyle(category).color;
  String get time => formatRelativeTime(timestamp);
  String get actionLabel => action.label;
  Color get actionColor => action.color;

  /// Firestoreへの書き込み用。staffId/storeId は HistoryStore 側で付与する。
  Map<String, dynamic> toMap() {
    return {
      'category': category,
      'title': title,
      'timestamp': Timestamp.fromDate(timestamp),
      'action': action.name,
      'fields': fields.map((f) => {'label': f.key, 'value': f.value}).toList(),
      'history':
          history.map((m) => {'sender': m.sender.name, 'text': m.text}).toList(),
    };
  }

  factory HistoryEntry.fromFirestore(String id, Map<String, dynamic> data) {
    final ts = data['timestamp'];
    return HistoryEntry(
      id: id,
      staffId: data['staffId'] as String?,
      staffName: data['staffName'] as String?,
      category: data['category'] as String? ?? '',
      title: data['title'] as String? ?? '',
      timestamp: ts is Timestamp ? ts.toDate() : DateTime.now(),
      action: SuggestedAction.values.firstWhere(
        (a) => a.name == data['action'],
        orElse: () => SuggestedAction.approveOnly,
      ),
      fields: ((data['fields'] as List?) ?? [])
          .map((f) => MapEntry(
                (f as Map)['label'] as String? ?? '',
                f['value'] as String? ?? '',
              ))
          .toList(),
      history: ((data['history'] as List?) ?? [])
          .map((h) => ChatMessage(
                (h as Map)['sender'] == 'user' ? Sender.user : Sender.jarvis,
                h['text'] as String? ?? '',
              ))
          .toList(),
    );
  }
}

String formatNowTime() {
  final now = DateTime.now();
  final hh = now.hour.toString().padLeft(2, '0');
  final mm = now.minute.toString().padLeft(2, '0');
  return '今日 $hh:$mm';
}

/// タイムスタンプから「今日 08:45」「昨日 08:45」「3日前 09:00」のような表示文字列を算出する。
String formatRelativeTime(DateTime timestamp) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final that = DateTime(timestamp.year, timestamp.month, timestamp.day);
  final diffDays = today.difference(that).inDays;
  final hh = timestamp.hour.toString().padLeft(2, '0');
  final mm = timestamp.minute.toString().padLeft(2, '0');
  final dayLabel = diffDays <= 0
      ? '今日'
      : diffDays == 1
          ? '昨日'
          : '$diffDays日前';
  return '$dayLabel $hh:$mm';
}

/// SVの報告一覧で「誰の報告か」を短く表示するための簡易表示用ID。
/// 現状は表示名の解決手段がない(SVは他スタッフのusersドキュメントを読めない)ため、
/// uidの先頭部分を暫定的に表示する。
String shortStaffId(String? staffId) {
  if (staffId == null || staffId.isEmpty) return '不明';
  return staffId.length <= 8 ? staffId : '${staffId.substring(0, 8)}…';
}

/// カテゴリ文字列からアイコンと色を算出する(Firestoreにはicon/colorを保存せず、
/// category から都度導出することでシリアライズ不可な値を持たずに済ませる)。
({IconData icon, Color color}) categoryStyle(String category) {
  if (category.startsWith('勤怠(遅刻)')) {
    return (icon: Icons.access_time, color: const Color(0xFF3B82F6));
  }
  if (category.startsWith('勤怠')) {
    return (icon: Icons.bedtime, color: const Color(0xFF3B82F6));
  }
  switch (category) {
    case '業務報告':
      return (icon: Icons.storefront, color: const Color(0xFF22C55E));
    case '業務相談':
      return (icon: Icons.chat_bubble, color: const Color(0xFFA855F7));
    case 'タスク完了':
      return (icon: Icons.check_circle_outline, color: const Color(0xFFF97316));
    case 'その他':
      return (icon: Icons.help_outline, color: const Color(0xFF64748B));
    case '周知確認':
      return (icon: Icons.campaign, color: const Color(0xFF06B6D4));
    default:
      return (icon: Icons.info_outline, color: const Color(0xFF64748B));
  }
}

class HistoryStore extends ChangeNotifier {
  HistoryStore._() {
    _authSub = FirebaseAuth.instance.authStateChanges().listen(_onAuthChanged);
  }
  static final HistoryStore instance = HistoryStore._();

  final _firestore = FirebaseFirestore.instance;
  StreamSubscription<User?>? _authSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _entriesSub;
  List<HistoryEntry> _entries = [];

  List<HistoryEntry> get entries => List.unmodifiable(_entries);

  void _onAuthChanged(User? user) {
    _entriesSub?.cancel();
    if (user == null) {
      _entries = [];
      notifyListeners();
      return;
    }
    _entriesSub = _firestore
        .collection('reports')
        .where('staffId', isEqualTo: user.uid)
        .orderBy('timestamp', descending: true)
        .snapshots()
        .listen((snapshot) {
      _entries = snapshot.docs
          .map((doc) => HistoryEntry.fromFirestore(doc.id, doc.data()))
          .toList();
      notifyListeners();
    }, onError: (Object e, StackTrace st) {
      debugPrint('[HistoryStore] snapshot error: $e');
    });
  }

  /// Firestoreの`reports`コレクションへ書き込む。staffIdはログイン中ユーザーから付与する。
  /// storeIdはSVの全件閲覧機能を実装する際に使う予約フィールド(現時点では未使用)。
  Future<void> add(HistoryEntry entry) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    await _firestore.collection('reports').add({
      ...entry.toMap(),
      'staffId': uid,
      'staffName': UserSession.instance.displayName,
      'storeId': null,
    });
  }

  /// 今月分の該当カテゴリの件数を数える(勤怠の頻度パターン連携などに使用)。
  /// categoryPrefix は前方一致で判定する(例:'勤怠(遅刻)' で遅刻のみ絞り込み)。
  int countThisMonth(String categoryPrefix) {
    final now = DateTime.now();
    return _entries.where((e) {
      return e.category.startsWith(categoryPrefix) &&
          e.timestamp.year == now.year &&
          e.timestamp.month == now.month;
    }).length;
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _entriesSub?.cancel();
    super.dispose();
  }
}

/// SVログイン時に全スタッフの`reports`を購読するストア。
/// role="sv"でないユーザーで全件クエリを投げるとセキュリティルールにより拒否されるため、
/// UserSessionでSVと確認できてから購読を開始する。
class SvReportStore extends ChangeNotifier {
  SvReportStore._() {
    UserSession.instance.addListener(_onSessionChanged);
    _onSessionChanged();
  }
  static final SvReportStore instance = SvReportStore._();

  final _firestore = FirebaseFirestore.instance;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _entriesSub;
  List<HistoryEntry> _entries = [];
  bool _isSv = false;

  List<HistoryEntry> get entries => List.unmodifiable(_entries);

  void _onSessionChanged() {
    final nowSv = UserSession.instance.role == UserRole.sv;
    if (nowSv == _isSv) return;
    _isSv = nowSv;
    _entriesSub?.cancel();

    if (!nowSv) {
      _entries = [];
      notifyListeners();
      return;
    }

    _entriesSub = _firestore
        .collection('reports')
        .orderBy('timestamp', descending: true)
        .snapshots()
        .listen((snapshot) {
      _entries = snapshot.docs
          .map((doc) => HistoryEntry.fromFirestore(doc.id, doc.data()))
          .toList();
      notifyListeners();
    }, onError: (Object e, StackTrace st) {
      debugPrint('[SvReportStore] snapshot error: $e');
    });
  }

  @override
  void dispose() {
    UserSession.instance.removeListener(_onSessionChanged);
    _entriesSub?.cancel();
    super.dispose();
  }
}

class ChatInputBar extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onSend;
  const ChatInputBar({super.key, required this.controller, required this.onSend});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'メッセージを入力',
                hintStyle: TextStyle(color: Colors.grey[500]),
                filled: true,
                fillColor: const Color(0xFF141826),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
              ),
              onSubmitted: (_) => onSend(),
            ),
          ),
          const SizedBox(width: 8),
          CircleAvatar(
            radius: 22,
            backgroundColor: const Color(0xFF3B82F6),
            child: IconButton(
              icon: const Icon(Icons.send, color: Colors.white, size: 18),
              onPressed: onSend,
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// 履歴タブ
// ============================================================


enum _AttendanceType { unknown, absence, lateness }

/// SVへの提出内容として集める情報。
/// 「足りない情報だけ聞く」ため、揃っている項目は再質問しない。
enum _LatenessCategory { unknown, train, car, other }

class _AttendanceReport {
  _AttendanceType type = _AttendanceType.unknown;
  _LatenessCategory latenessCategory = _LatenessCategory.unknown;
  String? reason; // 理由
  String? detail; // 遅刻:到着予定時刻(車の場合は現在地) / 欠勤:期間
  String? note; // 補足(任意)

  bool get isTypeKnown => type != _AttendanceType.unknown;
  bool get isLatenessCategoryKnown =>
      type != _AttendanceType.lateness || latenessCategory != _LatenessCategory.unknown;
  bool get hasReason => reason != null && reason!.trim().isNotEmpty;
  bool get hasDetail => detail != null && detail!.trim().isNotEmpty;

  bool get isComplete => isTypeKnown && hasReason && hasDetail;
}

class AttendanceChatScreen extends StatefulWidget {
  const AttendanceChatScreen({super.key});

  @override
  State<AttendanceChatScreen> createState() => _AttendanceChatScreenState();
}

class _AttendanceChatScreenState extends State<AttendanceChatScreen> {
  final List<ChatMessage> _messages = [];
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final _AttendanceReport _report = _AttendanceReport();

  bool _isComplete = false;

  @override
  void initState() {
    super.initState();
    _addJarvisMessage('お疲れ様です。今日は欠勤ですか、遅刻ですか？');
    setState(() => _awaitingTypeChoice = true);
  }

  void _addJarvisMessage(String text) {
    setState(() {
      _messages.add(ChatMessage(Sender.jarvis, text));
    });
    _scrollToBottom();
  }

  void _addUserMessage(String text) {
    setState(() {
      _messages.add(ChatMessage(Sender.user, text));
    });
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent + 80,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ------------------------------------------------------------
  // 簡易パース(キーワードマッチ)。
  // 実際のAI/バックエンド接続までのダミーロジックとして、
  // 「足りない情報だけ聞く」という設計方針だけを先に実証する。
  // ------------------------------------------------------------
  void _parseAndAdvance(String input) {
    // 理由・詳細はフリーテキストで受け取り、直前に聞いた質問の文脈でそのまま採用する
    if (!_report.hasReason && _lastAskedReason) {
      _report.reason = input;
    }
    if (!_report.hasDetail && _lastAskedDetail) {
      _report.detail = input;
    }

    _advanceConversation();
  }

  bool _lastAskedReason = false;
  bool _lastAskedDetail = false;
  bool _awaitingTypeChoice = false;
  bool _awaitingLatenessCategoryChoice = false;

  void _advanceConversation() {
    if (!_report.isTypeKnown) {
      _lastAskedReason = false;
      _lastAskedDetail = false;
      _addJarvisMessage('欠勤ですか、遅刻ですか？');
      setState(() => _awaitingTypeChoice = true);
      return;
    }

    // 遅刻の場合は、まず理由の大分類(電車/車/その他)を選んでもらう
    if (!_report.isLatenessCategoryKnown) {
      _lastAskedReason = false;
      _lastAskedDetail = false;
      _addJarvisMessage('遅刻の理由を教えてください。');
      setState(() => _awaitingLatenessCategoryChoice = true);
      return;
    }

    if (!_report.hasReason) {
      _lastAskedReason = true;
      _lastAskedDetail = false;
      if (_report.type == _AttendanceType.lateness &&
          _report.latenessCategory == _LatenessCategory.train) {
        _addJarvisMessage(
            '遅延している路線・区間・原因を教えてください。\n(例:○○線 ○○駅〜○○駅間 人身事故のため)');
      } else if (_report.type == _AttendanceType.lateness &&
          _report.latenessCategory == _LatenessCategory.car) {
        _addJarvisMessage('承知しました。念のため理由を一言で教えてください。(例:道路渋滞)');
      } else {
        _addJarvisMessage('承知しました。理由を教えてください。');
      }
      return;
    }

    // 自己申告を鵜呑みにしない:理由が曖昧な場合は深掘りする(レベル2:AIが誘導)。
    // 1回目は素直に聞き直し、2回目もまだ曖昧なら聞き方を変えて具体例を示す。
    if (_reasonGuidanceAttempts < 2 && isVagueAnswer(_report.reason ?? '')) {
      _reasonGuidanceAttempts++;
      _report.reason = null; // 再質問のためクリア
      _lastAskedReason = true;
      if (_reasonGuidanceAttempts == 1) {
        _addJarvisMessage('恐れ入りますが、もう少し具体的に理由を教えていただけますか？');
      } else {
        _addJarvisMessage(
            '度々恐れ入ります。例えば「頭痛がひどく体調不良のため」「○○線が○分遅延のため」のように、具体的な状況を教えていただけますか？');
      }
      return;
    }

    if (!_report.hasDetail) {
      _lastAskedReason = false;
      _lastAskedDetail = true;
      if (_report.type == _AttendanceType.lateness &&
          _report.latenessCategory == _LatenessCategory.car) {
        _addJarvisMessage('現在どこにいらっしゃいますか？(現在地を教えてください)');
      } else if (_report.type == _AttendanceType.lateness) {
        _addJarvisMessage('何時頃到着予定ですか？(例:10時30分頃)');
      } else {
        _addJarvisMessage('今日だけの欠勤ですか？期間を教えてください。');
      }
      return;
    }

    // 全項目が揃った → SV向けサマリーを生成(スタッフ画面には表示しない)
    _finalizeReport();
  }

  int _reasonGuidanceAttempts = 0;

  void _selectLatenessCategory(_LatenessCategory category, String label) {
    if (!_awaitingLatenessCategoryChoice) return;
    _addUserMessage(label);
    _report.latenessCategory = category;
    setState(() => _awaitingLatenessCategoryChoice = false);
    _advanceConversation();
  }

  Future<void> _finalizeReport() async {
    final typeLabel = _report.type == _AttendanceType.lateness ? '遅刻' : '欠勤';
    // 頻度連携:履歴ストアから「今月同じ種別が何回あったか」を数える(今回分を含めてカウント)
    final monthlyCount = HistoryStore.instance.countThisMonth('勤怠($typeLabel)') + 1;

    final action = _decideSuggestedAction(monthlyCount);
    setState(() {
      _isComplete = true;
    });

    final entry = HistoryEntry(
      category: '勤怠($typeLabel)',
      title: _report.reason ?? typeLabel,
      action: action,
      fields: [
        MapEntry('種別', typeLabel),
        MapEntry('理由', _report.reason ?? '-'),
        MapEntry(
          _report.type == _AttendanceType.lateness ? '到着予定' : '期間',
          _report.detail ?? '-',
        ),
        MapEntry('今月の回数', '今月$monthlyCount回目'),
      ],
      history: List.unmodifiable(_messages),
    );

    try {
      await HistoryStore.instance.add(entry);
      _addJarvisMessage('ありがとうございます。内容を確認し、SVに共有しました。');
    } catch (_) {
      _addJarvisMessage('申し訳ありません、保存に失敗しました。通信状況をご確認のうえ、もう一度お試しください。');
    }
  }


  SuggestedAction _decideSuggestedAction(int monthlyCount) {
    final reason = _report.reason ?? '';
    final detail = _report.detail ?? '';

    // 頻度連携:今月3回目以降は、内容に関わらずSVへエスカレーション
    if (monthlyCount >= 3) {
      return SuggestedAction.escalate;
    }

    if (_report.type == _AttendanceType.lateness) {
      if (_report.latenessCategory == _LatenessCategory.car) {
        // 車の場合は到着時刻が読めないため、原則「再調整が必要」とする
        return SuggestedAction.needsReschedule;
      }
      // 電車・その他:遅れが軽微そうなら承認のみでOK
      final minuteMatch = RegExp(r'(\d{1,3})\s*分').firstMatch(detail);
      final minutes = minuteMatch != null ? int.tryParse(minuteMatch.group(1)!) : null;
      if (minutes != null && minutes >= 90) {
        return SuggestedAction.needsReschedule;
      }
      if (monthlyCount >= 2) {
        // 今月2回目は軽度の注意喚起として再調整扱いに
        return SuggestedAction.needsReschedule;
      }
      if (_report.latenessCategory == _LatenessCategory.train ||
          reason.contains('体調不良')) {
        return SuggestedAction.approveOnly;
      }
      return SuggestedAction.needsReschedule;
    } else {
      // 欠勤:理由が不明瞭、または複数日にわたる場合はエスカレーション
      if (reason.trim().length <= 1) {
        return SuggestedAction.escalate;
      }
      if (detail.contains('明日') || RegExp(r'[2-9]\s*日').hasMatch(detail)) {
        return SuggestedAction.escalate;
      }
      if (monthlyCount >= 2) {
        return SuggestedAction.needsReschedule;
      }
      return SuggestedAction.approveOnly;
    }
  }

  void _selectType(_AttendanceType type, String label) {
    if (!_awaitingTypeChoice) return;
    _addUserMessage(label);
    _report.type = type;
    setState(() => _awaitingTypeChoice = false);
    _advanceConversation();
  }

  void _handleSend() {
    final text = _controller.text.trim();
    if (text.isEmpty || _isComplete) return;
    _addUserMessage(text);
    _controller.clear();
    _parseAndAdvance(text);
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0E1A),
        elevation: 0,
        title: const Text('勤怠 - 欠勤・遅刻',
            style: TextStyle(color: Colors.white, fontSize: 17)),
        iconTheme: const IconThemeData(color: Colors.white70),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.all(16),
                itemCount: _messages.length,
                itemBuilder: (context, index) {
                  return ChatBubble(message: _messages[index]);
                },
              ),
            ),
            if (_awaitingTypeChoice)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: ChoiceButton(
                        label: '欠勤',
                        icon: Icons.bedtime,
                        color: const Color(0xFF3B82F6),
                        onTap: () => _selectType(_AttendanceType.absence, '欠勤'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ChoiceButton(
                        label: '遅刻',
                        icon: Icons.access_time,
                        color: const Color(0xFFF59E0B),
                        onTap: () => _selectType(_AttendanceType.lateness, '遅刻'),
                      ),
                    ),
                  ],
                ),
              )
            else if (_awaitingLatenessCategoryChoice)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: ChoiceButton(
                        label: '電車',
                        icon: Icons.train,
                        color: const Color(0xFF06B6D4),
                        onTap: () => _selectLatenessCategory(_LatenessCategory.train, '電車'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ChoiceButton(
                        label: '車',
                        icon: Icons.directions_car,
                        color: const Color(0xFF64748B),
                        onTap: () => _selectLatenessCategory(_LatenessCategory.car, '車'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ChoiceButton(
                        label: 'その他',
                        icon: Icons.more_horiz,
                        color: const Color(0xFFA855F7),
                        onTap: () => _selectLatenessCategory(_LatenessCategory.other, 'その他'),
                      ),
                    ),
                  ],
                ),
              )
            else if (!_isComplete)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          hintText: 'メッセージを入力',
                          hintStyle: TextStyle(color: Colors.grey[500]),
                          filled: true,
                          fillColor: const Color(0xFF141826),
                          contentPadding:
                              const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24),
                            borderSide: BorderSide.none,
                          ),
                        ),
                        onSubmitted: (_) => _handleSend(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    CircleAvatar(
                      radius: 22,
                      backgroundColor: const Color(0xFF3B82F6),
                      child: IconButton(
                        icon: const Icon(Icons.send, color: Colors.white, size: 18),
                        onPressed: _handleSend,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}


class _WorkReportData {
  String? storeName;
  String? content;
  bool? hasIssue;
  String? issueDetail;
  String? severity; // 軽微 / 要対応 / 緊急

  bool get hasStoreName => storeName != null && storeName!.trim().isNotEmpty;
  bool get hasContent => content != null && content!.trim().isNotEmpty;
  bool get issueKnown => hasIssue != null;
  bool get issueDetailOk =>
      hasIssue == false || (issueDetail != null && issueDetail!.trim().isNotEmpty);
  bool get severityOk => hasIssue == false || severity != null;
  bool get isComplete =>
      hasStoreName && hasContent && issueKnown && issueDetailOk && severityOk;
}

class WorkReportChatScreen extends StatefulWidget {
  const WorkReportChatScreen({super.key});
  @override
  State<WorkReportChatScreen> createState() => _WorkReportChatScreenState();
}

class _WorkReportChatScreenState extends State<WorkReportChatScreen> {
  final List<ChatMessage> _messages = [];
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final _WorkReportData _data = _WorkReportData();

  bool _isComplete = false;
  bool _awaitingIssueChoice = false;
  bool _awaitingSeverityChoice = false;
  bool _lastAskedStoreName = false;
  bool _lastAskedContent = false;
  bool _lastAskedIssueDetail = false;

  @override
  void initState() {
    super.initState();
    _addJarvis('お疲れ様です。どちらの店舗の報告ですか？');
    _lastAskedStoreName = true;
  }

  void _addJarvis(String text) {
    setState(() => _messages.add(ChatMessage(Sender.jarvis, text)));
    _scrollToBottom();
  }

  void _addUser(String text) {
    setState(() => _messages.add(ChatMessage(Sender.user, text)));
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent + 80,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _handleSend() {
    final text = _controller.text.trim();
    if (text.isEmpty || _isComplete) return;
    _addUser(text);
    _controller.clear();

    if (_lastAskedStoreName) {
      _data.storeName = text;
    } else if (_lastAskedContent) {
      _data.content = text;
    } else if (_lastAskedIssueDetail) {
      _data.issueDetail = text;
    }
    _advance();
  }

  void _selectIssue(bool hasIssue, String label) {
    if (!_awaitingIssueChoice) return;
    _addUser(label);
    _data.hasIssue = hasIssue;
    setState(() => _awaitingIssueChoice = false);
    _advance();
  }

  void _selectSeverity(String label) {
    if (!_awaitingSeverityChoice) return;
    _addUser(label);
    _data.severity = label;
    setState(() => _awaitingSeverityChoice = false);
    _advance();
  }

  void _advance() {
    _lastAskedStoreName = false;
    _lastAskedContent = false;
    _lastAskedIssueDetail = false;

    if (!_data.hasStoreName) {
      _lastAskedStoreName = true;
      _addJarvis('どちらの店舗の報告ですか？');
      return;
    }
    if (!_data.hasContent) {
      _lastAskedContent = true;
      _addJarvis('作業内容や気づいた点を教えてください。');
      return;
    }
    // 自己申告を鵜呑みにしない:内容が曖昧な場合は深掘りする(レベル2:AIが誘導)。
    // 1回目は素直に聞き直し、2回目もまだ曖昧なら聞き方を変えて具体例を示す。
    if (_contentGuidanceAttempts < 2 && isVagueAnswer(_data.content ?? '')) {
      _contentGuidanceAttempts++;
      _data.content = null;
      _lastAskedContent = true;
      if (_contentGuidanceAttempts == 1) {
        _addJarvis('恐れ入りますが、もう少し具体的に作業内容を教えていただけますか？(例:何を確認し、結果はどうだったか)');
      } else {
        _addJarvis('重ねてすみません。例えば「在庫を確認し、A商品が3個不足していた」のように、確認した対象と結果をセットで教えてください。');
      }
      return;
    }
    if (!_data.issueKnown) {
      _addJarvis('特に問題はありましたか？');
      setState(() => _awaitingIssueChoice = true);
      return;
    }
    if (!_data.issueDetailOk) {
      _lastAskedIssueDetail = true;
      _addJarvis('問題の内容を詳しく教えてください。');
      return;
    }
    if (!_data.severityOk) {
      _addJarvis('その問題の深刻度を教えてください。');
      setState(() => _awaitingSeverityChoice = true);
      return;
    }
    _finalize();
  }

  int _contentGuidanceAttempts = 0;

  Future<void> _finalize() async {
    // 内容自体が薄く、問題「なし」の自己申告だけの場合はレベル3(SV介入)へ
    final contentStillVague = isVagueAnswer(_data.content ?? '');
    final SuggestedAction action;
    if (_data.hasIssue == true) {
      switch (_data.severity) {
        case '緊急':
          action = SuggestedAction.escalate;
          break;
        case '要対応':
          action = SuggestedAction.needsReschedule;
          break;
        default: // 軽微
          action = SuggestedAction.approveOnly;
      }
    } else if (contentStillVague) {
      action = SuggestedAction.needsReschedule;
    } else {
      action = SuggestedAction.approveOnly;
    }
    setState(() => _isComplete = true);

    final entry = HistoryEntry(
      category: '業務報告',
      title: '${_data.storeName}:${_data.content}',
      action: action,
      fields: [
        MapEntry('店舗', _data.storeName ?? '-'),
        MapEntry('内容', _data.content ?? '-'),
        MapEntry('問題', _data.hasIssue == true ? (_data.issueDetail ?? 'あり') : 'なし'),
        if (_data.hasIssue == true) MapEntry('深刻度', _data.severity ?? '-'),
      ],
      history: List.unmodifiable(_messages),
    );

    try {
      await HistoryStore.instance.add(entry);
      _addJarvis('ありがとうございます。内容を確認し、SVに共有しました。');
    } catch (_) {
      _addJarvis('申し訳ありません、保存に失敗しました。通信状況をご確認のうえ、もう一度お試しください。');
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0E1A),
        elevation: 0,
        title: const Text('業務報告', style: TextStyle(color: Colors.white, fontSize: 17)),
        iconTheme: const IconThemeData(color: Colors.white70),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.all(16),
                itemCount: _messages.length,
                itemBuilder: (context, index) => ChatBubble(message: _messages[index]),
              ),
            ),
            if (_awaitingIssueChoice)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: ChoiceButton(
                        label: 'あり',
                        icon: Icons.warning_amber,
                        color: const Color(0xFFF59E0B),
                        onTap: () => _selectIssue(true, 'あり'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ChoiceButton(
                        label: 'なし',
                        icon: Icons.check_circle,
                        color: const Color(0xFF22C55E),
                        onTap: () => _selectIssue(false, 'なし'),
                      ),
                    ),
                  ],
                ),
              )
            else if (_awaitingSeverityChoice)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: ChoiceButton(
                        label: '軽微',
                        icon: Icons.info_outline,
                        color: const Color(0xFF22C55E),
                        onTap: () => _selectSeverity('軽微'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ChoiceButton(
                        label: '要対応',
                        icon: Icons.warning_amber,
                        color: const Color(0xFFF59E0B),
                        onTap: () => _selectSeverity('要対応'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ChoiceButton(
                        label: '緊急',
                        icon: Icons.priority_high,
                        color: const Color(0xFFEF4444),
                        onTap: () => _selectSeverity('緊急'),
                      ),
                    ),
                  ],
                ),
              )
            else if (!_isComplete)
              ChatInputBar(controller: _controller, onSend: _handleSend),
          ],
        ),
      ),
    );
  }
}



class _ConsultationData {
  String? topic; // 店頭展示・POP / 商品知識・スペック / 店舗スタッフとの関係 / 競合情報 / その他
  String? content;
  String? urgency;

  bool get hasTopic => topic != null;
  bool get hasContent => content != null && content!.trim().isNotEmpty;
  bool get hasUrgency => urgency != null;
  bool get isComplete => hasTopic && hasContent && hasUrgency;
}

class ConsultationChatScreen extends StatefulWidget {
  const ConsultationChatScreen({super.key});
  @override
  State<ConsultationChatScreen> createState() => _ConsultationChatScreenState();
}

class _ConsultationChatScreenState extends State<ConsultationChatScreen> {
  final List<ChatMessage> _messages = [];
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final _ConsultationData _data = _ConsultationData();

  bool _isComplete = false;
  bool _awaitingUrgencyChoice = false;
  bool _awaitingTopicChoice = false;
  bool _lastAskedContent = false;

  @override
  void initState() {
    super.initState();
    _addJarvis('お疲れ様です。どのジャンルのご相談ですか？');
    setState(() => _awaitingTopicChoice = true);
  }

  void _addJarvis(String text) {
    setState(() => _messages.add(ChatMessage(Sender.jarvis, text)));
    _scrollToBottom();
  }

  void _addUser(String text) {
    setState(() => _messages.add(ChatMessage(Sender.user, text)));
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent + 80,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _handleSend() {
    final text = _controller.text.trim();
    if (text.isEmpty || _isComplete) return;
    _addUser(text);
    _controller.clear();
    if (_lastAskedContent) {
      _data.content = text;
    }
    _advance();
  }

  void _selectUrgency(String label) {
    if (!_awaitingUrgencyChoice) return;
    _addUser(label);
    _data.urgency = label;
    setState(() => _awaitingUrgencyChoice = false);
    _advance();
  }

  void _selectTopic(String label) {
    if (!_awaitingTopicChoice) return;
    _addUser(label);
    _data.topic = label;
    setState(() => _awaitingTopicChoice = false);
    _advance();
  }

  void _advance() {
    _lastAskedContent = false;
    if (!_data.hasTopic) {
      _addJarvis('お疲れ様です。どのジャンルのご相談ですか？');
      setState(() => _awaitingTopicChoice = true);
      return;
    }
    if (!_data.hasContent) {
      _lastAskedContent = true;
      _addJarvis('相談内容を具体的に教えてください。');
      return;
    }
    // 自己申告を鵜呑みにしない:内容が曖昧な場合は深掘りする(レベル2:AIが誘導)。
    // 1回目は素直に聞き直し、2回目もまだ曖昧なら聞き方を変える。
    if (_contentGuidanceAttempts < 2 && isVagueAnswer(_data.content ?? '')) {
      _contentGuidanceAttempts++;
      _data.content = null;
      _lastAskedContent = true;
      if (_contentGuidanceAttempts == 1) {
        _addJarvis('恐れ入りますが、もう少し詳しく状況を教えていただけますか？');
      } else {
        _addJarvis('度々すみません。いつ、どこで、何が起きたか、わかる範囲で構いませんので教えてください。');
      }
      return;
    }
    if (!_data.hasUrgency) {
      _addJarvis('回答の緊急度を教えてください。');
      setState(() => _awaitingUrgencyChoice = true);
      return;
    }
    _finalize();
  }

  int _contentGuidanceAttempts = 0;

  Future<void> _finalize() async {
    final SuggestedAction action;
    switch (_data.urgency) {
      case '今すぐ回答がほしい':
        action = SuggestedAction.escalate;
        break;
      case '今日中でOK':
        action = SuggestedAction.needsReschedule;
        break;
      default:
        action = SuggestedAction.approveOnly;
    }
    setState(() => _isComplete = true);

    final entry = HistoryEntry(
      category: '業務相談',
      title: '[${_data.topic}] ${_data.content}',
      action: action,
      fields: [
        MapEntry('ジャンル', _data.topic ?? '-'),
        MapEntry('相談内容', _data.content ?? '-'),
        MapEntry('緊急度', _data.urgency ?? '-'),
      ],
      history: List.unmodifiable(_messages),
    );

    try {
      await HistoryStore.instance.add(entry);
      _addJarvis('ありがとうございます。内容を確認し、SVに共有しました。');
    } catch (_) {
      _addJarvis('申し訳ありません、保存に失敗しました。通信状況をご確認のうえ、もう一度お試しください。');
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0E1A),
        elevation: 0,
        title: const Text('業務相談', style: TextStyle(color: Colors.white, fontSize: 17)),
        iconTheme: const IconThemeData(color: Colors.white70),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.all(16),
                itemCount: _messages.length,
                itemBuilder: (context, index) => ChatBubble(message: _messages[index]),
              ),
            ),
            if (_awaitingTopicChoice)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                child: Column(
                  children: [
                    ChoiceButton(
                      label: '店頭展示・POP',
                      icon: Icons.storefront,
                      color: const Color(0xFF22C55E),
                      onTap: () => _selectTopic('店頭展示・POP'),
                    ),
                    const SizedBox(height: 8),
                    ChoiceButton(
                      label: '商品知識・スペック',
                      icon: Icons.smartphone,
                      color: const Color(0xFF3B82F6),
                      onTap: () => _selectTopic('商品知識・スペック'),
                    ),
                    const SizedBox(height: 8),
                    ChoiceButton(
                      label: '店舗スタッフとの関係',
                      icon: Icons.people_outline,
                      color: const Color(0xFFF59E0B),
                      onTap: () => _selectTopic('店舗スタッフとの関係'),
                    ),
                    const SizedBox(height: 8),
                    ChoiceButton(
                      label: '競合情報',
                      icon: Icons.compare_arrows,
                      color: const Color(0xFF06B6D4),
                      onTap: () => _selectTopic('競合情報'),
                    ),
                    const SizedBox(height: 8),
                    ChoiceButton(
                      label: 'その他',
                      icon: Icons.more_horiz,
                      color: const Color(0xFF64748B),
                      onTap: () => _selectTopic('その他'),
                    ),
                  ],
                ),
              )
            else if (_awaitingUrgencyChoice)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                child: Column(
                  children: [
                    ChoiceButton(
                      label: '今すぐ回答がほしい',
                      icon: Icons.priority_high,
                      color: const Color(0xFFEF4444),
                      onTap: () => _selectUrgency('今すぐ回答がほしい'),
                    ),
                    const SizedBox(height: 8),
                    ChoiceButton(
                      label: '今日中でOK',
                      icon: Icons.today,
                      color: const Color(0xFFF59E0B),
                      onTap: () => _selectUrgency('今日中でOK'),
                    ),
                    const SizedBox(height: 8),
                    ChoiceButton(
                      label: '急ぎではない',
                      icon: Icons.check_circle,
                      color: const Color(0xFF22C55E),
                      onTap: () => _selectUrgency('急ぎではない'),
                    ),
                  ],
                ),
              )
            else if (!_isComplete)
              ChatInputBar(controller: _controller, onSend: _handleSend),
          ],
        ),
      ),
    );
  }
}



class _TaskCompletionData {
  String? taskName;
  String? verification;
  bool? hasExpense;
  String? expenseCategory; // 交通費 / ロッカー代 / 駐車場代 / 印刷代 / その他
  String? expenseAmount; // 金額(数字)

  bool get hasTaskName => taskName != null && taskName!.trim().isNotEmpty;
  bool get hasVerification => verification != null && verification!.trim().isNotEmpty;
  bool get expenseKnown => hasExpense != null;
  bool get expenseCategoryOk => hasExpense == false || expenseCategory != null;
  bool get expenseAmountOk =>
      hasExpense == false || (expenseAmount != null && expenseAmount!.trim().isNotEmpty);
  bool get isComplete =>
      hasTaskName && hasVerification && expenseKnown && expenseCategoryOk && expenseAmountOk;

  int? get expenseAmountValue {
    if (expenseAmount == null) return null;
    final match = RegExp(r'\d+').firstMatch(expenseAmount!.replaceAll(',', ''));
    return match != null ? int.tryParse(match.group(0)!) : null;
  }
}

class TaskCompletionChatScreen extends StatefulWidget {
  const TaskCompletionChatScreen({super.key});
  @override
  State<TaskCompletionChatScreen> createState() => _TaskCompletionChatScreenState();
}

class _TaskCompletionChatScreenState extends State<TaskCompletionChatScreen> {
  final List<ChatMessage> _messages = [];
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final _TaskCompletionData _data = _TaskCompletionData();

  bool _isComplete = false;
  bool _awaitingExpenseChoice = false;
  bool _awaitingExpenseCategoryChoice = false;
  bool _lastAskedTaskName = false;
  bool _lastAskedVerification = false;
  bool _lastAskedExpenseAmount = false;

  @override
  void initState() {
    super.initState();
    _addJarvis('お疲れ様です。完了したタスクの内容を教えてください。');
    _lastAskedTaskName = true;
  }

  void _addJarvis(String text) {
    setState(() => _messages.add(ChatMessage(Sender.jarvis, text)));
    _scrollToBottom();
  }

  void _addUser(String text) {
    setState(() => _messages.add(ChatMessage(Sender.user, text)));
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent + 80,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _handleSend() {
    final text = _controller.text.trim();
    if (text.isEmpty || _isComplete) return;
    _addUser(text);
    _controller.clear();

    if (_lastAskedTaskName) {
      _data.taskName = text;
    } else if (_lastAskedVerification) {
      _data.verification = text;
    } else if (_lastAskedExpenseAmount) {
      _data.expenseAmount = text;
    }
    _advance();
  }

  void _selectExpense(bool hasExpense, String label) {
    if (!_awaitingExpenseChoice) return;
    _addUser(label);
    _data.hasExpense = hasExpense;
    setState(() => _awaitingExpenseChoice = false);
    _advance();
  }

  void _selectExpenseCategory(String label) {
    if (!_awaitingExpenseCategoryChoice) return;
    _addUser(label);
    _data.expenseCategory = label;
    setState(() => _awaitingExpenseCategoryChoice = false);
    _advance();
  }

  void _advance() {
    _lastAskedTaskName = false;
    _lastAskedVerification = false;
    _lastAskedExpenseAmount = false;

    if (!_data.hasTaskName) {
      _lastAskedTaskName = true;
      _addJarvis('完了したタスクの内容を教えてください。(例:棚卸、緊急ヒアリング対応 など)');
      return;
    }
    if (!_data.hasVerification) {
      // 「完了しました」の一言だけを鵜呑みにせず、必ず具体的な内容を確認する
      _lastAskedVerification = true;
      _addJarvis('具体的に何を対応されましたか？完了確認のため、詳しく教えてください。');
      return;
    }
    // 自己申告を鵜呑みにしない:レベル2として、曖昧な回答には深掘りする。
    // 1回目は素直に聞き直し、2回目もまだ曖昧なら聞き方を変え、それでもダメならSVに委ねる。
    if (_verificationGuidanceAttempts < 2 && isVagueAnswer(_data.verification ?? '')) {
      _verificationGuidanceAttempts++;
      _data.verification = null;
      _lastAskedVerification = true;
      if (_verificationGuidanceAttempts == 1) {
        _addJarvis('恐れ入りますが、「完了しました」だけでは判断ができません。具体的に何を確認・対応したか教えていただけますか？');
      } else {
        _addJarvis('重ねて恐れ入ります。例えば「POPを2箇所に設置し写真を撮影した」のように、具体的な作業内容を教えてください。');
      }
      return;
    }
    if (!_data.expenseKnown) {
      _addJarvis('経費は発生しましたか？(交通費・ロッカー代・駐車場代・印刷代など)');
      setState(() => _awaitingExpenseChoice = true);
      return;
    }
    if (!_data.expenseCategoryOk) {
      _addJarvis('経費の種類を教えてください。');
      setState(() => _awaitingExpenseCategoryChoice = true);
      return;
    }
    if (!_data.expenseAmountOk) {
      _lastAskedExpenseAmount = true;
      _addJarvis('金額を教えてください。(例:800円)');
      return;
    }
    _finalize();
  }

  int _verificationGuidanceAttempts = 0;

  Future<void> _finalize() async {
    final verification = _data.verification ?? '';
    // レベル2で一度深掘りしても、なお曖昧な場合はレベル3(SVの直接介入)へ
    final stillVague = isVagueAnswer(verification);
    final amount = _data.expenseAmountValue;

    final SuggestedAction action;
    if (stillVague) {
      action = SuggestedAction.escalate;
    } else if (_data.hasExpense == true && amount != null && amount >= 10000) {
      // 高額な経費(交通費・ロッカー代・駐車場代・印刷代の通常範囲を超える)はエスカレーション
      action = SuggestedAction.escalate;
    } else if (_data.hasExpense == true && amount != null && amount >= 3000) {
      action = SuggestedAction.needsReschedule;
    } else if (_data.hasExpense == true) {
      // 交通費・ロッカー代など、日常的な少額経費は承認のみでOK
      action = SuggestedAction.approveOnly;
    } else {
      action = SuggestedAction.approveOnly;
    }
    setState(() => _isComplete = true);

    final entry = HistoryEntry(
      category: 'タスク完了',
      title: _data.taskName ?? '-',
      action: action,
      fields: [
        MapEntry('タスク', _data.taskName ?? '-'),
        MapEntry('完了内容', _data.verification ?? '-'),
        MapEntry(
          '経費',
          _data.hasExpense == true
              ? '${_data.expenseCategory ?? ''} ${_data.expenseAmount ?? ''}'
              : 'なし',
        ),
      ],
      history: List.unmodifiable(_messages),
    );

    try {
      await HistoryStore.instance.add(entry);
      _addJarvis('ありがとうございます。内容を確認し、SVに共有しました。');
    } catch (_) {
      _addJarvis('申し訳ありません、保存に失敗しました。通信状況をご確認のうえ、もう一度お試しください。');
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0E1A),
        elevation: 0,
        title: const Text('タスク完了', style: TextStyle(color: Colors.white, fontSize: 17)),
        iconTheme: const IconThemeData(color: Colors.white70),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.all(16),
                itemCount: _messages.length,
                itemBuilder: (context, index) => ChatBubble(message: _messages[index]),
              ),
            ),
            if (_awaitingExpenseChoice)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: ChoiceButton(
                        label: 'あり',
                        icon: Icons.receipt_long,
                        color: const Color(0xFFF97316),
                        onTap: () => _selectExpense(true, 'あり'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ChoiceButton(
                        label: 'なし',
                        icon: Icons.check_circle,
                        color: const Color(0xFF22C55E),
                        onTap: () => _selectExpense(false, 'なし'),
                      ),
                    ),
                  ],
                ),
              )
            else if (_awaitingExpenseCategoryChoice)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    SizedBox(
                      width: 150,
                      child: ChoiceButton(
                        label: '交通費',
                        icon: Icons.train,
                        color: const Color(0xFF3B82F6),
                        onTap: () => _selectExpenseCategory('交通費'),
                      ),
                    ),
                    SizedBox(
                      width: 150,
                      child: ChoiceButton(
                        label: 'ロッカー代',
                        icon: Icons.lock_outline,
                        color: const Color(0xFF64748B),
                        onTap: () => _selectExpenseCategory('ロッカー代'),
                      ),
                    ),
                    SizedBox(
                      width: 150,
                      child: ChoiceButton(
                        label: '駐車場代',
                        icon: Icons.local_parking,
                        color: const Color(0xFF06B6D4),
                        onTap: () => _selectExpenseCategory('駐車場代'),
                      ),
                    ),
                    SizedBox(
                      width: 150,
                      child: ChoiceButton(
                        label: '印刷代',
                        icon: Icons.print,
                        color: const Color(0xFFA855F7),
                        onTap: () => _selectExpenseCategory('印刷代'),
                      ),
                    ),
                    SizedBox(
                      width: 150,
                      child: ChoiceButton(
                        label: 'その他',
                        icon: Icons.more_horiz,
                        color: const Color(0xFFF97316),
                        onTap: () => _selectExpenseCategory('その他'),
                      ),
                    ),
                  ],
                ),
              )
            else if (!_isComplete)
              ChatInputBar(controller: _controller, onSend: _handleSend),
          ],
        ),
      ),
    );
  }
}



class _OtherData {
  String? content;
  String? urgency;

  bool get hasContent => content != null && content!.trim().isNotEmpty;
  bool get hasUrgency => urgency != null;
  bool get isComplete => hasContent && hasUrgency;
}

class OtherChatScreen extends StatefulWidget {
  const OtherChatScreen({super.key});
  @override
  State<OtherChatScreen> createState() => _OtherChatScreenState();
}

class _OtherChatScreenState extends State<OtherChatScreen> {
  final List<ChatMessage> _messages = [];
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final _OtherData _data = _OtherData();

  bool _isComplete = false;
  bool _awaitingUrgencyChoice = false;
  bool _lastAskedContent = false;

  @override
  void initState() {
    super.initState();
    _addJarvis('お疲れ様です。内容を教えてください。');
    _lastAskedContent = true;
  }

  void _addJarvis(String text) {
    setState(() => _messages.add(ChatMessage(Sender.jarvis, text)));
    _scrollToBottom();
  }

  void _addUser(String text) {
    setState(() => _messages.add(ChatMessage(Sender.user, text)));
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent + 80,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _handleSend() {
    final text = _controller.text.trim();
    if (text.isEmpty || _isComplete) return;
    _addUser(text);
    _controller.clear();
    if (_lastAskedContent) {
      _data.content = text;
    }
    _advance();
  }

  void _selectUrgency(String label) {
    if (!_awaitingUrgencyChoice) return;
    _addUser(label);
    _data.urgency = label;
    setState(() => _awaitingUrgencyChoice = false);
    _advance();
  }

  void _advance() {
    _lastAskedContent = false;
    if (!_data.hasContent) {
      _lastAskedContent = true;
      _addJarvis('内容を教えてください。');
      return;
    }
    // 自己申告を鵜呑みにしない:内容が曖昧な場合は深掘りする(レベル2:AIが誘導)。
    // 1回目は素直に聞き直し、2回目もまだ曖昧なら聞き方を変える。
    if (_contentGuidanceAttempts < 2 && isVagueAnswer(_data.content ?? '')) {
      _contentGuidanceAttempts++;
      _data.content = null;
      _lastAskedContent = true;
      if (_contentGuidanceAttempts == 1) {
        _addJarvis('恐れ入りますが、もう少し詳しく教えていただけますか？');
      } else {
        _addJarvis('度々すみません。差し支えない範囲で構いませんので、もう少し具体的に状況を教えてください。');
      }
      return;
    }
    if (!_data.hasUrgency) {
      _addJarvis('緊急度を教えてください。');
      setState(() => _awaitingUrgencyChoice = true);
      return;
    }
    _finalize();
  }

  int _contentGuidanceAttempts = 0;

  Future<void> _finalize() async {
    final SuggestedAction action;
    switch (_data.urgency) {
      case '今すぐ回答がほしい':
        action = SuggestedAction.escalate;
        break;
      case '今日中でOK':
        action = SuggestedAction.needsReschedule;
        break;
      default:
        action = SuggestedAction.approveOnly;
    }
    setState(() => _isComplete = true);

    final entry = HistoryEntry(
      category: 'その他',
      title: _data.content ?? '-',
      action: action,
      fields: [
        MapEntry('内容', _data.content ?? '-'),
        MapEntry('緊急度', _data.urgency ?? '-'),
      ],
      history: List.unmodifiable(_messages),
    );

    try {
      await HistoryStore.instance.add(entry);
      _addJarvis('ありがとうございます。内容を確認し、SVに共有しました。');
    } catch (_) {
      _addJarvis('申し訳ありません、保存に失敗しました。通信状況をご確認のうえ、もう一度お試しください。');
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0E1A),
        elevation: 0,
        title: const Text('その他', style: TextStyle(color: Colors.white, fontSize: 17)),
        iconTheme: const IconThemeData(color: Colors.white70),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.all(16),
                itemCount: _messages.length,
                itemBuilder: (context, index) => ChatBubble(message: _messages[index]),
              ),
            ),
            if (_awaitingUrgencyChoice)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                child: Column(
                  children: [
                    ChoiceButton(
                      label: '今すぐ回答がほしい',
                      icon: Icons.priority_high,
                      color: const Color(0xFFEF4444),
                      onTap: () => _selectUrgency('今すぐ回答がほしい'),
                    ),
                    const SizedBox(height: 8),
                    ChoiceButton(
                      label: '今日中でOK',
                      icon: Icons.today,
                      color: const Color(0xFFF59E0B),
                      onTap: () => _selectUrgency('今日中でOK'),
                    ),
                    const SizedBox(height: 8),
                    ChoiceButton(
                      label: '急ぎではない',
                      icon: Icons.check_circle,
                      color: const Color(0xFF22C55E),
                      onTap: () => _selectUrgency('急ぎではない'),
                    ),
                  ],
                ),
              )
            else if (!_isComplete)
              ChatInputBar(controller: _controller, onSend: _handleSend),
          ],
        ),
      ),
    );
  }
}



class AnnouncementChatScreen extends StatefulWidget {
  const AnnouncementChatScreen({super.key});
  @override
  State<AnnouncementChatScreen> createState() => _AnnouncementChatScreenState();
}

class _AnnouncementChatScreenState extends State<AnnouncementChatScreen> {
  final List<ChatMessage> _messages = [];
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  bool _isComplete = false;
  bool _awaitingConfirmChoice = false;
  bool _awaitingQuestionInput = false;
  String? _questionText;

  static const String _noticeText =
      '【本日の重要なお知らせ】\n'
      '来週より、勤怠報告の締め切り時刻が18:00に変更となります。\n'
      'ご確認をお願いします。';

  @override
  void initState() {
    super.initState();
    _addJarvis('お疲れ様です。$_noticeText');
    setState(() => _awaitingConfirmChoice = true);
  }

  void _addJarvis(String text) {
    setState(() => _messages.add(ChatMessage(Sender.jarvis, text)));
    _scrollToBottom();
  }

  void _addUser(String text) {
    setState(() => _messages.add(ChatMessage(Sender.user, text)));
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent + 80,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _confirmRead() {
    if (!_awaitingConfirmChoice) return;
    _addUser('確認しました');
    setState(() => _awaitingConfirmChoice = false);
    _finalize(hadQuestion: false);
  }

  void _hasQuestion() {
    if (!_awaitingConfirmChoice) return;
    _addUser('質問がある');
    setState(() {
      _awaitingConfirmChoice = false;
      _awaitingQuestionInput = true;
    });
    _addJarvis('ご質問の内容を教えてください。');
  }

  void _handleSend() {
    final text = _controller.text.trim();
    if (text.isEmpty || _isComplete) return;
    _addUser(text);
    _controller.clear();
    if (_awaitingQuestionInput) {
      _questionText = text;
      setState(() => _awaitingQuestionInput = false);
      _finalize(hadQuestion: true);
    }
  }

  Future<void> _finalize({required bool hadQuestion}) async {
    final action =
        hadQuestion ? SuggestedAction.needsReschedule : SuggestedAction.approveOnly;
    setState(() => _isComplete = true);

    final entry = HistoryEntry(
      category: '周知確認',
      title: hadQuestion ? (_questionText ?? '質問あり') : '確認済み',
      action: action,
      fields: [
        const MapEntry('お知らせ', '勤怠報告の締め切り時刻が18:00に変更'),
        MapEntry('確認結果', hadQuestion ? '質問あり:${_questionText ?? ''}' : '確認しました'),
      ],
      history: List.unmodifiable(_messages),
    );

    try {
      await HistoryStore.instance.add(entry);
      _addJarvis(hadQuestion
          ? 'ありがとうございます。ご質問をSVに共有しました。'
          : 'ご確認ありがとうございます。SVに確認済みとして共有しました。');
    } catch (_) {
      _addJarvis('申し訳ありません、保存に失敗しました。通信状況をご確認のうえ、もう一度お試しください。');
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0E1A),
        elevation: 0,
        title: const Text('周知確認', style: TextStyle(color: Colors.white, fontSize: 17)),
        iconTheme: const IconThemeData(color: Colors.white70),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.all(16),
                itemCount: _messages.length,
                itemBuilder: (context, index) => ChatBubble(message: _messages[index]),
              ),
            ),
            if (_awaitingConfirmChoice)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: ChoiceButton(
                        label: '確認しました',
                        icon: Icons.check_circle,
                        color: const Color(0xFF22C55E),
                        onTap: _confirmRead,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ChoiceButton(
                        label: '質問がある',
                        icon: Icons.help_outline,
                        color: const Color(0xFFA855F7),
                        onTap: _hasQuestion,
                      ),
                    ),
                  ],
                ),
              )
            else if (_awaitingQuestionInput)
              ChatInputBar(controller: _controller, onSend: _handleSend),
          ],
        ),
      ),
    );
  }
}



class HistoryTabBody extends StatefulWidget {
  const HistoryTabBody({super.key});

  @override
  State<HistoryTabBody> createState() => _HistoryTabBodyState();
}

class _HistoryTabBodyState extends State<HistoryTabBody> {
  @override
  void initState() {
    super.initState();
    HistoryStore.instance.addListener(_onStoreChanged);
  }

  @override
  void dispose() {
    HistoryStore.instance.removeListener(_onStoreChanged);
    super.dispose();
  }

  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final entries = HistoryStore.instance.entries;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
          child: Row(
            children: [
              Builder(
                builder: (context) => InkWell(
                  onTap: () => Scaffold.of(context).openDrawer(),
                  borderRadius: BorderRadius.circular(20),
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.menu, color: Colors.white70, size: 26),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              const Text('履歴',
                  style: TextStyle(
                      color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            itemCount: entries.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final e = entries[index];
              return Material(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(16),
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => SvSummaryScreen(
                          summary: SvReportSummary(
                            category: e.category,
                            icon: e.icon,
                            color: e.color,
                            time: e.time,
                            fields: e.fields,
                            action: e.action,
                            history: e.history,
                          ),
                        ),
                      ),
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF141826),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white10),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        CircleAvatar(
                          radius: 20,
                          backgroundColor: e.color.withValues(alpha: 0.3),
                          child: Icon(e.icon, color: Colors.white, size: 18),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(e.category,
                                      style: TextStyle(
                                          color: e.color,
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold)),
                                  Text(e.time,
                                      style: TextStyle(color: Colors.grey[500], fontSize: 11)),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(e.title,
                                  style: const TextStyle(
                                      color: Colors.white, fontSize: 13.5, height: 1.3)),
                              const SizedBox(height: 8),
                              Container(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: e.actionColor.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: e.actionColor.withValues(alpha: 0.5)),
                                ),
                                child: Text(e.actionLabel,
                                    style: TextStyle(
                                        color: e.actionColor,
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold)),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}


class _CategoryCount {
  final String label;
  final int count;
  final Color color;
  const _CategoryCount(this.label, this.count, this.color);
}

class SummaryTabBody extends StatefulWidget {
  const SummaryTabBody({super.key});

  @override
  State<SummaryTabBody> createState() => _SummaryTabBodyState();
}

class _SummaryTabBodyState extends State<SummaryTabBody> {
  static const List<_CategoryCount> _dummyBreakdown = [
    _CategoryCount('勤怠', 5, Color(0xFF3B82F6)),
    _CategoryCount('業務報告', 12, Color(0xFF22C55E)),
    _CategoryCount('業務相談', 3, Color(0xFFA855F7)),
    _CategoryCount('タスク完了', 8, Color(0xFFF97316)),
    _CategoryCount('その他', 1, Color(0xFF64748B)),
    _CategoryCount('周知確認', 6, Color(0xFF06B6D4)),
  ];

  @override
  void initState() {
    super.initState();
    UserSession.instance.addListener(_onChanged);
    SvReportStore.instance.addListener(_onChanged);
  }

  @override
  void dispose() {
    UserSession.instance.removeListener(_onChanged);
    SvReportStore.instance.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  List<_CategoryCount> _realBreakdown(List<HistoryEntry> entries) {
    final counts = <String, int>{};
    for (final e in entries) {
      counts[e.category] = (counts[e.category] ?? 0) + 1;
    }
    return counts.entries
        .map((e) => _CategoryCount(e.key, e.value, categoryStyle(e.key).color))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final isSv = UserSession.instance.role == UserRole.sv;
    final svEntries = SvReportStore.instance.entries;
    final breakdown = isSv ? _realBreakdown(svEntries) : _dummyBreakdown;
    final maxCount = breakdown.isEmpty
        ? 1
        : breakdown.map((e) => e.count).reduce((a, b) => a > b ? a : b);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Builder(
                builder: (context) => InkWell(
                  onTap: () => Scaffold.of(context).openDrawer(),
                  borderRadius: BorderRadius.circular(20),
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.menu, color: Colors.white70, size: 26),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              const Text('サマリー',
                  style: TextStyle(
                      color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: _SummaryStatCard(
                  label: '今週の対応件数',
                  value: '35件',
                  icon: Icons.inbox,
                  color: const Color(0xFF3B82F6),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _SummaryStatCard(
                  label: '承認のみでOK率',
                  value: '74%',
                  icon: Icons.check_circle,
                  color: const Color(0xFF22C55E),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _SummaryStatCard(
                  label: '要エスカレーション',
                  value: '4件',
                  icon: Icons.priority_high,
                  color: const Color(0xFFEF4444),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _SummaryStatCard(
                  label: '平均対応時間',
                  value: '3分',
                  icon: Icons.timer,
                  color: const Color(0xFF06B6D4),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF141826),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(isSv ? 'カテゴリ別件数(全スタッフ)' : 'カテゴリ別件数(今週)',
                    style: const TextStyle(
                        color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                if (breakdown.isEmpty)
                  Text(isSv ? '報告はまだありません。' : 'データがありません。',
                      style: TextStyle(color: Colors.grey[500], fontSize: 12.5)),
                for (final b in breakdown) ...[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(b.label,
                                style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
                            Text('${b.count}件',
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.bold)),
                          ],
                        ),
                        const SizedBox(height: 6),
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final ratio = b.count / maxCount;
                            return Stack(
                              children: [
                                Container(
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.06),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                ),
                                Container(
                                  height: 8,
                                  width: constraints.maxWidth * ratio,
                                  decoration: BoxDecoration(
                                    color: b.color,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (isSv) ...[
            const SizedBox(height: 24),
            const Text('全スタッフの報告一覧',
                style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            if (svEntries.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text('報告はまだありません。',
                    style: TextStyle(color: Colors.grey[500], fontSize: 12.5)),
              )
            else
              for (final e in svEntries) ...[
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Material(
                    color: Colors.transparent,
                    borderRadius: BorderRadius.circular(16),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => SvSummaryScreen(
                              summary: SvReportSummary(
                                category: e.category,
                                icon: e.icon,
                                color: e.color,
                                time: e.time,
                                fields: e.fields,
                                action: e.action,
                                history: e.history,
                              ),
                            ),
                          ),
                        );
                      },
                      child: Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFF141826),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Colors.white10),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            CircleAvatar(
                              radius: 20,
                              backgroundColor: e.color.withValues(alpha: 0.3),
                              child: Icon(e.icon, color: Colors.white, size: 18),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(e.category,
                                          style: TextStyle(
                                              color: e.color,
                                              fontSize: 12,
                                              fontWeight: FontWeight.bold)),
                                      Text(e.time,
                                          style: TextStyle(
                                              color: Colors.grey[500], fontSize: 11)),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Text(e.title,
                                      style: const TextStyle(color: Colors.white, fontSize: 13.5),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis),
                                  const SizedBox(height: 4),
                                  Text(
                                      '担当: ${e.staffName ?? shortStaffId(e.staffId)}',
                                      style: TextStyle(
                                          color: Colors.grey[600], fontSize: 11)),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
          ],
        ],
      ),
    );
  }
}

class _SummaryStatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;
  const _SummaryStatCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF141826),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(height: 10),
          Text(value,
              style: const TextStyle(
                  color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(color: Colors.grey[400], fontSize: 11.5)),
        ],
      ),
    );
  }
}

// ============================================================
// 設定タブ
// ============================================================


class SettingsTabBody extends StatefulWidget {
  const SettingsTabBody({super.key});

  @override
  State<SettingsTabBody> createState() => _SettingsTabBodyState();
}

class _SettingsTabBodyState extends State<SettingsTabBody> {
  bool _notificationsEnabled = true;
  bool _soundEnabled = true;

  @override
  void initState() {
    super.initState();
    UserSession.instance.addListener(_onSessionChanged);
  }

  @override
  void dispose() {
    UserSession.instance.removeListener(_onSessionChanged);
    super.dispose();
  }

  void _onSessionChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _handleLogout() => performLogout(context);

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Builder(
                builder: (context) => InkWell(
                  onTap: () => Scaffold.of(context).openDrawer(),
                  borderRadius: BorderRadius.circular(20),
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.menu, color: Colors.white70, size: 26),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              const Text('設定',
                  style: TextStyle(
                      color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF141826),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white10),
            ),
            child: Row(
              children: [
                const CircleAvatar(
                  radius: 28,
                  backgroundColor: Color(0xFF3B82F6),
                  child: Icon(Icons.person, color: Colors.white, size: 28),
                ),
                const SizedBox(width: 14),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(UserSession.instance.displayName ?? '-',
                        style: const TextStyle(
                            color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 2),
                    Text(UserSession.instance.role?.label ?? '-',
                        style: const TextStyle(color: Colors.grey, fontSize: 12.5)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          const Text('通知',
              style: TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          _SettingsSwitchTile(
            icon: Icons.notifications_none,
            label: 'プッシュ通知',
            value: _notificationsEnabled,
            onChanged: (v) => setState(() => _notificationsEnabled = v),
          ),
          const SizedBox(height: 8),
          _SettingsSwitchTile(
            icon: Icons.volume_up_outlined,
            label: '通知音',
            value: _soundEnabled,
            onChanged: (v) => setState(() => _soundEnabled = v),
          ),
          const SizedBox(height: 20),
          const Text('アプリ情報',
              style: TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const _SettingsNavTile(icon: Icons.info_outline, label: 'バージョン情報', trailing: 'v0.1.0'),
          const _SettingsNavTile(icon: Icons.description_outlined, label: '利用規約'),
          const _SettingsNavTile(icon: Icons.privacy_tip_outlined, label: 'プライバシーポリシー'),
          const SizedBox(height: 20),
          _SettingsNavTile(
            icon: Icons.logout,
            label: 'ログアウト',
            color: const Color(0xFFEF4444),
            onTap: _handleLogout,
          ),
        ],
      ),
    );
  }
}

class _SettingsSwitchTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _SettingsSwitchTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF141826),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        children: [
          Icon(icon, color: Colors.white70, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 14)),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: Colors.cyanAccent,
          ),
        ],
      ),
    );
  }
}

class _SettingsNavTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? trailing;
  final Color? color;
  final VoidCallback? onTap;
  const _SettingsNavTile({
    required this.icon,
    required this.label,
    this.trailing,
    this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tileColor = color ?? Colors.white;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: const Color(0xFF141826),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white10),
          ),
          child: Row(
            children: [
              Icon(icon, color: tileColor.withValues(alpha: 0.85), size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text(label, style: TextStyle(color: tileColor, fontSize: 14)),
              ),
              if (trailing != null)
                Text(trailing!, style: TextStyle(color: Colors.grey[500], fontSize: 12.5))
              else
                const Icon(Icons.chevron_right, color: Colors.white38, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
// SV向けサマリー画面
// ============================================================


class SvReportSummary {
  final String category;
  final IconData icon;
  final Color color;
  final String time;
  final List<MapEntry<String, String>> fields;
  final SuggestedAction action;
  final List<ChatMessage> history;

  const SvReportSummary({
    required this.category,
    required this.icon,
    required this.color,
    required this.time,
    required this.fields,
    required this.action,
    required this.history,
  });
}

class SvSummaryScreen extends StatefulWidget {
  final SvReportSummary summary;
  const SvSummaryScreen({super.key, required this.summary});

  @override
  State<SvSummaryScreen> createState() => _SvSummaryScreenState();
}

class _SvSummaryScreenState extends State<SvSummaryScreen> {
  bool _showHistory = false;
  SuggestedAction? _decision;

  void _decide(SuggestedAction action, String message) {
    setState(() => _decision = action);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFF141826),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.summary;
    final effectiveAction = _decision ?? s.action;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0E1A),
        elevation: 0,
        title: const Text('SV確認画面', style: TextStyle(color: Colors.white, fontSize: 17)),
        iconTheme: const IconThemeData(color: Colors.white70),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ヘッダー:カテゴリ・時刻
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF141826),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: s.color.withValues(alpha: 0.4)),
                ),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 24,
                      backgroundColor: s.color.withValues(alpha: 0.3),
                      child: Icon(s.icon, color: Colors.white, size: 22),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(s.category,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 17,
                                  fontWeight: FontWeight.bold)),
                          const SizedBox(height: 2),
                          Text(s.time,
                              style: TextStyle(color: Colors.grey[500], fontSize: 12.5)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // 整形済み内容(生ログではなく構造化データ)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF141826),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.description_outlined, color: Colors.white70, size: 18),
                        SizedBox(width: 8),
                        Text('内容',
                            style: TextStyle(
                                color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
                      ],
                    ),
                    const Divider(color: Colors.white12, height: 24),
                    for (final f in s.fields) SummaryRow(label: f.key, value: f.value),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // AIおすすめアクション
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: s.action.color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: s.action.color.withValues(alpha: 0.5)),
                ),
                child: Row(
                  children: [
                    Icon(s.action.icon, color: s.action.color, size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('AIおすすめアクション',
                              style: TextStyle(color: Colors.grey[400], fontSize: 11.5)),
                          const SizedBox(height: 2),
                          Text(s.action.label,
                              style: TextStyle(
                                  color: s.action.color,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // 対応履歴(展開式)
              InkWell(
                onTap: () => setState(() => _showHistory = !_showHistory),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      Icon(
                        _showHistory ? Icons.expand_less : Icons.expand_more,
                        color: Colors.white54,
                        size: 18,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _showHistory ? '対応履歴を閉じる' : '対応履歴を見る(AIの整形内容に不安がある場合)',
                        style: const TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
              if (_showHistory)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF141826),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: s.history.map((m) {
                      final isJarvis = m.sender == Sender.jarvis;
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: RichText(
                          text: TextSpan(
                            children: [
                              TextSpan(
                                text: isJarvis ? 'JARVIS: ' : 'スタッフ: ',
                                style: TextStyle(
                                  color: isJarvis
                                      ? const Color(0xFF7FF6FF)
                                      : Colors.orangeAccent,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                              TextSpan(
                                text: m.text,
                                style: const TextStyle(
                                    color: Colors.white70, fontSize: 12, height: 1.4),
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              const SizedBox(height: 90),
            ],
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(
            children: [
              Expanded(
                child: _SvActionButton(
                  label: '承認する',
                  icon: Icons.check_circle,
                  color: const Color(0xFF22C55E),
                  selected: effectiveAction == SuggestedAction.approveOnly,
                  onTap: () => _decide(SuggestedAction.approveOnly, '承認しました'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _SvActionButton(
                  label: '再調整依頼',
                  icon: Icons.sync_problem,
                  color: const Color(0xFFF59E0B),
                  selected: effectiveAction == SuggestedAction.needsReschedule,
                  onTap: () => _decide(SuggestedAction.needsReschedule, '再調整を依頼しました'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _SvActionButton(
                  label: 'エスカレーション',
                  icon: Icons.priority_high,
                  color: const Color(0xFFEF4444),
                  selected: effectiveAction == SuggestedAction.escalate,
                  onTap: () => _decide(SuggestedAction.escalate, 'エスカレーションしました'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SvActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final bool selected;
  final VoidCallback onTap;
  const _SvActionButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
          decoration: BoxDecoration(
            color: selected ? color.withValues(alpha: 0.25) : color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: color.withValues(alpha: selected ? 0.9 : 0.4), width: selected ? 1.6 : 1.2),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(height: 4),
              Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(color: color, fontSize: 11.5, fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
// ログイン画面(モックアップ:認証ロジックは未実装)
// ============================================================