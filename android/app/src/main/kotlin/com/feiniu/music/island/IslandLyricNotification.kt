package com.feiniu.music.island

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Bundle
import androidx.core.app.NotificationCompat
import com.feiniu.music.R
import com.feiniu.music.island.shizuku.ShizukuManager
import com.feiniu.music.island.shizuku.ShizukuServiceConnection
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * 通知歌词灵动岛 — 原生层。
 *
 * 两种通知类型，由 Dart 层 [notificationType] 决定：
 * - 实时通知（type 0，无 root/Shizuku）：标准 Android 实时通知接口上岛。
 *   移植自 HyperLyric 的 buildNormalNotification（GPL-3.0）——普通 ongoing
 *   通知 + 分段进度条 + setRequestPromotedOngoing(true)，HyperOS 3.0.300+ /
 *   Android 16 原生将其提升为灵动岛卡片，无需任何焦点通知 JSON 与白名单。
 * - 焦点通知（type 1）：MIUI「焦点通知」路径（移植自 HyperLyric 的
 *   buildFocusNotification，GPL-3.0）——通知 extras 携带 `mFocusNotification` +
 *   `miui.focus.param`(JSON) + `miui.focus.pics`(Bundle)，HyperOS 识别后在系统
 *   灵动岛渲染歌词卡片。需系统焦点通知白名单放行该包名。
 *
 * 同一 ID 连续 notify() 即实现歌词/进度原地刷新。
 */
class IslandLyricNotification(private val context: Context) {

    companion object {
        private const val TAG = "IslandLyricNotification"

        /** 灵动岛歌词使用的通知 ID（与 audio_service 媒体通知 ID 不同，互不干扰）。 */
        const val NOTIFICATION_ID = 2003

        private const val CHANNEL_ID = "feiniu_island_lyric_v1"

        /** 实时通知（无 root 路径）的常驻通道，与焦点通知共用。 */
        private const val CHANNEL_ID_LIVE = "feiniu_island_lyric_live_v1"

        /** 歌词行 / 进度更新时重发通知的最小间隔，避免高频刷新压垮系统。 */
        private const val MIN_UPDATE_INTERVAL_MS = 1000L

        /** 通知类型常量，与 Dart 层 IslandLyricSettings.typeLive/typeFocus 对应。 */
        const val TYPE_LIVE = 0
        const val TYPE_FOCUS = 1
    }

    private val notificationManager =
        context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private var lastLyricKey: String? = null
    private var lastSongKey: String? = null
    private var lastUpdateMs: Long = 0
    private var lastCoverPath: String? = null
    private var lastAodLyrics: Boolean = false
    private var lastNotificationType: Int = TYPE_LIVE
    private var cachedCoverPath: String? = null
    private var cachedCoverIcon: android.graphics.drawable.Icon? = null

    /** 异步绕过（Shizuku 拦/放 XMSF 网络）专用作用域，与通知发送生命周期隔离。 */
    private val shizukuScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val bypassMutex = Mutex()

    /** 上次焦点通知是否已尝试（或正处于）Shizuku 绕过流程。 */
    private var lastBypassFocusLimit: Boolean = false

    init {
        ensureNotificationChannel()
    }

