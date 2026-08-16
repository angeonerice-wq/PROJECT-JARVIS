import 'dart:async';
import 'dart:math' as math;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'firebase_options.dart';
import 'src/before_unload_guard_stub.dart'
    if (dart.library.html) 'src/before_unload_guard_web.dart';

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
      // PC/ワイド画面での応急処置: コンテンツ全体に最大幅を設けて中央寄せにする。
      // 本格的なレスポンシブ対応(PC専用レイアウト)ではなく、モバイル向けUIが
      // 間延びして見えるのを防ぐための暫定対応。各画面(Scaffold)は変更せず、
      // MaterialAppのbuilderでアプリ全体に一括適用する。
      builder: (context, child) {
        return Container(
          color: const Color(0xFF0A0E1A),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 700),
              child: child,
            ),
          ),
        );
      },
      home: const _AuthGate(),
    );
  }
}

/// 起動時にFirebaseの認証状態を確認し、既にログイン済みならログイン画面を
/// 経由せず直接ホーム画面へ進む。ページのリロード後も再ログインが不要になる。
class _AuthGate extends StatelessWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            backgroundColor: Color(0xFF0A0E1A),
            body: Center(
              child: CircularProgressIndicator(color: Colors.cyanAccent),
            ),
          );
        }
        return snapshot.data != null ? const HomePage() : const LoginScreen();
      },
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
  String? supervisorId;

  void _onAuthChanged(User? user) {
    _profileSub?.cancel();
    if (user == null) {
      role = null;
      displayName = null;
      storeId = null;
      supervisorId = null;
      notifyListeners();
      return;
    }
    _profileSub =
        _firestore.collection('users').doc(user.uid).snapshots().listen((doc) {
      final data = doc.data();
      role = _parseUserRole(data?['role']);
      displayName = data?['displayName'] as String?;
      storeId = data?['storeId'] as String?;
      supervisorId = data?['supervisorId'] as String?;
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
    } catch (e) {
      // ログイン自体は成功したがロール確認(Firestore読み取り)などで失敗した場合を含む、
      // FirebaseAuthException以外の予期しないエラー(通信断など)。中途半端な状態を避けるため
      // 念のためサインアウトしておく。
      try {
        await FirebaseAuth.instance.signOut();
      } catch (_) {
        // サインアウト自体の失敗は無視(すでにサインインしていない可能性もあるため)。
      }
      if (!mounted) return;
      setState(() =>
          _errorMessage = '通信エラーが発生しました。通信状況をご確認のうえ、もう一度お試しください。');
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
  SummaryReportTab? _summaryInitialTab;

  @override
  void initState() {
    super.initState();
    // ログイン直後はroleが非同期で確定するため、確定時に再描画してホーム画面を
    // (スタッフ向け⇔SV向けに)切り替えられるようにする。
    UserSession.instance.addListener(_onSessionChanged);
    // 履歴アイコンの未読バッジ(要対応件数)算出に使う。スタッフのみが対象。
    HistoryStore.instance.addListener(_onSessionChanged);
  }

  @override
  void dispose() {
    UserSession.instance.removeListener(_onSessionChanged);
    HistoryStore.instance.removeListener(_onSessionChanged);
    super.dispose();
  }

  void _onSessionChanged() {
    if (mounted) setState(() {});
  }

  /// ホーム画面の「未確認」「要対応」カードから、サマリータブの該当タブを選択した状態で開く。
  void _openSummaryTab(SummaryReportTab tab) {
    setState(() {
      _summaryInitialTab = tab;
      _selectedIndex = 3;
    });
  }

  /// ホーム画面の「要対応」件数タップ・アラートバナーから、履歴タブを開く。
  void _openHistoryTab() {
    setState(() => _selectedIndex = 1);
  }

  @override
  Widget build(BuildContext context) {
    final isSv = UserSession.instance.role == UserRole.sv;

    // 履歴アイコンの未読バッジ件数。ホームの「要対応」カードと同じ条件
    // (エスカレーションはSVが引き取るため含めない)。SVには表示しない。
    final needsRescheduleCount = isSv
        ? 0
        : HistoryStore.instance.entries
            .where((e) => e.reviewedAction == SuggestedAction.needsReschedule)
            .length;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      drawer: const _AppDrawer(),
      body: SafeArea(
        child: IndexedStack(
          index: _selectedIndex,
          children: [
            isSv
                ? _SvHomeTabBody(onOpenSummaryTab: _openSummaryTab)
                : _HomeTabBody(onOpenSummaryTab: _openSummaryTab, onOpenHistoryTab: _openHistoryTab),
            const HistoryTabBody(),
            isSv
                ? _SvHomeTabBody(onOpenSummaryTab: _openSummaryTab)
                : _HomeTabBody(onOpenSummaryTab: _openSummaryTab, onOpenHistoryTab: _openHistoryTab),
            SummaryTabBody(initialTab: _summaryInitialTab),
            const SettingsTabBody(),
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
          BottomNavigationBarItem(
              icon: _NavBadgeIcon(icon: Icons.history, count: needsRescheduleCount),
              label: '履歴'),
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

/// 下部ナビゲーションのアイコンに未読件数バッジ(赤丸+数字)を重ねる。
/// countが0の場合はバッジを出さず、通常のアイコンと同じ見た目にする。
class _NavBadgeIcon extends StatelessWidget {
  final IconData icon;
  final int count;
  const _NavBadgeIcon({required this.icon, required this.count});

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Icon(icon),
        if (count > 0)
          Positioned(
            right: -6,
            top: -4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              constraints: const BoxConstraints(minWidth: 16),
              decoration: BoxDecoration(
                color: const Color(0xFFEF4444),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                count > 9 ? '9+' : '$count',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
              ),
            ),
          ),
      ],
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
            if (UserSession.instance.role == UserRole.sv)
              ListTile(
                leading: const Icon(Icons.assignment_ind_outlined, color: Colors.white70),
                title: const Text('スタッフにタスクを割り当てる', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.of(context).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const AssignTaskScreen()),
                  );
                },
              ),
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

bool _isToday(DateTime dt) {
  final now = DateTime.now();
  return dt.year == now.year && dt.month == now.month && dt.day == now.day;
}

/// 「本日の状況」カードの最終更新表示用。渡されたタイムスタンプ群のうち、
/// 本日(0時以降)かつ最も新しいものを"HH:mm"形式で返す(該当がなければnull)。
String? latestTodayUpdateLabel(Iterable<DateTime> timestamps) {
  DateTime? latest;
  for (final ts in timestamps) {
    if (!_isToday(ts)) continue;
    if (latest == null || ts.isAfter(latest)) latest = ts;
  }
  if (latest == null) return null;
  return '${latest.hour.toString().padLeft(2, '0')}:${latest.minute.toString().padLeft(2, '0')}';
}

/// ホーム画面上部のメニューアイコン+通知ベル。スタッフ用・SV用の両ホーム画面から
/// 共用する(ベルのバッジ件数計算・タップ遷移を1箇所にまとめて重複を避ける)。
class _HomeHeaderBar extends StatefulWidget {
  final void Function(SummaryReportTab tab)? onOpenSummaryTab;

  const _HomeHeaderBar({this.onOpenSummaryTab});

  @override
  State<_HomeHeaderBar> createState() => _HomeHeaderBarState();
}

class _HomeHeaderBarState extends State<_HomeHeaderBar> {
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

  @override
  Widget build(BuildContext context) {
    final isSv = UserSession.instance.role == UserRole.sv;
    // 通知ベルのバッジ件数。統計カードの未確認/要対応(本日分のみ)とは異なり、
    // タップ先のサマリータブと一致させるため全期間で算出する。
    final bellBadgeCount = isSv
        ? filterReportsByTab(SvReportStore.instance.entries, SummaryReportTab.unreviewed)
                .length +
            filterReportsByTab(SvReportStore.instance.entries, SummaryReportTab.needsAction)
                .length
        : 0;

    return Row(
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
        Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: isSv
                ? () => widget.onOpenSummaryTab?.call(SummaryReportTab.unreviewed)
                : null,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  const Icon(Icons.notifications_none, color: Colors.white70, size: 26),
                  if (bellBadgeCount > 0)
                    Positioned(
                      right: -2,
                      top: -2,
                      child: Container(
                        padding: const EdgeInsets.all(3),
                        decoration: const BoxDecoration(
                          color: Colors.redAccent,
                          shape: BoxShape.circle,
                        ),
                        child: Text(
                          bellBadgeCount > 99 ? '99+' : '$bellBadgeCount',
                          style: const TextStyle(
                              color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _HomeTabBody extends StatefulWidget {
  final void Function(SummaryReportTab tab)? onOpenSummaryTab;
  final VoidCallback? onOpenHistoryTab;

  const _HomeTabBody({this.onOpenSummaryTab, this.onOpenHistoryTab});

  @override
  State<_HomeTabBody> createState() => _HomeTabBodyState();
}

class _HomeTabBodyState extends State<_HomeTabBody> {
  @override
  void initState() {
    super.initState();
    HistoryStore.instance.addListener(_onChanged);
    AssignedTaskStore.instance.addListener(_onChanged);
    ReceivedAnnouncementStore.instance.addListener(_onChanged);
  }

  @override
  void dispose() {
    HistoryStore.instance.removeListener(_onChanged);
    AssignedTaskStore.instance.removeListener(_onChanged);
    ReceivedAnnouncementStore.instance.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final entries = HistoryStore.instance.entries;
    final todayEntries = entries.where((e) => _isToday(e.timestamp)).toList();

    final completedTaskCount =
        todayEntries.where((e) => e.category == 'タスク完了').length;
    final unreviewedCount = todayEntries.where((e) => e.reviewedAt == null).length;
    // エスカレーションはSVが引き取って対応するため、スタッフ視点の「要対応」件数には
    // 含めない(再調整依頼のみをカウントする)。
    final needsActionEntries = todayEntries
        .where((e) => e.reviewedAction == SuggestedAction.needsReschedule)
        .toList();
    final needsActionCount = needsActionEntries.length;

    // 「SVからのタスク」の未完了件数。新規購読は追加せず、既に購読済みの
    // HistoryStore(自分が提出した報告。sourceTaskIdが紐づいた完了報告を含む)と
    // AssignedTaskStore(自分に割り当てられた全タスク)を突き合わせて都度算出する。
    final completedTaskIds = completedTaskIdsFrom(HistoryStore.instance.entries);
    final incompleteTaskCount = AssignedTaskStore.instance.entries
        .where((t) => !completedTaskIds.contains(t.id))
        .length;

    // お知らせの未確認件数。confirmedAtがannouncementsドキュメント自身に
    // 直接持たせてあるため、タスクのような報告横断集計は不要。
    final unconfirmedAnnouncementCount = ReceivedAnnouncementStore.instance.entries
        .where((a) => !a.isConfirmed)
        .length;

    // 「本日の状況」カードの最終更新時刻。このカードが参照している3つのデータソース
    // (自分の報告/割り当てられたタスク/受信したお知らせ)のうち、本日分の最新timestampを表示する。
    final todayUpdateLabel = latestTodayUpdateLabel([
      ...entries.map((e) => e.timestamp),
      ...AssignedTaskStore.instance.entries.map((t) => t.createdAt),
      ...ReceivedAnnouncementStore.instance.entries.map((a) => a.createdAt),
    ]);

    // ホーム画面のお知らせ・タスクセクションに表示するカード。該当件数が0のものは
    // 含めない(カードごと非表示にするため)。
    final noticeCards = <Widget>[
      if (incompleteTaskCount > 0)
        _HomeNoticeCard(
          icon: Icons.assignment_ind_outlined,
          iconColor: const Color(0xFFF97316),
          title: 'SVからのタスク',
          count: incompleteTaskCount,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const AssignedTasksScreen()),
          ),
        ),
      if (unconfirmedAnnouncementCount > 0)
        _HomeNoticeCard(
          icon: Icons.campaign_outlined,
          iconColor: const Color(0xFF06B6D4),
          title: 'SVからのお知らせ',
          count: unconfirmedAnnouncementCount,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const AnnouncementsScreen()),
          ),
        ),
      if (needsActionCount > 0)
        _HomeNoticeCard(
          icon: Icons.error_outline,
          iconColor: const Color(0xFFEF4444),
          title: '要対応の報告',
          count: needsActionCount,
          onTap: () {
            // 1件だけなら該当報告の詳細に直接遷移し、複数件ある場合は
            // どれを開くか選べるよう履歴タブを開く(スクロール等は行わない)。
            if (needsActionEntries.length == 1) {
              final entry = needsActionEntries.first;
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => SvSummaryScreen(
                    summary: SvReportSummary(
                      id: entry.id,
                      category: entry.category,
                      icon: entry.icon,
                      color: entry.color,
                      time: entry.time,
                      fields: entry.fields,
                      action: entry.action,
                      history: entry.history,
                      reviewedAction: entry.reviewedAction,
                    ),
                  ),
                ),
              );
            } else {
              widget.onOpenHistoryTab?.call();
            }
          },
        ),
    ];

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          _HomeHeaderBar(onOpenSummaryTab: widget.onOpenSummaryTab),
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
              // お知らせ・タスクなど、SVから届いた項目のセクション。「SVからのタスク」
              // 「SVからのお知らせ」のように_HomeNoticeCardを1つ追加するだけで
              // 並べられる構造にしている(Columnにspacingを指定しているので、
              // 複数枚並んでも自然に間隔が空く)。
              // 該当件数が0の項目はカードごと非表示にするため、noticeCardsが空の場合は
              // セクション自体(前後の余白含め)を丸ごと出さない。
              if (noticeCards.isNotEmpty) ...[
                const SizedBox(height: 24),
                Column(spacing: 12, children: noticeCards),
              ],
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
                    titleFontSize: 14,
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
                    titleFontSize: 14,
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
                    titleFontSize: 14,
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
                    title: '業務完了​確認',
                    titleFontSize: 14,
                    icon: Icons.fact_check,
                    color: const Color(0xFF06B6D4),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const BusinessCompletionChatScreen(),
                        ),
                      );
                    },
                  ),
                  CategoryCard(
                    title: 'その他',
                    titleFontSize: 14,
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
                    titleFontSize: 14,
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
                            Text(
                                todayUpdateLabel != null
                                    ? '最終更新 $todayUpdateLabel'
                                    : '最終更新 -',
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
                      children: [
                        StatItem(
                            icon: Icons.people,
                            color: Colors.blueAccent,
                            label: '全体稼働',
                            value: '-',
                            onTap: null),
                        StatItem(
                            icon: Icons.check_circle,
                            color: Colors.greenAccent,
                            label: '完了タスク',
                            value: '$completedTaskCount件',
                            onTap: null),
                        StatItem(
                            icon: Icons.warning_amber,
                            color: Colors.amber,
                            label: '未確認',
                            value: '$unreviewedCount件',
                            onTap: null),
                        StatItem(
                            icon: Icons.error_outline,
                            color: Colors.redAccent,
                            label: '要対応',
                            value: '$needsActionCount件',
                            onTap: widget.onOpenHistoryTab),
                        StatItem(
                            icon: Icons.campaign_outlined,
                            color: const Color(0xFF06B6D4),
                            label: 'お知らせ',
                            value: '$unconfirmedAnnouncementCount件',
                            onTap: () => Navigator.of(context).push(
                                  MaterialPageRoute(builder: (_) => const AnnouncementsScreen()),
                                )),
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

/// ホーム画面上部の「お知らせ・タスク」セクションで使う汎用カード。
/// アイコン+タイトル+件数+タップ遷移、という共通の見た目を1箇所にまとめておくことで、
/// 新しい通知種別が増えてもこのウィジェットを1つ追加するだけで済むようにする
/// (現在は「SVからのタスク」「SVからのお知らせ」の2種)。
class _HomeNoticeCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final int count;
  final VoidCallback onTap;

  const _HomeNoticeCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.count,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF141826),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white10),
          ),
          child: Row(
            children: [
              Icon(icon, color: iconColor, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Text(title,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
              ),
              Text('$count件', style: TextStyle(color: Colors.grey[400], fontSize: 13)),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right, color: Colors.white38, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

/// SV専用のホーム画面。スタッフ向けの6カテゴリ報告カードの代わりに、
/// SVの役割6項目(相談・報告受領/タスクを送る/既読・完了確認/お知らせ配信/
/// 稼働確認/スタッフ別管理)へのナビゲーションと、当日の集計サマリー
/// (「本日の状況」カード。旧`_HomeTabBody`のisSv分岐から移植)を表示する。
class _SvHomeTabBody extends StatefulWidget {
  final void Function(SummaryReportTab tab)? onOpenSummaryTab;

  const _SvHomeTabBody({this.onOpenSummaryTab});

  @override
  State<_SvHomeTabBody> createState() => _SvHomeTabBodyState();
}

class _SvHomeTabBodyState extends State<_SvHomeTabBody> {
  @override
  void initState() {
    super.initState();
    SvReportStore.instance.addListener(_onChanged);
    StaffRosterStore.instance.addListener(_onChanged);
  }

  @override
  void dispose() {
    SvReportStore.instance.removeListener(_onChanged);
    StaffRosterStore.instance.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final todayEntries =
        SvReportStore.instance.entries.where((e) => _isToday(e.timestamp)).toList();
    final totalStaffCount = StaffRosterStore.instance.staffCount;

    final absentCount = todayEntries
        .where((e) => e.category == '勤怠(欠勤)' || e.category == '勤怠(遅刻)')
        .length;
    final activeCount = (totalStaffCount - absentCount).clamp(0, totalStaffCount);
    final completedTaskCount =
        todayEntries.where((e) => e.category == 'タスク完了').length;
    final unreviewedCount = todayEntries.where((e) => e.reviewedAt == null).length;
    final needsActionCount = todayEntries
        .where((e) =>
            e.reviewedAction == SuggestedAction.needsReschedule ||
            e.reviewedAction == SuggestedAction.escalate)
        .length;

    // 「本日の状況」カードの最終更新時刻。このカードの4項目は全てSvReportStore
    // (自チームのreports)から算出しているため、その本日分の最新timestampを表示する。
    final todayUpdateLabel =
        latestTodayUpdateLabel(SvReportStore.instance.entries.map((e) => e.timestamp));

    // ホーム画面上部の通知バー。スタッフ側の`noticeCards`と対称の設計で、該当件数が
    // 0の項目はカードごと非表示にする。件数・タップ先は下の「本日の状況」カードの
    // 未確認/要対応スタットと同じもの(todayEntries基準)をそのまま使う。
    final svNoticeCards = <Widget>[
      if (unreviewedCount > 0)
        _HomeNoticeCard(
          icon: Icons.warning_amber,
          iconColor: Colors.amber,
          title: '未確認の報告',
          count: unreviewedCount,
          onTap: () => widget.onOpenSummaryTab?.call(SummaryReportTab.unreviewed),
        ),
      if (needsActionCount > 0)
        _HomeNoticeCard(
          icon: Icons.error_outline,
          iconColor: Colors.redAccent,
          title: '要対応の報告',
          count: needsActionCount,
          onTap: () => widget.onOpenSummaryTab?.call(SummaryReportTab.needsAction),
        ),
    ];

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          _HomeHeaderBar(onOpenSummaryTab: widget.onOpenSummaryTab),
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
              'SVメニュー',
              style: TextStyle(color: Colors.grey[400], fontSize: 15),
            ),
          ),
          if (svNoticeCards.isNotEmpty) ...[
            const SizedBox(height: 24),
            Column(spacing: 12, children: svNoticeCards),
          ],
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
                        Text(
                            todayUpdateLabel != null
                                ? '最終更新 $todayUpdateLabel'
                                : '最終更新 -',
                            style: TextStyle(color: Colors.grey[500], fontSize: 12)),
                        const SizedBox(width: 4),
                        Icon(Icons.refresh, color: Colors.grey[500], size: 14),
                      ],
                    ),
                  ],
                ),
                const Divider(color: Colors.white12, height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    StatItem(
                        icon: Icons.people,
                        color: Colors.blueAccent,
                        label: '全体稼働',
                        value: '$activeCount/$totalStaffCount名',
                        onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) => const AttendanceOverviewScreen()),
                            )),
                    StatItem(
                        icon: Icons.check_circle,
                        color: Colors.greenAccent,
                        label: '完了タスク',
                        value: '$completedTaskCount件',
                        onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) => const CompletedTasksScreen()),
                            )),
                    StatItem(
                        icon: Icons.warning_amber,
                        color: Colors.amber,
                        label: '未確認',
                        value: '$unreviewedCount件',
                        onTap: () =>
                            widget.onOpenSummaryTab?.call(SummaryReportTab.unreviewed)),
                    StatItem(
                        icon: Icons.error_outline,
                        color: Colors.redAccent,
                        label: '要対応',
                        value: '$needsActionCount件',
                        onTap: () =>
                            widget.onOpenSummaryTab?.call(SummaryReportTab.needsAction)),
                  ],
                ),
              ],
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
                title: '相談・報告​受領',
                titleFontSize: 14,
                icon: Icons.inbox,
                color: const Color(0xFF3B82F6),
                onTap: () => widget.onOpenSummaryTab?.call(SummaryReportTab.unreviewed),
              ),
              CategoryCard(
                title: 'タスク配信',
                titleFontSize: 14,
                icon: Icons.assignment_ind_outlined,
                color: const Color(0xFFF97316),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const AssignTaskScreen()),
                  );
                },
              ),
              CategoryCard(
                title: '既読・完了​確認',
                titleFontSize: 14,
                icon: Icons.fact_check_outlined,
                color: const Color(0xFF22C55E),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const SentTasksScreen()),
                  );
                },
              ),
              CategoryCard(
                title: 'お知らせ​配信',
                titleFontSize: 14,
                icon: Icons.campaign_outlined,
                color: const Color(0xFF06B6D4),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const AnnouncementSendScreen()),
                  );
                },
              ),
              CategoryCard(
                title: '稼働確認',
                titleFontSize: 14,
                icon: Icons.people_outline,
                color: const Color(0xFFA855F7),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const AttendanceOverviewScreen()),
                  );
                },
              ),
              CategoryCard(
                title: 'スタッフ別​管理',
                titleFontSize: 14,
                icon: Icons.manage_accounts_outlined,
                color: const Color(0xFF64748B),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const StaffManagementListScreen()),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class CategoryCard extends StatelessWidget {
  final String title;
  final String? subtitle;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final double titleFontSize;

  const CategoryCard({
    super.key,
    required this.title,
    this.subtitle,
    required this.icon,
    required this.color,
    required this.onTap,
    this.titleFontSize = 16,
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
                          child: _CategoryCardTitle(title: title, fontSize: titleFontSize),
                        ),
                        const Icon(Icons.chevron_right, color: Colors.white70, size: 18),
                      ],
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        subtitle!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 11, height: 1.3),
                      ),
                    ],
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

