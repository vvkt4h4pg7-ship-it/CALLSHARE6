# CALLSHARE FINAL R1 — Kaynak analizi ve test durumu

## İncelenen kullanıcı dosyaları
- `callshareioslast.zip`: iOS kaynak projesi.
- `CALLSHARE FİNAL İPA SÜPER ÇALIŞIYOR.zip`: başarılı test IPA'sı; iç binary içinde R3 audio engine, UDP RX recovery ve playback stall recovery string izleri var.
- `CALLSHARE_HYBRID_ANDROID_R1.zip`: tam Android kaynak arşivi.
- `ccallsharegüncel.zip`: daha yeni/different Android MainActivity tek dosya varyantı.
- `callshareapkproje.zip`: `WifiCoreSupervisor.java` ve R2 core koruma notları; çekirdek/supervisor davranışı değiştirilmedi.

## Asıl bulgular
1. iOS `AppModel.endFromCallKit()` zaten önce `sendVoiceClose()`, sonra `sendHangup()` çağırıyor. Kaynaktaki BLE kontrol gönderimi bu iki write için önceki sürümde acknowledgement bekleyen bir kuyruk kullanmıyordu. Adayda yalnızca control writes serialized; `VOICE_CLOSE` write cevabı gelmeden HANGUP gönderilmiyor.
2. Android MainActivity'nin mevcut HANGUP case'i `phone.hangup()` çağırdıktan sonra hemen `send(call.hangup())` ile sentetik `0x04` olayı üretiyor. iOS gerçek çağrı sonu `0x0B` (`EVT_RECEIVE_CALL_END`) bekliyor; gerçek bitiş `TelephonyBridge` içindeki `CALL_STATE_IDLE` ile gönderilmeli. Aday HANGUP case bu sentetik olayı kaldırıyor ve sadece isteğin kabul/ret durumunu not ediyor.
3. Android `TelephonyBridge.hangup()` orijinalinde `TelephonyManager.endCall()` gizli API'sini reflection ile çağırıyordu ve sonucunu kontrol etmiyordu. Aday Android 9+ cihazlar için `TelecomManager.endCall()` kullanıyor, `ANSWER_PHONE_CALLS` izin durumunu kontrol ediyor ve boolean sonucunu döndürüyor. API dokümanı, `endCall()` için `ANSWER_PHONE_CALLS` iznini şart koştuğunu ve boolean dönüşünün bitirilecek/ reddedilecek çağrı olup olmadığını gösterdiğini belirtir. citeturn687328search0
4. iOS Live Log / Diagnostic Log view ve `logs` array kaldırıldı. BLE/CallKit tanılama callback'leri devre dışı bırakıldı; Wi-Fi connection state `NWPathMonitor(requiredInterfaceType: .wifi)` ile gösterilmeye devam ediyor; BLE state ve IPv4 display/IP announcement korunuyor.
5. `WiFiTransport.swift` birebir aynı. `WiFiVoiceEngine.swift` sadece `report()` sink değişikliği taşıyor; PCM formatı, mic capture, packetization, playback queue/stall recovery ve route recovery kodu değiştirilmedi.

## Yapılan statik doğrulama
- Değiştirilen Swift dosyaları `swiftc -frontend -parse` ile parse edildi.
- Swift kaynaklarında doğrudan `NSLog(`, `print(`, `os_log`, `Logger`, `DiagnosticLogView`, `Live Log`, `@Published var logs` bulunmadı.
- Android diff, `CALLSHARE_HYBRID_ANDROID_R1.zip` içindeki orijinal dosyalara karşı hazırlandı. `ccallsharegüncel.zip` MainActivity'si ayrı bir varyant olduğu için dosyanın tamamını bununla değiştirmeyin; sadece HANGUP case'i için `ANDROID_HANGUP_PATCH/MAINACTIVITY_CASE4_MERGE.txt` talimatını izleyin.

## Henüz test edilmedi
- Bu ortamda Xcode/iOS SDK olmadığından yeni IPA derlenmedi.
- Android SDK build ve gerçek J7 aramasını sonlandırma testi yapılmadı.
- `TelecomManager.endCall()` isteğinin `true` dönmesi sadece isteğin kabulünü gösterir; kesin doğrulama J7'nin fiziksel GSM çağrısının `CALL_STATE_IDLE` durumuna geldiğini ve iOS'a 0x0B end event gönderdiğini görmektir.
