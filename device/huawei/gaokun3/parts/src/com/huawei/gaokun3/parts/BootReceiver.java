/*
 * 开机完成后拉起 UsbPortNotifier（v1.0 PWR-4 / USB-1）。
 *
 * BOOT_COMPLETED 在用户第一次解锁之后才发；在那之前不提示没关系 ——
 * broken 只会在待机之后出现，reversed 要用户插线时才有。
 * 本应用是 android.uid.system，后台 startService 不受限（见 UsbPortNotifier 顶部的注释）。
 */
package com.huawei.gaokun3.parts;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

public class BootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        if (!Intent.ACTION_BOOT_COMPLETED.equals(intent.getAction())) {
            return;
        }
        context.startService(new Intent(context, UsbPortNotifier.class));
    }
}
