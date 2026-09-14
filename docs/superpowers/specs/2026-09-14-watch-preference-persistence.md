# Watched preference persistence follow-up

Commit 125dd8b, “Keep watched addresses that cannot be revalidated on load”,
removed destructive load-time revalidation. Its claim that this “makes the loss
impossible” applies only to that path. It did not protect against a failed save.

The pinned shared_preferences 2.5.5 API uses the legacy Android implementation
in shared_preferences_android 2.4.23. Its LegacySharedPreferencesPlugin.java
setString returns Editor.commit() directly:
[Flutter plugin source](https://github.com/flutter/packages/blob/shared_preferences_android-v2.4.23/packages/shared_preferences/shared_preferences_android/android/src/main/java/io/flutter/plugins/sharedpreferences/LegacySharedPreferencesPlugin.java).

Android can return false when creating the preference file or its directory
fails, renaming the existing file to its backup fails, or serialization/writing
throws an exception. commit can also return false when interrupted while waiting
for disk completion; in that case persistence is uncertain.
[Android implementation](https://android.googlesource.com/platform/frameworks/base/+/HEAD/core/java/android/app/SharedPreferencesImpl.java).

Thus a storage failure (for example exhausted storage or an I/O error) is a
plausible explanation for an address appearing after import but disappearing
after restart: the old code changed memory and ignored false. It is not a
confirmed diagnosis of the user's device; no device failure was reproduced and
no storage logs from that incident are available.

Both watched services now check the write result. Failed adds/removals throw,
restore their in-memory membership, and emit no success notification. The
preference cache is reloaded after false so subsequent loads do not simply read
the optimistic Dart cache. UI callers report the failure. A failed account
frontier save reports refresh unavailable and clears the snapshot, disabling
Receive; the newly discovered high-water index stays in memory conservatively.
A false result is not a guarantee that Android's own memory/disk state rolled
back, and this does not claim transactional or durable storage guarantees.

Tests install a platform store returning false, checking failed additions,
removals and frontier persistence through the real SharedPreferences API.
