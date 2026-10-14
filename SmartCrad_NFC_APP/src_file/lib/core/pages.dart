/// The pages, in the order the rail shows them. Named, so a new page in the middle cannot quietly send a button to
/// the wrong screen, and so the guide can point at a page without knowing how the screens are wired.
abstract final class Pages {
  /// The launcher: every other page has a tile on it, which is how you get around.
  static const home = 0;
  static const check = 1;
  static const console = 2;
  static const read = 3;
  static const test = 4;
  static const runAll = 5;
  static const burner = 6;
  static const log = 7;
  static const rules = 8;
  static const errorMap = 9;
  static const profiles = 10;
  static const bootloader = 11;
  static const companyId = 12;
  static const appletLog = 13;
  static const count = 14;
}
