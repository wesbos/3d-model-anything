package com.wesbos.housecapture.ui

import android.util.Log
import androidx.lifecycle.ViewModel
import com.wesbos.housecapture.capture.CaptureContract
import com.wesbos.housecapture.capture.Phase
import com.wesbos.housecapture.capture.RoomSummary
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Keeps one capture controller alive for the scan destination's whole back-stack entry, so an
 * Activity recreation (dark theme at sunset, font or display size, split screen) re-attaches a new
 * preview view to the same recording instead of ending it and starting an empty session.
 * The controller is released when the entry is popped.
 */
class ScanViewModel(val controller: CaptureContract) : ViewModel() {
    private var started = false
    private var savedDelivered = false
    private val mutableResumeError = MutableStateFlow<String?>(null)

    /** An exception thrown by the controller's resume, shown as a failed scan instead of crashing. */
    val resumeError: StateFlow<String?> = mutableResumeError.asStateFlow()

    /** ON_RESUME of the scan entry. Starts the room once, after the first resume that didn't throw. */
    fun resume(name: String) {
        try {
            controller.onResume()
        } catch (e: Exception) {
            Log.e(TAG, "Resuming the AR session failed", e)
            mutableResumeError.value = e.message ?: e.javaClass.simpleName
            return
        }
        mutableResumeError.value = null
        if (!started) {
            started = true
            controller.startRoom(name)
        }
    }

    fun pause() {
        try {
            controller.onPause()
        } catch (e: Exception) {
            Log.e(TAG, "Pausing the AR session failed", e)
        }
    }

    /** The saved room, once: a recreated screen must not navigate to it a second time. */
    fun takeSaved(phase: Phase, saved: RoomSummary?): RoomSummary? {
        if (phase != Phase.SAVED || saved == null || savedDelivered) return null
        savedDelivered = true
        return saved
    }

    override fun onCleared() {
        controller.release()
    }

    private companion object {
        const val TAG = "ScanViewModel"
    }
}
