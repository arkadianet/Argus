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

  private let service = "com.argus.wallet.seed"
  private let registryAccount = "wallet_registry"

  private func seedAccount(for walletId: String?) -> String {
    walletId != nil ? "seed_\(walletId!)" : "encrypted_seed"
  }
  private func wrapAccount(for walletId: String?) -> String {
    walletId != nil ? "wrap_\(walletId!)" : "wrap_key"
  }
  private func pinAccount(for walletId: String?) -> String {
    walletId != nil ? "pin_\(walletId!)" : "pin_wrap"
  }

  private var secure = false
  private var cover: UIView?
  private var observing = false

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let walletId = (call.arguments as? [String: Any])?["walletId"] as? String
    switch call.method {
    case "saveEncryptedSeed":
      guard let args = call.arguments as? [String: Any],
            let json = args["encryptedSeedJson"] as? String else {
        result(FlutterError(code: "INVALID_ARGS", message: "Missing encryptedSeedJson", details: nil))
        return
      }
      save(json, account: seedAccount(for: walletId), biometric: false, result: result)
      if walletId != nil {
        addWalletId(walletId!)
      }

    case "loadEncryptedSeed":
      load(account: seedAccount(for: walletId), result: result)

    case "saveWrapKey":
      guard let args = call.arguments as? [String: Any],
            let key = args["wrapKey"] as? String else {
        result(FlutterError(code: "INVALID_ARGS", message: "Missing wrapKey", details: nil))
        return
      }
      save(key, account: wrapAccount(for: walletId), biometric: true, result: result)

    case "loadWrapKey":
      load(account: wrapAccount(for: walletId), result: result)

    case "savePinWrap":
      guard let args = call.arguments as? [String: Any],
            let json = args["pinWrapJson"] as? String else {
        result(FlutterError(code: "INVALID_ARGS", message: "Missing pinWrapJson", details: nil))
        return
      }
      save(json, account: pinAccount(for: walletId), biometric: false, result: result)

    case "loadPinWrap":
      load(account: pinAccount(for: walletId), result: result)

    case "deleteWrapKey":
      delete(account: wrapAccount(for: walletId))
      result(nil)

    case "deleteEncryptedSeed":
      delete(account: seedAccount(for: walletId))
      if walletId != nil {
        delete(account: wrapAccount(for: walletId))
        delete(account: pinAccount(for: walletId))
        removeWalletId(walletId!)
      } else {
        delete(account: wrapAccount(for: walletId))
        delete(account: pinAccount(for: walletId))
      }
      result(nil)

    case "deleteWallet":
      guard let args = call.arguments as? [String: Any],
            let wid = args["walletId"] as? String else {
        result(FlutterError(code: "INVALID_ARGS", message: "Missing walletId", details: nil))
        return
      }
      delete(account: seedAccount(for: wid))
      delete(account: wrapAccount(for: wid))
      delete(account: pinAccount(for: wid))
      removeWalletId(wid)
      result(nil)

    case "hasEncryptedSeed":
      if walletId != nil {
        result(hasItem(account: seedAccount(for: walletId)))
      } else {
        result(hasItem(account: "encrypted_seed") || hasItem(account: registryAccount))
      }

    case "hasPinWrap":
      result(hasItem(account: pinAccount(for: walletId)))

    case "hasWrapKey":
      result(hasItem(account: wrapAccount(for: walletId)))

    case "listWalletIds":
      var ids = getWalletIds()
      if hasItem(account: "encrypted_seed") && !ids.contains("legacy") {
        ids.append("legacy")
      }
      result(ids)

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
      loadProtected(account: wrapAccount(for: walletId), result: result)

    case "setSecureFlag":
      let args = call.arguments as? [String: Any]
      secure = args?["enable"] as? Bool ?? true
      DispatchQueue.main.async { self.updateCover(force: false) }
      result(true)

    case "loadPinGate":
      let defaults = UserDefaults.standard
      result([
        "count": defaults.integer(forKey: "argus_pin_fail_count"),
        "until": defaults.object(forKey: "argus_pin_lock_until") as? Int ?? 0,
      ])

    case "savePinGate":
      let args = call.arguments as? [String: Any]
      let defaults = UserDefaults.standard
      defaults.set(args?["count"] as? Int ?? 0, forKey: "argus_pin_fail_count")
      defaults.set(args?["until"] as? Int ?? 0, forKey: "argus_pin_lock_until")
      result(nil)

    case "migrateLegacyWallet":
      guard let args = call.arguments as? [String: Any],
            let newId = args["newWalletId"] as? String else {
        result(FlutterError(code: "INVALID_ARGS", message: "Missing newWalletId", details: nil))
        return
      }
      let migrated = migrateLegacyWallet(newWalletId: newId)
      result(migrated)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Wallet registry

  private func getWalletIds() -> [String] {
    var query = baseQuery(account: registryAccount)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var found: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &found)
    guard status == errSecSuccess, let data = found as? Data,
          let ids = try? JSONDecoder().decode([String].self, from: data) else {
      return []
    }
    return ids
  }

  private func setWalletIds(_ ids: [String]) {
    guard let data = try? JSONEncoder().encode(ids) else { return }
    delete(account: registryAccount)
    var query = baseQuery(account: registryAccount)
    query[kSecValueData as String] = data
    query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    SecItemAdd(query as CFDictionary, nil)
  }

  private func addWalletId(_ walletId: String) {
    var ids = getWalletIds()
    if !ids.contains(walletId) {
      ids.append(walletId)
      setWalletIds(ids)
    }
  }

  private func removeWalletId(_ walletId: String) {
    var ids = getWalletIds()
    if ids.removeAll { $0 == walletId } {
      setWalletIds(ids)
    }
  }

  private func migrateLegacyWallet(newWalletId: String) -> Bool {
    guard hasItem(account: "encrypted_seed") else { return false }
    let migrated = getWalletIds().toMutableSet()
    if migrated.contains(newWalletId) { return false }
    let seedData = loadData(account: "encrypted_seed")
    let wrapData = loadData(account: "wrap_key")
    let pinData = loadData(account: "pin_wrap")
    var success = true
    if let seed = seedData, !seed.isEmpty {
      save(seed, account: seedAccount(for: newWalletId), biometric: false, result: { _ in })
    } else { success = false }
    if let wrap = wrapData, !wrap.isEmpty {
      save(wrap, account: wrapAccount(for: newWalletId), biometric: true, result: { _ in })
    }
    if let pin = pinData, !pin.isEmpty {
      save(pin, account: pinAccount(for: newWalletId), biometric: false, result: { _ in })
    }
    delete(account: "encrypted_seed")
    delete(account: "wrap_key")
    delete(account: "pin_wrap")
    if success {
      addWalletId(newWalletId)
    }
    return success
  }

  // MARK: - Biometric / lifecycle

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

  // MARK: - Keychain ops

  private func baseQuery(account: String) -> [String: Any] {
    return [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
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

  private func loadData(account: String) -> String? {
    var item = baseQuery(account: account)
    item[kSecReturnData as String] = true
    item[kSecMatchLimit as String] = kSecMatchLimitOne

    var found: CFTypeRef?
    let status = SecItemCopyMatching(item as CFDictionary, &found)

    if status == errSecSuccess, let data = found as? Data {
      return String(data: data, encoding: .utf8)
    }
    return nil
  }

  private func load(account: String, result: @escaping FlutterResult) {
    loadProtected(account: account, result: result)
  }

  private func loadProtected(account: String, result: @escaping FlutterResult) {
    let value = loadData(account: account)
    if let value {
      result(value)
    } else {
      result(nil)
    }
  }

  private func delete(account: String) {
    SecItemDelete(baseQuery(account: account) as CFDictionary)
  }

  private func hasItem(account: String) -> Bool {
    var item = baseQuery(account: account)
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
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
}
