/// Applies the common identity, type, and field checks for immutable values.
bool ylValueEquals<T extends Object>(
  T value,
  Object? other,
  bool Function(T other) fieldsEqual,
) => identical(value, other) || other is T && fieldsEqual(other);

/// Typed nullable copy value with input-free errors for untrusted metadata.
T? ylNullableValue<T>(Object? value) {
  if (value == null || value is T) return value as T?;
  throw ArgumentError('Copy value has an invalid type.');
}
