/*
 * 待机（s2idle）开关（v1.0 PWR-16，并入 SEC-4）：替代文档里的
 * `adb shell su -c "setprop persist.vendor.gaokun3.allow_suspend 0"`。
 *
 * 只做一件事：把 persist.sys.gaokun3.allow_suspend 设成 "1" 或 "0"。
 * init（init.gaokun3.rc 里那两条字面值触发器）把它镜像成 vendor 侧真正起作用的
 * persist.vendor.gaokun3.allow_suspend —— usbrole.rc / init.gaokun3.rc / gaokun3-usbrole.sh
 * 读的都是后者，这里不碰它们的逻辑。
 *
 * ★ 为什么要绕 init 一跳（与扬声器增强 / etc/histen.rc 同一个理由）：
 *   本应用是 system_app（coredomain），设任何 vendor 属性都被
 *   refs/lineage-sepolicy/private/property.te:492-502 的 neverallow 禁掉
 *   （sepolicy/vendor_gaokun3_props.te 顶上记着那次编译失败）；
 *   而 persist.sys.* 是 system_prop（private/property_contexts:77），
 *   system_app 本来就能写（private/system_app.te:43）。init 两边都能碰。
 *
 * ★ 开关显示的是【生效值】persist.vendor.gaokun3.allow_suspend（system_app 能读：
 *   vendor_gaokun3_prop 是 vendor_public_prop，get_prop 在 vendor_gaokun3_props.te 里），
 *   不是自己写的那个 system 属性 —— 这样开发机上以前用 setprop 设过的 0 也能如实显示。
 *
 * 生效时机：关（1 → 0）立刻生效 —— 亮屏期间 gaokun3_usbrole 这把锁本来就握着，
 * 之后息屏不再去放它；开（0 → 1）从下一次息屏起生效。都不用重启。
 *
 * 写法照抄 SpeakerFxSettingsActivity（同一套 SettingsLib 页面与开关）。
 */
package com.huawei.gaokun3.parts;

import android.os.Bundle;
import android.os.SystemProperties;

import androidx.preference.Preference;
import androidx.preference.SwitchPreferenceCompat;

import com.android.settingslib.collapsingtoolbar.CollapsingToolbarBaseActivity;
import com.android.settingslib.widget.SettingsBasePreferenceFragment;

public class StandbySettingsActivity extends CollapsingToolbarBaseActivity {

    /** Parts 写的 system 属性；init 把它镜像成下面那个。 */
    private static final String PROP_UI = "persist.sys.gaokun3.allow_suspend";
    /** vendor 侧真正起作用的那个（镜像默认 1，device.mk 的 PRODUCT_VENDOR_PROPERTIES）。 */
    private static final String PROP_EFFECTIVE = "persist.vendor.gaokun3.allow_suspend";

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        if (savedInstanceState == null) {
            getSupportFragmentManager().beginTransaction()
                    .replace(com.android.settingslib.collapsingtoolbar.R.id.content_frame,
                            new StandbyFragment())
                    .commit();
        }
    }

    /** 生效值；读不到（理论上不会：镜像里有默认值 1）就退回本应用写过的值，再退回镜像默认 1。 */
    static boolean isStandbyAllowed() {
        String v = SystemProperties.get(PROP_EFFECTIVE, "");
        if (v.isEmpty()) {
            v = SystemProperties.get(PROP_UI, "1");
        }
        // 与 usbrole.rc / init.gaokun3.rc 的判据一致：只有 "1" 算允许待机。
        return "1".equals(v);
    }

    public static class StandbyFragment extends SettingsBasePreferenceFragment
            implements Preference.OnPreferenceChangeListener {

        private SwitchPreferenceCompat mSwitch;

        @Override
        public void onCreatePreferences(Bundle savedInstanceState, String rootKey) {
            setPreferencesFromResource(R.xml.standby_prefs, rootKey);
            mSwitch = findPreference("standby_enabled");
            mSwitch.setChecked(isStandbyAllowed());
            mSwitch.setOnPreferenceChangeListener(this);
        }

        @Override
        public boolean onPreferenceChange(Preference preference, Object newValue) {
            SystemProperties.set(PROP_UI, Boolean.TRUE.equals(newValue) ? "1" : "0");
            return true;
        }
    }
}
