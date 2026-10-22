package com.wesbos.housecapture

import android.app.Application
import android.util.Log
import com.wesbos.housecapture.capture.CaptureController
import com.wesbos.housecapture.capture.CaptureFactory
import com.wesbos.housecapture.store.HouseStore

class HouseCaptureApp : Application() {
    override fun onCreate() {
        super.onCreate()
        CaptureFactory.newController = { CaptureController(it) }
        CaptureFactory.library = { HouseStore(it) }
        // Make sure a crash on the GL or writer thread lands in logcat with its thread name.
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            Log.e("HouseCapture", "Uncaught exception on ${thread.name}", error)
            previous?.uncaughtException(thread, error)
        }
    }
}
