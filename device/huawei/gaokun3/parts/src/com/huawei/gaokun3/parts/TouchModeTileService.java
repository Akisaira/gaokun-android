/*
 * 控制中心（快捷设置）里的游戏触摸开关：进游戏前下拉一把就能切，不用翻设置。
 *
 * 和设置页共用同一条通路（TouchModeSettingsActivity 的 isGameMode / setGameMode，
 * 只改 persist.sys.gaokun3.touch_mode），两个入口不会打架。
 *
 * ⚠️ 磁贴默认不出现在控制中心，要用户在编辑页手动加一次（同 KeyboardTileService）。
 */
package com.huawei.gaokun3.parts;

import android.graphics.drawable.Icon;
import android.service.quicksettings.Tile;
import android.service.quicksettings.TileService;

public class TouchModeTileService extends TileService {

    private void refresh() {
        Tile tile = getQsTile();
        if (tile == null) {
            return;
        }
        boolean game = TouchModeSettingsActivity.isGameMode();
        tile.setState(game ? Tile.STATE_ACTIVE : Tile.STATE_INACTIVE);
        tile.setLabel(getString(R.string.touch_mode_tile_label));
        tile.setSubtitle(getString(game ? R.string.touch_mode_game : R.string.touch_mode_daily));
        tile.setIcon(Icon.createWithResource(this, R.drawable.ic_touch_game));
        tile.updateTile();
    }

    @Override
    public void onStartListening() {
        super.onStartListening();
        refresh();
    }

    @Override
    public void onClick() {
        super.onClick();
        TouchModeSettingsActivity.setGameMode(!TouchModeSettingsActivity.isGameMode());
        refresh();
    }
}
