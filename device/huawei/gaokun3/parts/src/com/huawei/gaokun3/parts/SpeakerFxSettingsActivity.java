/*
 * 扬声器增强（试验功能，PR #7）的开关和处理方式。
 *
 * 只做两件事：把 persist.sys.gaokun3.histen 设成 "1" 或 "0"（开关），把
 * persist.sys.gaokun3.speakerfx.engine 设成 "bass" 或 "histen"（处理方式）。
 * init（etc/histen.rc）把它们镜像成 vendor.gaokun3.histen.on 和
 * vendor.gaokun3.speakerfx.engine。bass 由音频 HAL 里的 speakerfx
 * （device/huawei/gaokun3/speakerfx/）处理，histen 由会话音效
 * （device/huawei/gaokun3/effects/）处理，两边按同一个镜像各自判断谁动手、
 * 什么时候生效、只处理内置扬声器 —— 那些判断都在它们里面，这里不重复。
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

import androidx.preference.ListPreference;
import androidx.preference.Preference;
import androidx.preference.SwitchPreferenceCompat;

import com.android.settingslib.collapsingtoolbar.CollapsingToolbarBaseActivity;
import com.android.settingslib.widget.SettingsBasePreferenceFragment;

public class SpeakerFxSettingsActivity extends CollapsingToolbarBaseActivity {

    /** effect 与 speakerfx 读的总开关。只有 "1" 算开；没设过 = 关。 */
    private static final String PROP = "persist.sys.gaokun3.histen";
    /** 处理方式。只有 "histen" 是 Histen；没设过 = 低音增强。 */
    private static final String ENGINE_PROP = "persist.sys.gaokun3.speakerfx.engine";
    private static final String ENGINE_HISTEN = "histen";
    private static final String ENGINE_BASS = "bass";

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
        private ListPreference mEngine;

        @Override
        public void onCreatePreferences(Bundle savedInstanceState, String rootKey) {
            setPreferencesFromResource(R.xml.speaker_fx_prefs, rootKey);
            mSwitch = findPreference("speaker_fx_enabled");
            // 与 effect 的判据一致：只有 "1" 是开。试验功能永远默认关。
            mSwitch.setChecked("1".equals(SystemProperties.get(PROP, "0")));
            mSwitch.setOnPreferenceChangeListener(this);
            // 与 effect / speakerfx 的判据一致：只有 "histen" 是 Histen，其余都是低音增强。
            mEngine = findPreference("speaker_fx_engine");
            mEngine.setValue(ENGINE_HISTEN.equals(SystemProperties.get(ENGINE_PROP, ""))
                    ? ENGINE_HISTEN : ENGINE_BASS);
            mEngine.setSummaryProvider(ListPreference.SimpleSummaryProvider.getInstance());
            mEngine.setOnPreferenceChangeListener(this);
        }

        @Override
        public boolean onPreferenceChange(Preference preference, Object newValue) {
            if (preference == mEngine) {
                SystemProperties.set(ENGINE_PROP, String.valueOf(newValue));
            } else {
                SystemProperties.set(PROP, Boolean.TRUE.equals(newValue) ? "1" : "0");
            }
            return true;
        }
    }
}
