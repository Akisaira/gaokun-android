// SPDX-License-Identifier: GPL-2.0
/*
 * gaokun3 指纹 TA【命令收发】bring-up 工具（out-of-tree，诊断用，不进发版内核）。
 *
 * 在 #125（LOAD 成功）之上,把 TA 常驻,并提供一个 debugfs 口子发【任意原始请求字节】、
 * 打印响应 —— 命令帧格式不写死在内核里,由我在用户态按逆向结论拼好 hex 再喂进来,便于迭代。
 *
 * 安全性:
 *  - LOAD 本身已验证安全(#125)。
 *  - 发命令:只发【只读】命令(版本/信息/探测)时不碰 SPI、不碰安全存储,不会触发 listener。
 *  - 万一某命令触发了安全存储 listener 而这里【没注册】,qcom_scm 核心会对无人认领的请求
 *    自动应答 FAILURE、并在 256 轮后 -ELOOP 放弃(见 patch 0050 的 service_listeners),
 *    所以【不会硬挂】,最坏是该命令失败。即便如此,发未知命令仍建议有人在设备旁。
 *
 * 用法:
 *   insmod qcom_qseecom_fpcmd.ko           # 只建 debugfs,不动作
 *   echo 1 > /sys/kernel/debug/gaokun3_fpcmd/load     # 读 mbn、LOAD、常驻(打印 app_id)
 *   echo "20800000 ..." > .../send_hex     # 发原始请求字节(空格/换行随意),打印响应到 dmesg
 *   echo 1 > .../unload                     # app_shutdown、释放
 */
#include <linux/module.h>
#include <linux/debugfs.h>
#include <linux/firmware/qcom/qcom_scm.h>
#include <linux/firmware/qcom/qcom_tzmem.h>
#include <linux/dma-mapping.h>
#include <linux/kernel_read_file.h>
#include <linux/vmalloc.h>
#include <linux/slab.h>
#include <linux/mutex.h>

#define FP_IMG_ALIGN	(4 * 1024 * 1024)
#define FP_IMG_PATH	"/data/local/tmp/fingerpr.mbn"
#define FP_IMG_MAX	(16 * 1024 * 1024)
#define FP_IO_SZ	4096			/* req/rsp 各一份 */

static DEFINE_MUTEX(fp_lock);
static struct dentry *fp_dir;
static struct qcom_tzmem_pool *fp_io_pool;
static void *fp_req, *fp_rsp;
static u32 fp_app_id;
static bool fp_loaded;

static void fp_hexdump(const char *tag, const void *p, size_t n)
{
	print_hex_dump(KERN_INFO, tag, DUMP_PREFIX_OFFSET, 16, 1, p, n, false);
}

static int fp_load(void)
{
	struct qcom_tzmem_pool_config cfg = { .policy = QCOM_TZMEM_POLICY_STATIC };
	struct qcom_tzmem_pool *img_pool;
	void *stage, *filebuf = NULL;
	phys_addr_t phys;
	size_t img_len = 0, stage_len;
	int ret;

	if (fp_loaded)
		return -EBUSY;

	ret = kernel_read_file_from_path(FP_IMG_PATH, 0, &filebuf, FP_IMG_MAX,
					 &img_len, READING_FIRMWARE);
	if (ret < 0) {
		pr_err("fpcmd: 读不到 %s: %d\n", FP_IMG_PATH, ret);
		return ret;
	}

	/* 镜像 <4MiB ⇒ 分配正好 4MiB(order-10,天然对齐),见 #125 */
	stage_len = ALIGN(img_len, FP_IMG_ALIGN);
	cfg.initial_size = cfg.max_size = stage_len;
	img_pool = qcom_tzmem_pool_new(&cfg);
	if (IS_ERR(img_pool)) { ret = PTR_ERR(img_pool); goto out_file; }
	stage = qcom_tzmem_alloc(img_pool, stage_len, GFP_KERNEL);
	if (!stage) { ret = -ENOMEM; goto out_imgpool; }
	phys = qcom_tzmem_to_phys(stage);
	if (upper_32_bits(phys) || !IS_ALIGNED(phys, FP_IMG_ALIGN)) {
		pr_err("fpcmd: 镜像缓冲 %pa 不满足 <4GB+4MiB 对齐,放弃\n", &phys);
		ret = -EINVAL; goto out_stage;
	}
	memcpy(stage, filebuf, img_len);

	ret = qcom_scm_qseecom_app_load(stage, 0, img_len, &fp_app_id);
	if (ret) { pr_err("fpcmd: LOAD 失败 %d\n", ret); goto out_stage; }
	pr_info("fpcmd: LOAD ok, app_id=%u\n", fp_app_id);

	/* req/rsp 的 TZ 缓冲(常驻) */
	cfg.initial_size = cfg.max_size = 2 * FP_IO_SZ;
	fp_io_pool = qcom_tzmem_pool_new(&cfg);
	if (IS_ERR(fp_io_pool)) { ret = PTR_ERR(fp_io_pool); goto out_shutdown; }
	fp_req = qcom_tzmem_alloc(fp_io_pool, FP_IO_SZ, GFP_KERNEL);
	fp_rsp = qcom_tzmem_alloc(fp_io_pool, FP_IO_SZ, GFP_KERNEL);
	if (!fp_req || !fp_rsp) { ret = -ENOMEM; goto out_iopool; }

	fp_loaded = true;
	ret = 0;
	goto out_stage;			/* img staging 加载后即可释放 */

out_iopool:
	qcom_tzmem_pool_free(fp_io_pool); fp_io_pool = NULL;
out_shutdown:
	qcom_scm_qseecom_app_shutdown(fp_app_id);
out_stage:
	qcom_tzmem_free(stage);
out_imgpool:
	qcom_tzmem_pool_free(img_pool);
out_file:
	vfree(filebuf);
	return ret;
}