/// CategoryCardのタイトル表示。CJK文字は文字間のどこでも自動改行されうるため、
/// 単純にmaxLines:2を指定するだけでは「幅に入るところまで詰めて折り返す」動きになり、
/// 意味のある区切り位置(例:「相談・報告」/「受領」)と一致しない。
/// titleにゼロ幅スペース(​)が含まれる場合、それを「2行に分けてよい唯一の
/// 区切り位置」として扱い、区切られた各グループを別々のTextとしてWrapに渡す。
/// Wrapは子を「幅が足りなければ丸ごと次の行に送る」ため、グループ内部で
/// 文字単位に割れることがなく、幅に収まる時は隙間なく1行に並ぶ。
/// (以前はTextPainterで事前に幅を計測して分岐を決めていたが、フォント読み込みが
/// 完了する前の計測結果に基づいて分岐が固定されてしまい、読み込み完了後の実際の
/// 描画とズレて見切れる問題があった。Wrapは通常のレイアウトパイプラインで
/// 都度改行を決めるため、フォント読み込み完了後の再レイアウトにも正しく追従する)
class _CategoryCardTitle extends StatelessWidget {
  final String title;
  final double fontSize;
  const _CategoryCardTitle({required this.title, required this.fontSize});

  @override
  Widget build(BuildContext context) {
    final style =
        TextStyle(color: Colors.white, fontSize: fontSize, fontWeight: FontWeight.bold);
    final groups = title.split('​').where((g) => g.isNotEmpty).toList();
    return Wrap(
      children: [
        for (final group in groups)
          Text(group, maxLines: 1, overflow: TextOverflow.ellipsis, softWrap: false, style: style),
      ],
    );
  }
}

class StatItem extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final String value;
  final VoidCallback? onTap;

  const StatItem({
    super.key,
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final content = Column(
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
    if (onTap == null) return content;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: content,
        ),
      ),
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

/// 各報告・相談チャット画面の先頭に表示する、その画面が何のためのものかを示す案内文。
/// ホーム画面のCategoryCardの説明文(勤怠なら「欠勤・遅刻の連絡はこちら」等)と同じ
/// 内容をチャット画面内向けの言い回しに変えたもの。
class _ChatGuidanceBanner extends StatelessWidget {
  final String text;
  const _ChatGuidanceBanner({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF141826),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, color: Colors.grey[500], size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: Colors.grey[400], fontSize: 12.5, height: 1.4),
            ),
          ),
        ],
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
  final DateTime? approvedAt;
  final String? reviewedBy;
  final DateTime? reviewedAt;
  final SuggestedAction? reviewedAction;
  final String? sourceTaskId;
  final String? announcementId;
  final String? sourceReportId;

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
    this.approvedAt,
    this.reviewedBy,
    this.reviewedAt,
    this.reviewedAction,
    this.sourceTaskId,
    this.announcementId,
    this.sourceReportId,
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
      // 値がある時だけキーを含める。sourceTaskId/announcementId/sourceReportIdを
      // 使わないフローのドキュメントに不要な `null` フィールドが付与されるのを避けるため。
      if (sourceTaskId != null) 'sourceTaskId': sourceTaskId,
      if (announcementId != null) 'announcementId': announcementId,
      if (sourceReportId != null) 'sourceReportId': sourceReportId,
    };
  }

  factory HistoryEntry.fromFirestore(String id, Map<String, dynamic> data) {
    final ts = data['timestamp'];
    final approvedTs = data['approvedAt'];
    final reviewedTs = data['reviewedAt'];
    return HistoryEntry(
      id: id,
      staffId: data['staffId'] as String?,
      staffName: data['staffName'] as String?,
      category: data['category'] as String? ?? '',
      title: data['title'] as String? ?? '',
      timestamp: ts is Timestamp ? ts.toDate() : DateTime.now(),
      approvedAt: approvedTs is Timestamp ? approvedTs.toDate() : null,
      reviewedBy: data['reviewedBy'] as String?,
      reviewedAt: reviewedTs is Timestamp ? reviewedTs.toDate() : null,
      reviewedAction: SuggestedAction.values
          .where((a) => a.name == data['reviewedAction'])
          .firstOrNull,
      sourceTaskId: data['sourceTaskId'] as String?,
      announcementId: data['announcementId'] as String?,
      sourceReportId: data['sourceReportId'] as String?,
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

/// 報告送信前にドキュメントIDを払い出す。オフライン時のタイムアウト後に
/// ユーザーが再送信しても同じIDへの書き込みになるよう、`HistoryEntry`生成時点で
/// (Firestoreへの書き込みより前に)呼び出しておく。
String generateReportId() =>
    FirebaseFirestore.instance.collection('reports').doc().id;

/// カテゴリ単位で「まだ成功が確認できていない送信」のドキュメントIDを覚えておく。
/// 送信中(オフラインでキューされたままなど)に画面を離脱し、同じカテゴリの報告フローを
/// もう一度最初からやり直した場合、新しいIDで新規ドキュメントを作ってしまうと
/// 前回の送信がオンライン復帰時に反映された分と合わせて2件の重複報告になる。
/// 同じカテゴリではIDを使い回す(=同じドキュメントへの上書き)ことで、
/// 最終的にFirestoreに残るのは一番最後に送信した内容のみになり、重複を防げる。
/// 送信が成功した時点でrelease()し、次回は新規IDになるようにする。
class PendingSubmissionRegistry {
  PendingSubmissionRegistry._() {
    FirebaseAuth.instance.authStateChanges().listen((_) => _pending.clear());
  }
  static final PendingSubmissionRegistry instance = PendingSubmissionRegistry._();

  final Map<String, String> _pending = {};

  String claim(String category) => _pending[category] ??= generateReportId();

  void release(String category) => _pending.remove(category);
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

/// まだ実装が用意できていない項目のタップ時に表示する簡易ダイアログ。
/// 設定タブ(利用規約・プライバシーポリシー)・SVホーム画面(未実装項目)で共用する。
void showComingSoonDialog(BuildContext context, String label) {
  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: const Color(0xFF141826),
      title: Text(label, style: const TextStyle(color: Colors.white)),
      content: const Text('準備中です。今しばらくお待ちください。',
          style: TextStyle(color: Colors.white70)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('閉じる'),
        ),
      ],
    ),
  );
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
    case '業務完了確認':
      return (icon: Icons.fact_check, color: const Color(0xFF06B6D4));
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
  /// supervisorIdは投稿者自身の`users`ドキュメントから取得した値をそのままコピーする
  /// (SVがチーム単位でreportsを絞り込むためのクエリ用、非正規化フィールド)。
  ///
  /// entry.id(呼び出し側で事前に払い出したドキュメントID)に対して`set`する。
  /// オフライン時、Firestoreはこの書き込みをキューイングして待ち続け例外を投げないため、
  /// 一定時間で諦めて呼び出し側にエラーとして伝えるために`timeout`を掛けている。
  /// その際、自動採番の`add()`だと再送信で新規ドキュメントが生成され、元のキューイング済み
  /// 書き込みがオンライン復帰時に反映されると報告が重複してしまう。`entry.id`への`set`に
  /// することで、再送信は同じドキュメントへの上書きになり重複を防げる。
  Future<void> add(HistoryEntry entry) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final docId = entry.id ?? _firestore.collection('reports').doc().id;
    await _firestore.collection('reports').doc(docId).set({
      ...entry.toMap(),
      'staffId': uid,
      'staffName': UserSession.instance.displayName,
      'storeId': null,
      'supervisorId': UserSession.instance.supervisorId,
    }).timeout(const Duration(seconds: 10));
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

/// SVログイン時に自分のチーム(supervisorId == 自分のuid)のスタッフの`reports`を
/// 購読するストア。role="sv"でないユーザーで全件クエリを投げるとセキュリティルールにより
/// 拒否されるため、UserSessionでSVと確認できてから購読を開始する。
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

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (!nowSv || uid == null) {
      _entries = [];
      notifyListeners();
      return;
    }

    _entriesSub = _firestore
        .collection('reports')
        .where('supervisorId', isEqualTo: uid)
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

/// SVが自分自身で対応(承認/再調整依頼/エスカレーション)した報告を購読するストア。
/// 履歴タブでSVに「自分が対応した報告」を表示するために使う。
class SvHistoryStore extends ChangeNotifier {
  SvHistoryStore._() {
    UserSession.instance.addListener(_onSessionChanged);
    _onSessionChanged();
  }
  static final SvHistoryStore instance = SvHistoryStore._();

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

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (!nowSv || uid == null) {
      _entries = [];
      notifyListeners();
      return;
    }

    _entriesSub = _firestore
        .collection('reports')
        .where('reviewedBy', isEqualTo: uid)
        .orderBy('reviewedAt', descending: true)
        .snapshots()
        .listen((snapshot) {
      _entries = snapshot.docs
          .map((doc) => HistoryEntry.fromFirestore(doc.id, doc.data()))
          .toList();
      notifyListeners();
    }, onError: (Object e, StackTrace st) {
      debugPrint('[SvHistoryStore] snapshot error: $e');
    });
  }

  @override
  void dispose() {
    UserSession.instance.removeListener(_onSessionChanged);
    _entriesSub?.cancel();
    super.dispose();
  }
}

/// SVが自分の配下(supervisorId == 自分のuid)のスタッフ人数を購読するストア。
/// ホーム画面の「全体稼働」の分母に使う。usersコレクション全体は読めないため、
/// 必ずsupervisorIdで絞り込んだクエリを投げる。
/// 配下スタッフのuid・表示名(勤怠一覧などで「誰が」を表示するために使用)。
class StaffProfile {
  final String uid;
  final String? displayName;
  const StaffProfile({required this.uid, this.displayName});
}

class StaffRosterStore extends ChangeNotifier {
  StaffRosterStore._() {
    UserSession.instance.addListener(_onSessionChanged);
    _onSessionChanged();
  }
  static final StaffRosterStore instance = StaffRosterStore._();

  final _firestore = FirebaseFirestore.instance;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _staffSub;
  List<StaffProfile> _staff = [];
  bool _isSv = false;

  List<StaffProfile> get staff => List.unmodifiable(_staff);
  int get staffCount => _staff.length;

  void _onSessionChanged() {
    final nowSv = UserSession.instance.role == UserRole.sv;
    if (nowSv == _isSv) return;
    _isSv = nowSv;
    _staffSub?.cancel();

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (!nowSv || uid == null) {
      _staff = [];
      notifyListeners();
      return;
    }

    _staffSub = _firestore
        .collection('users')
        .where('supervisorId', isEqualTo: uid)
        .snapshots()
        .listen((snapshot) {
      _staff = snapshot.docs
          .map((doc) => StaffProfile(
                uid: doc.id,
                displayName: doc.data()['displayName'] as String?,
              ))
          .toList();
      notifyListeners();
    }, onError: (Object e, StackTrace st) {
      debugPrint('[StaffRosterStore] snapshot error: $e');
    });
  }

  @override
  void dispose() {
    UserSession.instance.removeListener(_onSessionChanged);
    _staffSub?.cancel();
    super.dispose();
  }
}

/// SVがスタッフへ割り当てたタスク(`tasks`コレクション)のクライアント用モデル。
class AssignedTask {
  final String id;
  final String staffId;
  final String assignedBy;
  final String? assignedByName;
  final String title;
  final String detail;
  final DateTime createdAt;

  const AssignedTask({
    required this.id,
    required this.staffId,
    required this.assignedBy,
    this.assignedByName,
    required this.title,
    required this.detail,
    required this.createdAt,
  });

  String get time => formatRelativeTime(createdAt);

  factory AssignedTask.fromFirestore(String id, Map<String, dynamic> data) {
    final ts = data['createdAt'];
    return AssignedTask(
      id: id,
      staffId: data['staffId'] as String? ?? '',
      assignedBy: data['assignedBy'] as String? ?? '',
      assignedByName: data['assignedByName'] as String?,
      title: data['title'] as String? ?? '',
      detail: data['detail'] as String? ?? '',
      createdAt: ts is Timestamp ? ts.toDate() : DateTime.now(),
    );
  }
}

/// ログイン中スタッフに割り当てられたタスクをリアルタイム購読するストア。
/// `HistoryStore`と同型のパターン(authStateChanges()を直接見て、staffId一致で
/// フィルタ購読する)を踏襲している。taskのstaffIdは常にスタッフのuidになる設計
/// (AssignTaskScreenのスタッフ選択がSVの配下スタッフのみのため)なので、
/// SvReportStoreのような「role==svの時だけ購読」というロール判定は不要。
class AssignedTaskStore extends ChangeNotifier {
  AssignedTaskStore._() {
    _authSub = FirebaseAuth.instance.authStateChanges().listen(_onAuthChanged);
  }
  static final AssignedTaskStore instance = AssignedTaskStore._();

  final _firestore = FirebaseFirestore.instance;
  StreamSubscription<User?>? _authSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _entriesSub;
  List<AssignedTask> _entries = [];

  List<AssignedTask> get entries => List.unmodifiable(_entries);

  void _onAuthChanged(User? user) {
    _entriesSub?.cancel();
    if (user == null) {
      _entries = [];
      notifyListeners();
      return;
    }
    _entriesSub = _firestore
        .collection('tasks')
        .where('staffId', isEqualTo: user.uid)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .listen((snapshot) {
      _entries = snapshot.docs
          .map((doc) => AssignedTask.fromFirestore(doc.id, doc.data()))
          .toList();
      notifyListeners();
    }, onError: (Object e, StackTrace st) {
      debugPrint('[AssignedTaskStore] snapshot error: $e');
    });
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _entriesSub?.cancel();
    super.dispose();
  }
}

/// SVが自分自身で割り当てた(assignedBy==自分uid)タスクをリアルタイム購読するストア。
/// AssignedTaskStoreと全く同じ構造で、フィールドをstaffId→assignedByに変えただけ。
/// assignedByは常にSVのuidになる設計(スタッフはtasksを作成できない)なので、
/// AssignedTaskStoreと同様ロールでの絞り込みは行わない(スタッフで実行しても0件になるだけ)。
class SentTaskStore extends ChangeNotifier {
  SentTaskStore._() {
    _authSub = FirebaseAuth.instance.authStateChanges().listen(_onAuthChanged);
  }
  static final SentTaskStore instance = SentTaskStore._();

  final _firestore = FirebaseFirestore.instance;
  StreamSubscription<User?>? _authSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _entriesSub;
  List<AssignedTask> _entries = [];

  List<AssignedTask> get entries => List.unmodifiable(_entries);

