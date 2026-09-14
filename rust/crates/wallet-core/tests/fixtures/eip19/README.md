The two compact request JSON fixtures are extracted from `ColdWalletUtilsKtTest.kt`
at ergo-wallet-app revision `beeecb1009e26c6ea9b506d5fca3a4efb3f79f9e`:
https://github.com/ergoplatform/ergo-wallet-app/blob/beeecb1009e26c6ea9b506d5fca3a4efb3f79f9e/common-jvm/src/test/java/org/ergoplatform/transactions/ColdWalletUtilsKtTest.kt

Only JSON escaping/whitespace was normalized; Base64 payload bytes are unchanged.
Fixture 2 has three inputs, tokens and registers and occupies four low-density
Argus CSR pages. These fixtures establish request binary parity with that test
source; they are not evidence of a real-device round trip or signed Appkit parity.
