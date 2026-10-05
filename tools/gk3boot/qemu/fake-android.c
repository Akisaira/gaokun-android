/*
 * QEMU 夹具专用：冒充 ESP 上直连条目（<mid>-android-<槽>.conf）里的 "Image"。
 *
 * 真机上那是 EFI zboot 内核；夹具里换成这个小 PE：它打印一行可被测试脚本认出的标记
 * （带上 systemd-boot 传来的 LoadOptions 与 LoaderEntrySelected），然后 ResetSystem(Shutdown)
 * 让 QEMU 退出。测试用它确认"探针复位之后，下一次启动回到了 default 的 Android 条目"。
 */
#include "gk3efi.h"

/* S15：Makefile 用 -DGK3_FAKE_WHO='"WINDOWS"' 再编一份，冒充 bootmgfw.efi（GK3-FAKE-WINDOWS booted …） */
#ifndef GK3_FAKE_WHO
#define GK3_FAKE_WHO "ANDROID"
#endif

EFI_STATUS efi_main(EFI_HANDLE image, EFI_SYSTEM_TABLE *st)
{
    static char opts[1200], sel[128];
    static uint8_t buf[256];
    EFI_LOADED_IMAGE_PROTOCOL *li = NULL;
    UINTN sz = sizeof(buf);

    gk3efi_init(image, st);
    gk3_log_init(16384);
    opts[0] = sel[0] = 0;
    if (!EFI_ERROR(gk3_bs->HandleProtocol(image, (EFI_GUID *)&gk3_guid_loaded_image, (void **)&li)) && li &&
        li->LoadOptions)
        gk3_ucs2_to_ascii(li->LoadOptions, li->LoadOptionsSize / 2, opts, sizeof(opts));
    if (!EFI_ERROR(gk3_getvar(u"LoaderEntrySelected", &gk3_guid_loader, NULL, buf, &sz)))
        gk3_ucs2_to_ascii((const CHAR16 *)buf, sz / 2, sel, sizeof(sel));
    gk3_logf("\nGK3-FAKE-" GK3_FAKE_WHO " booted entry=\"%s\" load_options=\"%s\"\n", sel, opts);
    gk3_logf("GK3-FAKE-" GK3_FAKE_WHO " ResetSystem(EfiResetShutdown)\n");
    gk3_rt->ResetSystem(EfiResetShutdown, EFI_SUCCESS, 0, NULL);
    for (;;)
        gk3_bs->Stall(1000000);
    return EFI_SUCCESS;
}
