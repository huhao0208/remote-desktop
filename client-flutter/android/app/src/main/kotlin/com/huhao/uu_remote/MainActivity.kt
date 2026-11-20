package com.huhao.uu_remote

import android.content.Intent
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 唯一需要原生代码的地方：自动升级要拉起系统安装器。
 *
 * Android 不允许应用静默安装自己的新版本（那是系统权限），
 * 所以「自动升级」在这里只能是：Dart 下载 + 校验 → 通过 FileProvider 把 APK
 * 以 content:// URI 交给 PackageInstaller，用户在系统弹窗里点「安装」。
 */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "uu/installer")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrEmpty()) {
                            result.error("bad_args", "缺少 APK 路径", null)
                            return@setMethodCallHandler
                        }
                        installApk(path, result)
                    }

                    else -> result.notImplemented()
                }
            }
    }

    private fun installApk(path: String, result: MethodChannel.Result) {
        try {
            val file = File(path)
            if (!file.exists()) {
                result.error("missing_apk", "APK 不存在：$path", null)
                return
            }
            // authorities 必须与 AndroidManifest 里 provider 的 ${applicationId}.fileprovider 一致
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            result.error("install_failed", e.message ?: e.toString(), null)
        }
    }
}
