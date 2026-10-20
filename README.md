# CALLSHARE FINAL — iOS log cleanup + call-end candidate

This is a **separate untested candidate** built from the uploaded `callshareioslast.zip` source tree and the full Android R1 source. It is not the existing installed stable app or a final production release.

## User-requested scope
1. Remove iOS Live Log / diagnostic screens and runtime diagnostic output while preserving BLE/Wi-Fi connection state and IP display.
2. Make iPhone CallKit End issue serialized BLE `VOICE_CLOSE` then `HANGUP`, and have the Android bridge request a real cellular hang-up, reporting call end only after `CALL_STATE_IDLE`.
3. Preserve the working audio path.

## iOS project
The project root is this folder: `J7Bridge.xcodeproj`, `J7Bridge/`, `.github/`, `Scripts/`. Use these files in a **separate copy/branch** of CALLSHARENEW; do not overwrite the current stable commit in place. `PRODUCT_BUNDLE_IDENTIFIER` is set to `com.ugur.callshare.callendlogr1` with a matching unique BLE restoration identifier, so this candidate can be installed side-by-side without overwriting the already-tested `com.ugur.callshare.audiofixr2` app.

- Removed `DiagnosticLogView` / Live Log page and in-memory logs array.
- Removed app BLE/CallKit direct diagnostic output and disabled existing `log()` / `report()` message sinks via lazy no-op autoclosures.
- Main status card keeps Wi-Fi state, BLE state, J7 IPv4, and iPhone IPv4.
- BLE control writes are serialized using `didWriteValueFor` acknowledgements, so the `VOICE_CLOSE` write is processed before the subsequent `HANGUP` request. This change affects the BLE control plane only, not BLE audio framing.
- `WiFiTransport.swift` is byte-for-byte identical to the uploaded source.
- `WiFiVoiceEngine.swift` differs only in the final diagnostics `report()` sink; audio capture, packetization, playback queue, stall recovery, route recovery and PCM protocol logic are untouched.

## Android patch
Read `ANDROID_HANGUP_PATCH/README_TR.md`. The uploads represent multiple Android source variants, so the patch includes a unified diff for the full R1 project and a precise one-line case-4 merge note for the newer MainActivity in `ccallsharegüncel.zip`. Only Android `TelephonyBridge.java` and the HANGUP command branch are changed. `WifiCoreSupervisor.java` and the J7 Core are untouched. No private keystore is included.

## Checks performed
- Swift parser (`swiftc -frontend -parse`) passed for modified Swift files. This is **not** a full Xcode/iOS SDK build.
- No `NSLog`, `print`, `os_log`, `Logger`, Live Log, Diagnostic Log view or `@Published logs` collection remains under `J7Bridge/*.swift`.
- `WiFiTransport.swift` is byte-for-byte unchanged; `WiFiVoiceEngine.swift` differs only in `report()` sink.
- Android changes are source-reviewed and patch-tested against the provided full R1 archive; Android SDK build and physical J7 GSM hang-up test have not been run here.

## Test plan before calling this FINAL
1. Build iOS IPA on GitHub Actions and install alongside the existing working app.
2. Build/sign the Android companion APK with the correct existing signing key; grant `ANSWER_PHONE_CALLS`.
3. Test iPhone CallKit End during a real GSM call; verify `CALL_STATE_IDLE` and the actual GSM call disconnect.
4. Verify BLE connected, Wi-Fi connected, both IP values, and automatic IP update.
5. Run at least 3 consecutive calls, lock-screen answer, and a long idle (10-hour if practical) call wake test to verify audio remains good.

Do not modify the known-good J7 Wi-Fi Core or PCM/audio engine as part of this work.
