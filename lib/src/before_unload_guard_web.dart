// このファイルはmain.dartの条件付きインポート(dart.library.html)により
// Web版でのみ使われる。dart:htmlの利用は意図的なため、対応する2つのlintを無視する。
// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:html' as html;

/// Web版:報告送信中・SV対応中にページを閉じたりリロードしようとした場合、
/// ブラウザ標準の確認ダイアログ(「変更が保存されていない可能性があります」)を出す。
///
/// 送信中はオフラインならFirestoreの書き込みキューにしか反映されていない可能性があり、
/// ここでページを閉じられると(未確定のまま)何が起きたか分かりづらくなるため、
/// 明示的に確認を挟む。`enable`/`disable`の呼び出し回数をカウントすることで、
/// 複数箇所から同時に呼ばれても正しく状態を保てるようにしている。
class BeforeUnloadGuard {
  static int _activeCount = 0;
  static StreamSubscription<html.Event>? _sub;

  static void enable() {
    _activeCount++;
    _sub ??= html.window.onBeforeUnload.listen((event) {
      if (_activeCount <= 0) return;
      event.preventDefault();
      (event as html.BeforeUnloadEvent).returnValue = '';
    });
  }

  static void disable() {
    if (_activeCount > 0) _activeCount--;
  }
}