    private fun ensureNotificationChannel() {
        if (notificationManager.getNotificationChannel(CHANNEL_ID) == null) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "通知歌词灵动岛",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                setSound(null, null)
                setShowBadge(false)
                enableVibration(false)
                setLockscreenVisibility(Notification.VISIBILITY_PUBLIC)
            }
            notificationManager.createNotificationChannel(channel)
        }
        // 实时通知通道：与焦点通知同属性，区分开便于用户按类型管理通知权限。
        if (notificationManager.getNotificationChannel(CHANNEL_ID_LIVE) == null) {
            val channel = NotificationChannel(
                CHANNEL_ID_LIVE,
                "通知歌词灵动岛（实时）",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                setSound(null, null)
                setShowBadge(false)
                enableVibration(false)
                setLockscreenVisibility(Notification.VISIBILITY_PUBLIC)
            }
            notificationManager.createNotificationChannel(channel)
        }
    }

    /**
     * 更新灵动岛歌词。同一首歌内歌词行变化会立即刷新；仅进度变化时按
     * [MIN_UPDATE_INTERVAL_MS] 节流，避免高频刷新。
     *
     * @param leftLyric 大岛左侧歌词（长歌词前半段，短歌词传空）
     * @param lyric 大岛右侧歌词（长歌词后半段，或短歌词整行）
     * @param coverPath 封面本地文件路径（可为空，空则左侧不显示封面）
     * @param notificationType 通知类型：[TYPE_LIVE] 实时通知（无 root）/
     *                         [TYPE_FOCUS] 焦点通知
     * @param bypassFocusLimit 焦点通知下是否使用 Shizuku 绕过系统白名单限制
     *                         （仅对 [TYPE_FOCUS] 生效，实时通知忽略）
     */
    fun update(
        leftLyric: String,
        lyric: String,
        fullLyric: String,
        title: String,
        artist: String,
        isPlaying: Boolean,
        positionMs: Long,
        durationMs: Long,
        showProgressSetting: Boolean,
        coverPath: String?,
        aodLyrics: Boolean,
        notificationType: Int = TYPE_FOCUS,
        bypassFocusLimit: Boolean = false
    ) {
        // 完整歌词 = 左 + 右 拼接，用于歌曲变化判定（左右分割点变化不算切歌）
        val songKey = "$title|$artist"
        val lyricKey = "$leftLyric|$lyric".trim()

        // 切换歌曲或歌词行变化 → 立即刷新
        val lyricChanged = lyricKey != lastLyricKey
        val songChanged = songKey != lastSongKey
        val coverChanged = coverPath != lastCoverPath
        val aodLyricsChanged = aodLyrics != lastAodLyrics
        val typeChanged = notificationType != lastNotificationType
        val bypassChanged = bypassFocusLimit != lastBypassFocusLimit
        val shouldReleaseBypassService = lastBypassFocusLimit && !bypassFocusLimit
        lastCoverPath = coverPath
        lastAodLyrics = aodLyrics
        lastBypassFocusLimit = bypassFocusLimit
        if (shouldReleaseBypassService) {
            releaseBypassService()
        }

        val now = System.currentTimeMillis()
        // 实时通知只随歌词变化刷新：进度变化不触发重发（避免高频重发）。
        // 焦点通知保留进度驱动（1s 节流）。
        val progressChanged = notificationType != TYPE_LIVE &&
            (now - lastUpdateMs) >= MIN_UPDATE_INTERVAL_MS

        if (!lyricChanged && !songChanged && !coverChanged && !aodLyricsChanged &&
            !typeChanged && !bypassChanged && !progressChanged
        ) {
            return
        }

        lastLyricKey = lyricKey
        lastSongKey = songKey
        lastUpdateMs = now
        lastNotificationType = notificationType

        val duration = if (durationMs > 0) durationMs else 100L
        val position = positionMs.coerceIn(0, duration)
        val progress = if (duration > 1000) {
            ((position.toDouble() / duration) * 100).toInt().coerceIn(0, 100)
        } else {
            0
        }

        val songInfo = if (artist.isEmpty()) title else "$title · $artist"

        val uiState = IslandUiState(
            title = lyric,
            islandTitleLeft = leftLyric,
            fullLyric = fullLyric,
            // 通知/AOD 标题：关闭息屏歌词时显示「歌名 · 歌手」，
            // 开启时被 fullLyric 覆盖（歌词上标题、歌名·歌手移到副标题）。
            notificationTitleLeft = songInfo,
            notificationTitleRight = lyric,
            songInfo = songInfo,
            progress = progress,
            isPlaying = isPlaying,
            showProgress = showProgressSetting,
            hasCover = !coverPath.isNullOrBlank(),
            aodLyrics = aodLyrics
        )

        if (notificationType == TYPE_LIVE) {
            notifyLive(uiState, coverPath, duration)
        } else {
            val contentChanged = lyricChanged || songChanged || coverChanged ||
                aodLyricsChanged || typeChanged || bypassChanged
            // 白名单绕过只用于建立/更新通知内容。纯进度帧直接更新已存在的
            // 焦点通知，避免每 300ms 切换一次系统服务防火墙规则。
            notifyFocusWithBypass(uiState, coverPath, bypassFocusLimit && contentChanged)
        }
    }

    fun hide() {
        notificationManager.cancel(NOTIFICATION_ID)
        lastLyricKey = null
        lastSongKey = null
        lastUpdateMs = 0
        lastCoverPath = null
        lastAodLyrics = false
        lastNotificationType = TYPE_LIVE
        lastBypassFocusLimit = false
        cachedCoverPath = null
        cachedCoverIcon = null
        releaseBypassService()
    }

    /** 焦点通知路径：extras 携带焦点 JSON 交给 HyperOS 灵动岛渲染。 */
    private fun notifyFocus(uiState: IslandUiState, coverPath: String?) {
        // 焦点通知 extras：HyperOS 依据这些字段在灵动岛渲染
        val extras = Bundle()
        extras.putBoolean("mFocusNotification", true)
        extras.putString("miui.focus.param", FocusNotificationBuilder(uiState, uiState.showProgress).build())
        if (uiState.color != 0) {
            extras.putInt("mipush_focus_color", uiState.color)
        }

        // 图片资源：大岛左侧封面 + 小图标兜底
        val picsBundle = Bundle()
        val albumIcon = loadCoverIcon(coverPath)
        if (albumIcon != null) {
            picsBundle.putParcelable("miui.focus.pic_album", albumIcon)
        }
        extras.putBundle("miui.focus.pics", picsBundle)

        // 外发光光圈效果（参考 HyperIsland IslandOuterGlowHook 的注入方式）：
        // 通知 extras 的 miui.effect.src / miui.bigIsland.effect.src 触发
        // 悬浮/大岛光圈。普通应用可直接 put（HyperIsland IslandDispatcherNotifier
        // 同样是直接 put）。能否渲染取决于具体 HyperOS 版本。
        extras.putString("miui.effect.src", "outer_glow")
        extras.putString("miui.bigIsland.effect.src", "outer_glow")

        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOnlyAlertOnce(true)
            .setCustomContentView(null)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            // 息屏歌词开关为反向语义：
            // 开（aodLyrics=true）→ 标题 = 歌名，副标题无（息屏显示歌曲名）；
            // 关（aodLyrics=false，默认）→ 标题 = 完整歌词帧，歌名移到副标题（息屏显示歌词）。
            .setContentTitle(
                if (uiState.aodLyrics) uiState.notificationTitleLeft else uiState.fullLyric
            )
            .setSubText(
                if (uiState.aodLyrics) null else uiState.songInfo
            )
            .setContentText(uiState.notificationTitleRight)
            .addExtras(extras)

        val notification = builder.build()
        // 常驻通知：不可手动滑动清除，仅由 stop/暂停逻辑取消
        notification.flags =
            notification.flags or Notification.FLAG_ONGOING_EVENT or Notification.FLAG_NO_CLEAR

        try {
            notificationManager.notify(NOTIFICATION_ID, notification)
        } catch (e: Exception) {
            android.util.Log.w(TAG, "发送焦点通知失败", e)
        }
    }

    /**
     * 焦点通知发送（含 Shizuku 白名单绕过）。
     *
     * [bypass] 为 true 时：先拦截 XMSF 网络 → 发送焦点通知 → 短暂延迟后恢复
     * 网络。网络被掐断期间系统无法向小米服务端校验白名单，焦点通知得以绕过
     * 白名单渲染到灵动岛。拦截失败时回退为普通焦点通知（不阻塞发送）。
     */
    private fun notifyFocusWithBypass(uiState: IslandUiState, coverPath: String?, bypass: Boolean) {
        if (!bypass) {
            notifyFocus(uiState, coverPath)
            return
        }

        shizukuScope.launch {
            if (!bypassMutex.tryLock()) {
                // 上一轮仍在处理；跳过中间进度帧，后续位置事件会继续刷新。
                return@launch
            }
            var networkDisabled = false
            try {
                try {
                    val disableSuccess =
                        ShizukuManager.setXmsfNetworkingEnabled(context, false)
                    if (disableSuccess) {
                        networkDisabled = true
                        android.util.Log.d(TAG, "已拦截 XMSF 网络，准备发送焦点通知")
                    } else {
                        android.util.Log.w(TAG, "Shizuku 拦截 XMSF 网络失败，按普通焦点通知发送")
                    }
                } catch (e: Throwable) {
                    android.util.Log.e(TAG, "Shizuku 拦截 XMSF 网络异常", e)
                }

                notifyFocus(uiState, coverPath)

                if (networkDisabled) {
                    delay(100L)
                }
            } finally {
                if (networkDisabled) {
                    try {
                        ShizukuManager.setXmsfNetworkingEnabled(context, true)
                        android.util.Log.d(TAG, "已恢复 XMSF 网络")
                    } catch (e: Throwable) {
                        android.util.Log.e(TAG, "恢复 XMSF 网络异常", e)
                    }
                }
                bypassMutex.unlock()
            }
        }
    }

    private fun releaseBypassService() {
        shizukuScope.launch {
            bypassMutex.withLock {
                ShizukuServiceConnection.release()
            }
        }
    }

    /** 实时通知路径：标准 Android 实时通知接口上岛（无 root/Shizuku/白名单）。 */
    private fun notifyLive(uiState: IslandUiState, coverPath: String?, durationMs: Long) {        // 封面：实时动态左侧是图标位，用封面图（对齐 HyperLyric buildNormalNotification
        // 的 setSmallIcon(封面)）；无封面时退回应用图标。
        val albumIcon = loadCoverIcon(coverPath)
        val builder = NotificationCompat.Builder(context, CHANNEL_ID_LIVE)
            .setSmallIcon(
                if (albumIcon != null) {
                    androidx.core.graphics.drawable.IconCompat.createFromIcon(albumIcon)
                } else {
                    androidx.core.graphics.drawable.IconCompat.createWithResource(
                        context,
                        R.mipmap.ic_launcher
                    )
                }
            )
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCustomContentView(null)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setContentIntent(getContentPendingIntent())
            // Android 16 Live Updates：灵动岛主文本。HyperOS 实时动态渲染的
            // 就是这段 shortCriticalText，必须是完整歌词整行（fullLyric）——
            // 之前传的是右半 lyric，导致灵动岛只显示右半、左边空白。
            // 对齐 HyperLyric：实时通知下 disableLyricSplit=true，其 title
            // （shortCriticalText）即完整歌词整行。
            .setShortCriticalText(uiState.fullLyric.ifBlank { uiState.title })
            // 通知卡片：标题 = 歌词左半，内容 = 歌词右半，歌名·歌手放副标题
            .setContentTitle(
                uiState.islandTitleLeft.ifEmpty { uiState.notificationTitleLeft }
            )
            .setSubText(uiState.songInfo)
            .setContentText(uiState.notificationTitleRight)

        if (albumIcon != null) {
            builder.setLargeIcon(albumIcon)
        }

        // 分段进度条：对齐 HyperLyric buildNormalNotification —— 只要歌曲时长
        // 有效就总是生成进度条（含 progress=0 时一个空分段），让通知从一开始
        // 就是「实时更新」形态。仅当用户关闭进度显示时才不加。
        if (uiState.showProgress && durationMs > 1000) {
            try {
                val remaining = 100 - uiState.progress
                val segments = ArrayList<NotificationCompat.ProgressStyle.Segment>(2)
                if (uiState.progress > 0) {
                    val segment = NotificationCompat.ProgressStyle.Segment(uiState.progress)
                    if (uiState.progressColorEnabled) {
                        segment.setColor(uiState.color)
                    }
                    segments.add(segment)
                }
                if (remaining > 0) {
                    segments.add(
                        NotificationCompat.ProgressStyle.Segment(remaining)
                            .setColor(0x40FFFFFF)
                    )
                }
                val style = NotificationCompat.ProgressStyle()
                    .setProgressSegments(segments)
                    .setStyledByProgress(false)
                    .setProgress(uiState.progress)
                builder.setStyle(style)
            } catch (_: Exception) {
                // ProgressStyle 在低版本 core 上不可用时忽略，通知仍可正常发送
            }
        }

        // Android 16 实时通知提升 API：请求把 ongoing 通知提升为灵动岛/胶囊卡片。
        // 需配合 manifest 的 POST_PROMOTED_NOTIFICATIONS 权限，否则被系统忽略。
        builder.setRequestPromotedOngoing(true)

        val notification = builder.build()
        // 常驻通知：不可手动滑动清除，仅由 stop/暂停逻辑取消
        notification.flags =
            notification.flags or Notification.FLAG_ONGOING_EVENT or Notification.FLAG_NO_CLEAR

        try {
            notificationManager.notify(NOTIFICATION_ID, notification)
        } catch (e: Exception) {
            android.util.Log.w(TAG, "发送实时通知失败", e)
        }
    }

    /** 通知点击回到主界面（Flutter 入口）。 */
    private fun getContentPendingIntent(): android.app.PendingIntent {
        val intent = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?: android.content.Intent(context, com.feiniu.music.MainActivity::class.java)
        return android.app.PendingIntent.getActivity(
            context,
            0,
            intent,
            android.app.PendingIntent.FLAG_UPDATE_CURRENT or
                android.app.PendingIntent.FLAG_IMMUTABLE
        )
    }

    /**
     * 从本地文件加载封面为圆角正方形系统 Icon（失败返回 null）。
     *
     * 裁剪居中正方形 + 圆角（cornerRadius = 边长/4，对齐 HyperLyric
     * AlbumImageHelper.processAlbumBitmap），供实时通知 small/large icon、
     * 焦点通知 miui.focus.pics 使用。
     */
    @Synchronized
    private fun loadCoverIcon(coverPath: String?): android.graphics.drawable.Icon? {
        if (coverPath.isNullOrBlank()) {
            cachedCoverPath = null
            cachedCoverIcon = null
            return null
        }
        if (coverPath == cachedCoverPath) return cachedCoverIcon
        return try {
            val file = java.io.File(coverPath)
            if (!file.exists()) return null
            val source = android.graphics.BitmapFactory.decodeFile(coverPath)
                ?: return null
            val rounded = roundRectBitmap(source)
            if (rounded == null) return null
            android.graphics.drawable.Icon.createWithBitmap(rounded).also {
                cachedCoverPath = coverPath
                cachedCoverIcon = it
            }
        } catch (e: Exception) {
            android.util.Log.w(TAG, "加载封面失败 coverPath=$coverPath", e)
            null
        }
    }

    /** 裁剪居中正方形并加圆角（PorterDuff SRC_IN mask，对齐 HyperLyric 实现）。 */
    private fun roundRectBitmap(source: android.graphics.Bitmap): android.graphics.Bitmap? {
        try {
            val targetSize = 128
            val w = source.width
            val h = source.height
            if (w <= 0 || h <= 0) return null
            val cropSize = minOf(w, h)
            val xOffset = (w - cropSize) / 2
            val yOffset = (h - cropSize) / 2

            val output = android.graphics.Bitmap.createBitmap(
                targetSize,
                targetSize,
                android.graphics.Bitmap.Config.ARGB_8888
            )
            val canvas = android.graphics.Canvas(output)
            val cornerRadius = targetSize / 4f
            val rectF = android.graphics.RectF(0f, 0f, targetSize.toFloat(), targetSize.toFloat())

            val maskPaint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG)
            canvas.drawRoundRect(rectF, cornerRadius, cornerRadius, maskPaint)

            val bitmapPaint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
                isFilterBitmap = true
                xfermode = android.graphics.PorterDuffXfermode(
                    android.graphics.PorterDuff.Mode.SRC_IN
                )
            }
            val srcRect = android.graphics.Rect(
                xOffset,
                yOffset,
                xOffset + cropSize,
                yOffset + cropSize
            )
            val dstRect = android.graphics.Rect(0, 0, targetSize, targetSize)
            canvas.drawBitmap(source, srcRect, dstRect, bitmapPaint)

            source.recycle()
            return output
        } catch (e: Exception) {
            android.util.Log.w(TAG, "封面圆角处理失败", e)
            return null
        }
    }
}
