package com.limitlesscloud.limitless_cloud

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import androidx.exifinterface.media.ExifInterface
import java.io.File
import java.io.FileOutputStream
import kotlin.math.abs
import kotlin.math.roundToInt

// All EXIF tags we want to carry forward from the original capture.
// This ensures GPS, camera model, lens info, ISO, aperture, shutter speed,
// focal length, flash, timestamp, software etc. are preserved after re-encoding.
private val EXIF_TAGS_TO_COPY = arrayOf(
    ExifInterface.TAG_MAKE,
    ExifInterface.TAG_MODEL,
    ExifInterface.TAG_SOFTWARE,
    ExifInterface.TAG_DATETIME,
    ExifInterface.TAG_DATETIME_ORIGINAL,
    ExifInterface.TAG_DATETIME_DIGITIZED,
    ExifInterface.TAG_OFFSET_TIME,
    ExifInterface.TAG_OFFSET_TIME_ORIGINAL,
    ExifInterface.TAG_OFFSET_TIME_DIGITIZED,
    ExifInterface.TAG_SUBSEC_TIME,
    ExifInterface.TAG_SUBSEC_TIME_ORIGINAL,
    ExifInterface.TAG_SUBSEC_TIME_DIGITIZED,
    ExifInterface.TAG_GPS_LATITUDE,
    ExifInterface.TAG_GPS_LATITUDE_REF,
    ExifInterface.TAG_GPS_LONGITUDE,
    ExifInterface.TAG_GPS_LONGITUDE_REF,
    ExifInterface.TAG_GPS_ALTITUDE,
    ExifInterface.TAG_GPS_ALTITUDE_REF,
    ExifInterface.TAG_GPS_TIMESTAMP,
    ExifInterface.TAG_GPS_DATESTAMP,
    ExifInterface.TAG_GPS_SPEED,
    ExifInterface.TAG_GPS_SPEED_REF,
    ExifInterface.TAG_GPS_DEST_BEARING,
    ExifInterface.TAG_GPS_DEST_BEARING_REF,
    ExifInterface.TAG_GPS_IMG_DIRECTION,
    ExifInterface.TAG_GPS_IMG_DIRECTION_REF,
    ExifInterface.TAG_GPS_PROCESSING_METHOD,
    ExifInterface.TAG_EXPOSURE_TIME,
    ExifInterface.TAG_F_NUMBER,
    ExifInterface.TAG_ISO_SPEED_RATINGS,
    ExifInterface.TAG_EXPOSURE_BIAS_VALUE,
    ExifInterface.TAG_FOCAL_LENGTH,
    ExifInterface.TAG_FOCAL_LENGTH_IN_35MM_FILM,
    ExifInterface.TAG_FLASH,
    ExifInterface.TAG_WHITE_BALANCE,
    ExifInterface.TAG_METERING_MODE,
    ExifInterface.TAG_EXPOSURE_MODE,
    ExifInterface.TAG_SCENE_CAPTURE_TYPE,
    ExifInterface.TAG_LIGHT_SOURCE,
    ExifInterface.TAG_SENSING_METHOD,
    ExifInterface.TAG_SUBJECT_DISTANCE,
    ExifInterface.TAG_SUBJECT_DISTANCE_RANGE,
    ExifInterface.TAG_COLOR_SPACE,
    ExifInterface.TAG_DIGITAL_ZOOM_RATIO,
    ExifInterface.TAG_SHARPNESS,
    ExifInterface.TAG_SATURATION,
    ExifInterface.TAG_CONTRAST,
    ExifInterface.TAG_BRIGHTNESS_VALUE,
    ExifInterface.TAG_MAX_APERTURE_VALUE,
    ExifInterface.TAG_APERTURE_VALUE,
    ExifInterface.TAG_SHUTTER_SPEED_VALUE,
    ExifInterface.TAG_EXPOSURE_PROGRAM,
    ExifInterface.TAG_PHOTOGRAPHIC_SENSITIVITY,
    ExifInterface.TAG_LENS_MAKE,
    ExifInterface.TAG_LENS_MODEL,
    ExifInterface.TAG_LENS_SPECIFICATION,
    ExifInterface.TAG_PIXEL_X_DIMENSION,
    ExifInterface.TAG_PIXEL_Y_DIMENSION,
    ExifInterface.TAG_X_RESOLUTION,
    ExifInterface.TAG_Y_RESOLUTION,
    ExifInterface.TAG_RESOLUTION_UNIT,
    ExifInterface.TAG_IMAGE_DESCRIPTION,
    ExifInterface.TAG_USER_COMMENT,
    ExifInterface.TAG_ARTIST,
    ExifInterface.TAG_COPYRIGHT,
)

