package com.limitlesscloud.limitless_cloud

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    /**
     * Flutter ↔ Kotlin MethodChannel for the TransferForegroundService.
     *
     * Flutter calls:
     *   startTransfer(title: String)         — starts foreground service
     *   updateProgress(title, progress: Int) — updates notification progress %
     *   stopTransfer()                       — stops service & dismisses notification
     */
    private val CHANNEL = "com.limitlesscloud/transfer_service"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
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
    }
}
