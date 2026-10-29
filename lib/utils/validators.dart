/// Shared input validators — one source for the messages shown on invalid
/// input across auth forms and admin dialogs.
class Validators {
  Validators._();

  static final _emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  static String? required(String? value, [String field = 'This field']) {
    if (value == null || value.trim().isEmpty) return '$field is required';
    return null;
  }

  static String? name(String? value) {
    if (value == null || value.trim().length < 2) {
      return 'Enter your name';
    }
    return null;
  }

  static String? email(String? value) {
    if (value == null || !_emailRe.hasMatch(value.trim())) {
      return 'Enter a valid email';
    }
    return null;
  }

  static String? password(String? value, {int min = 8}) {
    if (value == null || value.length < min) {
      return 'At least $min characters';
    }
    return null;
  }
}
