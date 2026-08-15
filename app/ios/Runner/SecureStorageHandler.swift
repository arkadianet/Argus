import Foundation
import Flutter
import LocalAuthentication
import Security
import UIKit

/// Secure storage method channel handler for iOS Keychain.
public class SecureStorageHandler: NSObject, FlutterPlugin {

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "com.argus.wallet/secure_storage",
      binaryMessenger: registrar.messenger()
    )
    let instance = SecureStorageHandler()
    instance.observeCapture()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  private let serviceName = "com.argus.wallet.seed"
  private let seedAccount = "encrypted_seed"
  private let wrapAccount = "wrap_key"
  private let pinAccount = "pin_wrap"
  private let pinFailKey = "argus_pin_fail_count"
  private let pinLockKey = "argus_pin_lock_until"
  private var secure = false
  private var cover: UIView?
  private var observing = false

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "saveEncryptedSeed":
      guard let args = call.arguments as? [String: Any],
            let json = args["encryptedSeedJson"] as? String else {
        result(FlutterError(code: "INVALID_ARGS", message: "Missing encryptedSeedJson", details: nil))
        return
      }
      save(json, account: seedAccount, biometric: false, result: result)

    case "loadEncryptedSeed":
      load(account: seedAccount, result: result)

    case "saveWrapKey":
      guard let args = call.arguments as? [String: Any],
            let key = args["wrapKey"] as? String else {
        result(FlutterError(code: "INVALID_ARGS", message: "Missing wrapKey", details: nil))
        return
      }
      save(key, account: wrapAccount, biometric: true, result: result)

    case "loadWrapKey":
      load(account: wrapAccount, result: result)

    case "savePinWrap":
      guard let args = call.arguments as? [String: Any],
            let json = args["pinWrapJson"] as? String else {
        result(FlutterError(code: "INVALID_ARGS", message: "Missing pinWrapJson", details: nil))
        return
      }
      save(json, account: pinAccount, biometric: false, result: result)

    case "loadPinWrap":
      load(account: pinAccount, result: result)

    case "deleteWrapKey":
      delete(account: wrapAccount)
      result(nil)

    case "deleteEncryptedSeed":
      delete(account: seedAccount)
      delete(account: wrapAccount)
      delete(account: pinAccount)
      result(nil)

    case "hasEncryptedSeed":
      result(hasItem(account: seedAccount))

    case "hasPinWrap":
      result(hasItem(account: pinAccount))

    case "hasWrapKey":
      result(hasItem(account: wrapAccount))

    case "hasBiometric":
      let ctx = LAContext()
      var error: NSError?
      let ok = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
      if ok {
        result(true)
      } else if let error, !isAbsentBiometry(error) {
        result(FlutterError(code: "BIOMETRIC", message: error.localizedDescription, details: nil))
      } else {
        result(false)
      }

    case "authenticateBiometric":
      loadProtected(account: wrapAccount, result: result)

    case "setSecureFlag":
      let args = call.arguments as? [String: Any]
      secure = args?["enable"] as? Bool ?? true
      DispatchQueue.main.async { self.updateCover(force: false) }
      result(true)

    case "loadPinGate":
      let defaults = UserDefaults.standard
      result([
        "count": defaults.integer(forKey: pinFailKey),
        "until": defaults.object(forKey: pinLockKey) as? Int ?? 0,
      ])

    case "savePinGate":
      let args = call.arguments as? [String: Any]
      let defaults = UserDefaults.standard
      defaults.set(args?["count"] as? Int ?? 0, forKey: pinFailKey)
      defaults.set(args?["until"] as? Int ?? 0, forKey: pinLockKey)
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func isAbsentBiometry(_ error: NSError) -> Bool {
    let code = LAError.Code(rawValue: error.code)
    return code == .biometryNotAvailable
      || code == .biometryNotEnrolled
      || code == .passcodeNotSet
  }

  private func observeCapture() {
    if observing { return }
    observing = true
    let center = NotificationCenter.default
    center.addObserver(self, selector: #selector(onCaptureChange), name: UIScreen.capturedDidChangeNotification, object: nil)
    center.addObserver(self, selector: #selector(onResign), name: UIApplication.willResignActiveNotification, object: nil)
    center.addObserver(self, selector: #selector(onActive), name: UIApplication.didBecomeActiveNotification, object: nil)
  }

  @objc private func onCaptureChange() {
    updateCover(force: false)
  }

  @objc private func onResign() {
    updateCover(force: true)
  }

  @objc private func onActive() {
    updateCover(force: false)
  }

  private func updateCover(force: Bool) {
    let hide = secure && (force || UIScreen.main.isCaptured)
    if hide {
      if cover == nil, let window = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene })
        .flatMap({ $0.windows })
        .first(where: { $0.isKeyWindow }) {
        let view = UIView(frame: window.bounds)
        view.backgroundColor = .black
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(view)
        cover = view
      }
    } else {
      cover?.removeFromSuperview()
      cover = nil
    }
  }

  private func save(_ value: String, account: String, biometric: Bool, result: @escaping FlutterResult) {
    guard let data = value.data(using: .utf8) else {
      result(FlutterError(code: "ENCODE_ERROR", message: "Failed to encode data", details: nil))
      return
    }

    SecItemDelete(query(account) as CFDictionary)

    var item = query(account)
    item[kSecValueData as String] = data
    if biometric {
      var error: Unmanaged<CFError>?
      guard let access = SecAccessControlCreateWithFlags(
        nil,
        kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        .biometryCurrentSet,
        &error
      ) else {
        result(FlutterError(code: "KEYCHAIN_ERROR", message: error?.takeRetainedValue().localizedDescription ?? "access control", details: nil))
        return
      }
      item[kSecAttrAccessControl as String] = access
    } else {
      item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    }

    let status = SecItemAdd(item as CFDictionary, nil)
    if status == errSecSuccess {
      result(true)
    } else {
      result(FlutterError(code: "KEYCHAIN_ERROR", message: "Failed to save: \(status)", details: nil))
    }
  }

  private func load(account: String, result: @escaping FlutterResult) {
    loadProtected(account: account, result: result)
  }

  private func loadProtected(account: String, result: @escaping FlutterResult) {
    var item = query(account)
    item[kSecReturnData as String] = true
    item[kSecMatchLimit as String] = kSecMatchLimitOne

    var found: CFTypeRef?
    let status = SecItemCopyMatching(item as CFDictionary, &found)

    if status == errSecSuccess, let data = found as? Data {
      result(String(data: data, encoding: .utf8))
    } else if status == errSecItemNotFound || status == errSecUserCanceled {
      result(nil)
    } else {
      result(FlutterError(code: "KEYCHAIN_ERROR", message: "Failed to load: \(status)", details: nil))
    }
  }

  private func delete(account: String) {
    SecItemDelete(query(account) as CFDictionary)
  }

  private func hasItem(account: String) -> Bool {
    var item = query(account)
    item[kSecReturnData as String] = false
    item[kSecMatchLimit as String] = kSecMatchLimitOne
    item[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail

    var found: CFTypeRef?
    let status = SecItemCopyMatching(item as CFDictionary, &found)
    return status == errSecSuccess || status == errSecInteractionNotAllowed
  }

  private func query(_ account: String) -> [String: Any] {
    return [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: serviceName,
      kSecAttrAccount as String: account,
    ]
  }
}
