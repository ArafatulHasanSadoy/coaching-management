package com.farhantanvir.coaching_ops

import android.content.Context
import android.os.Bundle
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.print.PageRange
import android.print.PrintAttributes
import android.print.PrintDocumentAdapter
import android.print.PrintDocumentInfo
import android.print.PrintManager
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import android.webkit.WebView
import android.webkit.WebViewClient
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// FlutterFragmentActivity rather than FlutterActivity: local_auth's biometric
// prompt is a fragment and crashes on a plain FlutterActivity host.
class MainActivity : FlutterFragmentActivity() {

    private val channelName = "coaching_ops/print"

    // A WebView that gets garbage collected mid-job silently cancels printing,
    // so the instance driving a print job is held until the job is handed off.
    private var printWebView: WebView? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "printHtml" -> {
                        val html = call.argument<String>("html")
                        val jobName = call.argument<String>("jobName") ?: "Document"
                        val mediaSize = call.argument<String>("mediaSize") ?: "A4"
                        if (html == null) {
                            result.error("NO_HTML", "html argument is required", null)
                        } else {
                            printHtml(html, jobName, mediaSize)
                            result.success(true)
                        }
                    }
                    "printPdf" -> {
                        val path = call.argument<String>("path")
                        val jobName = call.argument<String>("jobName") ?: "Document"
                        val file = if (path == null) null else File(path)
                        if (file == null || !file.exists()) {
                            result.error("NO_FILE", "the file is missing", path)
                        } else {
                            printPdf(file, jobName)
                            result.success(true)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun printHtml(html: String, jobName: String, mediaSize: String) {
        val webView = WebView(this)
        webView.settings.javaScriptEnabled = false
        webView.webViewClient = object : WebViewClient() {
            override fun onPageFinished(view: WebView, url: String?) {
                val printManager = getSystemService(Context.PRINT_SERVICE) as PrintManager
                val adapter = view.createPrintDocumentAdapter(jobName)
                // The paper size belongs to the print job, not to CSS: an
                // @page rule cannot shrink an A4 sheet, so an A5 receipt asked
                // for here would otherwise be laid out on A4 with the bottom
                // half blank.
                val media = when (mediaSize) {
                    "A5" -> PrintAttributes.MediaSize.ISO_A5
                    else -> PrintAttributes.MediaSize.ISO_A4
                }
                val attributes = PrintAttributes.Builder()
                    .setMediaSize(media)
                    .setResolution(PrintAttributes.Resolution("pdf", "pdf", 600, 600))
                    .setMinMargins(PrintAttributes.Margins.NO_MARGINS)
                    .build()
                printManager.print(jobName, adapter, attributes)
                printWebView = null
            }
        }
        printWebView = webView
        webView.loadDataWithBaseURL("file:///android_asset/", html, "text/html", "UTF-8", null)
    }

    /// Prints a PDF the centre already has, unchanged.
    ///
    /// A WebView cannot render PDF, so the fixed forms an owner uploads — the
    /// diary page, a blank attendance sheet — need their own path: an adapter
    /// that hands the existing file straight to the print system.
    private fun printPdf(file: File, jobName: String) {
        val printManager = getSystemService(Context.PRINT_SERVICE) as PrintManager
        printManager.print(
            jobName,
            PdfFilePrintAdapter(file),
            PrintAttributes.Builder()
                .setMediaSize(PrintAttributes.MediaSize.ISO_A4)
                .setResolution(PrintAttributes.Resolution("pdf", "pdf", 600, 600))
                .setMinMargins(PrintAttributes.Margins.NO_MARGINS)
                .build(),
        )
    }
}

/// Streams an existing PDF to the printer without re-rendering it.
///
/// Subclassing [PrintDocumentAdapter] is fine — the restriction that bites
/// elsewhere is on *constructing* its result callbacks, which this only
/// receives.
private class PdfFilePrintAdapter(private val file: File) : PrintDocumentAdapter() {

    override fun onLayout(
        oldAttributes: PrintAttributes?,
        newAttributes: PrintAttributes?,
        cancellationSignal: CancellationSignal?,
        callback: LayoutResultCallback,
        extras: Bundle?,
    ) {
        if (cancellationSignal?.isCanceled == true) {
            callback.onLayoutCancelled()
            return
        }

        val info = PrintDocumentInfo.Builder(file.name)
            .setContentType(PrintDocumentInfo.CONTENT_TYPE_DOCUMENT)
            // The page count is inside the PDF; the print system reads it from
            // the stream rather than needing it declared up front.
            .setPageCount(PrintDocumentInfo.PAGE_COUNT_UNKNOWN)
            .build()

        callback.onLayoutFinished(info, true)
    }

    override fun onWrite(
        pages: Array<out PageRange>?,
        destination: ParcelFileDescriptor,
        cancellationSignal: CancellationSignal?,
        callback: WriteResultCallback,
    ) {
        try {
            FileInputStream(file).use { input ->
                FileOutputStream(destination.fileDescriptor).use { output ->
                    input.copyTo(output)
                }
            }
            if (cancellationSignal?.isCanceled == true) {
                callback.onWriteCancelled()
            } else {
                callback.onWriteFinished(arrayOf(PageRange.ALL_PAGES))
            }
        } catch (e: Exception) {
            callback.onWriteFailed(e.message)
        }
    }
}
