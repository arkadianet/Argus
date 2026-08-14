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
  private let accountName = "encrypted_seed"

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "saveEncryptedSeed":
      guard let args = call.arguments as? [String: Any],
            let json = args["encryptedSeedJson"] as? String else {
        result(FlutterError(code: "INVALID_ARGS", message: "Missing encryptedSeedJson", details: nil))
        return
      }
      save(json, result: result)

    case "loadEncryptedSeed":
      load(result: result)

    case "deleteEncryptedSeed":
      delete(result: result)

    case "hasEncryptedSeed":
      result(hasSeed())

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func save(_ value: String, result: @escaping FlutterResult) {
    guard let data = value.data(using: .utf8) else {
      result(FlutterError(code: "ENCODE_ERROR", message: "Failed to encode data", details: nil))
      return
    }

    // Delete existing item first
    SecItemDelete(query())

    var query = query()
    query[kSecValueData as String] = data
    query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

    let status = SecItemAdd(query as CFDictionary, nil)
    if status == errSecSuccess {
      result(true)
    } else {
      result(FlutterError(code: "KEYCHAIN_ERROR", message: "Failed to save: \(status)", details: nil))
    }
  }

  private func load(result: @escaping FlutterResult) {
    var query = query()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)

    if status == errSecSuccess, let data = item as? Data {
      result(String(data: data, encoding: .utf8))
    } else if status == errSecItemNotFound {
      result(nil)
    } else {
      result(FlutterError(code: "KEYCHAIN_ERROR", message: "Failed to load: \(status)", details: nil))
    }
  }

  private func delete(result: @escaping FlutterResult) {
    let status = SecItemDelete(query())
    if status == errSecSuccess || status == errSecItemNotFound {
      result(nil)
    } else {
      result(FlutterError(code: "KEYCHAIN_ERROR", message: "Failed to delete: \(status)", details: nil))
    }
  }

  private func hasSeed() -> Bool {
    var query = query()
    query[kSecReturnData as String] = false
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    return status == errSecSuccess
  }

  private func query() -> [String: Any] {
    return [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: serviceName,
      kSecAttrAccount as String: accountName,
    ]
  }
}