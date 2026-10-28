package io.github.yy1319hua.app

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Dart 侧对应实现：lib/features/updater/data/apk_installer.dart
 *
 * 通道方法：
 *  - getUpdateDir                -> String  APK 下载目录（filesDir/updates）
 *  - canInstallPackages          -> Bool    是否已获"未知来源安装"授权（Android 8.0+）
 *  - openUnknownSourceSettings   -> void    跳转系统授权页
 *  - installApk(path)            -> void    经 FileProvider 唤起系统安装器
 */
class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getUpdateDir" -> result.success(updateDir().absolutePath)
                    "canInstallPackages" -> result.success(canInstallPackages())
                    "openUnknownSourceSettings" -> {
                        openUnknownSourceSettings()
                        result.success(null)
                    }
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("BAD_ARGS", "缺少 path 参数", null)
                        } else {
                            try {
                                installApk(path)
                                result.success(null)
                            } catch (e: Throwable) {
                                result.error("INSTALL_FAILED", e.message, null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /** APK 存放目录：内部存储，无需额外读写权限即可经 FileProvider 授权给安装器。 */
    private fun updateDir(): File {
        val dir = File(filesDir, UPDATE_DIR)
        if (!dir.exists()) {
            dir.mkdirs()
        }
        return dir
    }

    /** Android 8.0 之前只有全局"未知来源"开关，无法按包名查询，按已授权处理。 */
    private fun canInstallPackages(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true
        return packageManager.canRequestPackageInstalls()
    }

    private fun openUnknownSourceSettings() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val intent = Intent(
            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
            Uri.parse("package:$packageName"),
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            startActivity(intent)
        } catch (e: ActivityNotFoundException) {
            startActivity(
                Intent(Settings.ACTION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        }
    }

    private fun installApk(path: String) {
        val file = File(path)
        if (!file.exists()) {
            throw IllegalStateException("安装包不存在：$path")
        }
        val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        try {
            startActivity(intent)
        } catch (e: ActivityNotFoundException) {
            throw IllegalStateException("未找到可用的安装程序")
        }
    }

    companion object {
        private const val CHANNEL = "io.github.yy1319hua.app/installer"
        private const val UPDATE_DIR = "updates"
    }
}
