package com.feiniu.music.island.shizuku

import android.content.ComponentName
import android.content.ServiceConnection
import android.os.IBinder
import android.util.Log
import com.feiniu.music.island.shizuku.IPrivilegedLogCallback
import com.feiniu.music.island.shizuku.IPrivilegedService
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import rikka.shizuku.Shizuku
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Shizuku User Service（特权服务）连接管理。
 *
 * 负责按需绑定 [PrivilegedServiceImpl]（跑在 Shizuku 子进程，具备高权限），
 * 带缓存与超时，避免反复 bind/unbind。完整移植自 HyperNotification 的
 * ShizukuServiceConnection（Apache-2.0）。
 */
object ShizukuServiceConnection {

    private val serviceMutex = Mutex()
    private var cachedService: IPrivilegedService? = null
    private var serviceConnection: ServiceConnection? = null
    private var serviceArgs: Shizuku.UserServiceArgs? = null
    private var lastPingAttempt = 0L
    private const val TAG = "ShizukuServiceConnection"
    private const val PING_INTERVAL_MS = 5000L // 每 5 秒才 ping 一次，避免开销
    private const val BIND_TIMEOUT_MS = 10000L // 服务绑定 10 秒超时

    @Volatile
    private var logCallbackEnabled = true
    private val logCallback = object : IPrivilegedLogCallback.Stub() {
        override fun log(level: Int, tag: String?, message: String?) {
            val safeTag = tag ?: "PrivilegedService"
            val safeMsg = message ?: ""
            when (level) {
                0 -> Log.d(safeTag, safeMsg)
                1 -> Log.i(safeTag, safeMsg)
                2 -> Log.w(safeTag, safeMsg)
                3 -> Log.e(safeTag, safeMsg)
                else -> Log.d(safeTag, safeMsg)
            }
        }
    }

    /**
     * 获取（或创建）到特权服务的持久连接。带缓存，避免反复 bind/unbind。
     *
     * [packageName] 为当前应用实际安装包名（applicationId），用于定位本应用
     * 内的 User Service 组件。类包名（com.feiniu.music.island.shizuku）由
     * namespace 固定，不随 applicationId 变化，故类名无需传入。
     */
    suspend fun getPrivilegedService(packageName: String): IPrivilegedService {
        serviceMutex.withLock {
            cachedService?.let { cached ->
                val now = System.currentTimeMillis()
                if (now - lastPingAttempt > PING_INTERVAL_MS) {
                    try {
                        if (cached.asBinder().pingBinder()) {
                            lastPingAttempt = now
                            Log.d(TAG, "Service 缓存有效 (ping 成功)")
                            return cached
                        }
                    } catch (e: Throwable) {
                        Log.w(TAG, "Service ping 失败, 正在重新绑定: ${e.message}")
                    }
                    lastPingAttempt = now
                    cachedService = null
                } else {
                    Log.v(TAG, "正在使用缓存 of Service (距离上次 ping 已过 ${now - lastPingAttempt}ms)")
                    return cached
                }
            }

            Log.d(TAG, "正在建立新的 Service 连接...")
            return establishServiceConnection(packageName).also {
                lastPingAttempt = System.currentTimeMillis()
                Log.d(TAG, "Service 连接建立成功")
            }
        }
    }

    fun setLogCallbackEnabled(enabled: Boolean) {
        logCallbackEnabled = enabled
        val service = cachedService ?: return
        try {
            if (enabled) {
                service.setLogCallback(logCallback)
                Log.d(TAG, "Log 回调已注册到特权 Service (开关切换)")
            } else {
                service.setLogCallback(null)
                Log.d(TAG, "Log 回调已从特权 Service 取消注册 (开关切换)")
            }
        } catch (e: Throwable) {
            Log.w(TAG, "切换 Log 回调失败: ${e.message}")
        }
    }

    private suspend fun establishServiceConnection(packageName: String): IPrivilegedService {
        return withTimeoutOrNull(BIND_TIMEOUT_MS) {
            suspendCancellableCoroutine { continuation ->
                val connection = object : ServiceConnection {
                    override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
                        Log.d(TAG, "onServiceConnected 被调用, service=$service")
                        if (service != null) {
                            val privileged = IPrivilegedService.Stub.asInterface(service)
                            if (logCallbackEnabled) {
                                try {
                                    privileged.setLogCallback(logCallback)
                                    Log.d(TAG, "Log 回调已注册到特权 Service")
                                } catch (e: Exception) {
                                    Log.w(TAG, "注册 Log 回调失败: ${e.message}")
                                }
                            }
                            cachedService = privileged
                            serviceConnection = this
                            continuation.resume(privileged)
                        } else {
                            Log.e(TAG, "onServiceConnected 但 binder 为 null!")
                            continuation.resumeWithException(Exception("Shizuku UserService 已绑定但返回了空的 binder"))
                        }
                    }

                    override fun onServiceDisconnected(name: ComponentName?) {
                        Log.w(TAG, "Service 异常断开连接")
                        cachedService = null
                    }
                }

                val args = Shizuku.UserServiceArgs(
                    ComponentName(
                        packageName,
                        PrivilegedServiceImpl::class.java.name
                    )
                )
                    .daemon(false)
                    .processNameSuffix("privileged")
                    .version(2)

                serviceArgs = args

                try {
                    Log.d(TAG, "正在调用 Shizuku.bindUserService()...")
                    Shizuku.bindUserService(args, connection)
                } catch (e: Throwable) {
                    Log.e(TAG, "bindUserService 抛出异常: ${e.message}", e)
                    continuation.resumeWithException(e)
                }

                continuation.invokeOnCancellation {
                    Log.d(TAG, "Service 绑定已取消, 正在执行 unbind...")
                    try {
                        Shizuku.unbindUserService(args, connection, true)
                    } catch (ignored: Throwable) {
                        Log.w(TAG, "执行 unbind 期间发生错误: ${ignored.message}")
                    }
                }
            }
        } ?: throw Exception("Service 绑定超时, 超时时间为 ${BIND_TIMEOUT_MS}ms")
    }

    suspend fun <T> executeWithService(
        packageName: String,
        action: suspend (IPrivilegedService) -> T
    ): T {
        Log.d(TAG, "executeWithService 被调用")
        return try {
            action(getPrivilegedService(packageName)).also {
                Log.d(TAG, "executeWithService 执行成功")
            }
        } catch (e: Throwable) {
            Log.e(TAG, "executeWithService 执行失败: ${e.message}", e)
            throw e
        }
    }

    suspend fun release() {
        serviceMutex.withLock {
            val args = serviceArgs
            val connection = serviceConnection
            runCatching { cachedService?.setLogCallback(null) }
            cachedService = null
            serviceConnection = null
            serviceArgs = null
            lastPingAttempt = 0L
            if (args != null && connection != null) {
                try {
                    Shizuku.unbindUserService(args, connection, true)
                    Log.d(TAG, "Service 连接已释放")
                } catch (e: Throwable) {
                    Log.w(TAG, "释放 Service 连接失败: ${e.message}")
                }
            }
        }
    }
}