  void _onAuthChanged(User? user) {
    _entriesSub?.cancel();
    if (user == null) {
      _entries = [];
      notifyListeners();
      return;
    }
    _entriesSub = _firestore
        .collection('tasks')
        .where('assignedBy', isEqualTo: user.uid)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .listen((snapshot) {
      _entries = snapshot.docs
          .map((doc) => AssignedTask.fromFirestore(doc.id, doc.data()))
          .toList();
      notifyListeners();
    }, onError: (Object e, StackTrace st) {
      debugPrint('[SentTaskStore] snapshot error: $e');
    });
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _entriesSub?.cancel();
    super.dispose();
  }
}

// ============================================================
// SVによるお知らせ配信(タスクとは別コレクション。完了/問い合わせの概念を持たず、
// 「確認済みかどうか」はannouncementsドキュメント自身のconfirmedAtで直接管理する)
// ============================================================

class Announcement {
  final String id;
  final String staffId;
  final String sentBy;
  final String? sentByName;
  final String title;
  final String body;
  final DateTime createdAt;
  final DateTime? confirmedAt;

  const Announcement({
    required this.id,
    required this.staffId,
    required this.sentBy,
    this.sentByName,
    required this.title,
    required this.body,
    required this.createdAt,
    this.confirmedAt,
  });

  String get time => formatRelativeTime(createdAt);
  bool get isConfirmed => confirmedAt != null;

  factory Announcement.fromFirestore(String id, Map<String, dynamic> data) {
    final ts = data['createdAt'];
    final confirmedTs = data['confirmedAt'];
    return Announcement(
      id: id,
      staffId: data['staffId'] as String? ?? '',
      sentBy: data['sentBy'] as String? ?? '',
      sentByName: data['sentByName'] as String?,
      title: data['title'] as String? ?? '',
      body: data['body'] as String? ?? '',
      createdAt: ts is Timestamp ? ts.toDate() : DateTime.now(),
      confirmedAt: confirmedTs is Timestamp ? confirmedTs.toDate() : null,
    );
  }
}

/// ログイン中スタッフ宛のお知らせをリアルタイム購読するストア。AssignedTaskStoreと同型。
class ReceivedAnnouncementStore extends ChangeNotifier {
  ReceivedAnnouncementStore._() {
    _authSub = FirebaseAuth.instance.authStateChanges().listen(_onAuthChanged);
  }
  static final ReceivedAnnouncementStore instance = ReceivedAnnouncementStore._();

  final _firestore = FirebaseFirestore.instance;
  StreamSubscription<User?>? _authSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _entriesSub;
  List<Announcement> _entries = [];

  List<Announcement> get entries => List.unmodifiable(_entries);

  void _onAuthChanged(User? user) {
    _entriesSub?.cancel();
    if (user == null) {
      _entries = [];
      notifyListeners();
      return;
    }
    _entriesSub = _firestore
        .collection('announcements')
        .where('staffId', isEqualTo: user.uid)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .listen((snapshot) {
      _entries = snapshot.docs
          .map((doc) => Announcement.fromFirestore(doc.id, doc.data()))
          .toList();
      notifyListeners();
    }, onError: (Object e, StackTrace st) {
      debugPrint('[ReceivedAnnouncementStore] snapshot error: $e');
    });
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _entriesSub?.cancel();
    super.dispose();
  }
}

/// SVが自分自身で送信した(sentBy==自分uid)お知らせをリアルタイム購読するストア。
/// SentTaskStoreと同じ構造。
class SentAnnouncementStore extends ChangeNotifier {
  SentAnnouncementStore._() {
    _authSub = FirebaseAuth.instance.authStateChanges().listen(_onAuthChanged);
  }
  static final SentAnnouncementStore instance = SentAnnouncementStore._();

  final _firestore = FirebaseFirestore.instance;
  StreamSubscription<User?>? _authSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _entriesSub;
  List<Announcement> _entries = [];

  List<Announcement> get entries => List.unmodifiable(_entries);

  void _onAuthChanged(User? user) {
    _entriesSub?.cancel();
    if (user == null) {
      _entries = [];
      notifyListeners();
      return;
    }
    _entriesSub = _firestore
        .collection('announcements')
        .where('sentBy', isEqualTo: user.uid)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .listen((snapshot) {
      _entries = snapshot.docs
          .map((doc) => Announcement.fromFirestore(doc.id, doc.data()))
          .toList();
      notifyListeners();
    }, onError: (Object e, StackTrace st) {
      debugPrint('[SentAnnouncementStore] snapshot error: $e');
    });
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _entriesSub?.cancel();
    super.dispose();
  }
}

/// sourceTaskIdが紐づいた報告(タスク完了・業務相談など)を、タスクIDごとに
/// グルーピングする。1つのタスクに完了報告と問い合わせの両方が紐づくこともあるため、
/// 単純な真偽値ではなくリストで持たせておき、呼び出し側で必要なカテゴリだけを
/// 見るようにする(ホーム画面・タスク一覧・SVの送信済みタスク一覧などで共用)。
Map<String, List<HistoryEntry>> taskLinkedReportsFrom(List<HistoryEntry> entries) {
  final map = <String, List<HistoryEntry>>{};
  for (final e in entries) {
    final taskId = e.sourceTaskId;
    if (taskId == null) continue;
    map.putIfAbsent(taskId, () => []).add(e);
  }
  return map;
}

/// sourceTaskIdが紐づいた「タスク完了」報告から、完了済みタスクIDの集合を求める。
/// 「問い合わせ」(業務相談カテゴリ)もsourceTaskIdを持つが、これはタスクの完了を
/// 意味しないため、category=='タスク完了'に限定して判定する。ホーム画面の未完了件数
/// (_HomeTabBody)とタスク一覧(AssignedTasksScreen)の両方で使う共通ロジック。
Set<String> completedTaskIdsFrom(List<HistoryEntry> entries) {
  final grouped = taskLinkedReportsFrom(entries);
  return grouped.entries
      .where((e) => e.value.any((r) => r.category == 'タスク完了'))
      .map((e) => e.key)
      .toSet();
}

/// 指定スタッフの、指定カテゴリ(前方一致)の今月の件数を数える。
/// HistoryStore.countThisMonthと同じロジックだが、「ログイン中の自分」専用ではなく
/// SVが任意の配下スタッフ(staffId)について集計できるようにしたもの(スタッフ別管理画面用)。
int monthlyCategoryCountForStaff(
  List<HistoryEntry> entries,
  String staffId,
  String categoryPrefix,
) {
  final now = DateTime.now();
  return entries.where((e) {
    return e.staffId == staffId &&
        e.category.startsWith(categoryPrefix) &&
        e.timestamp.year == now.year &&
        e.timestamp.month == now.month;
  }).length;
}

/// announcementIdが紐づいた報告(問い合わせ=業務相談)を、お知らせIDごとに
/// グルーピングする。taskLinkedReportsFromと同じ考え方だが、お知らせの確認済み状態は
/// announcementsドキュメント自身のconfirmedAtで持つため、ここでは問い合わせの有無判定のみに使う。
Map<String, List<HistoryEntry>> announcementLinkedReportsFrom(List<HistoryEntry> entries) {
  final map = <String, List<HistoryEntry>>{};
  for (final e in entries) {
    final announcementId = e.announcementId;
    if (announcementId == null) continue;
    map.putIfAbsent(announcementId, () => []).add(e);
  }
  return map;
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

/// 会話完了後の送信状態を表示する共通ウィジェット。
/// 送信中はスピナー、失敗時は再送信ボタンを表示する(成功時は何も表示しない=非表示)。
class _SubmitStatusBar extends StatelessWidget {
  final bool isSaving;
  final VoidCallback onRetry;
  const _SubmitStatusBar({required this.isSaving, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    if (isSaving) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70),
            ),
            SizedBox(width: 10),
            Text('送信中...', style: TextStyle(color: Colors.white70, fontSize: 13)),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('再送信する'),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.white,
            side: const BorderSide(color: Colors.white24),
          ),
        ),
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
  bool _isSaving = false;
  bool _saveFailed = false;
  HistoryEntry? _pendingEntry;

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
      id: PendingSubmissionRegistry.instance.claim('勤怠($typeLabel)'),
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

    await _submitEntry(entry);
  }

  Future<void> _submitEntry(HistoryEntry entry) async {
    setState(() {
      _isSaving = true;
      _saveFailed = false;
    });
    BeforeUnloadGuard.enable();
    try {
      await HistoryStore.instance.add(entry);
      PendingSubmissionRegistry.instance.release(entry.category);
      BeforeUnloadGuard.disable();
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _pendingEntry = null;
      });
      _addJarvisMessage('ありがとうございます。内容を確認し、SVに共有しました。');
    } catch (_) {
      BeforeUnloadGuard.disable();
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _saveFailed = true;
        _pendingEntry = entry;
      });
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
            const _ChatGuidanceBanner(text: 'ここは欠勤・遅刻の連絡用チャット欄です。'),
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
              )
            else if (_isSaving || _saveFailed)
              _SubmitStatusBar(
                isSaving: _isSaving,
                onRetry: () {
                  if (_pendingEntry != null) _submitEntry(_pendingEntry!);
                },
              ),
          ],
        ),
      ),
    );
  }
}


/// 所属ごとの役職選択肢。「顧客」はキーを持たない(役職質問自体をスキップする)。
const Map<String, List<String>> _positionOptionsByAffiliation = {
  '店舗社員': ['店長', '副店長', 'フロア長', '部門長', '主任', 'マネージャー'],
  'ドコモ': ['CS営業', '代理店営業', 'リーダー', '一般スタッフ'],
  'Softbank': ['部長', '課長', 'エリアマネージャー', 'SV', 'リーダー', '一般スタッフ'],
  'KDDI': ['グループリーダー', '営業', 'CSA', 'リーダー', '一般スタッフ'],
};

class _WorkReportData {
  String? whenWhere; // いつ・どこで
  String? affiliation; // 店舗社員 / ドコモ / KDDI / Softbank / 顧客
  String? position; // 役職(affiliation=='顧客'の場合は使わない)
  String? personName; // 名前
  String? content; // 何があった/何を言われたか
  String? background; // 背景・状況(不明可)
  String? request; // どうしてほしいか

  bool get hasWhenWhere => whenWhere != null && whenWhere!.trim().isNotEmpty;
  bool get hasAffiliation => affiliation != null;
  bool get needsPosition => affiliation != null && affiliation != '顧客';
  bool get positionOk => !needsPosition || position != null;
  bool get hasPersonName => personName != null && personName!.trim().isNotEmpty;
  bool get hasContent => content != null && content!.trim().isNotEmpty;
  bool get hasBackground => background != null && background!.trim().isNotEmpty;
  bool get hasRequest => request != null && request!.trim().isNotEmpty;
  bool get isComplete =>
      hasWhenWhere &&
      hasAffiliation &&
      positionOk &&
      hasPersonName &&
      hasContent &&
      hasBackground &&
      hasRequest;
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
  bool _awaitingAffiliationChoice = false;
  bool _awaitingPositionChoice = false;
  bool _lastAskedWhenWhere = false;
  bool _lastAskedPersonName = false;
  bool _lastAskedContent = false;
  bool _lastAskedBackground = false;
  bool _lastAskedRequest = false;
  bool _isSaving = false;
  bool _saveFailed = false;
  HistoryEntry? _pendingEntry;

  @override
  void initState() {
    super.initState();
    _addJarvis('お疲れ様です。いつ・どこでの出来事か教えてください。');
    _lastAskedWhenWhere = true;
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

    if (_lastAskedWhenWhere) {
      _data.whenWhere = text;
    } else if (_lastAskedPersonName) {
      _data.personName = text;
    } else if (_lastAskedContent) {
      _data.content = text;
    } else if (_lastAskedBackground) {
      _data.background = text;
    } else if (_lastAskedRequest) {
      _data.request = text;
    }
    _advance();
  }

  void _selectAffiliation(String label) {
    if (!_awaitingAffiliationChoice) return;
    _addUser(label);
    _data.affiliation = label;
    setState(() => _awaitingAffiliationChoice = false);
    _advance();
  }

  void _selectPosition(String label) {
    if (!_awaitingPositionChoice) return;
    _addUser(label);
    _data.position = label;
    setState(() => _awaitingPositionChoice = false);
    _advance();
  }

  void _advance() {
    _lastAskedWhenWhere = false;
    _lastAskedPersonName = false;
    _lastAskedContent = false;
    _lastAskedBackground = false;
    _lastAskedRequest = false;

    if (!_data.hasWhenWhere) {
      _lastAskedWhenWhere = true;
      _addJarvis('いつ・どこでの出来事か教えてください。');
      return;
    }
    if (!_data.hasAffiliation) {
      _addJarvis('相手の所属を教えてください。');
      setState(() => _awaitingAffiliationChoice = true);
      return;
    }
    if (_data.needsPosition && !_data.positionOk) {
      _addJarvis('相手の役職を教えてください。');
      setState(() => _awaitingPositionChoice = true);
      return;
    }
    if (!_data.hasPersonName) {
      _lastAskedPersonName = true;
      _addJarvis('お名前を教えてください。');
      return;
    }
    if (!_data.hasContent) {
      _lastAskedContent = true;
      _addJarvis('何があった、または何を言われましたか？');
      return;
    }
    // 自己申告を鵜呑みにしない:内容が曖昧な場合は深掘りする(レベル2:AIが誘導)。
    // 1回目は素直に聞き直し、2回目もまだ曖昧なら聞き方を変えて具体例を示す。
    // 2回聞き直しても曖昧なままなら、それ以上は拒否せず次の質問へ進む。
    if (_contentGuidanceAttempts < 2 && isVagueAnswer(_data.content ?? '')) {
      _contentGuidanceAttempts++;
      _data.content = null;
      _lastAskedContent = true;
      if (_contentGuidanceAttempts == 1) {
        _addJarvis('恐れ入りますが、もう少し具体的に教えていただけますか？(例:誰が何を言った、何が起きたか)');
      } else {
        _addJarvis('重ねてすみません。例えば「○○について改善してほしいと言われた」のように、具体的な内容を教えてください。');
      }
      return;
    }
    if (!_data.hasBackground) {
      _lastAskedBackground = true;
      _addJarvis('背景・状況を教えてください。(不明であれば「不明」とご記入ください)');
      return;
    }
    // 「背景・状況」は案内文で「不明」という回答を明示的に許容しているため、
    // isVagueAnswer()の一般的な曖昧判定(4文字以下は曖昧扱い)から「不明」だけは
    // 除外し、深掘りせずそのまま次へ進めるようにする。
    if (_backgroundGuidanceAttempts < 2 &&
        _data.background?.trim() != '不明' &&
        isVagueAnswer(_data.background ?? '')) {
      _backgroundGuidanceAttempts++;
      _data.background = null;
      _lastAskedBackground = true;
      if (_backgroundGuidanceAttempts == 1) {
        _addJarvis('恐れ入りますが、わかる範囲で構いませんので、もう少し状況を教えていただけますか？');
      } else {
        _addJarvis('重ねてすみません。わからなければ「不明」で構いませんので、その旨を教えてください。');
      }
      return;
    }
    if (!_data.hasRequest) {
      _lastAskedRequest = true;
      _addJarvis('どうしてほしいですか？');
      return;
    }
    _finalize();
  }

  int _contentGuidanceAttempts = 0;
  int _backgroundGuidanceAttempts = 0;

  Future<void> _finalize() async {
    // 緊急性の高いものは電話等の別経路で連絡が来る前提のため、JARVIS経由の業務報告は
    // 深刻度による分岐をせず全件SVの要対応として必ず表示されるようにする。
    const action = SuggestedAction.needsReschedule;
    setState(() => _isComplete = true);

    final entry = HistoryEntry(
      id: PendingSubmissionRegistry.instance.claim('業務報告'),
      category: '業務報告',
      title: '${_data.whenWhere} ${_data.personName}様:${_data.content}',
      action: action,
      fields: [
        MapEntry('いつ・どこで', _data.whenWhere ?? '-'),
        MapEntry('相手の所属', _data.affiliation ?? '-'),
        if (_data.needsPosition) MapEntry('相手の役職', _data.position ?? '-'),
        MapEntry('相手の名前', _data.personName ?? '-'),
        MapEntry('内容', _data.content ?? '-'),
        MapEntry('背景・状況', _data.background ?? '-'),
        MapEntry('どうしてほしいか', _data.request ?? '-'),
      ],
      history: List.unmodifiable(_messages),
    );

    await _submitEntry(entry);
  }

  Future<void> _submitEntry(HistoryEntry entry) async {
    setState(() {
      _isSaving = true;
      _saveFailed = false;
    });
    BeforeUnloadGuard.enable();
    try {
      await HistoryStore.instance.add(entry);
      PendingSubmissionRegistry.instance.release(entry.category);
      BeforeUnloadGuard.disable();
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _pendingEntry = null;
      });
      _addJarvis('ありがとうございます。内容を確認し、SVに共有しました。');
    } catch (_) {
      BeforeUnloadGuard.disable();
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _saveFailed = true;
        _pendingEntry = entry;
      });
      _addJarvis('申し訳ありません、保存に失敗しました。通信状況をご確認のうえ、もう一度お試しください。');
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Widget _wrapChoices(List<String> options, void Function(String) onSelect,
      {IconData icon = Icons.person_outline, Color color = const Color(0xFF22C55E)}) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final option in options)
          SizedBox(
            width: 150,
            child: ChoiceButton(
              label: option,
              icon: icon,
              color: color,
              onTap: () => onSelect(option),
            ),
          ),
      ],
    );
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
            const _ChatGuidanceBanner(text: 'ここは巡回・作業報告のチャット欄です。'),
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.all(16),
                itemCount: _messages.length,
                itemBuilder: (context, index) => ChatBubble(message: _messages[index]),
              ),
            ),
            if (_awaitingAffiliationChoice)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                child: _wrapChoices(
                  const ['店舗社員', 'ドコモ', 'KDDI', 'Softbank', '顧客'],
                  _selectAffiliation,
                  icon: Icons.groups_outlined,
                  color: const Color(0xFF3B82F6),
                ),
              )
            else if (_awaitingPositionChoice)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                child: _wrapChoices(
                  _positionOptionsByAffiliation[_data.affiliation] ?? const [],
                  _selectPosition,
                  icon: Icons.badge_outlined,
                  color: const Color(0xFFA855F7),
                ),
              )
            else if (!_isComplete)
              ChatInputBar(controller: _controller, onSend: _handleSend)
            else if (_isSaving || _saveFailed)
              _SubmitStatusBar(
                isSaving: _isSaving,
                onRetry: () {
                  if (_pendingEntry != null) _submitEntry(_pendingEntry!);
                },
              ),
          ],
        ),
      ),
    );
  }
}



class _ConsultationData {
  String? topic; // 業務のやり方 / 労務・勤怠関連 / その他
  String? content;

  bool get hasTopic => topic != null;
  bool get hasContent => content != null && content!.trim().isNotEmpty;
  bool get isComplete => hasTopic && hasContent;
}

