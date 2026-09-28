/*
 * 扬声器增强（试验功能，PR #7）的开关。
 *
 * 只做一件事：把 persist.sys.gaokun3.histen 设成 "1" 或 "0"。
 * init（etc/histen.rc）把它镜像成 vendor.gaokun3.histen.on，音频 HAL 里的
 * effect（device/huawei/gaokun3/effects/）读那个镜像：关掉约一秒内生效，
 * 打开从下一次开始播放起生效，而且只在输出是内置扬声器时处理 ——
 * 那些判断都在 effect 里，这里不重复。
 *
 * ★ 为什么要绕 init 一跳：本应用是 system_app（coredomain），不许写任何 vendor
 *   属性（sepolicy/vendor_gaokun3_props.te 顶上有编译器实测）；而 vendor 的 HAL
 *   又读不了 system_prop（它是 core_property_type，sepolicy/hal_audio_default.te
 *   里记着 2026-09-26 的编译失败）。两头都堵死，只有 init 两边都能碰。
 *
 * 写法照抄 KeyboardSettingsActivity（同一套 SettingsLib 页面与开关）。
 */
package com.huawei.gaokun3.parts;

import android.os.Bundle;
import android.os.SystemProperties;

import androidx.preference.Preference;
import androidx.preference.SwitchPreferenceCompat;

import com.android.settingslib.collapsingtoolbar.CollapsingToolbarBaseActivity;
import com.android.settingslib.widget.SettingsBasePreferenceFragment;

public class SpeakerFxSettingsActivity extends CollapsingToolbarBaseActivity {

    /** effect 读的总开关。只有 "1" 算开；没设过 = 关。 */
    private static final String PROP = "persist.sys.gaokun3.histen";

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        // 内容放进 CollapsingToolbarBaseActivity 的 content_frame（edge-to-edge 由它处理）。
        if (savedInstanceState == null) {
            getSupportFragmentManager().beginTransaction()
                    .replace(com.android.settingslib.collapsingtoolbar.R.id.content_frame,
                            new SpeakerFxFragment())
                    .commit();
        }
    }

    public static class SpeakerFxFragment extends SettingsBasePreferenceFragment
            implements Preference.OnPreferenceChangeListener {

        private SwitchPreferenceCompat mSwitch;

        @Override
        public void onCreatePreferences(Bundle savedInstanceState, String rootKey) {
            setPreferencesFromResource(R.xml.speaker_fx_prefs, rootKey);
            mSwitch = findPreference("speaker_fx_enabled");
            // 与 effect 的判据一致：只有 "1" 是开。试验功能永远默认关。
            mSwitch.setChecked("1".equals(SystemProperties.get(PROP, "0")));
            mSwitch.setOnPreferenceChangeListener(this);
        }

        @Override
        public boolean onPreferenceChange(Preference preference, Object newValue) {
            SystemProperties.set(PROP, Boolean.TRUE.equals(newValue) ? "1" : "0");
            return true;
        }
    }
}
