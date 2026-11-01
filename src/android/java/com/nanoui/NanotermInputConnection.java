package com.nanoui;

import android.view.inputmethod.BaseInputConnection;
import android.view.inputmethod.CompletionInfo;
import android.view.inputmethod.CorrectionInfo;
import android.view.inputmethod.ExtractedText;
import android.view.inputmethod.ExtractedTextRequest;
import android.view.KeyEvent;
import android.view.View;

/**
 * Custom InputConnection for nanoui to support IME composition
 * (including Chinese input and other multi-language input methods).
 */
public class NanotermInputConnection extends BaseInputConnection {
    private final View targetView;
    private StringBuilder text = new StringBuilder();
    private int cursorPosition = 0;
    private int composingStart = -1;
    private int composingEnd = -1;

    public NanotermInputConnection(View targetView, boolean fullEditor) {
        super(targetView, fullEditor);
        this.targetView = targetView;
    }

    @Override
    public CharSequence getTextBeforeCursor(int n, int flags) {
        int start = Math.max(0, cursorPosition - n);
        return text.subSequence(start, cursorPosition);
    }

    @Override
    public CharSequence getTextAfterCursor(int n, int flags) {
        int end = Math.min(text.length(), cursorPosition + n);
        return text.subSequence(cursorPosition, end);
    }

    @Override
    public CharSequence getSelectedText(int flags) {
        return ""; // No selection support for now
    }

    @Override
    public int getCursorCapsMode(int reqModes) {
        return 0;
    }

    @Override
    public ExtractedText getExtractedText(ExtractedTextRequest request, int flags) {
        ExtractedText et = new ExtractedText();
        et.startOffset = 0;
        et.text = text.toString();
        et.selectionStart = cursorPosition;
        et.selectionEnd = cursorPosition;
        et.flags = 0;
        return et;
    }

    @Override
    public boolean deleteSurroundingText(int beforeLength, int afterLength) {
        if (beforeLength > 0) {
            int start = Math.max(0, cursorPosition - beforeLength);
            text.delete(start, cursorPosition);
            cursorPosition = start;
        }
        if (afterLength > 0) {
            int end = Math.min(text.length(), cursorPosition + afterLength);
            text.delete(cursorPosition, end);
        }
        updateNativeText(this.text.toString());
        return true;
    }

    @Override
    public boolean deleteSurroundingTextInCodePoints(int beforeLength, int afterLength) {
        if (beforeLength > 0) {
            int start = Math.max(0, cursorPosition - beforeLength);
            text.delete(start, cursorPosition);
            cursorPosition = start;
        }
        if (afterLength > 0) {
            int end = Math.min(text.length(), cursorPosition + afterLength);
            text.delete(cursorPosition, end);
        }
        updateNativeText(this.text.toString());
        return true;
    }

    @Override
    public boolean setComposingText(CharSequence text, int newCursorPosition) {
        // Update composing region
        if (composingStart == -1) {
            composingStart = cursorPosition;
        }
        composingEnd = composingStart + text.length();

        // Replace existing composing text with new text
        if (composingStart >= 0 && composingEnd <= this.text.length()) {
            this.text.replace(composingStart, composingEnd, text);
        } else {
            this.text.insert(cursorPosition, text);
        }

        cursorPosition = composingStart + newCursorPosition;
        if (newCursorPosition < 0) {
            cursorPosition = this.text.length() + newCursorPosition;
        }

        updateNativeText(this.text.toString());
        return true;
    }

    @Override
    public boolean setComposingRegion(int start, int end) {
        composingStart = Math.max(0, start);
        composingEnd = Math.min(text.length(), end);
        return true;
    }

    @Override
    public boolean finishComposingText() {
        composingStart = -1;
        composingEnd = -1;
        updateNativeText(this.text.toString());
        return true;
    }

    @Override
    public boolean commitText(CharSequence text, int newCursorPosition) {
        finishComposingText();

        if (newCursorPosition > 0) {
            this.text.insert(cursorPosition, text);
            cursorPosition += text.length();
        } else if (newCursorPosition == 0) {
            this.text.insert(cursorPosition, text);
        } else {
            // newCursorPosition is negative, position from end
            this.text.insert(cursorPosition, text);
            cursorPosition = this.text.length() + newCursorPosition;
        }

        updateNativeText(this.text.toString());
        return true;
    }

    @Override
    public boolean commitCompletion(CompletionInfo text) {
        return commitText(text.getText(), 1);
    }

    @Override
    public boolean commitCorrection(CorrectionInfo correctionInfo) {
        return commitText(correctionInfo.getNewText(), 1);
    }

    @Override
    public boolean setSelection(int start, int end) {
        // For now, just move cursor to end
        cursorPosition = Math.min(text.length(), end);
        return true;
    }

    @Override
    public boolean sendKeyEvent(KeyEvent event) {
        if (event.getAction() == KeyEvent.ACTION_DOWN) {
            int keyCode = event.getKeyCode();
            if (keyCode == KeyEvent.KEYCODE_DEL) {
                if (cursorPosition > 0) {
                    text.deleteCharAt(cursorPosition - 1);
                    cursorPosition--;
                    updateNativeText(this.text.toString());
                }
                return true;
            } else if (keyCode == KeyEvent.KEYCODE_ENTER) {
                commitText("\n", 1);
                return true;
            }
        }
        return super.sendKeyEvent(event);
    }

    @Override
    public boolean clearMetaKeyStates(int states) {
        return false;
    }

    @Override
    public boolean reportFullscreenMode(boolean enabled) {
        return false;
    }

    @Override
    public boolean performEditorAction(int editorAction) {
        return false;
    }

    @Override
    public boolean performContextMenuAction(int id) {
        return false;
    }

    /**
     * Get the current text for native code to read
     */
    public String getText() {
        return text.toString();
    }

    /**
     * Set text from native code (e.g., when user deletes from terminal)
     */
    public void setText(String newText) {
        text = new StringBuilder(newText);
        cursorPosition = text.length();
        composingStart = -1;
        composingEnd = -1;
    }

    /**
     * Clear all text
     */
    public void clear() {
        text.setLength(0);
        cursorPosition = 0;
        composingStart = -1;
        composingEnd = -1;
    }

    /**
     * Update native text buffer via JNI
     * This will be implemented in Zig/Java binding
     */
    private native void updateNativeText(String text);
}
