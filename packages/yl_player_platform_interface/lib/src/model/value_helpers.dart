/// Applies the common identity, type, and field checks for immutable values.
bool ylValueEquals<T extends Object>(
  T value,
  Object? other,
  bool Function(T other) fieldsEqual,
) => identical(value, other) || other is T && fieldsEqual(other);