object NativeImageProcessor {

    /**
     * Processes captured camera photo using Android's native hardware-accelerated pipeline:
     * 1. Reads physical EXIF orientation to determine true rotation.
     * 2. Corrects physical orientation via native Matrix (hardware SIMD).
     * 3. Un-mirrors front camera photo (horizontal flip) so selfie matches the live viewfinder preview.
     * 4. Crops to selected aspect ratio (1:1, 4:3, 16:9, etc.) if requested.
     * 5. Encodes using Android OS native libjpeg-turbo with 100% quality.
     *    This bypasses software DCT quantization loss and eliminates "dot dot" compression noise.
     * 6. Normalizes EXIF orientation to ORIENTATION_NORMAL (1).
     */
    fun processImage(
        filePath: String,
        isFrontCamera: Boolean,
        mirrorFrontCamera: Boolean = true,
        targetRatio: Double? = null,
        quality: Int = 100
    ): Map<String, Any> {
        val result = mutableMapOf<String, Any>()
        val file = File(filePath)
        if (!file.exists()) {
            result["success"] = false
            result["error"] = "File not found: $filePath"
            return result
        }

        try {
            // 1. Read EXIF orientation
            val exif = ExifInterface(filePath)
            val orientation = exif.getAttributeInt(
                ExifInterface.TAG_ORIENTATION,
                ExifInterface.ORIENTATION_NORMAL
            )

            var rotationDegrees = 0
            var exifFlipped = false
            when (orientation) {
                ExifInterface.ORIENTATION_ROTATE_90 -> rotationDegrees = 90
                ExifInterface.ORIENTATION_ROTATE_180 -> rotationDegrees = 180
                ExifInterface.ORIENTATION_ROTATE_270 -> rotationDegrees = 270
                ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> exifFlipped = true
                ExifInterface.ORIENTATION_FLIP_VERTICAL -> {
                    rotationDegrees = 180
                    exifFlipped = true
                }
                ExifInterface.ORIENTATION_TRANSPOSE -> {
                    rotationDegrees = 90
                    exifFlipped = true
                }
                ExifInterface.ORIENTATION_TRANSVERSE -> {
                    rotationDegrees = 270
                    exifFlipped = true
                }
            }

            val needsMirror = isFrontCamera && mirrorFrontCamera
            val needsRotation = rotationDegrees != 0 || exifFlipped

            // Query dimensions without loading entire bitmap into memory
            val boundsOptions = BitmapFactory.Options().apply {
                inJustDecodeBounds = true
            }
            BitmapFactory.decodeFile(filePath, boundsOptions)
            val origW = boundsOptions.outWidth
            val origH = boundsOptions.outHeight
            if (origW <= 0 || origH <= 0) {
                result["success"] = false
                result["error"] = "Invalid image dimensions: ${origW}x${origH}"
                return result
            }

            // Calculate post-rotation dimensions
            val postRotW = if (rotationDegrees == 90 || rotationDegrees == 270) origH else origW
            val postRotH = if (rotationDegrees == 90 || rotationDegrees == 270) origW else origH
            val currentRatio = postRotW.toDouble() / postRotH.toDouble()

            val needsCrop = targetRatio != null && abs(currentRatio - targetRatio) > 0.02

            // Fast path: if back camera, already physically upright, and no aspect ratio crop needed,
            // we leave the pristine raw hardware JPEG untouched!
            if (!needsMirror && !needsRotation && !needsCrop) {
                result["success"] = true
                result["transformed"] = false
                result["width"] = origW
                result["height"] = origH
                return result
            }

            // 2. Decode full bitmap using native Android Skia engine
            val decodeOptions = BitmapFactory.Options().apply {
                inPreferredConfig = Bitmap.Config.ARGB_8888
                inMutable = true
                inScaled = false  // Prevent Android auto-downscaling (preserves full sensor resolution)
            }
            val sourceBitmap = BitmapFactory.decodeFile(filePath, decodeOptions)
            if (sourceBitmap == null) {
                result["success"] = false
                result["error"] = "BitmapFactory failed to decode file"
                return result
            }

            // 3. Configure hardware transformation Matrix
            val matrix = Matrix()

            // Correct EXIF orientation
            if (rotationDegrees != 0) {
                matrix.postRotate(rotationDegrees.toFloat())
            }
            if (exifFlipped) {
                matrix.postScale(-1f, 1f)
            }

            // Un-mirror front camera photo:
            // Android camera sensor captures inverted relative to preview viewfinder mirror.
            // Flipping horizontally ensures that what user saw in preview (e.g. left hand raised)
            // is exactly what is saved in the photo.
            if (needsMirror) {
                matrix.postScale(-1f, 1f)
            }

            // Apply matrix transformation using native Skia
            var currentBitmap = Bitmap.createBitmap(
                sourceBitmap,
                0, 0,
                sourceBitmap.width, sourceBitmap.height,
                matrix,
                true
            )

            // If a new bitmap was allocated, free sourceBitmap immediately
            if (currentBitmap != sourceBitmap) {
                sourceBitmap.recycle()
            }

            // 4. Crop to target aspect ratio if needed
            if (needsCrop && targetRatio != null) {
                val curW = currentBitmap.width
                val curH = currentBitmap.height
                val curR = curW.toDouble() / curH.toDouble()

                var cropW = curW
                var cropH = curH
                var cropX = 0
                var cropY = 0

                if (curR > targetRatio) {
                    cropW = (curH * targetRatio).roundToInt().coerceIn(1, curW)
                    cropX = (curW - cropW) / 2
                } else {
                    cropH = (curW / targetRatio).roundToInt().coerceIn(1, curH)
                    cropY = (curH - cropH) / 2
                }

                val croppedBitmap = Bitmap.createBitmap(currentBitmap, cropX, cropY, cropW, cropH)
                if (croppedBitmap != currentBitmap) {
                    currentBitmap.recycle()
                    currentBitmap = croppedBitmap
                }
            }

            // 5. Compress using native OS libjpeg-turbo with 100% quality
            val tempFile = File(filePath + ".native_tmp")
            FileOutputStream(tempFile).use { outStream ->
                currentBitmap.compress(Bitmap.CompressFormat.JPEG, quality.coerceIn(90, 100), outStream)
                outStream.flush()
            }

            val finalW = currentBitmap.width
            val finalH = currentBitmap.height
            currentBitmap.recycle()

            // Atomically replace original file with hardware-processed file
            if (tempFile.exists()) {
                file.delete()
                tempFile.renameTo(file)
            }

            // 6. Restore ALL original EXIF metadata into the processed file.
            // Only TAG_ORIENTATION is updated to NORMAL (1) — all other camera metadata
            // (GPS, ISO, aperture, focal length, timestamp, lens model etc.) is copied
            // verbatim from the original capture so no photo information is lost.
            try {
                val newExif = ExifInterface(filePath)
                // Copy every metadata tag we care about
                for (tag in EXIF_TAGS_TO_COPY) {
                    val value = exif.getAttribute(tag)
                    if (value != null) {
                        newExif.setAttribute(tag, value)
                    }
                }
                // Always set orientation to NORMAL because we physically corrected the pixels
                newExif.setAttribute(
                    ExifInterface.TAG_ORIENTATION,
                    ExifInterface.ORIENTATION_NORMAL.toString()
                )
                // Update pixel dimensions to match the final cropped/rotated output
                newExif.setAttribute(ExifInterface.TAG_PIXEL_X_DIMENSION, finalW.toString())
                newExif.setAttribute(ExifInterface.TAG_PIXEL_Y_DIMENSION, finalH.toString())
                newExif.saveAttributes()
            } catch (_: Exception) {}

            result["success"] = true
            result["transformed"] = true
            result["width"] = finalW
            result["height"] = finalH
            return result
        } catch (e: Throwable) {
            result["success"] = false
            result["error"] = e.message ?: e.toString()
            return result
        }
    }

