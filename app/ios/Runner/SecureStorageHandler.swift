import Foundation
import Flutter
import Security

/// Secure storage method channel handler for iOS Keychain.
public class SecureStorageHandler: NSObject, FlutterPlugin {

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "com.argus.wallet/secure_storage",
      binaryMessenger: registrar.messenger()
    )
    let instance = SecureStorageHandler()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  private let serviceName = "com.argus.wallet.seed"
  private let seedAccount = "encrypted_seed"
  private let wrapAccount = "wrap_key"

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "saveEncryptedSeed":
      guard let args = call.arguments as? [String: Any],
            let json = args["encryptedSeedJson"] as? String else {
        result(FlutterError(code: "INVALID_ARGS", message: "Missing encryptedSeedJson", details: nil))
        return
      }
      save(json, account: seedAccount, result: result)

    case "loadEncryptedSeed":
      load(account: seedAccount, result: result)

    case "saveWrapKey":
      guard let args = call.arguments as? [String: Any],
            let key = args["wrapKey"] as? String else {
        result(FlutterError(code: "INVALID_ARGS", message: "Missing wrapKey", details: nil))
        return
      }
      save(key, account: wrapAccount, result: result)

    case "loadWrapKey":
      load(account: wrapAccount, result: result)

    case "deleteEncryptedSeed":
      delete(account: seedAccount)
      delete(account: wrapAccount)
      result(nil)

    case "hasEncryptedSeed":
      result(hasItem(account: seedAccount))

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func save(_ value: String, account: String, result: @escaping FlutterResult) {
    guard let data = value.data(using: .utf8) else {
      result(FlutterError(code: "ENCODE_ERROR", message: "Failed to encode data", details: nil))
      return
    }

    SecItemDelete(query(account) as CFDictionary)

    var item = query(account)
    item[kSecValueData as String] = data
    item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

    let status = SecItemAdd(item as CFDictionary, nil)
    if status == errSecSuccess {
      result(true)
    } else {
      result(FlutterError(code: "KEYCHAIN_ERROR", message: "Failed to save: \(status)", details: nil))
    }
  }

  private func load(account: String, result: @escaping FlutterResult) {
    var item = query(account)
    item[kSecReturnData as String] = true
    item[kSecMatchLimit as String] = kSecMatchLimitOne

    var found: CFTypeRef?
    let status = SecItemCopyMatching(item as CFDictionary, &found)

    if status == errSecSuccess, let data = found as? Data {
      result(String(data: data, encoding: .utf8))
    } else if status == errSecItemNotFound {
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

    var found: CFTypeRef?
    let status = SecItemCopyMatching(item as CFDictionary, &found)
    return status == errSecSuccess
  }

  private func query(_ account: String) -> [String: Any] {
    return [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: serviceName,
      kSecAttrAccount as String: account,
    ]
  }
}