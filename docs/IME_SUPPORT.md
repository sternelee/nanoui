# Android/iOS IME Multi-Language Input Support

## Overview

This document describes the changes made to nanoui to support IME (Input Method Editor) for multi-language input, including Chinese, Japanese, Korean, and other languages that use composition-based input methods.

## Android Implementation

### Changes Made

1. **Custom InputConnection (Java)**
   - Created `src/android/java/com/nanoui/NanotermInputConnection.java`
   - Implements `BaseInputConnection` to handle IME composition
   - Supports:
     - Text composition (e.g., pinyin → Chinese characters)
     - Marked text (underlined composition text)
     - Text deletion (including surrogate pairs)
     - Committing composed text
     - Key events (delete, enter)

2. **Custom EditText (Java)**
   - Created `src/android/java/com/nanoui/NanotermEditText.java`
   - Extends `EditText` to use the custom `NanotermInputConnection`
   - Configures proper `EditorInfo` for IME support

3. **Updated IME Module (Zig)**
   - Modified `src/android/ime.zig` to use `TYPE_CLASS_TEXT` instead of `TYPE_NULL`
   - Added documentation explaining the full IME implementation path
   - The Zig code provides basic multi-language support; full composition requires the Java classes

### How It Works

1. When the keyboard is shown, a hidden `NanotermEditText` is created
2. The EditText uses `NanotermInputConnection` to communicate with the IME
3. As the user types (e.g., pinyin), the IME calls `setComposingText()` to show composition
4. When the user selects a character, the IME calls `commitText()` to finalize it
5. The InputConnection tracks text state and can report it back to the native code via JNI

### Integration with nanoui

The Java classes need to be compiled and included in the APK. This requires:
1. Java compilation step in the build process
2. Conversion to DEX format using dx/d8
3. Inclusion in the APK

Currently, the build system (tools/android/apk.zig) does not include Java compilation. This is a placeholder for future implementation.

## iOS Implementation

### Current Status

iOS already has full IME support implemented in `src/ios/textinput.zig`:
- Implements the full `UITextInput` protocol
- Supports marked text (composition)
- Handles autocorrect, dictation, and edit menu
- Works with pinyin, kana, Hangul, and other IMEs

### How It Works

1. A hidden UIView serves as the text input target
2. The view implements `UITextInput` methods to communicate with the keyboard
3. Text composition happens through `setMarkedText:selectedRange:`
4. Text is committed via `unmarkText` or direct insertion
5. The implementation bridges UIKit's text operations to nanoui's `TextOp` system

### No Changes Needed

The iOS implementation is already complete and works well for multi-language input. No changes are required.

## Testing

### Android Testing

To test the Android implementation:
1. Build an app using the modified nanoui
2. Install on an Android device
3. Enable a Chinese/Japanese/Korean input method
4. Test composition (e.g., type pinyin and select characters)

### iOS Testing

To test the iOS implementation:
1. Build an app using nanoui
2. Run on iOS device or simulator
3. Enable a Chinese/Japanese/Korean keyboard
4. Test composition and autocorrect

## Limitations

### Android

1. **Java Integration**: The Java classes need to be compiled and included in the APK. The current build system does not support this automatically.

2. **JNI Bridge**: The InputConnection needs to communicate text changes back to the native Zig code. This requires a JNI callback mechanism.

3. **Build Process**: The Android build system (tools/android/apk.zig) needs to be extended to:
   - Compile Java sources
   - Convert to DEX format
   - Include in the APK

### iOS

No known limitations. The implementation is complete.

## Future Work

### Android

1. Extend the build system to compile Java classes
2. Implement JNI callback for text updates
3. Add Java class compilation to tools/android/apk.zig
4. Test with various IMEs (Google Pinyin, Gboard, Samsung Keyboard, etc.)

### iOS

1. None - implementation is complete

## References

- Android InputConnection: https://developer.android.com/reference/android/view/inputmethod/InputConnection
- Android IME Guide: https://developer.android.com/guide/topics/text/creating-input-method
- iOS UITextInput: https://developer.apple.com/documentation/uikit/uitextinput
- iOS Text Input: https://developer.apple.com/documentation/uikit/text_and_web