class ConsultationChatScreen extends StatefulWidget {
  /// タスク詳細画面の「問い合わせ」から遷移した場合に、どのタスクについての
  /// 相談かを引き継ぐための任意パラメータ。
  final String? sourceTaskId;
  final String? sourceTaskTitle;

  /// お知らせ詳細画面の「問い合わせ」から遷移した場合に、どのお知らせについての
  /// 相談かを引き継ぐための任意パラメータ(sourceTaskId/sourceTaskTitleと同じ形)。
  final String? sourceAnnouncementId;
  final String? sourceAnnouncementTitle;

  /// SV確認画面の「対応する」から遷移した場合に、どの報告(再調整依頼)についての
  /// 相談かを引き継ぐための任意パラメータ(sourceTaskId/sourceTaskTitleと同じ形)。
  final String? sourceReportId;
  final String? sourceReportTitle;

  const ConsultationChatScreen({
    super.key,
    this.sourceTaskId,
    this.sourceTaskTitle,
    this.sourceAnnouncementId,
    this.sourceAnnouncementTitle,
    this.sourceReportId,
    this.sourceReportTitle,
  });
  @override
  State<ConsultationChatScreen> createState() => _ConsultationChatScreenState();
}

class _ConsultationChatScreenState extends State<ConsultationChatScreen> {
  final List<ChatMessage> _messages = [];
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final _ConsultationData _data = _ConsultationData();

  bool _isComplete = false;
  bool _awaitingTopicChoice = false;
  bool _lastAskedContent = false;
  bool _isSaving = false;
  bool _saveFailed = false;
  HistoryEntry? _pendingEntry;

  @override
  void initState() {
    super.initState();
    if (widget.sourceTaskTitle != null) {
      _addJarvis('「${widget.sourceTaskTitle}」についてのお問い合わせですね。');
    } else if (widget.sourceAnnouncementTitle != null) {
      _addJarvis('「${widget.sourceAnnouncementTitle}」についてのお問い合わせですね。');
    } else if (widget.sourceReportTitle != null) {
      _addJarvis('「${widget.sourceReportTitle}」の再調整についてのご相談ですね。');
    }
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
    _finalize();
  }

  int _contentGuidanceAttempts = 0;

  Future<void> _finalize() async {
    // 緊急な場合はJARVIS経由ではなく電話等の別経路で連絡が来る前提のため、
    // 業務報告カテゴリと同じく緊急度による分岐をせず全件SVの要対応として必ず表示する。
    const action = SuggestedAction.needsReschedule;
    setState(() => _isComplete = true);

    final entry = HistoryEntry(
      id: PendingSubmissionRegistry.instance.claim('業務相談'),
      category: '業務相談',
      title: '[${_data.topic}] ${_data.content}',
      action: action,
      fields: [
        MapEntry('ジャンル', _data.topic ?? '-'),
        MapEntry('相談内容', _data.content ?? '-'),
      ],
      history: List.unmodifiable(_messages),
      sourceTaskId: widget.sourceTaskId,
      announcementId: widget.sourceAnnouncementId,
      sourceReportId: widget.sourceReportId,
    );

    await _submitEntry(entry);
  }

  Future<void> _submitEntry(HistoryEntry entry) async {
    setState(() {
      _isSaving = true;
      _saveFailed = false;
    });
    BeforeUnloadGuard.enable();
    try {
      await HistoryStore.instance.add(entry);
      PendingSubmissionRegistry.instance.release(entry.category);
      BeforeUnloadGuard.disable();
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _pendingEntry = null;
      });
      _addJarvis('ありがとうございます。内容を確認し、SVに共有しました。');
      // タスク詳細画面/お知らせ詳細画面の「問い合わせ」から遷移してきた場合は、
      // TaskQuickCompleteScreen(完了報告)と同じく、少し間を置いて一覧画面まで自動で戻る。
      // 通常のホーム画面からの業務相談(どちらの紐づけもなし)は、このままチャット画面に
      // 留まる既存の挙動を変えない。
      if (widget.sourceTaskId != null ||
          widget.sourceAnnouncementId != null ||
          widget.sourceReportId != null) {
        await Future<void>.delayed(const Duration(milliseconds: 700));
        if (!mounted) return;
        Navigator.of(context)
          ..pop()
          ..pop();
      }
    } catch (_) {
      BeforeUnloadGuard.disable();
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _saveFailed = true;
        _pendingEntry = entry;
      });
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
            const _ChatGuidanceBanner(text: 'ここは業務に関する相談・確認のチャット欄です。'),
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
                      label: '業務のやり方',
                      icon: Icons.help_outline,
                      color: const Color(0xFF3B82F6),
                      onTap: () => _selectTopic('業務のやり方'),
                    ),
                    const SizedBox(height: 8),
                    ChoiceButton(
                      label: '労務・勤怠関連',
                      icon: Icons.badge_outlined,
                      color: const Color(0xFFF59E0B),
                      onTap: () => _selectTopic('労務・勤怠関連'),
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
            else if (!_isComplete)
              ChatInputBar(controller: _controller, onSend: _handleSend)
            else if (_isSaving || _saveFailed)
              _SubmitStatusBar(
                isSaving: _isSaving,
                onRetry: () {
                  if (_pendingEntry != null) _submitEntry(_pendingEntry!);
                },
              ),
          ],
        ),
      ),
    );
  }
}



class _BusinessCompletionData {
  String? completionStatus; // 'はい' / '一部未完了'
  String? incompleteDetail; // 一部未完了の場合の自由記述(内容)
  bool? hasNote; // 特記事項の有無
  String? noteContent; // 特記事項ありの場合の自由記述(内容)
  String? scheduleChange; // '変更なし' / '変更あり'
  String? scheduleChangeDetail; // 変更ありの場合の自由記述

  bool get hasCompletionStatus => completionStatus != null;
  bool get incompleteDetailOk =>
      completionStatus != '一部未完了' ||
      (incompleteDetail != null && incompleteDetail!.trim().isNotEmpty);
  bool get hasNoteKnown => hasNote != null;
  bool get noteContentOk =>
      hasNote != true || (noteContent != null && noteContent!.trim().isNotEmpty);
  bool get hasScheduleChangeKnown => scheduleChange != null;
  bool get scheduleChangeDetailOk =>
      scheduleChange != '変更あり' ||
      (scheduleChangeDetail != null && scheduleChangeDetail!.trim().isNotEmpty);
  bool get isComplete =>
      hasCompletionStatus &&
      incompleteDetailOk &&
      hasNoteKnown &&
      noteContentOk &&
      hasScheduleChangeKnown &&
      scheduleChangeDetailOk;
}

class BusinessCompletionChatScreen extends StatefulWidget {
  const BusinessCompletionChatScreen({super.key});
  @override
  State<BusinessCompletionChatScreen> createState() => _BusinessCompletionChatScreenState();
}

class _BusinessCompletionChatScreenState extends State<BusinessCompletionChatScreen> {
  final List<ChatMessage> _messages = [];
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final _BusinessCompletionData _data = _BusinessCompletionData();

  bool _isComplete = false;
  bool _awaitingCompletionChoice = false;
  bool _awaitingNoteChoice = false;
  bool _awaitingScheduleChoice = false;
  bool _lastAskedIncompleteDetail = false;
  bool _lastAskedNoteContent = false;
  bool _lastAskedScheduleDetail = false;
  bool _isSaving = false;
  bool _saveFailed = false;
  HistoryEntry? _pendingEntry;

  @override
  void initState() {
    super.initState();
    _addJarvis('お疲れ様です。今日の業務は完了しましたか？');
    _awaitingCompletionChoice = true;
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

    if (_lastAskedIncompleteDetail) {
      _data.incompleteDetail = text;
    } else if (_lastAskedNoteContent) {
      _data.noteContent = text;
    } else if (_lastAskedScheduleDetail) {
      _data.scheduleChangeDetail = text;
    }
    _advance();
  }

  void _selectCompletionStatus(String label) {
    if (!_awaitingCompletionChoice) return;
    _addUser(label);
    _data.completionStatus = label;
    setState(() => _awaitingCompletionChoice = false);
    _advance();
  }

  void _selectNote(bool hasNote, String label) {
    if (!_awaitingNoteChoice) return;
    _addUser(label);
    _data.hasNote = hasNote;
    setState(() => _awaitingNoteChoice = false);
    _advance();
  }

  void _selectScheduleChange(String label) {
    if (!_awaitingScheduleChoice) return;
    _addUser(label);
    _data.scheduleChange = label;
    setState(() => _awaitingScheduleChoice = false);
    _advance();
  }

  void _advance() {
    _lastAskedIncompleteDetail = false;
    _lastAskedNoteContent = false;
    _lastAskedScheduleDetail = false;

    if (!_data.hasCompletionStatus) {
      _addJarvis('今日の業務は完了しましたか？');
      setState(() => _awaitingCompletionChoice = true);
      return;
    }
    if (!_data.incompleteDetailOk) {
      _lastAskedIncompleteDetail = true;
      _addJarvis('未完了の内容を教えてください。');
      return;
    }
    // 自己申告を鵜呑みにしない:内容が曖昧な場合は深掘りする(レベル2:AIが誘導)。
    // 1回目は素直に聞き直し、2回目もまだ曖昧なら聞き方を変える。
    if (_data.completionStatus == '一部未完了' &&
        _incompleteDetailGuidanceAttempts < 2 &&
        isVagueAnswer(_data.incompleteDetail ?? '')) {
      _incompleteDetailGuidanceAttempts++;
      _data.incompleteDetail = null;
      _lastAskedIncompleteDetail = true;
      if (_incompleteDetailGuidanceAttempts == 1) {
        _addJarvis('恐れ入りますが、もう少し具体的に未完了の内容を教えていただけますか？');
      } else {
        _addJarvis('重ねて恐れ入ります。何が、なぜ完了しなかったか、わかる範囲で構いませんので教えてください。');
      }
      return;
    }
    if (!_data.hasNoteKnown) {
      _addJarvis('特記事項はありますか？');
      setState(() => _awaitingNoteChoice = true);
      return;
    }
    if (!_data.noteContentOk) {
      _lastAskedNoteContent = true;
      _addJarvis('特記事項の内容を教えてください。');
      return;
    }
    // 自己申告を鵜呑みにしない:内容が曖昧な場合は深掘りする(レベル2:AIが誘導)。
    // 1回目は素直に聞き直し、2回目もまだ曖昧なら聞き方を変える。
    if (_data.hasNote == true &&
        _noteContentGuidanceAttempts < 2 &&
        isVagueAnswer(_data.noteContent ?? '')) {
      _noteContentGuidanceAttempts++;
      _data.noteContent = null;
      _lastAskedNoteContent = true;
      if (_noteContentGuidanceAttempts == 1) {
        _addJarvis('恐れ入りますが、もう少し具体的に特記事項の内容を教えていただけますか？');
      } else {
        _addJarvis('重ねて恐れ入ります。何が、どのような状況かわかる範囲で構いませんので教えてください。');
      }
      return;
    }
    if (!_data.hasScheduleChangeKnown) {
      _addJarvis('明日の予定に変更はありますか？');
      setState(() => _awaitingScheduleChoice = true);
      return;
    }
    if (!_data.scheduleChangeDetailOk) {
      _lastAskedScheduleDetail = true;
      _addJarvis('変更内容を教えてください。');
      return;
    }
    _finalize();
  }

  int _incompleteDetailGuidanceAttempts = 0;
  int _noteContentGuidanceAttempts = 0;

  Future<void> _finalize() async {
    final SuggestedAction action;
    if (_data.completionStatus == '一部未完了') {
      // 未完了分が残っているため、フォローが必要な状態としてSVの要対応に残す
      action = SuggestedAction.needsReschedule;
    } else if (_data.hasNote == true) {
      // 特記事項ありの場合、紐づく業務報告が未確認のうちはこの完了確認自体も
      // SV側の要対応に残るようにする(業務報告だけでなく完了確認も見落とされないため)
      action = SuggestedAction.needsReschedule;
    } else {
      action = SuggestedAction.approveOnly;
    }
    setState(() => _isComplete = true);

    final entry = HistoryEntry(
      id: PendingSubmissionRegistry.instance.claim('業務完了確認'),
      category: '業務完了確認',
      title: _data.completionStatus == '一部未完了'
          ? (_data.incompleteDetail ?? '一部未完了')
          : '本日の業務完了確認',
      action: action,
      fields: [
        MapEntry('完了状況', _data.completionStatus ?? '-'),
        if (_data.completionStatus == '一部未完了')
          MapEntry('未完了の内容', _data.incompleteDetail ?? '-'),
        MapEntry('特記事項', _data.hasNote == true ? 'あり' : 'なし'),
        if (_data.hasNote == true) MapEntry('特記事項の内容', _data.noteContent ?? '-'),
        MapEntry('明日の予定変更', _data.scheduleChange ?? '-'),
        if (_data.scheduleChange == '変更あり')
          MapEntry('変更内容', _data.scheduleChangeDetail ?? '-'),
      ],
      history: List.unmodifiable(_messages),
    );

    await _submitEntry(entry);
  }

  Future<void> _submitEntry(HistoryEntry entry) async {
    setState(() {
      _isSaving = true;
      _saveFailed = false;
    });
    BeforeUnloadGuard.enable();
    try {
      await HistoryStore.instance.add(entry);
      PendingSubmissionRegistry.instance.release(entry.category);
      BeforeUnloadGuard.disable();
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _pendingEntry = null;
      });
      _addJarvis('ありがとうございます。内容を確認し、SVに共有しました。');
    } catch (_) {
      BeforeUnloadGuard.disable();
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _saveFailed = true;
        _pendingEntry = entry;
      });
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
        title: const Text('業務完了確認', style: TextStyle(color: Colors.white, fontSize: 17)),
        iconTheme: const IconThemeData(color: Colors.white70),
      ),
      body: SafeArea(
        child: Column(
          children: [
            const _ChatGuidanceBanner(text: 'ここは本日の業務完了確認用のチャット欄です。'),
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.all(16),
                itemCount: _messages.length,
                itemBuilder: (context, index) => ChatBubble(message: _messages[index]),
              ),
            ),
            if (_awaitingCompletionChoice)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: ChoiceButton(
                        label: 'はい',
                        icon: Icons.check_circle,
                        color: const Color(0xFF22C55E),
                        onTap: () => _selectCompletionStatus('はい'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ChoiceButton(
                        label: '一部未完了',
                        icon: Icons.warning_amber,
                        color: const Color(0xFFF97316),
                        onTap: () => _selectCompletionStatus('一部未完了'),
                      ),
                    ),
                  ],
                ),
              )
            else if (_awaitingNoteChoice)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: ChoiceButton(
                        label: 'あり',
                        icon: Icons.flag,
                        color: const Color(0xFFA855F7),
                        onTap: () => _selectNote(true, 'あり'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ChoiceButton(
                        label: 'なし',
                        icon: Icons.check_circle,
                        color: const Color(0xFF22C55E),
                        onTap: () => _selectNote(false, 'なし'),
                      ),
                    ),
                  ],
                ),
              )
            else if (_awaitingScheduleChoice)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: ChoiceButton(
                        label: '変更なし',
                        icon: Icons.check_circle,
                        color: const Color(0xFF22C55E),
                        onTap: () => _selectScheduleChange('変更なし'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ChoiceButton(
                        label: '変更あり',
                        icon: Icons.event,
                        color: const Color(0xFF3B82F6),
                        onTap: () => _selectScheduleChange('変更あり'),
                      ),
                    ),
                  ],
                ),
              )
            else if (!_isComplete)
              ChatInputBar(controller: _controller, onSend: _handleSend)
            else if (_isSaving || _saveFailed)
              _SubmitStatusBar(
                isSaving: _isSaving,
                onRetry: () {
                  if (_pendingEntry != null) _submitEntry(_pendingEntry!);
                },
              ),
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
  bool _isSaving = false;
  bool _saveFailed = false;
  HistoryEntry? _pendingEntry;

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
      id: PendingSubmissionRegistry.instance.claim('その他'),
      category: 'その他',
      title: _data.content ?? '-',
      action: action,
      fields: [
        MapEntry('内容', _data.content ?? '-'),
        MapEntry('緊急度', _data.urgency ?? '-'),
      ],
      history: List.unmodifiable(_messages),
    );

    await _submitEntry(entry);
  }

  Future<void> _submitEntry(HistoryEntry entry) async {
    setState(() {
      _isSaving = true;
      _saveFailed = false;
    });
    BeforeUnloadGuard.enable();
    try {
      await HistoryStore.instance.add(entry);
      PendingSubmissionRegistry.instance.release(entry.category);
      BeforeUnloadGuard.disable();
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _pendingEntry = null;
      });
      _addJarvis('ありがとうございます。内容を確認し、SVに共有しました。');
    } catch (_) {
      BeforeUnloadGuard.disable();
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _saveFailed = true;
        _pendingEntry = entry;
      });
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
            const _ChatGuidanceBanner(text: 'ここは他のカテゴリに当てはまらないご連絡のチャット欄です。'),
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
              ChatInputBar(controller: _controller, onSend: _handleSend)
            else if (_isSaving || _saveFailed)
              _SubmitStatusBar(
                isSaving: _isSaving,
                onRetry: () {
                  if (_pendingEntry != null) _submitEntry(_pendingEntry!);
                },
              ),
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
  bool _isSaving = false;
  bool _saveFailed = false;
  HistoryEntry? _pendingEntry;
  bool _pendingHadQuestion = false;

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
      id: PendingSubmissionRegistry.instance.claim('周知確認'),
      category: '周知確認',
      title: hadQuestion ? (_questionText ?? '質問あり') : '確認済み',
      action: action,
      fields: [
        const MapEntry('お知らせ', '勤怠報告の締め切り時刻が18:00に変更'),
        MapEntry('確認結果', hadQuestion ? '質問あり:${_questionText ?? ''}' : '確認しました'),
      ],
      history: List.unmodifiable(_messages),
    );

    await _submitEntry(entry, hadQuestion: hadQuestion);
  }

  Future<void> _submitEntry(HistoryEntry entry, {required bool hadQuestion}) async {
    setState(() {
      _isSaving = true;
      _saveFailed = false;
      _pendingHadQuestion = hadQuestion;
    });
    BeforeUnloadGuard.enable();
    try {
      await HistoryStore.instance.add(entry);
      PendingSubmissionRegistry.instance.release(entry.category);
      BeforeUnloadGuard.disable();
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _pendingEntry = null;
      });
      _addJarvis(hadQuestion
          ? 'ありがとうございます。ご質問をSVに共有しました。'
          : 'ご確認ありがとうございます。SVに確認済みとして共有しました。');
    } catch (_) {
      BeforeUnloadGuard.disable();
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _saveFailed = true;
        _pendingEntry = entry;
      });
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
            const _ChatGuidanceBanner(text: 'ここは重要なお知らせの確認のチャット欄です。'),
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
              ChatInputBar(controller: _controller, onSend: _handleSend)
            else if (_isSaving || _saveFailed)
              _SubmitStatusBar(
                isSaving: _isSaving,
                onRetry: () {
                  if (_pendingEntry != null) {
                    _submitEntry(_pendingEntry!, hadQuestion: _pendingHadQuestion);
                  }
                },
              ),
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
    UserSession.instance.addListener(_onStoreChanged);
    HistoryStore.instance.addListener(_onStoreChanged);
    SvHistoryStore.instance.addListener(_onStoreChanged);
    SvReportStore.instance.addListener(_onStoreChanged);
  }

  @override
  void dispose() {
    UserSession.instance.removeListener(_onStoreChanged);
    HistoryStore.instance.removeListener(_onStoreChanged);
    SvHistoryStore.instance.removeListener(_onStoreChanged);
    SvReportStore.instance.removeListener(_onStoreChanged);
    super.dispose();
  }

  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final isSv = UserSession.instance.role == UserRole.sv;
    final entries = isSv ? SvHistoryStore.instance.entries : HistoryStore.instance.entries;
    // sourceReportIdが紐づく報告(「対応する」経由の業務相談)で、元の報告のカテゴリを
    // 一覧・詳細画面に注記するためのルックアップ。元の報告がまだ未レビューの場合は
    // SvHistoryStore(自分がレビュー済みの報告のみ)には無いため、自チーム全報告を
    // 購読しているSvReportStoreから構築する(新規Firestore読み取りは不要)。
    final reportCategoryById = {
      for (final e in SvReportStore.instance.entries)
        if (e.id != null) e.id!: e.category,
    };

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
              Text(isSv ? '履歴(自分が対応した報告)' : '履歴',
                  style: const TextStyle(
                      color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
            ],
          ),
        ),
        if (entries.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Text(
                isSv ? 'まだ対応した報告はありません。' : 'まだ報告はありません。',
                style: TextStyle(color: Colors.grey[500], fontSize: 12.5)),
          ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            itemCount: entries.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final e = entries[index];
              // 要対応(再調整依頼、未承認)は履歴一覧の中で最も目に留まるよう、
              // カード自体の背景・枠線も強調する(バッジだけだと目立たないため)。
              final isNeedsAction =
                  e.approvedAt == null && e.reviewedAction == SuggestedAction.needsReschedule;
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
                            id: e.id,
                            category: e.category,
                            icon: e.icon,
                            color: e.color,
                            time: e.time,
                            fields: e.fields,
                            action: e.action,
                            history: e.history,
                            reviewedAction: e.reviewedAction,
                            sourceReportCategory: e.sourceReportId != null
                                ? reportCategoryById[e.sourceReportId]
                                : null,
                          ),
                        ),
                      ),
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: isNeedsAction
                          ? const Color(0xFFF59E0B).withValues(alpha: 0.12)
                          : const Color(0xFF141826),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isNeedsAction
                            ? const Color(0xFFF59E0B).withValues(alpha: 0.8)
                            : Colors.white10,
                        width: isNeedsAction ? 1.5 : 1,
                      ),
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
                              if (e.sourceReportId != null &&
                                  reportCategoryById[e.sourceReportId] != null) ...[
                                const SizedBox(height: 4),
                                Text(
                                    '元の報告:「${reportCategoryById[e.sourceReportId]}」への回答',
                                    style: const TextStyle(
                                        color: Color(0xFFA855F7),
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold)),
                              ],
                              if (isSv) ...[
                                const SizedBox(height: 4),
                                Text(
                                    '担当: ${e.staffName ?? shortStaffId(e.staffId)}',
                                    style: TextStyle(
                                        color: Colors.grey[600], fontSize: 11)),
                              ],
                              const SizedBox(height: 8),
                              _ReportStatusBadge(entry: e, isSv: isSv),
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


