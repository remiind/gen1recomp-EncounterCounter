`debug.keystore` signs the fork's CI debug APKs (alias `androiddebugkey`,
passwords `android`, the Android debug defaults). It is a throwaway debug key,
committed on purpose: with one fixed certificate every new APK installs over
the previous one instead of failing with "App not installed".
