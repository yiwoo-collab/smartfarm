import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

/// 웹 버전에서 쓸 한글 글꼴 이름. 불러오지 못하면 null (기본 글꼴).
String? webFontFamily;

/// 웹 버전만: web/fonts 의 Noto Sans KR을 불러온다.
/// Flutter 웹은 원래 글꼴을 Google 서버에서 받는데, 바로 보기 링크(호스팅 페이지)는
/// 외부 요청이 막혀 한글이 네모로 나온다. 그래서 글꼴을 같이 올리고 직접 읽는다.
/// 안드로이드 앱은 폰 글꼴을 쓰므로 아무것도 하지 않는다 (APK 크기 그대로).
Future<void> loadWebKoreanFont() async {
  if (!kIsWeb) return;
  try {
    final loader = FontLoader('NotoSansKR');
    var added = 0;
    for (final file in const [
      'fonts/NotoSansKR-Regular.otf',
      'fonts/NotoSansKR-Bold.otf',
    ]) {
      final res = await http.get(Uri.base.resolve(file));
      if (res.statusCode == 200) {
        loader.addFont(Future.value(ByteData.sublistView(res.bodyBytes)));
        added++;
      }
    }
    if (added == 0) return;
    await loader.load();
    webFontFamily = 'NotoSansKR';
  } catch (_) {
    // 글꼴을 못 불러와도 앱은 그대로 동작한다
  }
}