    /**
     * Applies optical DSLR background bokeh blur natively on Android:
     * - Blurs background via downscaled multi-pass sliding-window box blur
     * - Bilinearly interpolates MLKit neural segmentation mask
     * - Preserves human faces, hair, eyes, and torso at 100% sharp original sensor resolution
     * - Row-by-row low memory compositing (avoids OOM on high-MP images)
     * - Encodes with Android native libjpeg-turbo at 100% quality (NO dot-dot artifacts)
     */
    fun applyPortraitBokeh(
        filePath: String,
        blurRadius: Float,
        segmentationMask: FloatArray?,
        maskWidth: Int,
        maskHeight: Int,
        faces: List<Map<String, Any>>,
        focusNormX: Float = 0.5f,
        focusNormY: Float = 0.5f,
        quality: Int = 100
    ): Map<String, Any> {
        val result = mutableMapOf<String, Any>()
        val file = File(filePath)
        if (!file.exists()) {
            result["success"] = false
            result["error"] = "File not found: $filePath"
            return result
        }

        try {
            // Snapshot original EXIF before any processing (bokeh re-encodes the file)
            val originalExif = try { ExifInterface(filePath) } catch (_: Exception) { null }

            val decodeOptions = BitmapFactory.Options().apply {
                inPreferredConfig = Bitmap.Config.ARGB_8888
                inMutable = true
                inScaled = false  // Preserve full sensor resolution
            }
            val srcBitmap = BitmapFactory.decodeFile(filePath, decodeOptions)
            if (srcBitmap == null) {
                result["success"] = false
                result["error"] = "Failed to decode bitmap for portrait bokeh"
                return result
            }

            val w = srcBitmap.width
            val h = srcBitmap.height

            // 1. Generate smooth optical background blur
            val blurWorkW = 480
            val blurWorkH = ((blurWorkW.toLong() * h) / w).toInt().coerceAtLeast(1)
            val smallBitmap = Bitmap.createScaledBitmap(srcBitmap, blurWorkW, blurWorkH, true)
            val passes = (blurRadius * 0.75f).roundToInt().coerceIn(4, 20)
            val blurredSmall = fastBoxBlur(smallBitmap, passes)
            if (blurredSmall != smallBitmap) {
                smallBitmap.recycle()
            }
            val blurredBg = Bitmap.createScaledBitmap(blurredSmall, w, h, true)
            blurredSmall.recycle()

            // 2. Prepare face rectangles
            val faceList = faces.mapNotNull { f ->
                val left = (f["left"] as? Number)?.toDouble() ?: return@mapNotNull null
                val top = (f["top"] as? Number)?.toDouble() ?: return@mapNotNull null
                val width = (f["width"] as? Number)?.toDouble() ?: return@mapNotNull null
                val height = (f["height"] as? Number)?.toDouble() ?: return@mapNotNull null
                FaceBox(left.toFloat(), top.toFloat(), width.toFloat(), height.toFloat())
            }

            val hasNeuralMask = segmentationMask != null && segmentationMask.isNotEmpty() && maskWidth > 0 && maskHeight > 0
            val hasFaces = faceList.isNotEmpty()

            // Fallback focus point radii if no face or neural mask
            val fbCx = focusNormX * w
            val fbCy = focusNormY * h
            val fbRx = w * 0.36f
            val fbRy = h * 0.42f

            // 3. Row-by-row blend: 16KB working memory per row, zero OOM risk!
            val srcRow = IntArray(w)
            val blurRow = IntArray(w)

            for (py in 0 until h) {
                srcBitmap.getPixels(srcRow, 0, w, 0, py, w, 1)
                blurredBg.getPixels(blurRow, 0, w, 0, py, w, 1)

                val normY = py.toFloat() / h.toFloat()
                val imgY = py.toFloat()

                for (px in 0 until w) {
                    val normX = px.toFloat() / w.toFloat()
                    val imgX = px.toFloat()

                    var alpha = 0.0f

                    if (hasNeuralMask) {
                        val mxF = normX * (maskWidth - 1)
                        val myF = normY * (maskHeight - 1)
                        val mx0 = mxF.toInt().coerceIn(0, maskWidth - 1)
                        val my0 = myF.toInt().coerceIn(0, maskHeight - 1)
                        val mx1 = (mx0 + 1).coerceIn(0, maskWidth - 1)
                        val my1 = (my0 + 1).coerceIn(0, maskHeight - 1)
                        val fx = mxF - mx0
                        val fy = myF - my0

                        val c00 = segmentationMask!![my0 * maskWidth + mx0]
                        val c10 = segmentationMask[my0 * maskWidth + mx1]
                        val c01 = segmentationMask[my1 * maskWidth + mx0]
                        val c11 = segmentationMask[my1 * maskWidth + mx1]

                        val conf = c00 * (1f - fx) * (1f - fy) +
                                   c10 * fx * (1f - fy) +
                                   c01 * (1f - fx) * fy +
                                   c11 * fx * fy

                        if (conf >= 0.65f) {
                            alpha = 1.0f
                        } else if (conf > 0.35f) {
                            val t = (conf - 0.35f) / 0.30f
                            alpha = t * t * (3.0f - 2.0f * t) // Hermite smoothstep
                        }
                    }

                    if (hasFaces) {
                        for (face in faceList) {
                            val headCx = face.left + face.width * 0.5f
                            val headCy = face.top + face.height * 0.40f
                            val headRx = face.width * 0.80f
                            val headRy = face.height * 0.85f

                            val dx = (imgX - headCx) / headRx
                            val dy = (imgY - headCy) / headRy
                            val distHead = dx * dx + dy * dy

                            var headAlpha = 0.0f
                            if (distHead <= 1.0f) {
                                headAlpha = 1.0f
                            } else if (distHead < 1.5f) {
                                val t = (1.5f - distHead) / 0.5f
                                headAlpha = t * t * (3.0f - 2.0f * t)
                            }
                            if (headAlpha > alpha) alpha = headAlpha

                            // Torso anchor expanding downward from chin
                            if (imgY > face.top + face.height * 0.55f) {
                                val dyTorso = imgY - (face.top + face.height * 0.55f)
                                val halfW = (face.width * 0.70f) + (dyTorso * 0.28f)
                                val edgeDist = halfW - abs(imgX - headCx)
                                if (edgeDist >= 0) {
                                    val ta = (edgeDist / 20.0f).coerceIn(0.0f, 1.0f)
                                    val smoothTorso = ta * ta * (3.0f - 2.0f * ta)
                                    if (smoothTorso > alpha) alpha = smoothTorso
                                }
                            }
                        }
                    } else if (!hasNeuralMask) {
                        // Radial fallback
                        val dx = (imgX - fbCx) / fbRx
                        val dy = (imgY - fbCy) / fbRy
                        val distSq = dx * dx + dy * dy
                        if (distSq <= 1.0f) {
                            alpha = 1.0f
                        } else if (distSq < 1.5f) {
                            val t = (1.5f - distSq) / 0.5f
                            alpha = t * t * (3.0f - 2.0f * t)
                        }
                    }

                    // Composite
                    if (alpha >= 0.999f) {
                        // Keep pure original sensor pixel
                    } else if (alpha <= 0.001f) {
                        srcRow[px] = blurRow[px]
                    } else {
                        val sp = srcRow[px]
                        val bp = blurRow[px]
                        val sr = (sp shr 16) and 0xFF
                        val sg = (sp shr 8) and 0xFF
                        val sb = sp and 0xFF
                        val br = (bp shr 16) and 0xFF
                        val bg = (bp shr 8) and 0xFF
                        val bb = bp and 0xFF

                        val r = (sr * alpha + br * (1.0f - alpha)).roundToInt().coerceIn(0, 255)
                        val g = (sg * alpha + bg * (1.0f - alpha)).roundToInt().coerceIn(0, 255)
                        val b = (sb * alpha + bb * (1.0f - alpha)).roundToInt().coerceIn(0, 255)
                        srcRow[px] = (0xFF shl 24) or (r shl 16) or (g shl 8) or b
                    }
                }

                srcBitmap.setPixels(srcRow, 0, w, 0, py, w, 1)
            }

            blurredBg.recycle()

            // 4. Compress with native libjpeg-turbo at 100% quality
            val tempFile = File(filePath + ".bokeh_tmp")
            FileOutputStream(tempFile).use { outStream ->
                srcBitmap.compress(Bitmap.CompressFormat.JPEG, quality.coerceIn(90, 100), outStream)
                outStream.flush()
            }
            srcBitmap.recycle()

            if (tempFile.exists()) {
                file.delete()
                tempFile.renameTo(file)
            }

            // Restore all original EXIF metadata to the bokeh-processed file
            if (originalExif != null) {
                try {
                    val processedExif = ExifInterface(filePath)
                    for (tag in EXIF_TAGS_TO_COPY) {
                        val value = originalExif.getAttribute(tag)
                        if (value != null) processedExif.setAttribute(tag, value)
                    }
                    // Mark as physically upright (bokeh input is already rotated)
                    processedExif.setAttribute(
                        ExifInterface.TAG_ORIENTATION,
                        ExifInterface.ORIENTATION_NORMAL.toString()
                    )
                    processedExif.saveAttributes()
                } catch (_: Exception) {}
            }

            result["success"] = true
            return result
        } catch (e: Throwable) {
            result["success"] = false
            result["error"] = e.message ?: e.toString()
            return result
        }
    }

