/// Which phone the tool acts as.
enum PhonePlatform { iphone, android }

extension PhonePlatformText on PhonePlatform {
  /// "iPhone" / "Android".
  String get short => this == PhonePlatform.iphone ? 'iPhone' : 'Android';

  /// "iPhone" / "Android phone".
  String get phone => this == PhonePlatform.iphone ? 'iPhone' : 'Android phone';

  /// "iPhone app" / "Android app".
  String get app => this == PhonePlatform.iphone ? 'iPhone app' : 'Android app';

  /// iOS ends a reader session after 60 s; Android has no session limit.
  bool get hasSessionLimit => this == PhonePlatform.iphone;
}
