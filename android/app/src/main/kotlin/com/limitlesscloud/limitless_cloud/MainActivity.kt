package com.limitlesscloud.limitless_cloud

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {

    private val TRANSFER_CHANNEL = "com.limitlesscloud/transfer_service"
    private val CAMERA_CHANNEL = "com.limitlesscloud/camera_service"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ── Transfer Foreground Service Channel ───────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, TRANSFER_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startTransfer" -> {
                        val title = call.argument<String>("title") ?: "Transferring…"
                        TransferForegroundService.start(this, title)
                        result.success(null)
                    }
                    "updateProgress" -> {
                        val title    = call.argument<String>("title") ?: "Transferring…"
                        val progress = call.argument<Int>("progress") ?: 0
                        TransferForegroundService.update(this, title, progress)
                        result.success(null)
                    }
                    "stopTransfer" -> {
                        TransferForegroundService.stop(this)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        // ── Camera Hardware Processing Channel ────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CAMERA_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "processImage" -> {
                        val filePath = call.argument<String>("filePath")
                        val isFrontCamera = call.argument<Boolean>("isFrontCamera") ?: false
                        val mirrorFrontCamera = call.argument<Boolean>("mirrorFrontCamera") ?: true
                        val targetRatio = call.argument<Double>("targetRatio")
                        val quality = call.argument<Int>("quality") ?: 100

                        if (filePath == null) {
                            result.error("INVALID_ARGUMENT", "filePath is required", null)
                            return@setMethodCallHandler
                        }

                        thread(start = true) {
                            try {
                                val outcome = NativeImageProcessor.processImage(
                                    filePath = filePath,
                                    isFrontCamera = isFrontCamera,
                                    mirrorFrontCamera = mirrorFrontCamera,
                                    targetRatio = targetRatio,
                                    quality = quality
                                )
                                runOnUiThread {
                                    result.success(outcome)
                                }
                            } catch (e: Throwable) {
                                runOnUiThread {
                                    result.error("PROCESS_FAILED", e.message, null)
                                }
                            }
                        }
                    }
                    "applyPortraitBokeh" -> {
                        val filePath = call.argument<String>("filePath")
                        val blurRadius = (call.argument<Double>("blurRadius") ?: 12.0).toFloat()
                        val maskList = call.argument<List<Double>>("segmentationMask")
                        val maskWidth = call.argument<Int>("maskWidth") ?: 0
                        val maskHeight = call.argument<Int>("maskHeight") ?: 0
                        @Suppress("UNCHECKED_CAST")
                        val facesList = call.argument<List<Map<String, Any>>>("faces") ?: emptyList()
                        val focusNormX = (call.argument<Double>("focusNormX") ?: 0.5).toFloat()
                        val focusNormY = (call.argument<Double>("focusNormY") ?: 0.5).toFloat()
                        val quality = call.argument<Int>("quality") ?: 100

                        if (filePath == null) {
                            result.error("INVALID_ARGUMENT", "filePath is required", null)
                            return@setMethodCallHandler
                        }

                        thread(start = true) {
                            try {
                                val floatMask = maskList?.let { list ->
                                    FloatArray(list.size) { i -> list[i].toFloat() }
                                }
                                val outcome = NativeImageProcessor.applyPortraitBokeh(
                                    filePath = filePath,
                                    blurRadius = blurRadius,
                                    segmentationMask = floatMask,
                                    maskWidth = maskWidth,
                                    maskHeight = maskHeight,
                                    faces = facesList,
                                    focusNormX = focusNormX,
                                    focusNormY = focusNormY,
                                    quality = quality
                                )
                                runOnUiThread {
                                    result.success(outcome)
                                }
                            } catch (e: Throwable) {
                                runOnUiThread {
                                    result.error("BOKEH_FAILED", e.message, null)
                                }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
