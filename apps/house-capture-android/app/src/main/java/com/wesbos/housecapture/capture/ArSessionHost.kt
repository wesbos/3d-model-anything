package com.wesbos.housecapture.capture

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.pm.PackageManager
import android.opengl.GLES20
import android.opengl.GLSurfaceView
import android.util.Log
import android.view.Surface
import androidx.core.content.ContextCompat
import com.google.ar.core.ArCoreApk
import com.google.ar.core.CameraConfig
import com.google.ar.core.CameraConfigFilter
import com.google.ar.core.Config
import com.google.ar.core.Frame
import com.google.ar.core.Session
import com.google.ar.core.exceptions.CameraNotAvailableException
import com.google.ar.core.exceptions.UnavailableApkTooOldException
import com.google.ar.core.exceptions.UnavailableArcoreNotInstalledException
import com.google.ar.core.exceptions.UnavailableDeviceNotCompatibleException
import com.google.ar.core.exceptions.UnavailableSdkTooOldException
import com.google.ar.core.exceptions.UnavailableUserDeclinedInstallationException
import java.util.EnumSet
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10

/**
 * Owns the ARCore Session and the GLSurfaceView that feeds it: picks the camera config with the
 * largest CPU image, turns on raw depth when supported, draws the camera background and hands
 * every frame to the listener on the GL thread.
 */
class ArSessionHost(private val context: Context, private val listener: Listener) : GLSurfaceView.Renderer {
    interface Listener {
        /** The session is configured; called on the main thread before the first frame. */
        fun onSessionConfigured(info: SessionInfo)
        /** GL thread. Keep it cheap: copy what you need and hand heavy work to another thread. */
        fun onFrame(session: Session, frame: Frame)
        fun onError(message: String)
    }

    /** What the chosen camera config and depth mode turned out to be (recorded in the manifest). */
    class SessionInfo(
        val imageWidth: Int, val imageHeight: Int,
        val textureWidth: Int, val textureHeight: Int,
        val fpsMin: Int, val fpsMax: Int,
        val depthEnabled: Boolean,
    )

    @Volatile private var session: Session? = null
    private var view: GLSurfaceView? = null
    private var installRequested = false
    /** resume() arrived before any preview view: wait for one, since the install prompt needs its Activity */
    private var resumePending = false
    private val background = BackgroundRenderer()

    // GL thread
    private var textureBoundTo: Session? = null
    @Volatile private var viewportChanged = false
    @Volatile private var viewportWidth = 0
    @Volatile private var viewportHeight = 0
    @Volatile private var displayRotation = Surface.ROTATION_0

    /**
     * A new preview for each Activity (the session outlives Activity recreation). The view's context
     * should be the Activity: ARCore's install/update prompt is launched from it.
     */
    fun createView(context: Context): GLSurfaceView {
        view?.onPause()
        val created = GLSurfaceView(context).also {
            it.preserveEGLContextOnPause = true
            it.setEGLContextClientVersion(2)
            it.setEGLConfigChooser(8, 8, 8, 8, 16, 0)
            it.setRenderer(this)
            it.renderMode = GLSurfaceView.RENDERMODE_CONTINUOUSLY
            it.setWillNotDraw(false)
        }
        view = created
        if (resumePending) {
            resumePending = false
            resume()
        }
        return created
    }

    /** Main thread, from the screen's ON_RESUME. Creates the session on first use. Never throws. */
    fun resume() {
        if (session == null && view == null && findActivity(context) == null) {
            resumePending = true
            return
        }
        if (session == null) {
            val created = try {
                createSession() ?: return
            } catch (e: Exception) {
                listener.onError(describe(e))
                return
            }
            session = created
        }
        try {
            session?.resume()
        } catch (e: Exception) {
            // CameraNotAvailable, SecurityException (permission revoked while away), FatalException
            listener.onError(describe(e))
            return
        }
        view?.onResume()
    }

    fun pause() {
        resumePending = false
        view?.onPause()
        session?.pause()
    }

    fun release() {
        resumePending = false
        view?.onPause()
        view = null
        session?.close()
        session = null
    }

