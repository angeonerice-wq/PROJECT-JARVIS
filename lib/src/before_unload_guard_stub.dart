/// Web以外のプラットフォーム向けの何もしない実装。
/// `main.dart`からは`dart.library.html`の条件付きインポートで
/// Web版(`before_unload_guard_web.dart`)と切り替えて使われる。
class BeforeUnloadGuard {
  static void enable() {}
  static void disable() {}
}
