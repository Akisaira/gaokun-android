/*
 * 磁吸键盘开关。
 *
 * 只做一件事：把 persist.sys.gaokun3.keyboard 设成 "1" 或 "0"。
 * 真正动硬件的是 init 触发器 + /vendor/bin/gaokun3-keyboard.sh，
 * 它写内核的 /sys/class/input/inputN/inhibited。
 *
 * ★ 用属性而不是让应用直接写 sysfs：应用（哪怕 system uid）不该有写
 *   /sys/class/input 的权限，而 init 触发器是 Android 里做这件事的标准通路，
 *   将来转 SELinux enforcing 也不用为这个 app 开特权。
 *
 * ★ 界面用 androidx.preference + SettingsLib（2026-09-28 用户要求换成系统设置同款的
 *   Material 3 Expressive 开关）。此前用的是平台自带、已废弃的 android.preference ——
 *   少一个静态库依赖，但开关是旧样式，页面也和系统设置对不上。依赖见 Android.bp。
 */
package com.huawei.gaokun3.parts;

import android.os.Bundle;
import android.os.SystemProperties;

import androidx.preference.Preference;
import androidx.preference.SwitchPreferenceCompat;

import com.android.settingslib.collapsingtoolbar.CollapsingToolbarBaseActivity;
import com.android.settingslib.widget.SettingsBasePreferenceFragment;

public class KeyboardSettingsActivity extends CollapsingToolbarBaseActivity {

    /** init 触发器监听的属性。persist.sys.* 的上下文是 system_prop，系统应用可写。 */
    private static final String PROP = "persist.sys.gaokun3.keyboard";

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        // 不再需要自己带 fitsSystemWindows 的 layout：CollapsingToolbarBaseActivity 自己处理 edge-to-edge，
        // 内容放进它的 content_frame。
        if (savedInstanceState == null) {
            getSupportFragmentManager().beginTransaction()
                    .replace(com.android.settingslib.collapsingtoolbar.R.id.content_frame,
                            new KeyboardFragment())
                    .commit();
        }
    }

    public static class KeyboardFragment extends SettingsBasePreferenceFragment
            implements Preference.OnPreferenceChangeListener {

        private SwitchPreferenceCompat mSwitch;

        @Override
        public void onCreatePreferences(Bundle savedInstanceState, String rootKey) {
            setPreferencesFromResource(R.xml.keyboard_prefs, rootKey);
            mSwitch = findPreference("keyboard_enabled");
            // 属性没设过 = 键盘开着。默认永远偏向"能用"——写坏了也不至于把
            // 用户唯一的输入设备锁死。
            mSwitch.setChecked(!"0".equals(SystemProperties.get(PROP, "1")));
            mSwitch.setOnPreferenceChangeListener(this);
        }

        @Override
        public boolean onPreferenceChange(Preference preference, Object newValue) {
            SystemProperties.set(PROP, Boolean.TRUE.equals(newValue) ? "1" : "0");
            return true;
        }
    }
}
