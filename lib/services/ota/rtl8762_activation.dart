/// An activation write can fail when the target resets before its GATT reply.
/// A separately observed disconnect is required; post-activation identity and
/// version checks must still be performed by the caller.
Future<void> confirmRtl8762Activation({
  required Future<void> Function() write,
  required Future<bool> Function() waitForDisconnect,
}) async {
  Object? writeError;
  StackTrace? writeStack;
  try {
    await write();
  } catch (error, stack) {
    writeError = error;
    writeStack = stack;
  }
  if (!await waitForDisconnect()) {
    if (writeError != null) Error.throwWithStackTrace(writeError, writeStack!);
    throw StateError('升级设备未确认激活重启');
  }
}