/// 承認済み(approvedAt あり)なら「✓ 承認済み」、まだなら「AI提案:xxx」を表示する。
/// AIの提案アクションと、SVが実際に承認したかどうかを見分けやすくするためのバッジ。
class _ReportStatusBadge extends StatelessWidget {
  final HistoryEntry entry;
  final bool isSv;
  const _ReportStatusBadge({required this.entry, required this.isSv});

  @override
  Widget build(BuildContext context) {
    final isApproved = entry.approvedAt != null;
    // エスカレーションはSVが引き取って対応する性質のもののため、スタッフ視点では
    // 「対応が必要」ではなく受け身の表示にする。SV視点では従来通り自分の対応待ち
    // キューとして「要対応」のまま扱う(SummaryTabBodyの要対応タブと表示を揃える)。
    final isEscalatedForStaff =
        !isApproved && !isSv && entry.reviewedAction == SuggestedAction.escalate;
    // 再調整依頼・エスカレーション済み(reviewedAtあり・approvedAtなし)は「要対応」として
    // 未対応(AI提案)と区別する。SVが既に対応方針を選んでいるのに「AI提案」表示のままだと
    // 未対応と見分けがつかなくなるため。
    final needsAction = !isApproved &&
        !isEscalatedForStaff &&
        (entry.reviewedAction == SuggestedAction.needsReschedule ||
            entry.reviewedAction == SuggestedAction.escalate);
    final Color color;
    final IconData icon;
    final String label;
    if (isApproved) {
      color = const Color(0xFF22C55E);
      icon = Icons.check_circle;
      label = '承認済み';
    } else if (isEscalatedForStaff) {
      color = Colors.grey[500]!;
      icon = Icons.supervisor_account_outlined;
      label = 'SV対応中';
    } else if (needsAction) {
      color = entry.reviewedAction!.color;
      icon = Icons.error_outline;
      label = '要対応:${entry.reviewedAction!.label}';
    } else {
      color = Colors.grey[500]!;
      icon = Icons.smart_toy_outlined;
      label = 'AI提案:${entry.actionLabel}';
    }
    final filled = isApproved || needsAction;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: filled ? color.withValues(alpha: 0.15) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: filled ? 0.5 : 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}

class _CategoryCount {
  final String label;
  final int count;
  final Color color;
  const _CategoryCount(this.label, this.count, this.color);
}

/// SVサマリー画面「全スタッフの報告一覧」の絞り込みタブ。
enum SummaryReportTab { unreviewed, needsAction, all }

extension SummaryReportTabX on SummaryReportTab {
  String get label {
    switch (this) {
      case SummaryReportTab.unreviewed:
        return '未確認';
      case SummaryReportTab.needsAction:
        return '要対応';
      case SummaryReportTab.all:
        return '全件';
    }
  }
}

/// SVサマリー画面のタブ・ホーム画面の通知ベルバッジなど、複数箇所で共用する
/// 「未確認」「要対応」の判定ロジック。未確認(reviewedAt未設定)と要対応
/// (reviewedActionが再調整/エスカレーション)は定義上排他なので、合算しても
/// 二重カウントにはならない。
List<HistoryEntry> filterReportsByTab(List<HistoryEntry> entries, SummaryReportTab tab) {
  switch (tab) {
    case SummaryReportTab.unreviewed:
      return entries.where((e) => e.reviewedAt == null).toList();
    case SummaryReportTab.needsAction:
      return entries
          .where((e) =>
              e.reviewedAction == SuggestedAction.needsReschedule ||
              e.reviewedAction == SuggestedAction.escalate)
          .toList();
    case SummaryReportTab.all:
      return entries;
  }
}

class SummaryTabBody extends StatefulWidget {
  /// ホーム画面の統計カードから遷移した際に、開いた時点で選択しておくタブ。
  /// nullの場合は前回選択(初期値は全件)を維持する。
  final SummaryReportTab? initialTab;

  const SummaryTabBody({super.key, this.initialTab});

  @override
  State<SummaryTabBody> createState() => _SummaryTabBodyState();
}

class _SummaryTabBodyState extends State<SummaryTabBody> {
  late SummaryReportTab _selectedTab = widget.initialTab ?? SummaryReportTab.all;
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
    HistoryStore.instance.addListener(_onChanged);
    AssignedTaskStore.instance.addListener(_onChanged);
  }

  @override
  void dispose() {
    UserSession.instance.removeListener(_onChanged);
    SvReportStore.instance.removeListener(_onChanged);
    HistoryStore.instance.removeListener(_onChanged);
    AssignedTaskStore.instance.removeListener(_onChanged);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant SummaryTabBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    // ホーム画面の統計カードから再度遷移してきた場合、指定されたタブに切り替える。
    if (widget.initialTab != null && widget.initialTab != oldWidget.initialTab) {
      setState(() => _selectedTab = widget.initialTab!);
    }
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

  DateTime _startOfWeek(DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    return today.subtract(Duration(days: today.weekday - 1));
  }

  int _weeklyCount(List<HistoryEntry> entries) {
    final start = _startOfWeek(DateTime.now());
    return entries.where((e) => !e.timestamp.isBefore(start)).length;
  }

  String _approveRateLabel(List<HistoryEntry> entries) {
    if (entries.isEmpty) return '-';
    final approveCount =
        entries.where((e) => e.action == SuggestedAction.approveOnly).length;
    final rate = (approveCount / entries.length * 100).round();
    return '$rate%';
  }

  int _escalateCount(List<HistoryEntry> entries) {
    return entries.where((e) => e.action == SuggestedAction.escalate).length;
  }

  /// 承認済み全件の(approvedAt - timestamp)の平均。承認済みが1件もなければ「-」。
  String _avgResponseTimeLabel(List<HistoryEntry> entries) {
    final approved = entries.where((e) => e.approvedAt != null).toList();
    if (approved.isEmpty) return '-';
    final totalSeconds = approved.fold<int>(
      0,
      (acc, e) => acc + e.approvedAt!.difference(e.timestamp).inSeconds,
    );
    final avgMinutes = (totalSeconds / approved.length / 60).round();
    if (avgMinutes < 60) return '$avgMinutes分';
    return '${avgMinutes ~/ 60}時間${avgMinutes % 60}分';
  }

  /// スタッフ向け指標。自分の報告について、提出(timestamp)からSVが何らかの対応
  /// (承認/再調整依頼/エスカレーションいずれか、reviewedAt基準)をするまでの平均時間。
  /// SV側の_avgResponseTimeLabel(承認のみ・approvedAt基準)とは意図的に別ロジックにしている
  /// (承認のみに絞るとスタッフ視点では母数が少なすぎるため)。対応済みが1件もなければ「-」。
  String _staffAvgResponseTimeLabel(List<HistoryEntry> entries) {
    final reviewed = entries.where((e) => e.reviewedAt != null).toList();
    if (reviewed.isEmpty) return '-';
    final totalSeconds = reviewed.fold<int>(
      0,
      (acc, e) => acc + e.reviewedAt!.difference(e.timestamp).inSeconds,
    );
    final avgMinutes = (totalSeconds / reviewed.length / 60).round();
    if (avgMinutes < 60) return '$avgMinutes分';
    return '${avgMinutes ~/ 60}時間${avgMinutes % 60}分';
  }

  @override
  Widget build(BuildContext context) {
    final isSv = UserSession.instance.role == UserRole.sv;
    final svEntries = SvReportStore.instance.entries;
    // sourceReportIdが紐づく報告(「対応する」経由の業務相談)で、元の報告のカテゴリを
    // 一覧・詳細画面に注記するためのルックアップ。新規クエリは不要(svEntriesは
    // 既に全報告を購読済み)。
    final reportCategoryById = {
      for (final e in svEntries)
        if (e.id != null) e.id!: e.category,
    };
    final breakdown = isSv ? _realBreakdown(svEntries) : _dummyBreakdown;
    final maxCount = breakdown.isEmpty
        ? 1
        : breakdown.map((e) => e.count).reduce((a, b) => a > b ? a : b);

    // スタッフ向け指標(SV向けとは対象データ・意味が異なる独立した算出)。
    final staffEntries = HistoryStore.instance.entries;
    final completedTaskIds = completedTaskIdsFrom(staffEntries);
    final incompleteTaskCount = AssignedTaskStore.instance.entries
        .where((t) => !completedTaskIds.contains(t.id))
        .length;
    final pendingApprovalCount = staffEntries.where((e) => e.reviewedAt == null).length;

    final (statCard1Label, statCard1Value, statCard1Icon, statCard1Color) = isSv
        ? ('今週の対応件数', '${_weeklyCount(svEntries)}件', Icons.inbox, const Color(0xFF3B82F6))
        : ('未対応タスク数', '$incompleteTaskCount件', Icons.assignment_late, const Color(0xFFF97316));

    final (statCard2Label, statCard2Value, statCard2Icon, statCard2Color) = isSv
        ? ('承認のみでOK率', _approveRateLabel(svEntries), Icons.check_circle, const Color(0xFF22C55E))
        : ('承認待ち数', '$pendingApprovalCount件', Icons.hourglass_empty, Colors.amber);

    final (statCard3Label, statCard3Value, statCard3Icon, statCard3Color) = isSv
        ? ('要エスカレーション', '${_escalateCount(svEntries)}件', Icons.priority_high, const Color(0xFFEF4444))
        : ('平均対応時間', _staffAvgResponseTimeLabel(staffEntries), Icons.timer, const Color(0xFF06B6D4));

    final (statCard4Label, statCard4Value, statCard4Icon, statCard4Color) = isSv
        ? ('平均対応時間', _avgResponseTimeLabel(svEntries), Icons.timer, const Color(0xFF06B6D4))
        : ('送付件数', '${_weeklyCount(staffEntries)}件', Icons.send, const Color(0xFF3B82F6));

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
                  label: statCard1Label,
                  value: statCard1Value,
                  icon: statCard1Icon,
                  color: statCard1Color,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _SummaryStatCard(
                  label: statCard2Label,
                  value: statCard2Value,
                  icon: statCard2Icon,
                  color: statCard2Color,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _SummaryStatCard(
                  label: statCard3Label,
                  value: statCard3Value,
                  icon: statCard3Icon,
                  color: statCard3Color,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _SummaryStatCard(
                  label: statCard4Label,
                  value: statCard4Value,
                  icon: statCard4Icon,
                  color: statCard4Color,
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
            Row(
              children: [
                for (final tab in SummaryReportTab.values) ...[
                  if (tab != SummaryReportTab.values.first) const SizedBox(width: 8),
                  Expanded(
                    child: _SummaryTabChip(
                      label: tab.label,
                      selected: tab == _selectedTab,
                      onTap: () => setState(() => _selectedTab = tab),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            Builder(builder: (context) {
              final filteredEntries = filterReportsByTab(svEntries, _selectedTab);
              if (filteredEntries.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                      svEntries.isEmpty ? '報告はまだありません。' : '該当する報告はありません。',
                      style: TextStyle(color: Colors.grey[500], fontSize: 12.5)),
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final e in filteredEntries) ...[
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
                                id: e.id,
                                category: e.category,
                                icon: e.icon,
                                color: e.color,
                                time: e.time,
                                fields: e.fields,
                                action: e.action,
                                history: e.history,
                                reviewedAction: e.reviewedAction,
                                sourceReportCategory: e.sourceReportId != null
                                    ? reportCategoryById[e.sourceReportId]
                                    : null,
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
                                  if (e.sourceReportId != null &&
                                      reportCategoryById[e.sourceReportId] != null) ...[
                                    const SizedBox(height: 4),
                                    Text(
                                        '元の報告:「${reportCategoryById[e.sourceReportId]}」への回答',
                                        style: const TextStyle(
                                            color: Color(0xFFA855F7),
                                            fontSize: 11,
                                            fontWeight: FontWeight.bold)),
                                  ],
                                  const SizedBox(height: 4),
                                  Text(
                                      '担当: ${e.staffName ?? shortStaffId(e.staffId)}',
                                      style: TextStyle(
                                          color: Colors.grey[600], fontSize: 11)),
                                  const SizedBox(height: 8),
                                  _ReportStatusBadge(entry: e, isSv: true),
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
              );
            }),
          ],
        ],
      ),
    );
  }
}

class _SummaryTabChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _SummaryTabChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? Colors.cyanAccent.withValues(alpha: 0.15) : const Color(0xFF141826),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: selected ? Colors.cyanAccent : Colors.white10),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              color: selected ? Colors.cyanAccent : Colors.grey[400],
              fontSize: 12.5,
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ),
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
// 本日の勤怠一覧・本日の完了一覧(ホーム画面の統計カードから遷移)
// ============================================================

class AttendanceOverviewScreen extends StatefulWidget {
  const AttendanceOverviewScreen({super.key});

  @override
  State<AttendanceOverviewScreen> createState() => _AttendanceOverviewScreenState();
}

class _AttendanceOverviewScreenState extends State<AttendanceOverviewScreen> {
  @override
  void initState() {
    super.initState();
    SvReportStore.instance.addListener(_onChanged);
    StaffRosterStore.instance.addListener(_onChanged);
  }

  @override
  void dispose() {
    SvReportStore.instance.removeListener(_onChanged);
    StaffRosterStore.instance.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final todayEntries =
        SvReportStore.instance.entries.where((e) => _isToday(e.timestamp)).toList();
    final absenceEntries = <String, HistoryEntry>{};
    final latenessEntries = <String, HistoryEntry>{};
    for (final e in todayEntries) {
      if (e.staffId == null) continue;
      if (e.category == '勤怠(欠勤)') {
        absenceEntries[e.staffId!] = e;
      } else if (e.category == '勤怠(遅刻)') {
        latenessEntries[e.staffId!] = e;
      }
    }
    final staff = StaffRosterStore.instance.staff;
    final presentStaff = staff
        .where((s) =>
            !absenceEntries.containsKey(s.uid) && !latenessEntries.containsKey(s.uid))
        .toList();

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0E1A),
        elevation: 0,
        title: const Text('本日の勤怠一覧', style: TextStyle(color: Colors.white, fontSize: 17)),
        iconTheme: const IconThemeData(color: Colors.white70),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _AttendanceSection(
                title: '出勤',
                icon: Icons.check_circle,
                color: const Color(0xFF22C55E),
                count: presentStaff.length,
                children: presentStaff.isEmpty
                    ? [const _EmptyRow(label: '該当者はいません。')]
                    : presentStaff
                        .map((s) => _StaffNameRow(name: s.displayName ?? shortStaffId(s.uid)))
                        .toList(),
              ),
              const SizedBox(height: 20),
              _AttendanceSection(
                title: '遅刻',
                icon: Icons.access_time,
                color: const Color(0xFF3B82F6),
                count: latenessEntries.length,
                children: latenessEntries.isEmpty
                    ? [const _EmptyRow(label: '該当者はいません。')]
                    : latenessEntries.values.map((e) => _AttendanceReportRow(entry: e)).toList(),
              ),
              const SizedBox(height: 20),
              _AttendanceSection(
                title: '欠勤',
                icon: Icons.event_busy,
                color: const Color(0xFFEF4444),
                count: absenceEntries.length,
                children: absenceEntries.isEmpty
                    ? [const _EmptyRow(label: '該当者はいません。')]
                    : absenceEntries.values.map((e) => _AttendanceReportRow(entry: e)).toList(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AttendanceSection extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color color;
  final int count;
  final List<Widget> children;

  const _AttendanceSection({
    required this.title,
    required this.icon,
    required this.color,
    required this.count,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
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
            children: [
              Icon(icon, color: color, size: 18),
              const SizedBox(width: 8),
              Text(title,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
              const Spacer(),
              Text('$count名',
                  style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.bold)),
            ],
          ),
          const Divider(color: Colors.white12, height: 20),
          ...children,
        ],
      ),
    );
  }
}

class _StaffNameRow extends StatelessWidget {
  final String name;
  const _StaffNameRow({required this.name});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          const Icon(Icons.person, color: Colors.white38, size: 16),
          const SizedBox(width: 8),
          Text(name, style: const TextStyle(color: Colors.white70, fontSize: 13.5)),
        ],
      ),
    );
  }
}

