/*
 * USB-C 口（port0，靠近电源键的那个）的两条提示（v1.0 PWR-4 / USB-1，2026-10-05）。
 *
 * 只看两个属性，都由 /vendor/bin/gaokun3-usbrole.sh 设（vendor_gaokun3_prop，sepolicy 给了 system_app 读）：
 *   vendor.gaokun3.usbrole.broken   = 1：息屏切 host 失败（A6：待机后回插坏口，xhci 一律 -110）。
 *       之后每次息屏都失败、一直持有 wakelock ⇒ 这次开机余下的时间整机不再待机，USB 数据也没了，只有重启能恢复。
 *       下一次切 host 成功时清 0（实际上口坏了就不会再成功）。
 *   vendor.gaokun3.usbrole.reversed = 1：我方在给对端供电、对端不支持 PD、约 6 秒没有数据连接
 *       （插 Mac 时偶发，拔插一次就好；内核换不了供电方向，ucsi_pr_swap 要 PD）。条件不成立 / 拔线即清 0。
 *
 * ★ 为什么是轮询而不是属性回调：SystemProperties.addChangeCallback 只在有人调 reportSyspropChanged()
 *   时才回调（frameworks/base core/java/android/os/SystemProperties.java:248-315，LineageOS lineage-23.2 的上游副本），
 *   init / vendor 脚本 setprop 不会触发它。所以：
 *   · 亮屏期间每 3 秒读一次两个属性（读属性是本进程内的共享内存读，不走 binder、不 fork）；
 *   · 息屏时不轮询（broken 正是在息屏那一刻产生的，亮屏广播一来立刻读一次 —— 用户看到屏幕时通知就在）；
 *   · 开机由 BootReceiver 拉起本服务（START_STICKY，被杀了系统会再拉起）。
 * ★ 本应用是 android.uid.system：后台起服务不受限制（与 system_server 同一个 uid，UidRecord 不会 idle，
 *   ActivityManagerService.getAppStartModeLOSP，ActivityManagerService.java:6480-6538）；发通知的权限检查走
 *   checkComponentPermission，system uid 一律放行（⬜ ActivityManager.checkComponentPermission 那一行待构建机核对）。
 *
 * 判据（⬜ 未编译、未上机）：
 *   · 开机解锁后 `dumpsys activity services com.huawei.gaokun3.parts` 能看到 UsbPortNotifier；
 *   · V11 人为造出坏口（broken=1）后亮屏，通知栏出现"USB-C 口出了故障"；
 *   · USB-1 复现（插 Mac 落成我方供电）约 6–9 秒后弹"连接方向反了"，重插后自动消失。
 */
package com.huawei.gaokun3.parts;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.PowerManager;
import android.os.SystemProperties;
import android.util.Log;

public class UsbPortNotifier extends Service {

    private static final String TAG = "Gaokun3UsbPort";

    static final String PROP_BROKEN = "vendor.gaokun3.usbrole.broken";
    static final String PROP_REVERSED = "vendor.gaokun3.usbrole.reversed";

    private static final String CHANNEL = "usb_port";
    private static final int ID_BROKEN = 1;
    private static final int ID_REVERSED = 2;

    /** 亮屏时的轮询间隔。USB-1 那条本身要约 6 秒才置位，3 秒的延迟用户感觉不到。 */
    private static final long POLL_MS = 3000;

    private final Handler mHandler = new Handler(Looper.getMainLooper());
    private NotificationManager mNm;
    private boolean mScreenOn;
    private boolean mShownBroken;
    private boolean mShownReversed;

    private final Runnable mPoll = new Runnable() {
        @Override
        public void run() {
            refresh();
            mHandler.removeCallbacks(this);
            if (mScreenOn) {
                mHandler.postDelayed(this, POLL_MS);
            }
        }
    };

    private final BroadcastReceiver mScreenReceiver = new BroadcastReceiver() {
        @Override
        public void onReceive(Context context, Intent intent) {
            mScreenOn = !Intent.ACTION_SCREEN_OFF.equals(intent.getAction());
            mHandler.removeCallbacks(mPoll);
            if (mScreenOn) {
                mHandler.post(mPoll);   // 亮屏 / 解锁：立刻读一次，再接着轮询
            }
        }
    };

    @Override
    public void onCreate() {
        super.onCreate();
        mNm = getSystemService(NotificationManager.class);
        NotificationChannel ch = new NotificationChannel(CHANNEL,
                getString(R.string.usb_port_channel), NotificationManager.IMPORTANCE_HIGH);
        ch.setDescription(getString(R.string.usb_port_channel_desc));
        mNm.createNotificationChannel(ch);

        IntentFilter f = new IntentFilter();
        f.addAction(Intent.ACTION_SCREEN_ON);
        f.addAction(Intent.ACTION_SCREEN_OFF);
        f.addAction(Intent.ACTION_USER_PRESENT);
        // 这三个都是系统发的受保护广播；NOT_EXPORTED 照样收得到系统 uid 发来的广播。
        registerReceiver(mScreenReceiver, f, Context.RECEIVER_NOT_EXPORTED);

        mScreenOn = getSystemService(PowerManager.class).isInteractive();
        mHandler.post(mPoll);
        Log.i(TAG, "started, screenOn=" + mScreenOn);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        mHandler.removeCallbacks(mPoll);
        unregisterReceiver(mScreenReceiver);
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    private void refresh() {
        boolean broken = "1".equals(SystemProperties.get(PROP_BROKEN, ""));
        boolean reversed = "1".equals(SystemProperties.get(PROP_REVERSED, ""));

        if (broken != mShownBroken) {
            if (broken) {
                // 常驻（划不掉）：口坏了、待机也没了，直到重启 —— 这件事不能让用户一划就忘。
                post(ID_BROKEN, R.string.usb_port_broken_title, R.string.usb_port_broken_text, true);
            } else {
                mNm.cancel(ID_BROKEN);
            }
            mShownBroken = broken;
            Log.i(TAG, PROP_BROKEN + "=" + (broken ? 1 : 0));
        }
        if (reversed != mShownReversed) {
            if (reversed) {
                post(ID_REVERSED, R.string.usb_port_reversed_title, R.string.usb_port_reversed_text,
                        false);
            } else {
                mNm.cancel(ID_REVERSED);   // 重插 / 拔线后 usbrole 清 0，通知跟着消失
            }
            mShownReversed = reversed;
            Log.i(TAG, PROP_REVERSED + "=" + (reversed ? 1 : 0));
        }
    }

    private void post(int id, int title, int text, boolean ongoing) {
        Notification n = new Notification.Builder(this, CHANNEL)
                .setSmallIcon(R.drawable.ic_usb)
                .setContentTitle(getString(title))
                .setContentText(getString(text))
                .setStyle(new Notification.BigTextStyle().bigText(getString(text)))
                .setCategory(Notification.CATEGORY_STATUS)
                .setOngoing(ongoing)
                .setOnlyAlertOnce(true)
                .setShowWhen(true)
                .build();
        mNm.notify(id, n);
    }
}
