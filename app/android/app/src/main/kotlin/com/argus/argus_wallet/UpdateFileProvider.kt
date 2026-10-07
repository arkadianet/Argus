package com.argus.argus_wallet

import androidx.core.content.FileProvider

/// Serves the verified update APK to the system installer through a content
/// URI. A subclass of its own, so the manifest entry cannot collide with a
/// library that declares the stock `androidx.core.content.FileProvider`.
class UpdateFileProvider : FileProvider()