class _EmptyRow extends StatelessWidget {
  final String label;
  const _EmptyRow({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Text(label, style: TextStyle(color: Colors.grey[600], fontSize: 12.5)),
    );
  }
}

class _AttendanceReportRow extends StatelessWidget {
  final HistoryEntry entry;
  const _AttendanceReportRow({required this.entry});

  @override
  Widget build(BuildContext context) {
    final reasonField = entry.fields.firstWhere(
      (f) => f.key == '理由',
      orElse: () => const MapEntry('理由', '-'),
    );
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => SvSummaryScreen(
                summary: SvReportSummary(
                  id: entry.id,
                  category: entry.category,
                  icon: entry.icon,
                  color: entry.color,
                  time: entry.time,
                  fields: entry.fields,
                  action: entry.action,
                  history: entry.history,
                  reviewedAction: entry.reviewedAction,
                ),
              ),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.person, color: Colors.white38, size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(entry.staffName ?? shortStaffId(entry.staffId),
                        style: const TextStyle(color: Colors.white70, fontSize: 13.5)),
                    const SizedBox(height: 2),
                    Text('${reasonField.value} ・ ${entry.time}',
                        style: TextStyle(color: Colors.grey[600], fontSize: 11.5)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Colors.white24, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

class CompletedTasksScreen extends StatefulWidget {
  const CompletedTasksScreen({super.key});

  @override
  State<CompletedTasksScreen> createState() => _CompletedTasksScreenState();
}

class _CompletedTasksScreenState extends State<CompletedTasksScreen> {
  @override
  void initState() {
    super.initState();
    SvReportStore.instance.addListener(_onChanged);
  }

  @override
  void dispose() {
    SvReportStore.instance.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final entries = SvReportStore.instance.entries
        .where((e) => e.category == 'タスク完了' && _isToday(e.timestamp))
        .toList();

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0E1A),
        elevation: 0,
        title: const Text('本日の完了一覧', style: TextStyle(color: Colors.white, fontSize: 17)),
        iconTheme: const IconThemeData(color: Colors.white70),
      ),
      body: SafeArea(
        child: entries.isEmpty
            ? Center(
                child: Text('本日の完了報告はまだありません。',
                    style: TextStyle(color: Colors.grey[500], fontSize: 13)),
              )
            : ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: entries.length,
                itemBuilder: (context, index) {
                  final e = entries[index];
                  return Padding(
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
                                  id: e.id,
                                  category: e.category,
                                  icon: e.icon,
                                  color: e.color,
                                  time: e.time,
                                  fields: e.fields,
                                  action: e.action,
                                  history: e.history,
                                  reviewedAction: e.reviewedAction,
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
                                    Text('担当: ${e.staffName ?? shortStaffId(e.staffId)}',
                                        style: TextStyle(color: Colors.grey[600], fontSize: 11)),
                                    const SizedBox(height: 8),
                                    _ReportStatusBadge(entry: e, isSv: true),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}

// ============================================================
// SVによるタスク割り当て(ドロワーから遷移、SV専用)
// ============================================================

class AssignTaskScreen extends StatefulWidget {
  const AssignTaskScreen({super.key});

  @override
  State<AssignTaskScreen> createState() => _AssignTaskScreenState();
}

class _AssignTaskScreenState extends State<AssignTaskScreen> {
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _detailController = TextEditingController();
  final Set<String> _selectedStaffIds = {};
  bool _sendToEveryone = false;
  bool _isSaving = false;
  bool _saveFailed = false;
  String? _validationError;

  @override
  void initState() {
    super.initState();
    StaffRosterStore.instance.addListener(_onRosterChanged);
  }

  @override
  void dispose() {
    StaffRosterStore.instance.removeListener(_onRosterChanged);
    _titleController.dispose();
    _detailController.dispose();
    super.dispose();
  }

  void _onRosterChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _submit() async {
    final roster = StaffRosterStore.instance.staff;
    final targets = _sendToEveryone
        ? roster
        : roster.where((s) => _selectedStaffIds.contains(s.uid)).toList();
    final title = _titleController.text.trim();
    final detail = _detailController.text.trim();
    if (targets.isEmpty || title.isEmpty) {
      setState(() => _validationError = '送信先スタッフとタイトルは必須です。');
      return;
    }

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    setState(() {
      _isSaving = true;
      _saveFailed = false;
      _validationError = null;
    });
    try {
      final batch = FirebaseFirestore.instance.batch();
      for (final staff in targets) {
        final ref = FirebaseFirestore.instance.collection('tasks').doc();
        batch.set(ref, {
          'staffId': staff.uid,
          'assignedBy': uid,
          'assignedByName': UserSession.instance.displayName,
          'title': title,
          'detail': detail,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }
      await batch.commit().timeout(const Duration(seconds: 10));
      if (!mounted) return;
      setState(() => _isSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(targets.length == 1
              ? '${targets.first.displayName ?? shortStaffId(targets.first.uid)}さんにタスクを割り当てました。'
              : '${targets.length}名にタスクを割り当てました。'),
          backgroundColor: const Color(0xFF141826),
          behavior: SnackBarBehavior.floating,
        ),
      );
      Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _saveFailed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final staff = StaffRosterStore.instance.staff;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0E1A),
        elevation: 0,
        title: const Text('タスクを割り当てる', style: TextStyle(color: Colors.white, fontSize: 17)),
        iconTheme: const IconThemeData(color: Colors.white70),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('送信先スタッフ',
                  style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              if (staff.isEmpty)
                Text('配下スタッフが見つかりません。', style: TextStyle(color: Colors.grey[500], fontSize: 12.5))
              else
                Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF141826),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: Column(
                    children: [
                      CheckboxListTile(
                        value: _sendToEveryone,
                        title: Text('全員に送信(${staff.length}名)',
                            style: const TextStyle(color: Colors.white, fontSize: 14)),
                        activeColor: Colors.cyanAccent,
                        checkColor: Colors.black,
                        controlAffinity: ListTileControlAffinity.leading,
                        onChanged: _isSaving
                            ? null
                            : (v) => setState(() {
                                  _sendToEveryone = v ?? false;
                                  _validationError = null;
                                }),
                      ),
                      const Divider(height: 1, color: Colors.white10),
                      ...staff.map((s) => CheckboxListTile(
                            value: _sendToEveryone || _selectedStaffIds.contains(s.uid),
                            title: Text(s.displayName ?? shortStaffId(s.uid),
                                style: const TextStyle(color: Colors.white, fontSize: 14)),
                            activeColor: Colors.cyanAccent,
                            checkColor: Colors.black,
                            controlAffinity: ListTileControlAffinity.leading,
                            onChanged: (_isSaving || _sendToEveryone)
                                ? null
                                : (v) => setState(() {
                                      if (v == true) {
                                        _selectedStaffIds.add(s.uid);
                                      } else {
                                        _selectedStaffIds.remove(s.uid);
                                      }
                                      _validationError = null;
                                    }),
                          )),
                    ],
                  ),
                ),
              const SizedBox(height: 20),
              const Text('タイトル',
                  style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              TextField(
                controller: _titleController,
                enabled: !_isSaving,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: const Color(0xFF141826),
                  hintText: '例:什器の在庫確認',
                  hintStyle: TextStyle(color: Colors.grey[600]),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              const Text('詳細(任意)',
                  style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              TextField(
                controller: _detailController,
                enabled: !_isSaving,
                maxLines: 4,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: const Color(0xFF141826),
                  hintText: '具体的な作業内容や期限などを入力してください',
                  hintStyle: TextStyle(color: Colors.grey[600]),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              if (_validationError != null) ...[
                const SizedBox(height: 12),
                Text(_validationError!,
                    style: const TextStyle(color: Color(0xFFEF4444), fontSize: 12.5)),
              ],
              const SizedBox(height: 24),
              if (_isSaving || _saveFailed)
                _SubmitStatusBar(isSaving: _isSaving, onRetry: _submit)
              else
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _submit,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.cyanAccent,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text('割り当てる', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
// SVによるお知らせ配信(SVメニューの④カードから遷移)
// AssignTaskScreenと同じ複数選択+WriteBatchパターンをannouncementsコレクション向けに
// 複製したもの。完了/問い合わせの概念がないため送信後の確認画面は無く、代わりに
// AppBarから送信済みお知らせの確認状況一覧(SentAnnouncementsScreen)に遷移できる。
// ============================================================

class AnnouncementSendScreen extends StatefulWidget {
  const AnnouncementSendScreen({super.key});

  @override
  State<AnnouncementSendScreen> createState() => _AnnouncementSendScreenState();
}

class _AnnouncementSendScreenState extends State<AnnouncementSendScreen> {
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _bodyController = TextEditingController();
  final Set<String> _selectedStaffIds = {};
  bool _sendToEveryone = false;
  bool _isSaving = false;
  bool _saveFailed = false;
  String? _validationError;

  @override
  void initState() {
    super.initState();
    StaffRosterStore.instance.addListener(_onRosterChanged);
  }

  @override
  void dispose() {
    StaffRosterStore.instance.removeListener(_onRosterChanged);
    _titleController.dispose();
    _bodyController.dispose();
    super.dispose();
  }

  void _onRosterChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _submit() async {
    final roster = StaffRosterStore.instance.staff;
    final targets = _sendToEveryone
        ? roster
        : roster.where((s) => _selectedStaffIds.contains(s.uid)).toList();
    final title = _titleController.text.trim();
    final body = _bodyController.text.trim();
    if (targets.isEmpty || title.isEmpty) {
      setState(() => _validationError = '送信先スタッフとタイトルは必須です。');
      return;
    }

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    setState(() {
      _isSaving = true;
      _saveFailed = false;
      _validationError = null;
    });
    try {
      final batch = FirebaseFirestore.instance.batch();
      for (final staff in targets) {
        final ref = FirebaseFirestore.instance.collection('announcements').doc();
        batch.set(ref, {
          'staffId': staff.uid,
          'sentBy': uid,
          'sentByName': UserSession.instance.displayName,
          'title': title,
          'body': body,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }
      await batch.commit().timeout(const Duration(seconds: 10));
      if (!mounted) return;
      setState(() => _isSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(targets.length == 1
              ? '${targets.first.displayName ?? shortStaffId(targets.first.uid)}さんにお知らせを送信しました。'
              : '${targets.length}名にお知らせを送信しました。'),
          backgroundColor: const Color(0xFF141826),
          behavior: SnackBarBehavior.floating,
        ),
      );
      Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _saveFailed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final staff = StaffRosterStore.instance.staff;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0E1A),
        elevation: 0,
        title: const Text('お知らせ配信', style: TextStyle(color: Colors.white, fontSize: 17)),
        iconTheme: const IconThemeData(color: Colors.white70),
        actions: [
          IconButton(
            icon: const Icon(Icons.history, color: Colors.white70),
            tooltip: '送信済みお知らせの確認状況',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SentAnnouncementsScreen()),
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('送信先スタッフ',
                  style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              if (staff.isEmpty)
                Text('配下スタッフが見つかりません。', style: TextStyle(color: Colors.grey[500], fontSize: 12.5))
              else
                Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF141826),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: Column(
                    children: [
                      CheckboxListTile(
                        value: _sendToEveryone,
                        title: Text('全員に送信(${staff.length}名)',
                            style: const TextStyle(color: Colors.white, fontSize: 14)),
                        activeColor: Colors.cyanAccent,
                        checkColor: Colors.black,
                        controlAffinity: ListTileControlAffinity.leading,
                        onChanged: _isSaving
                            ? null
                            : (v) => setState(() {
                                  _sendToEveryone = v ?? false;
                                  _validationError = null;
                                }),
                      ),
                      const Divider(height: 1, color: Colors.white10),
                      ...staff.map((s) => CheckboxListTile(
                            value: _sendToEveryone || _selectedStaffIds.contains(s.uid),
                            title: Text(s.displayName ?? shortStaffId(s.uid),
                                style: const TextStyle(color: Colors.white, fontSize: 14)),
                            activeColor: Colors.cyanAccent,
                            checkColor: Colors.black,
                            controlAffinity: ListTileControlAffinity.leading,
                            onChanged: (_isSaving || _sendToEveryone)
                                ? null
                                : (v) => setState(() {
                                      if (v == true) {
                                        _selectedStaffIds.add(s.uid);
                                      } else {
                                        _selectedStaffIds.remove(s.uid);
                                      }
                                      _validationError = null;
                                    }),
                          )),
                    ],
                  ),
                ),
              const SizedBox(height: 20),
              const Text('タイトル',
                  style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              TextField(
                controller: _titleController,
                enabled: !_isSaving,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: const Color(0xFF141826),
                  hintText: '例:勤怠報告の締め切り時刻変更について',
                  hintStyle: TextStyle(color: Colors.grey[600]),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              const Text('本文',
                  style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              TextField(
                controller: _bodyController,
                enabled: !_isSaving,
                maxLines: 4,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: const Color(0xFF141826),
                  hintText: 'お知らせの内容を入力してください',
                  hintStyle: TextStyle(color: Colors.grey[600]),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              if (_validationError != null) ...[
                const SizedBox(height: 12),
                Text(_validationError!,
                    style: const TextStyle(color: Color(0xFFEF4444), fontSize: 12.5)),
              ],
              const SizedBox(height: 24),
              if (_isSaving || _saveFailed)
                _SubmitStatusBar(isSaving: _isSaving, onRetry: _submit)
              else
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _submit,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.cyanAccent,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text('送信する', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
// スタッフによるタスク確認(一覧・詳細、ホーム画面のカードから遷移)
// ============================================================

class AssignedTasksScreen extends StatefulWidget {
  const AssignedTasksScreen({super.key});

  @override
  State<AssignedTasksScreen> createState() => _AssignedTasksScreenState();
}

class _AssignedTasksScreenState extends State<AssignedTasksScreen> {
  @override
  void initState() {
    super.initState();
    AssignedTaskStore.instance.addListener(_onChanged);
    HistoryStore.instance.addListener(_onChanged);
  }

  @override
  void dispose() {
    AssignedTaskStore.instance.removeListener(_onChanged);
    HistoryStore.instance.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // ホーム画面の未完了件数と同じロジック(sourceTaskIdが紐づいた完了報告の集合)。
    // この一覧は未完了のみを表示する(完了履歴はSV側の報告受領機能で参照する想定)。
    final completedTaskIds = completedTaskIdsFrom(HistoryStore.instance.entries);
    final tasks = AssignedTaskStore.instance.entries
        .where((t) => !completedTaskIds.contains(t.id))
        .toList();

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0E1A),
        elevation: 0,
        title: const Text('SVからのタスク', style: TextStyle(color: Colors.white, fontSize: 17)),
        iconTheme: const IconThemeData(color: Colors.white70),
      ),
      body: SafeArea(
        child: tasks.isEmpty
            ? Center(
                child: Text('未完了のタスクはありません。',
                    style: TextStyle(color: Colors.grey[500], fontSize: 13)),
              )
            : ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: tasks.length,
                itemBuilder: (context, index) {
                  final task = tasks[index];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Material(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(16),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => AssignedTaskDetailScreen(task: task),
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
                              const CircleAvatar(
                                radius: 20,
                                backgroundColor: Color(0x33F97316),
                                child: Icon(Icons.assignment_ind_outlined,
                                    color: Colors.white, size: 18),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        const Text('タスク',
                                            style: TextStyle(
                                                color: Color(0xFFF97316),
                                                fontSize: 12,
                                                fontWeight: FontWeight.bold)),
                                        Text(task.time,
                                            style: TextStyle(
                                                color: Colors.grey[500], fontSize: 11)),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Text(task.title,
                                        style: const TextStyle(
                                            color: Colors.white, fontSize: 13.5, height: 1.3)),
                                    const SizedBox(height: 4),
                                    Text(
                                        '依頼者: ${task.assignedByName ?? shortStaffId(task.assignedBy)}',
                                        style: TextStyle(
                                            color: Colors.grey[600], fontSize: 11)),
                                  ],
                                ),
                              ),
                              const Icon(Icons.chevron_right, color: Colors.white24, size: 18),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}

class AssignedTaskDetailScreen extends StatelessWidget {
  final AssignedTask task;
  const AssignedTaskDetailScreen({super.key, required this.task});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0E1A),
        elevation: 0,
        title: const Text('タスク詳細', style: TextStyle(color: Colors.white, fontSize: 17)),
        iconTheme: const IconThemeData(color: Colors.white70),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
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
                      children: [
                        const CircleAvatar(
                          radius: 20,
                          backgroundColor: Color(0x33F97316),
                          child: Icon(Icons.assignment_ind_outlined,
                              color: Colors.white, size: 18),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(task.title,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text('依頼者: ${task.assignedByName ?? shortStaffId(task.assignedBy)}',
                        style: TextStyle(color: Colors.grey[400], fontSize: 12.5)),
                    const SizedBox(height: 4),
                    Text('受け取り: ${task.time}',
                        style: TextStyle(color: Colors.grey[400], fontSize: 12.5)),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const Text('内容',
                  style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF141826),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white10),
                ),
                child: Text(
                  task.detail.isEmpty ? '(詳細の記載はありません)' : task.detail,
                  style: const TextStyle(color: Colors.white70, fontSize: 13.5, height: 1.5),
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => ConsultationChatScreen(
                              sourceTaskId: task.id,
                              sourceTaskTitle: task.title,
                            ),
                          ),
                        );
                      },
                      icon: const Icon(Icons.chat_bubble_outline, size: 18),
                      label: const Text('問い合わせ'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white24),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => TaskQuickCompleteScreen(task: task),
                          ),
                        );
                      },
                      icon: const Icon(Icons.check_circle_outline, size: 18),
                      label: const Text('完了'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.cyanAccent,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// タスク詳細画面の「完了」ボタンから遷移する、シンプルな完了報告フォーム。
/// 既存のTaskCompletionChatScreen(3問チャット)とは異なり、タスク内容は既知の
/// ため聞き直さず、自由記載欄(任意)のみでワンタップ相当の軽い操作にしている。
class TaskQuickCompleteScreen extends StatefulWidget {
  final AssignedTask task;
  const TaskQuickCompleteScreen({super.key, required this.task});

  @override
  State<TaskQuickCompleteScreen> createState() => _TaskQuickCompleteScreenState();
}

class _TaskQuickCompleteScreenState extends State<TaskQuickCompleteScreen> {
  final TextEditingController _memoController = TextEditingController();
  bool _isSaving = false;
  bool _saveFailed = false;

  @override
  void dispose() {
    _memoController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_isSaving) return; // 二重送信防止(SvSummaryScreen._decideと同じガード)
    setState(() {
      _isSaving = true;
      _saveFailed = false;
    });
    final memo = _memoController.text.trim();
    final entry = HistoryEntry(
      id: generateReportId(),
      category: 'タスク完了',
      title: widget.task.title,
      action: SuggestedAction.approveOnly,
      fields: [
        MapEntry('タスク', widget.task.title),
        MapEntry('完了メモ', memo.isEmpty ? '(記載なし)' : memo),
      ],
      history: const [],
      sourceTaskId: widget.task.id,
    );
    try {
      await HistoryStore.instance.add(entry);
      if (!mounted) return;
      // 成功時はNavigatorで一覧に戻るまで_isSavingをtrueのままにしておく
      // (SvSummaryScreen._decideと同じ)。ここでfalseに戻すと、自動遷移までの
      // 間だけボタンが再度タップ可能になり、連打で二重送信されてしまう。
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('完了報告を送信しました。'),
          backgroundColor: Color(0xFF141826),
          behavior: SnackBarBehavior.floating,
        ),
      );
      // スナックバーが見える程度の間を置いてから、タスク一覧画面まで自動で戻る
      // (SvSummaryScreen._decideの成功時と同じパターン)。詳細画面→完了報告画面と
      // 2つ進んだ状態なので、一覧まで戻るには2回popする。
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (!mounted) return;
      Navigator.of(context)
        ..pop()
        ..pop();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _saveFailed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0E1A),
        elevation: 0,
        title: const Text('タスク完了報告', style: TextStyle(color: Colors.white, fontSize: 17)),
        iconTheme: const IconThemeData(color: Colors.white70),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF141826),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('完了するタスク',
                        style: TextStyle(
                            color: Colors.grey, fontSize: 12, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 6),
                    Text(widget.task.title,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              const Text('完了メモ(任意)',
                  style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              TextField(
                controller: _memoController,
                enabled: !_isSaving,
                maxLines: 4,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: const Color(0xFF141826),
                  hintText: '特記事項があれば入力してください(空欄でも送信できます)',
                  hintStyle: TextStyle(color: Colors.grey[600]),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              if (_isSaving || _saveFailed)
                _SubmitStatusBar(isSaving: _isSaving, onRetry: _submit)
              else
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _submit,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.cyanAccent,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text('完了として報告する',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
// スタッフによるお知らせ確認(一覧・詳細、ホーム画面の通知カードから遷移)
// ============================================================

class AnnouncementsScreen extends StatefulWidget {
  const AnnouncementsScreen({super.key});

  @override
  State<AnnouncementsScreen> createState() => _AnnouncementsScreenState();
}

class _AnnouncementsScreenState extends State<AnnouncementsScreen> {
  @override
  void initState() {
    super.initState();
    ReceivedAnnouncementStore.instance.addListener(_onChanged);
  }

  @override
  void dispose() {
    ReceivedAnnouncementStore.instance.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final announcements = ReceivedAnnouncementStore.instance.entries;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0E1A),
        elevation: 0,
        title: const Text('SVからのお知らせ', style: TextStyle(color: Colors.white, fontSize: 17)),
        iconTheme: const IconThemeData(color: Colors.white70),
      ),
      body: SafeArea(
        child: announcements.isEmpty
            ? Center(
                child: Text('お知らせはありません。',
                    style: TextStyle(color: Colors.grey[500], fontSize: 13)),
              )
            : ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: announcements.length,
                itemBuilder: (context, index) {
                  final announcement = announcements[index];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Material(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(16),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) =>
                                  AnnouncementDetailScreen(announcement: announcement),
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
                              const CircleAvatar(
                                radius: 20,
                                backgroundColor: Color(0x3306B6D4),
                                child: Icon(Icons.campaign_outlined,
                                    color: Colors.white, size: 18),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        const Text('お知らせ',
                                            style: TextStyle(
                                                color: Color(0xFF06B6D4),
                                                fontSize: 12,
                                                fontWeight: FontWeight.bold)),
                                        Text(announcement.time,
                                            style: TextStyle(
                                                color: Colors.grey[500], fontSize: 11)),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Text(announcement.title,
                                        style: const TextStyle(
                                            color: Colors.white, fontSize: 13.5, height: 1.3)),
                                    const SizedBox(height: 8),
                                    _AnnouncementStatusChip(
                                        isConfirmed: announcement.isConfirmed),
                                  ],
                                ),
                              ),
                              const Icon(Icons.chevron_right, color: Colors.white24, size: 18),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}

class _AnnouncementStatusChip extends StatelessWidget {
  final bool isConfirmed;
  const _AnnouncementStatusChip({required this.isConfirmed});

  @override
  Widget build(BuildContext context) {
    final color = isConfirmed ? const Color(0xFF22C55E) : Colors.grey[500]!;
    final icon = isConfirmed ? Icons.check_circle : Icons.mark_email_unread_outlined;
    final label = isConfirmed ? '確認済み' : '未確認';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: isConfirmed ? color.withValues(alpha: 0.15) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: isConfirmed ? 0.5 : 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}

class AnnouncementDetailScreen extends StatefulWidget {
  final Announcement announcement;
  const AnnouncementDetailScreen({super.key, required this.announcement});

  @override
  State<AnnouncementDetailScreen> createState() => _AnnouncementDetailScreenState();
}

class _AnnouncementDetailScreenState extends State<AnnouncementDetailScreen> {
  bool _isConfirming = false;
  bool _confirmFailed = false;
  DateTime? _confirmedAtOverride;

  Future<void> _confirm() async {
    if (_isConfirming) return; // 二重送信防止
    setState(() {
      _isConfirming = true;
      _confirmFailed = false;
    });
    try {
      await FirebaseFirestore.instance
          .collection('announcements')
          .doc(widget.announcement.id)
          .update({'confirmedAt': FieldValue.serverTimestamp()})
          .timeout(const Duration(seconds: 10));
      if (!mounted) return;
      // 成功時はNavigatorで一覧に戻るまで_isConfirmingをtrueのままにしておく
      // (TaskQuickCompleteScreen._submitと同じ)。ここでfalseに戻すと、自動遷移までの
      // 間だけボタンが再度タップ可能になり、連打で二重送信されてしまう。
      setState(() => _confirmedAtOverride = DateTime.now());
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('確認しました。'),
          backgroundColor: Color(0xFF141826),
          behavior: SnackBarBehavior.floating,
        ),
      );
      // スナックバーが見える程度の間を置いてから、一覧画面まで自動で戻る
      // (TaskQuickCompleteScreen._submitの成功時と同じパターン)。
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isConfirming = false;
        _confirmFailed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final announcement = widget.announcement;
    // confirmedAtはFirestore側の更新がReceivedAnnouncementStore経由で反映されるが、
    // この画面はwidget.announcementのスナップショットを保持したままなので、確認直後は
    // _confirmedAtOverrideで見た目を即時反映する(_SvSummaryScreenの_decisionと同じ考え方)。
    final isConfirmed = _confirmedAtOverride != null || announcement.isConfirmed;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0E1A),
        elevation: 0,
        title: const Text('お知らせ詳細', style: TextStyle(color: Colors.white, fontSize: 17)),
        iconTheme: const IconThemeData(color: Colors.white70),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
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
                      children: [
                        const CircleAvatar(
                          radius: 20,
                          backgroundColor: Color(0x3306B6D4),
                          child: Icon(Icons.campaign_outlined, color: Colors.white, size: 18),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(announcement.title,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                        '送信者: ${announcement.sentByName ?? shortStaffId(announcement.sentBy)}',
                        style: TextStyle(color: Colors.grey[400], fontSize: 12.5)),
                    const SizedBox(height: 4),
                    Text('受け取り: ${announcement.time}',
                        style: TextStyle(color: Colors.grey[400], fontSize: 12.5)),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const Text('内容',
                  style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF141826),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white10),
                ),
                child: Text(
                  announcement.body.isEmpty ? '(本文の記載はありません)' : announcement.body,
                  style: const TextStyle(color: Colors.white70, fontSize: 13.5, height: 1.5),
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => ConsultationChatScreen(
                              sourceAnnouncementId: announcement.id,
                              sourceAnnouncementTitle: announcement.title,
                            ),
                          ),
                        );
                      },
                      icon: const Icon(Icons.chat_bubble_outline, size: 18),
                      label: const Text('問い合わせ'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white24),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: isConfirmed
                        ? OutlinedButton.icon(
                            onPressed: null,
                            icon: const Icon(Icons.check_circle, size: 18),
                            label: const Text('確認済み'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFF22C55E),
                              disabledForegroundColor: const Color(0xFF22C55E),
                              side: const BorderSide(color: Color(0xFF22C55E)),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          )
                        : ElevatedButton.icon(
                            onPressed: _isConfirming ? null : _confirm,
                            icon: _isConfirming
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: Colors.black),
                                  )
                                : const Icon(Icons.check_circle_outline, size: 18),
                            label: const Text('確認しました'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.cyanAccent,
                              foregroundColor: Colors.black,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                  ),
                ],
              ),
              if (_confirmFailed) ...[
                const SizedBox(height: 12),
                const Text('確認の送信に失敗しました。もう一度お試しください。',
                    style: TextStyle(color: Color(0xFFEF4444), fontSize: 12.5)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
// SVによる送信済みタスクの確認(SVホーム「既読・完了確認」から遷移)
// 読み取り専用。既存の書き込みロジック(タスク作成・完了報告・問い合わせ)には
// 一切触れない。
// ============================================================

enum _SentTaskTab { incomplete, completed, all }

extension on _SentTaskTab {
  String get label {
    switch (this) {
      case _SentTaskTab.incomplete:
        return '未完了';
      case _SentTaskTab.completed:
        return '完了済み';
      case _SentTaskTab.all:
        return '全件';
    }
  }
}

class SentTasksScreen extends StatefulWidget {
  const SentTasksScreen({super.key});

  @override
  State<SentTasksScreen> createState() => _SentTasksScreenState();
}

class _SentTasksScreenState extends State<SentTasksScreen> {
  _SentTaskTab _selectedTab = _SentTaskTab.incomplete;

  @override
  void initState() {
    super.initState();
    SentTaskStore.instance.addListener(_onChanged);
    SvReportStore.instance.addListener(_onChanged);
    StaffRosterStore.instance.addListener(_onChanged);
  }

  @override
  void dispose() {
    SentTaskStore.instance.removeListener(_onChanged);
    SvReportStore.instance.removeListener(_onChanged);
    StaffRosterStore.instance.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final tasks = SentTaskStore.instance.entries;
    final linkedReports = taskLinkedReportsFrom(SvReportStore.instance.entries);
    final staffNames = {
      for (final s in StaffRosterStore.instance.staff) s.uid: s.displayName,
    };

    bool isCompleted(String taskId) =>
        linkedReports[taskId]?.any((r) => r.category == 'タスク完了') ?? false;

    List<AssignedTask> filtered;
    switch (_selectedTab) {
      case _SentTaskTab.incomplete:
        filtered = tasks.where((t) => !isCompleted(t.id)).toList();
        break;
      case _SentTaskTab.completed:
        filtered = tasks.where((t) => isCompleted(t.id)).toList();
        break;
      case _SentTaskTab.all:
        filtered = tasks;
        break;
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0E1A),
        elevation: 0,
        title: const Text('送信したタスク', style: TextStyle(color: Colors.white, fontSize: 17)),
        iconTheme: const IconThemeData(color: Colors.white70),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  for (final tab in _SentTaskTab.values) ...[
                    if (tab != _SentTaskTab.values.first) const SizedBox(width: 8),
                    Expanded(
                      child: _SummaryTabChip(
                        label: tab.label,
                        selected: tab == _selectedTab,
                        onTap: () => setState(() => _selectedTab = tab),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Text('該当するタスクはありません。',
                          style: TextStyle(color: Colors.grey[500], fontSize: 13)),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final task = filtered[index];
                        final reports = linkedReports[task.id] ?? const [];
                        final completed = reports.any((r) => r.category == 'タスク完了');
                        final hasInquiry = reports.any((r) => r.category == '業務相談');
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Material(
                            color: Colors.transparent,
                            borderRadius: BorderRadius.circular(16),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(16),
                              onTap: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => SentTaskDetailScreen(
                                      task: task,
                                      linkedReports: reports,
                                      staffName: staffNames[task.staffId],
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
                                    const CircleAvatar(
                                      radius: 20,
                                      backgroundColor: Color(0x33F97316),
                                      child: Icon(Icons.assignment_ind_outlined,
                                          color: Colors.white, size: 18),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                            children: [
                                              Expanded(
                                                child: Text(
                                                  '宛先: ${staffNames[task.staffId] ?? shortStaffId(task.staffId)}',
                                                  style: const TextStyle(
                                                      color: Color(0xFFF97316),
                                                      fontSize: 12,
                                                      fontWeight: FontWeight.bold),
                                                ),
                                              ),
                                              Text(task.time,
                                                  style: TextStyle(
                                                      color: Colors.grey[500], fontSize: 11)),
                                            ],
                                          ),
                                          const SizedBox(height: 4),
                                          Text(task.title,
                                              style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 13.5,
                                                  height: 1.3)),
                                          const SizedBox(height: 8),
                                          Wrap(
                                            spacing: 6,
                                            runSpacing: 6,
                                            children: [
                                              _SentTaskStatusChip(isCompleted: completed),
                                              if (hasInquiry) const _InquiryChip(),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                    const Icon(Icons.chevron_right, color: Colors.white24, size: 18),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SentTaskStatusChip extends StatelessWidget {
  final bool isCompleted;
  const _SentTaskStatusChip({required this.isCompleted});

  @override
  Widget build(BuildContext context) {
    final color = isCompleted ? const Color(0xFF22C55E) : Colors.grey[500]!;
    final icon = isCompleted ? Icons.check_circle : Icons.pending_outlined;
    final label = isCompleted ? '完了済み' : '未完了';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: isCompleted ? color.withValues(alpha: 0.15) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: isCompleted ? 0.5 : 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}

class _InquiryChip extends StatelessWidget {
  const _InquiryChip();

  @override
  Widget build(BuildContext context) {
    const color = Color(0xFFA855F7);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.chat_bubble_outline, size: 12, color: color),
          SizedBox(width: 4),
          Text('問い合わせあり',
              style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}

class SentTaskDetailScreen extends StatelessWidget {
  final AssignedTask task;
  final List<HistoryEntry> linkedReports;
  final String? staffName;

  const SentTaskDetailScreen({
    super.key,
    required this.task,
    required this.linkedReports,
    this.staffName,
  });

  @override
  Widget build(BuildContext context) {
    final completed = linkedReports.any((r) => r.category == 'タスク完了');

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0E1A),
        elevation: 0,
        title: const Text('タスク詳細', style: TextStyle(color: Colors.white, fontSize: 17)),
        iconTheme: const IconThemeData(color: Colors.white70),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
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
                      children: [
                        const CircleAvatar(
                          radius: 20,
                          backgroundColor: Color(0x33F97316),
                          child: Icon(Icons.assignment_ind_outlined,
                              color: Colors.white, size: 18),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(task.title,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text('宛先: ${staffName ?? shortStaffId(task.staffId)}',
                        style: TextStyle(color: Colors.grey[400], fontSize: 12.5)),
                    const SizedBox(height: 4),
                    Text('送信: ${task.time}',
                        style: TextStyle(color: Colors.grey[400], fontSize: 12.5)),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        _SentTaskStatusChip(isCompleted: completed),
                        if (linkedReports.any((r) => r.category == '業務相談'))
                          const _InquiryChip(),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const Text('内容',
                  style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF141826),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white10),
                ),
                child: Text(
                  task.detail.isEmpty ? '(詳細の記載はありません)' : task.detail,
                  style: const TextStyle(color: Colors.white70, fontSize: 13.5, height: 1.5),
                ),
              ),
              if (linkedReports.isNotEmpty) ...[
                const SizedBox(height: 20),
                const Text('スタッフからの回答',
                    style:
                        TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                for (final report in linkedReports) ...[
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(14),
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
                            Text(report.category,
                                style: TextStyle(
                                    color: report.color,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold)),
                            Text(report.time,
                                style: TextStyle(color: Colors.grey[500], fontSize: 11)),
                          ],
                        ),
                        const SizedBox(height: 6),
                        for (final field in report.fields)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: RichText(
                              text: TextSpan(
                                style: const TextStyle(fontSize: 12.5, height: 1.4),
                                children: [
                                  TextSpan(
                                      text: '${field.key}: ',
                                      style: TextStyle(color: Colors.grey[500])),
                                  TextSpan(
                                      text: field.value,
                                      style: const TextStyle(color: Colors.white70)),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
// SVによる送信済みお知らせの確認状況(AnnouncementSendScreenのAppBarから遷移)
// SentTasksScreen/SentTaskDetailScreenと同じ構造をannouncements向けに複製したもの。
// 確認済み判定はannouncementsドキュメント自身のconfirmedAtを直接見るため、
// タスクのようなsourceTaskId横断集計(taskLinkedReportsFrom相当)は確認判定には不要
// (問い合わせ有無の判定にはannouncementLinkedReportsFromを使う)。
// ============================================================

enum _SentAnnouncementTab { unconfirmed, confirmed, all }

extension on _SentAnnouncementTab {
  String get label {
    switch (this) {
      case _SentAnnouncementTab.unconfirmed:
        return '未確認';
      case _SentAnnouncementTab.confirmed:
        return '確認済み';
      case _SentAnnouncementTab.all:
        return '全件';
    }
  }
}

class SentAnnouncementsScreen extends StatefulWidget {
  const SentAnnouncementsScreen({super.key});

  @override
  State<SentAnnouncementsScreen> createState() => _SentAnnouncementsScreenState();
}

class _SentAnnouncementsScreenState extends State<SentAnnouncementsScreen> {
  _SentAnnouncementTab _selectedTab = _SentAnnouncementTab.unconfirmed;

  @override
  void initState() {
    super.initState();
    SentAnnouncementStore.instance.addListener(_onChanged);
    SvReportStore.instance.addListener(_onChanged);
    StaffRosterStore.instance.addListener(_onChanged);
  }

  @override
  void dispose() {
    SentAnnouncementStore.instance.removeListener(_onChanged);
    SvReportStore.instance.removeListener(_onChanged);
    StaffRosterStore.instance.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final announcements = SentAnnouncementStore.instance.entries;
    final linkedReports = announcementLinkedReportsFrom(SvReportStore.instance.entries);
    final staffNames = {
      for (final s in StaffRosterStore.instance.staff) s.uid: s.displayName,
    };

    List<Announcement> filtered;
    switch (_selectedTab) {
      case _SentAnnouncementTab.unconfirmed:
        filtered = announcements.where((a) => !a.isConfirmed).toList();
        break;
      case _SentAnnouncementTab.confirmed:
        filtered = announcements.where((a) => a.isConfirmed).toList();
        break;
      case _SentAnnouncementTab.all:
        filtered = announcements;
        break;
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0E1A),
        elevation: 0,
        title: const Text('送信したお知らせ', style: TextStyle(color: Colors.white, fontSize: 17)),
        iconTheme: const IconThemeData(color: Colors.white70),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  for (final tab in _SentAnnouncementTab.values) ...[
                    if (tab != _SentAnnouncementTab.values.first) const SizedBox(width: 8),
                    Expanded(
                      child: _SummaryTabChip(
                        label: tab.label,
                        selected: tab == _selectedTab,
                        onTap: () => setState(() => _selectedTab = tab),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Text('該当するお知らせはありません。',
                          style: TextStyle(color: Colors.grey[500], fontSize: 13)),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final announcement = filtered[index];
                        final reports = linkedReports[announcement.id] ?? const [];
                        final hasInquiry = reports.any((r) => r.category == '業務相談');
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Material(
                            color: Colors.transparent,
                            borderRadius: BorderRadius.circular(16),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(16),
                              onTap: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => SentAnnouncementDetailScreen(
                                      announcement: announcement,
                                      linkedReports: reports,
                                      staffName: staffNames[announcement.staffId],
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
                                    const CircleAvatar(
                                      radius: 20,
                                      backgroundColor: Color(0x3306B6D4),
                                      child: Icon(Icons.campaign_outlined,
                                          color: Colors.white, size: 18),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                            children: [
                                              Expanded(
                                                child: Text(
                                                  '宛先: ${staffNames[announcement.staffId] ?? shortStaffId(announcement.staffId)}',
                                                  style: const TextStyle(
                                                      color: Color(0xFF06B6D4),
                                                      fontSize: 12,
                                                      fontWeight: FontWeight.bold),
                                                ),
                                              ),
                                              Text(announcement.time,
                                                  style: TextStyle(
                                                      color: Colors.grey[500], fontSize: 11)),
                                            ],
                                          ),
                                          const SizedBox(height: 4),
                                          Text(announcement.title,
                                              style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 13.5,
                                                  height: 1.3)),
                                          const SizedBox(height: 8),
                                          Wrap(
                                            spacing: 6,
                                            runSpacing: 6,
                                            children: [
                                              _AnnouncementStatusChip(
                                                  isConfirmed: announcement.isConfirmed),
                                              if (hasInquiry) const _InquiryChip(),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                    const Icon(Icons.chevron_right,
                                        color: Colors.white24, size: 18),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class SentAnnouncementDetailScreen extends StatelessWidget {
  final Announcement announcement;
  final List<HistoryEntry> linkedReports;
  final String? staffName;

  const SentAnnouncementDetailScreen({
    super.key,
    required this.announcement,
    required this.linkedReports,
    this.staffName,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0E1A),
        elevation: 0,
        title: const Text('お知らせ詳細', style: TextStyle(color: Colors.white, fontSize: 17)),
        iconTheme: const IconThemeData(color: Colors.white70),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
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
                      children: [
                        const CircleAvatar(
                          radius: 20,
                          backgroundColor: Color(0x3306B6D4),
                          child: Icon(Icons.campaign_outlined, color: Colors.white, size: 18),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(announcement.title,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text('宛先: ${staffName ?? shortStaffId(announcement.staffId)}',
                        style: TextStyle(color: Colors.grey[400], fontSize: 12.5)),
                    const SizedBox(height: 4),
                    Text('送信: ${announcement.time}',
                        style: TextStyle(color: Colors.grey[400], fontSize: 12.5)),
                    if (announcement.isConfirmed) ...[
                      const SizedBox(height: 4),
                      Text('確認: ${formatRelativeTime(announcement.confirmedAt!)}',
                          style: TextStyle(color: Colors.grey[400], fontSize: 12.5)),
                    ],
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        _AnnouncementStatusChip(isConfirmed: announcement.isConfirmed),
                        if (linkedReports.any((r) => r.category == '業務相談'))
                          const _InquiryChip(),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const Text('内容',
                  style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF141826),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white10),
                ),
                child: Text(
                  announcement.body.isEmpty ? '(本文の記載はありません)' : announcement.body,
                  style: const TextStyle(color: Colors.white70, fontSize: 13.5, height: 1.5),
                ),
              ),
              if (linkedReports.isNotEmpty) ...[
                const SizedBox(height: 20),
                const Text('スタッフからの回答',
                    style:
                        TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                for (final report in linkedReports) ...[
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(14),
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
                            Text(report.category,
                                style: TextStyle(
                                    color: report.color,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold)),
                            Text(report.time,
                                style: TextStyle(color: Colors.grey[500], fontSize: 11)),
                          ],
                        ),
                        const SizedBox(height: 6),
                        for (final field in report.fields)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: RichText(
                              text: TextSpan(
                                style: const TextStyle(fontSize: 12.5, height: 1.4),
                                children: [
                                  TextSpan(
                                      text: '${field.key}: ',
                                      style: TextStyle(color: Colors.grey[500])),
                                  TextSpan(
                                      text: field.value,
                                      style: const TextStyle(color: Colors.white70)),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
// SVによるスタッフ別管理(SVホーム画面のカードから遷移)
// 新規Firestoreクエリは追加せず、StaffRosterStore/SvReportStore/SentTaskStoreが
// 既に購読済みのデータをstaffIdでクライアント側フィルタするだけで構成する。
// ============================================================

class StaffManagementListScreen extends StatefulWidget {
  const StaffManagementListScreen({super.key});

  @override
  State<StaffManagementListScreen> createState() => _StaffManagementListScreenState();
}

class _StaffManagementListScreenState extends State<StaffManagementListScreen> {
  @override
  void initState() {
    super.initState();
    StaffRosterStore.instance.addListener(_onChanged);
  }

  @override
  void dispose() {
    StaffRosterStore.instance.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final staff = StaffRosterStore.instance.staff;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0E1A),
        elevation: 0,
        title: const Text('スタッフ別管理', style: TextStyle(color: Colors.white, fontSize: 17)),
        iconTheme: const IconThemeData(color: Colors.white70),
      ),
      body: SafeArea(
        child: staff.isEmpty
            ? Center(
                child: Text('配下スタッフが見つかりません。',
                    style: TextStyle(color: Colors.grey[500], fontSize: 13)),
              )
            : ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: staff.length,
                itemBuilder: (context, index) {
                  final s = staff[index];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Material(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(16),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => StaffDetailScreen(staff: s),
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
                            children: [
                              const CircleAvatar(
                                radius: 20,
                                backgroundColor: Color(0x3364748B),
                                child: Icon(Icons.person, color: Colors.white, size: 18),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(s.displayName ?? shortStaffId(s.uid),
                                    style: const TextStyle(color: Colors.white, fontSize: 14.5)),
                              ),
                              const Icon(Icons.chevron_right, color: Colors.white38, size: 18),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}

class StaffDetailScreen extends StatefulWidget {
  final StaffProfile staff;
  const StaffDetailScreen({super.key, required this.staff});

  @override
  State<StaffDetailScreen> createState() => _StaffDetailScreenState();
}

class _StaffDetailScreenState extends State<StaffDetailScreen> {
  @override
  void initState() {
    super.initState();
    SvReportStore.instance.addListener(_onChanged);
    SentTaskStore.instance.addListener(_onChanged);
  }

  @override
  void dispose() {
    SvReportStore.instance.removeListener(_onChanged);
    SentTaskStore.instance.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Widget _sectionCard({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF141826),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white10),
      ),
      child: child,
    );
  }

  Widget _entryList(List<HistoryEntry> entries, String emptyLabel,
      Map<String, String> reportCategoryById) {
    if (entries.isEmpty) {
      return Text(emptyLabel, style: TextStyle(color: Colors.grey[500], fontSize: 12.5));
    }
    final rows = entries.take(5).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Divider(height: 1, color: Colors.white10),
            ),
          _StaffHistoryRow(entry: rows[i], reportCategoryById: reportCategoryById),
        ],
      ],
    );
  }

  Widget _taskList(List<AssignedTask> tasks, Map<String, List<HistoryEntry>> linkedReports,
      String? staffName) {
    if (tasks.isEmpty) {
      return Text('送信済みのタスクはありません。',
          style: TextStyle(color: Colors.grey[500], fontSize: 12.5));
    }
    final rows = tasks.take(5).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Divider(height: 1, color: Colors.white10),
            ),
          _StaffTaskRow(
            task: rows[i],
            linkedReports: linkedReports[rows[i].id] ?? const [],
            staffName: staffName,
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final staffId = widget.staff.uid;
    final staffName = widget.staff.displayName ?? shortStaffId(staffId);

    final allReports =
        SvReportStore.instance.entries.where((e) => e.staffId == staffId).toList();
    final attendanceReports =
        allReports.where((e) => e.category.startsWith('勤怠')).toList();
    final workReports = allReports
        .where((e) => e.category == '業務報告' || e.category == '業務相談')
        .toList();
    final absentCount = monthlyCategoryCountForStaff(allReports, staffId, '勤怠(欠勤)');
    final lateCount = monthlyCategoryCountForStaff(allReports, staffId, '勤怠(遅刻)');
    // sourceReportIdが紐づく報告(「対応する」経由の業務相談)で、元の報告のカテゴリを
    // 一覧・詳細画面に注記するためのルックアップ。SvReportStoreは既に自チーム全報告を
    // 購読済みのため新規Firestore読み取りは不要。
    final reportCategoryById = {
      for (final e in SvReportStore.instance.entries)
        if (e.id != null) e.id!: e.category,
    };

    final tasks = SentTaskStore.instance.entries.where((t) => t.staffId == staffId).toList();
    final linkedReports = taskLinkedReportsFrom(SvReportStore.instance.entries);

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0E1A),
        elevation: 0,
        title: Text(staffName, style: const TextStyle(color: Colors.white, fontSize: 17)),
        iconTheme: const IconThemeData(color: Colors.white70),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('勤怠状況',
                  style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              _sectionCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('今月: 欠勤$absentCount件・遅刻$lateCount件',
                        style: const TextStyle(
                            color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 10),
                    _entryList(attendanceReports, '勤怠関連の報告はありません。', reportCategoryById),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              const Text('業務報告・相談履歴',
                  style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              _sectionCard(
                  child: _entryList(
                      workReports, '業務報告・相談の履歴はありません。', reportCategoryById)),
              const SizedBox(height: 20),
              const Text('送ったタスクの状況',
                  style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              _sectionCard(child: _taskList(tasks, linkedReports, staffName)),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

class _StaffHistoryRow extends StatelessWidget {
  final HistoryEntry entry;
  final Map<String, String> reportCategoryById;
  const _StaffHistoryRow({required this.entry, required this.reportCategoryById});

  @override
  Widget build(BuildContext context) {
    final sourceReportCategory =
        entry.sourceReportId != null ? reportCategoryById[entry.sourceReportId] : null;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => SvSummaryScreen(
                summary: SvReportSummary(
                  id: entry.id,
                  category: entry.category,
                  icon: entry.icon,
                  color: entry.color,
                  time: entry.time,
                  fields: entry.fields,
                  action: entry.action,
                  history: entry.history,
                  reviewedAction: entry.reviewedAction,
                  sourceReportCategory: sourceReportCategory,
                ),
              ),
            ),
          );
        },
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(entry.icon, color: entry.color, size: 16),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(entry.category,
                      style: TextStyle(
                          color: entry.color, fontSize: 12.5, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 2),
                  Text(entry.title, style: const TextStyle(color: Colors.white, fontSize: 13)),
                  if (sourceReportCategory != null) ...[
                    const SizedBox(height: 2),
                    Text('元の報告:「$sourceReportCategory」への回答',
                        style: const TextStyle(
                            color: Color(0xFFA855F7),
                            fontSize: 11,
                            fontWeight: FontWeight.bold)),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(entry.time, style: TextStyle(color: Colors.grey[500], fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

class _StaffTaskRow extends StatelessWidget {
  final AssignedTask task;
  final List<HistoryEntry> linkedReports;
  final String? staffName;
  const _StaffTaskRow({required this.task, required this.linkedReports, this.staffName});

  @override
  Widget build(BuildContext context) {
    final completed = linkedReports.any((r) => r.category == 'タスク完了');
    final hasInquiry = linkedReports.any((r) => r.category == '業務相談');
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => SentTaskDetailScreen(
                task: task,
                linkedReports: linkedReports,
                staffName: staffName,
              ),
            ),
          );
        },
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.assignment_ind_outlined, color: Colors.white38, size: 16),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(task.title, style: const TextStyle(color: Colors.white, fontSize: 13)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      _SentTaskStatusChip(isCompleted: completed),
                      if (hasInquiry) const _InquiryChip(),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(task.time, style: TextStyle(color: Colors.grey[500], fontSize: 11)),
          ],
        ),
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
          _SettingsNavTile(
            icon: Icons.description_outlined,
            label: '利用規約',
            onTap: () => showComingSoonDialog(context, '利用規約'),
          ),
          _SettingsNavTile(
            icon: Icons.privacy_tip_outlined,
            label: 'プライバシーポリシー',
            onTap: () => showComingSoonDialog(context, 'プライバシーポリシー'),
          ),
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
  final String? id;
  final String category;
  final IconData icon;
  final Color color;
  final String time;
  final List<MapEntry<String, String>> fields;
  final SuggestedAction action;
  final List<ChatMessage> history;
  final SuggestedAction? reviewedAction;
  final String? sourceReportCategory;

  const SvReportSummary({
    this.id,
    required this.category,
    required this.icon,
    required this.color,
    required this.time,
    required this.fields,
    required this.action,
    required this.history,
    this.reviewedAction,
    this.sourceReportCategory,
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
  bool _isSubmitting = false;

  Future<void> _decide(SuggestedAction action, String message) async {
    if (_isSubmitting) return; // 二重送信防止
    setState(() => _isSubmitting = true);
    BeforeUnloadGuard.enable();

    final reportId = widget.summary.id;
    final uid = FirebaseAuth.instance.currentUser?.uid;
    var success = false;

    if (reportId != null && uid != null) {
      final update = <String, dynamic>{
        'reviewedBy': uid,
        'reviewedAt': FieldValue.serverTimestamp(),
        'reviewedAction': action.name,
      };
      if (action == SuggestedAction.approveOnly) {
        update['approvedAt'] = FieldValue.serverTimestamp();
      } else {
        // 承認済みの報告を後から再調整/エスカレーションに変更した場合、
        // approvedAtが残ったままだと「承認済み」バッジと「要対応」タブの
        // 両方に矛盾して現れてしまうため、明示的にクリアする。
        update['approvedAt'] = FieldValue.delete();
      }
      try {
        // オフライン時、Firestoreは書き込みをキューイングして待ち続け例外を投げないため、
        // 一定時間で諦めてエラー扱いにする(updateは同じフィールドへの上書きで冪等なため、
        // 再度ボタンを押し直しても重複の心配はない)。
        await FirebaseFirestore.instance
            .collection('reports')
            .doc(reportId)
            .update(update)
            .timeout(const Duration(seconds: 10));
        success = true;
      } catch (e) {
        debugPrint('[SvSummaryScreen] 対応状況の更新に失敗しました: $e');
      }
    }
    BeforeUnloadGuard.disable();

    if (!mounted) return;

    if (!success) {
      // 失敗時は選択状態を反映せず、再度ボタンを押し直せるようにする。
      setState(() => _isSubmitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('保存に失敗しました。通信状況をご確認のうえ、もう一度お試しください。'),
          backgroundColor: Color(0xFF7F1D1D),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    setState(() => _decision = action);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFF141826),
        behavior: SnackBarBehavior.floating,
      ),
    );

    // スナックバーが見える程度の間を置いてから、前の画面(一覧)に自動で戻る。
    await Future<void>.delayed(const Duration(milliseconds: 700));
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.summary;
    final effectiveAction = _decision ?? s.action;
    final isSv = UserSession.instance.role == UserRole.sv;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0E1A),
        elevation: 0,
        title: Text(isSv ? 'SV確認画面' : '報告詳細',
            style: const TextStyle(color: Colors.white, fontSize: 17)),
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
                          if (s.sourceReportCategory != null) ...[
                            const SizedBox(height: 4),
                            Text('元の報告:「${s.sourceReportCategory}」への回答',
                                style: const TextStyle(
                                    color: Color(0xFFA855F7),
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold)),
                          ],
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
              if (!isSv && s.reviewedAction == SuggestedAction.needsReschedule) ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => ConsultationChatScreen(
                            sourceReportId: s.id,
                            sourceReportTitle: s.category,
                          ),
                        ),
                      );
                    },
                    icon: const Icon(Icons.chat_bubble_outline, size: 18),
                    label: const Text('対応する'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.cyanAccent,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ],
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
      bottomNavigationBar: !isSv
          ? null
          : SafeArea(
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
                        onTap: _isSubmitting
                            ? null
                            : () => _decide(SuggestedAction.approveOnly, '承認しました'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _SvActionButton(
                        label: '再調整依頼',
                        icon: Icons.sync_problem,
                        color: const Color(0xFFF59E0B),
                        selected: effectiveAction == SuggestedAction.needsReschedule,
                        onTap: _isSubmitting
                            ? null
                            : () => _decide(SuggestedAction.needsReschedule, '再調整を依頼しました'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _SvActionButton(
                        label: 'エスカレーション',
                        icon: Icons.priority_high,
                        color: const Color(0xFFEF4444),
                        selected: effectiveAction == SuggestedAction.escalate,
                        onTap: _isSubmitting
                            ? null
                            : () => _decide(SuggestedAction.escalate, 'エスカレーションしました'),
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
  final VoidCallback? onTap;
  const _SvActionButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Opacity(
          opacity: disabled ? 0.4 : 1,
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
      ),
    );
  }
}

// ============================================================
// ログイン画面(モックアップ:認証ロジックは未実装)
// ============================================================