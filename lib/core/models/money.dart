int majorToMinor(double amount, {int fractionDigits = 2}) {
  if (!amount.isFinite) {
    throw ArgumentError.value(amount, 'amount', 'Amount must be finite.');
  }
  final factor = _powerOfTen(fractionDigits);
  return (amount * factor).round();
}

double minorToMajor(int amountMinor, {int fractionDigits = 2}) {
  return amountMinor / _powerOfTen(fractionDigits);
}

int _powerOfTen(int exponent) {
  if (exponent < 0 || exponent > 6) {
    throw RangeError.range(exponent, 0, 6, 'fractionDigits');
  }
  var value = 1;
  for (var index = 0; index < exponent; index++) {
    value *= 10;
  }
  return value;
}