    private fun createSession(): Session? {
        val activity = findActivity(view?.context ?: context)
        if (activity != null) {
            val status = ArCoreApk.getInstance().requestInstall(activity, !installRequested)
            if (status == ArCoreApk.InstallStatus.INSTALL_REQUESTED) {
                // Play Store install/update flow; we come back through onResume.
                installRequested = true
                return null
            }
        }
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            listener.onError("Camera permission is needed to scan.")
            return null
        }
        val session = Session(activity ?: context)
        try {
            val filter = CameraConfigFilter(session)
            filter.setTargetFps(EnumSet.of(CameraConfig.TargetFps.TARGET_FPS_30))
            val best = session.getSupportedCameraConfigs(filter).maxWithOrNull(
                compareBy<CameraConfig>({ it.imageSize.width * it.imageSize.height }, { it.textureSize.width * it.textureSize.height }),
            )
            if (best != null) session.setCameraConfig(best)
            val depth = session.isDepthModeSupported(Config.DepthMode.RAW_DEPTH_ONLY)
            val config = Config(session)
            config.setDepthMode(if (depth) Config.DepthMode.RAW_DEPTH_ONLY else Config.DepthMode.DISABLED)
            config.setPlaneFindingMode(Config.PlaneFindingMode.HORIZONTAL_AND_VERTICAL)
            config.setFocusMode(Config.FocusMode.AUTO)
            config.setUpdateMode(Config.UpdateMode.LATEST_CAMERA_IMAGE)
            config.setLightEstimationMode(Config.LightEstimationMode.AMBIENT_INTENSITY)
            config.setInstantPlacementMode(Config.InstantPlacementMode.DISABLED)
            session.configure(config)
            val chosen = session.cameraConfig
            listener.onSessionConfigured(
                SessionInfo(
                    imageWidth = chosen.imageSize.width, imageHeight = chosen.imageSize.height,
                    textureWidth = chosen.textureSize.width, textureHeight = chosen.textureSize.height,
                    fpsMin = chosen.fpsRange.lower, fpsMax = chosen.fpsRange.upper,
                    depthEnabled = depth,
                ),
            )
            return session
        } catch (e: Exception) {
            session.close()
            throw e
        }
    }

    // --- GLSurfaceView.Renderer (GL thread) ---------------------------------------------------

    override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        background.createOnGlThread()
        textureBoundTo = null
    }

    override fun onSurfaceChanged(gl: GL10?, width: Int, height: Int) {
        GLES20.glViewport(0, 0, width, height)
        viewportWidth = width
        viewportHeight = height
        displayRotation = view?.display?.rotation ?: Surface.ROTATION_0
        viewportChanged = true
    }

    override fun onDrawFrame(gl: GL10?) {
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT or GLES20.GL_DEPTH_BUFFER_BIT)
        val session = session ?: return
        if (textureBoundTo !== session) {
            session.setCameraTextureName(background.textureId)
            textureBoundTo = session
            viewportChanged = true
        }
        if (viewportChanged) {
            session.setDisplayGeometry(displayRotation, viewportWidth, viewportHeight)
            viewportChanged = false
        }
        val frame = try {
            session.update()
        } catch (e: Exception) {
            // paused, camera lost, or not resumed yet: skip this frame
            return
        }
        background.draw(frame)
        try {
            listener.onFrame(session, frame)
        } catch (e: Exception) {
            Log.e(TAG, "Frame processing failed", e)
        }
    }

    private fun describe(e: Exception): String = when (e) {
        is UnavailableArcoreNotInstalledException, is UnavailableUserDeclinedInstallationException ->
            "Install Google Play Services for AR to scan."
        is UnavailableApkTooOldException -> "Update Google Play Services for AR to scan."
        is UnavailableSdkTooOldException -> "This app needs a newer ARCore SDK."
        is UnavailableDeviceNotCompatibleException -> "This device does not support ARCore."
        is CameraNotAvailableException -> "The camera is unavailable. Close other camera apps and try again."
        is SecurityException -> "Camera permission is needed to scan."
        else -> "AR session failed: ${e.message ?: e.javaClass.simpleName}"
    }.also { Log.e(TAG, it, e) }

    private companion object {
        const val TAG = "ArSessionHost"

        fun findActivity(context: Context): Activity? {
            var c: Context? = context
            while (c is ContextWrapper) {
                if (c is Activity) return c
                c = c.baseContext
            }
            return null
        }
    }
}
