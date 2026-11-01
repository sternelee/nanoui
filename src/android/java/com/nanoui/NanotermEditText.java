package com.nanoui;

import android.content.Context;
import android.util.AttributeSet;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.widget.EditText;

/**
 * Custom EditText that uses NanotermInputConnection for IME support.
 */
public class NanotermEditText extends EditText {
    private NanotermInputConnection inputConnection;

    public NanotermEditText(Context context) {
        super(context);
    }

    public NanotermEditText(Context context, AttributeSet attrs) {
        super(context, attrs);
    }

    public NanotermEditText(Context context, AttributeSet attrs, int defStyleAttr) {
        super(context, attrs, defStyleAttr);
    }

    @Override
    public InputConnection onCreateInputConnection(EditorInfo outAttrs) {
        inputConnection = new NanotermInputConnection(this, true);

        // Configure EditorInfo for better IME support
        outAttrs.inputType = EditorInfo.TYPE_CLASS_TEXT | EditorInfo.TYPE_TEXT_FLAG_MULTI_LINE;
        outAttrs.imeOptions = EditorInfo.IME_FLAG_NO_EXTRACT_UI;
        outAttrs.initialSelStart = 0;
        outAttrs.initialSelEnd = 0;

        return inputConnection;
    }

    /**
     * Get the InputConnection for native code to access
     */
    public NanotermInputConnection getInputConnection() {
        return inputConnection;
    }
}
