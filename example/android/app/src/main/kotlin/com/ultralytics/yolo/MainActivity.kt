// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

package com.ultralytics.yolo

import android.graphics.Bitmap
import android.graphics.Color
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.os.Bundle
import androidx.activity.SystemBarStyle
import androidx.activity.enableEdgeToEdge
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

class MainActivity : FlutterFragmentActivity() {
    private val videoExecutor = Executors.newSingleThreadExecutor()

    override fun onCreate(savedInstanceState: Bundle?) {
        // Android 15 deprecates the Window system-bar color setters. SystemBarStyle makes both bars
        // transparent through the supported API on every Android version (and disables the navigation
        // bar contrast scrim where it applies).
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.auto(Color.TRANSPARENT, Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.auto(Color.TRANSPARENT, Color.TRANSPARENT),
        )
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "roadchitra/video_frames")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getVideoDurationMs" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank()) {
                            result.error("INVALID_ARGS", "Missing video path", null)
                            return@setMethodCallHandler
                        }
                        videoExecutor.execute {
                            val retriever = MediaMetadataRetriever()
                            try {
                                retriever.setDataSource(path)
                                val durationMs =
                                    retriever
                                        .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                                        ?.toLongOrNull() ?: 0L
                                val mime = readVideoCodecMime(path)
                                runOnUiThread {
                                    result.success(mapOf("durationMs" to durationMs, "mimeType" to mime))
                                }
                            } catch (e: Exception) {
                                runOnUiThread {
                                    result.error("VIDEO_DURATION_ERROR", e.message, null)
                                }
                            } finally {
                                runCatching { retriever.release() }
                            }
                        }
                    }

                    "extractFrame" -> {
                        val path = call.argument<String>("path")
                        val timeMs = (call.argument<Number>("timeMs"))?.toLong() ?: 0L
                        val maxWidth = (call.argument<Number>("maxWidth"))?.toInt() ?: 1280
                        if (path.isNullOrBlank()) {
                            result.error("INVALID_ARGS", "Missing video path", null)
                            return@setMethodCallHandler
                        }
                        videoExecutor.execute {
                            val retriever = MediaMetadataRetriever()
                            try {
                                retriever.setDataSource(path)
                                val rawBitmap =
                                    retriever.getFrameAtTime(
                                        timeMs * 1000L,
                                        MediaMetadataRetriever.OPTION_CLOSEST,
                                    ) ?: retriever.getFrameAtTime(
                                        timeMs * 1000L,
                                        MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                                    )
                                if (rawBitmap == null) {
                                    runOnUiThread { result.success(null) }
                                    return@execute
                                }
                                val scaled =
                                    if (maxWidth > 0 && rawBitmap.width > maxWidth) {
                                        val targetHeight =
                                            (rawBitmap.height.toFloat() * maxWidth / rawBitmap.width)
                                                .toInt()
                                                .coerceAtLeast(1)
                                        Bitmap.createScaledBitmap(rawBitmap, maxWidth, targetHeight, true)
                                    } else {
                                        rawBitmap
                                    }
                                val stream = ByteArrayOutputStream()
                                scaled.compress(Bitmap.CompressFormat.JPEG, 88, stream)
                                if (scaled !== rawBitmap) {
                                    scaled.recycle()
                                }
                                rawBitmap.recycle()
                                val bytes = stream.toByteArray()
                                runOnUiThread { result.success(bytes) }
                            } catch (e: Exception) {
                                runOnUiThread {
                                    result.error("VIDEO_FRAME_ERROR", e.message, null)
                                }
                            } finally {
                                runCatching { retriever.release() }
                            }
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    private fun readVideoCodecMime(path: String): String? {
        val extractor = MediaExtractor()
        return try {
            extractor.setDataSource(path)
            (0 until extractor.trackCount)
                .asSequence()
                .map { extractor.getTrackFormat(it) }
                .mapNotNull { format -> format.getString(MediaFormat.KEY_MIME) }
                .firstOrNull { it.startsWith("video/") }
        } catch (_: Exception) {
            null
        } finally {
            runCatching { extractor.release() }
        }
    }

    override fun onDestroy() {
        videoExecutor.shutdown()
        super.onDestroy()
    }
}