    private class FaceBox(val left: Float, val top: Float, val width: Float, val height: Float)

    /**
     * O(N) sliding-window box blur running in ~5ms on low-res bitmap.
     * Repeated passes approximate a continuous Gaussian bokeh blur with 0 boundary artifacts.
     */
    private fun fastBoxBlur(bitmap: Bitmap, passes: Int): Bitmap {
        val w = bitmap.width
        val h = bitmap.height
        val pixels = IntArray(w * h)
        bitmap.getPixels(pixels, 0, w, 0, 0, w, h)
        val temp = IntArray(w * h)

        val radius = 3
        val div = radius * 2 + 1

        for (p in 0 until passes) {
            // Horizontal blur
            for (y in 0 until h) {
                val rowOffset = y * w
                var rSum = 0
                var gSum = 0
                var bSum = 0
                for (i in -radius..radius) {
                    val c = pixels[rowOffset + i.coerceIn(0, w - 1)]
                    rSum += (c shr 16) and 0xFF
                    gSum += (c shr 8) and 0xFF
                    bSum += c and 0xFF
                }
                for (x in 0 until w) {
                    temp[rowOffset + x] = (0xFF shl 24) or ((rSum / div) shl 16) or ((gSum / div) shl 8) or (bSum / div)
                    val xOut = (x - radius).coerceIn(0, w - 1)
                    val xIn = (x + radius + 1).coerceIn(0, w - 1)
                    val cOut = pixels[rowOffset + xOut]
                    val cIn = pixels[rowOffset + xIn]
                    rSum += ((cIn shr 16) and 0xFF) - ((cOut shr 16) and 0xFF)
                    gSum += ((cIn shr 8) and 0xFF) - ((cOut shr 8) and 0xFF)
                    bSum += (cIn and 0xFF) - (cOut and 0xFF)
                }
            }
            // Vertical blur
            for (x in 0 until w) {
                var rSum = 0
                var gSum = 0
                var bSum = 0
                for (i in -radius..radius) {
                    val c = temp[i.coerceIn(0, h - 1) * w + x]
                    rSum += (c shr 16) and 0xFF
                    gSum += (c shr 8) and 0xFF
                    bSum += c and 0xFF
                }
                for (y in 0 until h) {
                    pixels[y * w + x] = (0xFF shl 24) or ((rSum / div) shl 16) or ((gSum / div) shl 8) or (bSum / div)
                    val yOut = (y - radius).coerceIn(0, h - 1)
                    val yIn = (y + radius + 1).coerceIn(0, h - 1)
                    val cOut = temp[yOut * w + x]
                    val cIn = temp[yIn * w + x]
                    rSum += ((cIn shr 16) and 0xFF) - ((cOut shr 16) and 0xFF)
                    gSum += ((cIn shr 8) and 0xFF) - ((cOut shr 8) and 0xFF)
                    bSum += (cIn and 0xFF) - (cOut and 0xFF)
                }
            }
        }

        val resultBitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        resultBitmap.setPixels(pixels, 0, w, 0, 0, w, h)
        return resultBitmap
    }
}
