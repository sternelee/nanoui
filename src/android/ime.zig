//! The software keyboard. Android shows one only for a view that edits
//! text, which NativeActivity's isn't: a hidden EditText added to the
//! activity takes the focus while a nanoui field has it, and asks for the
//! keyboard. Its input type is TYPE_CLASS_TEXT to support basic IME input.
//!
//! NOTE: Full IME composition (including Chinese input) requires a custom
//! InputConnection implementation in Java. This implementation provides
//! basic multi-language support but may not work for all IMEs.
//! See src/android/java/com/nanoui/ for the full IME implementation
//! that needs to be compiled into the APK.
//!
//! Run on Java's thread (`activity.onUiThread`).
const std = @import("std");
const jni = @import("jni.zig");
const activity = @import("activity.zig");

/// The EditText, a global reference, made once for the activity (and let
/// go with it, `release`).
var edit: jni.Object = null;

fn inputMethods(env: jni.Env, act: jni.Object) jni.Object {
    const name = jni.string(env, "input_method");
    return jni.call(env, act, "getSystemService", "(Ljava/lang/String;)Ljava/lang/Object;", &.{jni.ref(name)}) orelse null;
}

/// The keyboard up, for typing into the app's field.
pub fn show(_: ?*anyopaque, env: jni.Env) void {
    const a = activity.activity orelse return;
    const frame = jni.Frame.push(env, 16);
    defer frame.pop();
    if (edit == null) {
        const e = jni.new(env, "android/widget/EditText", "(Landroid/content/Context;)V", &.{jni.ref(a.clazz)});
        if (e == null) return;
        // TYPE_CLASS_TEXT: enables basic IME support (better than TYPE_NULL)
        // Full composition support requires custom InputConnection (see Java files)
        _ = jni.call(env, e, "setInputType", "(I)V", &.{jni.int(0x00000001)});
        _ = jni.call(env, e, "setFocusableInTouchMode", "(Z)V", &.{jni.boolean(true)});
        const params = jni.new(env, "android/view/ViewGroup$LayoutParams", "(II)V", &.{ jni.int(1), jni.int(1) });
        if (jni.call(env, a.clazz, "addContentView", "(Landroid/view/View;Landroid/view/ViewGroup$LayoutParams;)V", &.{ jni.ref(e), jni.ref(params) }) == null) return;
        edit = jni.newGlobal(env, e);
    }
    _ = jni.call(env, edit, "requestFocus", "()Z", &.{});
    _ = jni.call(env, inputMethods(env, a.clazz), "showSoftInput", "(Landroid/view/View;I)Z", &.{ jni.ref(edit), jni.int(0) });
}

/// The keyboard down; the activity's own view has the focus again.
pub fn hide(_: ?*anyopaque, env: jni.Env) void {
    const a = activity.activity orelse return;
    if (edit == null) return;
    const frame = jni.Frame.push(env, 8);
    defer frame.pop();
    const token = jni.call(env, edit, "getWindowToken", "()Landroid/os/IBinder;", &.{}) orelse return;
    _ = jni.call(env, inputMethods(env, a.clazz), "hideSoftInputFromWindow", "(Landroid/os/IBinder;I)Z", &.{ jni.ref(token), jni.int(0) });
    _ = jni.call(env, edit, "clearFocus", "()V", &.{});
}

/// The activity goes, with its view: the EditText is let go.
pub fn release(env: jni.Env) void {
    if (edit != null) jni.deleteGlobal(env, edit);
    edit = null;
}
