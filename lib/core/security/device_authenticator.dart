import 'package:local_auth/local_auth.dart';

/// Small boundary around the platform authentication plugin.
///
/// Keeping the plugin behind this interface lets the lock screen exercise its
/// success, cancellation, unsupported-device, and failure paths in widget
/// tests without showing a real system prompt.
abstract interface class DeviceAuthenticator {
  Future<bool> isDeviceSupported();

  Future<bool> authenticate();
}

final class LocalDeviceAuthenticator implements DeviceAuthenticator {
  LocalDeviceAuthenticator({LocalAuthentication? localAuthentication})
    : _localAuthentication = localAuthentication ?? LocalAuthentication();

  final LocalAuthentication _localAuthentication;

  @override
  Future<bool> isDeviceSupported() => _localAuthentication.isDeviceSupported();

  @override
  Future<bool> authenticate() => _localAuthentication.authenticate(
    localizedReason: 'Unlock Expense Tracker',
    biometricOnly: false,
    persistAcrossBackgrounding: true,
  );
}