static void fp_unload(void)
{
	if (!fp_loaded)
		return;
	qcom_tzmem_free(fp_req);
	qcom_tzmem_free(fp_rsp);
	qcom_tzmem_pool_free(fp_io_pool);
	fp_io_pool = NULL;
	qcom_scm_qseecom_app_shutdown(fp_app_id);
	pr_info("fpcmd: app_shutdown(%u)\n", fp_app_id);
	fp_loaded = false;
}

/* 解析 "20 80 00 00 ff.." 之类 hex(忽略空白),写进 fp_req,返回字节数 */
static int fp_parse_hex(const char *s, size_t slen, u8 *out, size_t outmax)
{
	size_t n = 0; int hi = -1;
	for (size_t i = 0; i < slen; i++) {
		int v;
		char c = s[i];
		if (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == ',')
			continue;
		if (c >= '0' && c <= '9') v = c - '0';
		else if (c >= 'a' && c <= 'f') v = c - 'a' + 10;
		else if (c >= 'A' && c <= 'F') v = c - 'A' + 10;
		else return -EINVAL;
		if (hi < 0) { hi = v; }
		else {
			if (n >= outmax) return -E2BIG;
			out[n++] = (hi << 4) | v; hi = -1;
		}
	}
	if (hi >= 0) return -EINVAL;		/* 半个字节 */
	return n;
}

static ssize_t fp_send_write(struct file *f, const char __user *ubuf,
			     size_t len, loff_t *off)
{
	char *kbuf;
	int req_len, ret;

	if (len == 0 || len > 8192)
		return -EINVAL;
	kbuf = kmalloc(len, GFP_KERNEL);
	if (!kbuf) return -ENOMEM;
	if (copy_from_user(kbuf, ubuf, len)) { kfree(kbuf); return -EFAULT; }

	guard(mutex)(&fp_lock);
	if (!fp_loaded) { kfree(kbuf); return -ENODEV; }

	req_len = fp_parse_hex(kbuf, len, fp_req, FP_IO_SZ);
	kfree(kbuf);
	if (req_len <= 0) return req_len ? req_len : -EINVAL;

	memset(fp_rsp, 0, FP_IO_SZ);
	pr_info("fpcmd: SEND app_id=%u req_len=%d\n", fp_app_id, req_len);
	fp_hexdump("fpcmd req: ", fp_req, min(req_len, 64));

	ret = qcom_scm_qseecom_app_send(fp_app_id, fp_req, req_len,
					fp_rsp, FP_IO_SZ);
	if (ret) {
		pr_err("fpcmd: app_send 失败 %d\n", ret);
		return ret;
	}
	pr_info("fpcmd: SEND ok, 响应前 64 字节:\n");
	fp_hexdump("fpcmd rsp: ", fp_rsp, 64);
	return len;
}

static ssize_t fp_load_write(struct file *f, const char __user *u, size_t len, loff_t *o)
{ guard(mutex)(&fp_lock); return fp_load() ?: len; }
static ssize_t fp_unload_write(struct file *f, const char __user *u, size_t len, loff_t *o)
{ guard(mutex)(&fp_lock); fp_unload(); return len; }

static const struct file_operations fp_load_fops   = { .owner=THIS_MODULE, .write=fp_load_write };
static const struct file_operations fp_unload_fops = { .owner=THIS_MODULE, .write=fp_unload_write };
static const struct file_operations fp_send_fops   = { .owner=THIS_MODULE, .write=fp_send_write };

static int __init fpcmd_init(void)
{
	fp_dir = debugfs_create_dir("gaokun3_fpcmd", NULL);
	if (IS_ERR(fp_dir)) return PTR_ERR(fp_dir);
	debugfs_create_file("load",     0200, fp_dir, NULL, &fp_load_fops);
	debugfs_create_file("unload",   0200, fp_dir, NULL, &fp_unload_fops);
	debugfs_create_file("send_hex", 0200, fp_dir, NULL, &fp_send_fops);
	pr_info("fpcmd: 就绪。echo 1 > .../load 然后 echo <hex> > .../send_hex\n");
	return 0;
}

static void __exit fpcmd_exit(void)
{
	mutex_lock(&fp_lock);
	fp_unload();
	mutex_unlock(&fp_lock);
	debugfs_remove_recursive(fp_dir);
}

module_init(fpcmd_init);
module_exit(fpcmd_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("gaokun3 fingerprint TA command sender (bring-up)");
