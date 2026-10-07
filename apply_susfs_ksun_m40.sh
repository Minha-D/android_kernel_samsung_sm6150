#!/usr/bin/env bash
# apply_susfs_ksun_m40.sh
# Adds SUSFS v2.3.0 support to KernelSU-Next 3.4.0-legacy (flat layout: drivers/kernelsu/{core,feature,hook,
# selinux,supercall}/...) for the Samsung M40 (sm6150, 4.14) kernel.
#
# Based on 6.diff, adapted for this tree:
#   - paths flattened (drivers/kernelsu/kernel/* -> drivers/kernelsu/*)
#   - arch/arm64/configs/ksu.config and build/ckbuild.sh hunks dropped (not present here)
#   - hook/setuid_hook.c hunk #1 (includes, SID helpers, zygote_next early return) applied by script
#     instead of patch, because that hunk does not match this KSU-Next revision
#   - KSU_SUSFS_TRY_UMOUNT and KSU_SUSFS_SUS_MEMFD Kconfig options removed: the kernel-side susfs
#     (JackA1ltman/NonGKI_Kernel_Build_2nd, SUSFS v2.3.0) has no implementation for them yet
#
# Usage (from anywhere):   ./apply_susfs_ksun_m40.sh [KERNEL_ROOT] [--dry-run] [--keep-try-umount] [--keep-sus-memfd]
# Requires: GNU patch, python3. Works through the drivers/kernelsu symlink (git apply does not).
#
# Afterwards, commit in the REAL KSU-Next checkout (readlink -f drivers/kernelsu) and, to get a
# plain patch tied to your exact revision:   git -C "$(readlink -f drivers/kernelsu)" diff > susfs-ksun.patch
set -euo pipefail

ROOT=.; DRY=0
export KEEP_TRY_UMOUNT=0 KEEP_SUS_MEMFD=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --keep-try-umount) KEEP_TRY_UMOUNT=1 ;;
    --keep-sus-memfd) KEEP_SUS_MEMFD=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) ROOT="$a" ;;
  esac
done

die()  { echo "[-] $*" >&2; exit 1; }
info() { echo "[+] $*"; }
warn() { echo "[!] $*" >&2; }

cd "$ROOT"
D=drivers/kernelsu
[ -f "$D/Kbuild" ] && [ -f "$D/supercall/supercall.c" ] && [ -f "$D/hook/setuid_hook.c" ] \
  || die "run this from the kernel root; expected flat KSU-Next layout at $D (Kbuild, supercall/, hook/)"

# kernel-side susfs must already be in the kernel
[ -f fs/susfs.c ] && [ -f include/linux/susfs.h ] && [ -f include/linux/susfs_def.h ] \
  || die "kernel-side susfs missing (fs/susfs.c, include/linux/susfs.h, susfs_def.h) - apply the kernel patch first"
grep -q '#define SUSFS_VERSION "v2\.' include/linux/susfs.h \
  || warn "kernel-side SUSFS_VERSION is not v2.x - this patch targets v2.3.0"
grep -qE '^struct work_struct susfs_extra_works' fs/susfs.c \
  || warn "susfs_extra_works is not a non-static global in fs/susfs.c - setuid_hook.c extern will not link"

# already patched?
if grep -rq 'ksu_handle_susfs_cmd\|KSU_SUSFS' "$D/supercall" "$D/Kconfig" 2>/dev/null; then
  die "$D already contains susfs integration - reset it first:  git -C \"\$(readlink -f $D)\" checkout -- . && git -C \"\$(readlink -f $D)\" clean -f"
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/susfs.patch" <<'__SUSFS_PATCH__'
diff --git a/drivers/kernelsu/Kbuild b/drivers/kernelsu/Kbuild
index 1c6574a80be5..6c1a5b125be8 100644
--- a/drivers/kernelsu/Kbuild
+++ b/drivers/kernelsu/Kbuild
@@ -339,4 +339,14 @@ ccflags-y += -DEXPECTED_MANAGER_HASH=\"$(KSU_NEXT_MANAGER_HASH)\"
 ccflags-y += -Wno-strict-prototypes -Wno-int-conversion -Wno-gcc-compat -Wno-missing-prototypes
 ccflags-y += -Wno-declaration-after-statement -Wno-unused-function -Wno-unused-variable
 
+## For susfs stuff ##
+ifeq ($(CONFIG_KSU_SUSFS), y)
+ifeq ($(shell test -e $(srctree)/fs/susfs.c; echo $$?),0)
+$(eval SUSFS_VERSION=$(shell cat $(srctree)/include/linux/susfs.h | grep -E '^#define SUSFS_VERSION' | cut -d' ' -f3 | sed 's/"//g'))
+$(info -- SUSFS_VERSION: $(SUSFS_VERSION))
+else
+$(error -- CONFIG_KSU_SUSFS is enabled but susfs is not integrated in your kernel. Read: https://gitlab.com/simonpunk/susfs4ksu)
+endif
+endif
+
 # Keep a new line here!! Because someone may append config
diff --git a/drivers/kernelsu/Kconfig b/drivers/kernelsu/Kconfig
index a4ffed6f3216..d51540b31c00 100644
--- a/drivers/kernelsu/Kconfig
+++ b/drivers/kernelsu/Kconfig
@@ -71,4 +71,109 @@ config KSU_ALLOWLIST_WORKAROUND
 
 # endchoice
 
+menu "KernelSU - SUSFS"
+config KSU_SUSFS
+    bool "KernelSU addon - SUSFS"
+    depends on KSU
+    depends on THREAD_INFO_IN_TASK && 64BIT
+    default n
+    help
+        Patch and Enable SUSFS to kernel with KernelSU.
+
+config KSU_SUSFS_SUS_PATH
+    bool "Enable to hide suspicious path"
+    depends on KSU_SUSFS
+    default y
+    help
+        - Allow hiding the user-defined path and all its sub-paths from various system calls.
+        - Use "add_sus_path_loop" instead of "add_sus_path" if the user-defined path is frequently modified.
+        - Use with caution, as it may cause performance loss and be vulnerable to side-channel attacks.
+          just disable this feature if it doesn't work for you or you don't need it at all.
+        - Effective only on zygote spawned user app process with uid >= 10000.
+
+config KSU_SUSFS_SUS_MOUNT
+    bool "Enable to hide suspicious mounts"
+    depends on KSU_SUSFS
+    default y
+    help
+        - Automatically assign fake mnt_id and fake mnt_group_id for mounts mounted by ksu process until /sdcard is decrypted, this is to evade from mnt_id/mnt_group_id gap detections.
+        - Allow hiding all sus mounts from /proc/self/[mounts|mountinfo|mountstat] for non-su processes.
+
+config KSU_SUSFS_SUS_KSTAT
+    bool "Enable to spoof suspicious kstat"
+    depends on KSU_SUSFS
+    default y
+    help
+        - Allow spoofing the kstat of user-defined file/directory.
+        - Effective only on zygote spawned user app process with uid >= 10000.
+
+config KSU_SUSFS_TRY_UMOUNT
+    bool "Enable to use ksu's try_umount"
+    depends on KSU_SUSFS
+    default y
+    help
+        - Allow using try_umount to umount other user-defined mount paths prior to ksu's default umount paths.
+        - Effective only on zygote spawned umounted user app process.
+
+config KSU_SUSFS_SPOOF_UNAME
+    bool "Enable to spoof uname"
+    depends on KSU_SUSFS
+    default y
+    help
+        - Allow spoofing the string returned by uname syscall to user-defined string.
+        - Effective on all processes.
+
+config KSU_SUSFS_ENABLE_LOG
+    bool "Enable logging susfs log to kernel"
+    depends on KSU_SUSFS
+    default y
+    help
+        - Allow logging susfs log to kernel, uncheck it to completely disable all susfs log.
+
+config KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS
+    bool "Enable to automatically hide ksu and susfs symbols from /proc/kallsyms"
+    depends on KSU_SUSFS
+    default y
+    help
+        - Automatically hide ksu and susfs symbols from '/proc/kallsyms'.
+        - Effective on all processes.
+
+config KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
+    bool "Enable to spoof /proc/bootconfig (gki) or /proc/cmdline (non-gki)"
+    depends on KSU_SUSFS
+    default y
+    help
+        - Spoof the output of /proc/bootconfig (gki) or /proc/cmdline (non-gki) with a user-defined file.
+        - Effective on all processes.
+
+config KSU_SUSFS_OPEN_REDIRECT
+    bool "Enable to redirect a path to be opened with another path (experimental)"
+    depends on KSU_SUSFS
+    default y
+    help
+        - Allow redirecting a target path to be opened with another user-defined path.
+        - Please be reminded that process with open access to the target and redirected path can be detected.
+        - Effective only on processes with uid < 2000.
+
+config KSU_SUSFS_SUS_MAP
+    bool "Enable hiding some mmapped real files from different proc maps interfaces"
+    depends on KSU_SUSFS
+    default y
+    help
+        - Allow hiding mmapped real files from /proc/<pid>/[maps|smaps|smaps_rollup|map_files|mem|pagemap]
+        - It does NOT support hiding anon memory.
+        - It does NOT hide any inline hooks or PLT hooks caused by the injected library itself.
+        - It may not be able to evade detections by apps that implement a good injection detection.
+        - Effective only on zygote spawned umounted user app process >= 10000.
+
+config KSU_SUSFS_SUS_MEMFD
+    bool "Enable to block sus memfd"
+    depends on KSU_SUSFS
+    default y
+    help
+        - Allow blocking the creation of user-defined memfd.
+        - Effective on all processes.
+
+endmenu
+
 endmenu
diff --git a/drivers/kernelsu/core/init.c b/drivers/kernelsu/core/init.c
index 2359678b57e1..972d85960843 100644
--- a/drivers/kernelsu/core/init.c
+++ b/drivers/kernelsu/core/init.c
@@ -22,6 +22,9 @@
 #include "selinux/selinux.h"
 #include "feature/selinux_hide.h"
 #include "feature/adb_root.h"
+#ifdef CONFIG_KSU_SUSFS
+#include <linux/susfs.h>
+#endif // #ifdef CONFIG_KSU_SUSFS
 
 extern void __init ksu_lsm_hook_init(void);
 extern int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr,
@@ -169,6 +172,10 @@ int __init kernelsu_init(void)
 
 		ksu_throne_tracker_init();
 
+#ifdef CONFIG_KSU_SUSFS
+		susfs_init();
+#endif // #ifdef CONFIG_KSU_SUSFS
+
 		ksu_ksud_init();
 
 		ksu_file_wrapper_init();
diff --git a/drivers/kernelsu/feature/kernel_umount.c b/drivers/kernelsu/feature/kernel_umount.c
index 275dde8d0a9a..0b112b23b202 100644
--- a/drivers/kernelsu/feature/kernel_umount.c
+++ b/drivers/kernelsu/feature/kernel_umount.c
@@ -22,6 +22,10 @@
 #include "ksu.h"
 #include "compat/kernel_compat.h"
 
+#ifdef CONFIG_KSU_SUSFS_TRY_UMOUNT
+extern void susfs_try_umount(uid_t uid);
+#endif // #ifdef CONFIG_KSU_SUSFS_TRY_UMOUNT
+
 static bool ksu_kernel_umount_enabled = true;
 
 static int kernel_umount_feature_get(u64 *value)
@@ -79,7 +83,12 @@ static void ksu_sys_umount(const char *mnt, int flags)
 
 #endif
 
+// fs/susfs.c calls this for its try_umount list
+#ifdef CONFIG_KSU_SUSFS_TRY_UMOUNT
+void try_umount(const char *mnt, int flags)
+#else
 static void try_umount(const char *mnt, int flags)
+#endif // #ifdef CONFIG_KSU_SUSFS_TRY_UMOUNT
 {
 	struct path path;
 	int err = kern_path(mnt, 0, &path);
@@ -104,6 +113,11 @@ static void umount_tw_func(struct callback_head *cb)
 	struct umount_tw *tw = container_of(cb, struct umount_tw, cb);
 	const struct cred *saved = override_creds(ksu_cred);
 
+#ifdef CONFIG_KSU_SUSFS_TRY_UMOUNT
+	// susfs try_umount paths go prior to ksu's default umount paths
+	susfs_try_umount(current_uid().val);
+#endif // #ifdef CONFIG_KSU_SUSFS_TRY_UMOUNT
+
     struct mount_entry *entry;
     down_read(&mount_list_lock);
     list_for_each_entry(entry, &mount_list, list) {
diff --git a/drivers/kernelsu/hook/setuid_hook.c b/drivers/kernelsu/hook/setuid_hook.c
index 3184deb27bad..8dac397357b4 100644
--- a/drivers/kernelsu/hook/setuid_hook.c
+++ b/drivers/kernelsu/hook/setuid_hook.c
@@ -67,6 +67,11 @@ int ksu_handle_setresuid(uid_t old_uid, uid_t new_uid)
 #endif
     }
 
+#ifdef CONFIG_KSU_SUSFS
+    if (current_uid().val == 0)
+        ksu_handle_susfs_zygote_setresuid(new_uid);
+#endif // #ifdef CONFIG_KSU_SUSFS
+
     // Handle kernel umount
     ksu_handle_umount(old_uid, new_uid);
 
diff --git a/drivers/kernelsu/selinux/rules.c b/drivers/kernelsu/selinux/rules.c
index 14e4480d584d..bdf64212f75f 100644
--- a/drivers/kernelsu/selinux/rules.c
+++ b/drivers/kernelsu/selinux/rules.c
@@ -279,6 +279,9 @@ void apply_kernelsu_rules()
 	smp_mb();
 	reset_avc_cache();
 #endif
+#ifdef CONFIG_KSU_SUSFS
+	susfs_set_batch_sid();
+#endif // #ifdef CONFIG_KSU_SUSFS
 }
 
 #define KSU_SEPOLICY_MAX_BATCH_SIZE (8U * 1024U * 1024U)
diff --git a/drivers/kernelsu/selinux/selinux.c b/drivers/kernelsu/selinux/selinux.c
index 36f1677f2e37..6ded00e0d6d3 100644
--- a/drivers/kernelsu/selinux/selinux.c
+++ b/drivers/kernelsu/selinux/selinux.c
@@ -270,3 +270,100 @@ void escape_to_root_for_adb_root(void)
     }
     commit_creds(cred);
 }
+
+#ifdef CONFIG_KSU_SUSFS
+#define KERNEL_INIT_DOMAIN "u:r:init:s0"
+#define KERNEL_ZYGOTE_DOMAIN "u:r:zygote:s0"
+#define KERNEL_ZYGOTE_NEXT_DOMAIN "u:r:zygote_next:s0"
+#define KERNEL_PRIV_APP_DOMAIN "u:r:priv_app:s0:c512,c768"
+
+u32 susfs_ksu_sid __read_mostly = 0;
+u32 susfs_init_sid __read_mostly = 0;
+u32 susfs_zygote_sid __read_mostly = 0;
+u32 susfs_zygote_next_sid __read_mostly = 0;
+u32 susfs_priv_app_sid __read_mostly = 0;
+
+static inline void susfs_set_sid(const char *secctx_name, u32 *out_sid)
+{
+    int err;
+
+    if (!secctx_name || !out_sid) {
+        pr_err("secctx_name || out_sid is NULL\n");
+        return;
+    }
+
+    err = security_secctx_to_secid(secctx_name, strlen(secctx_name),
+                       out_sid);
+    if (err) {
+        pr_err("failed setting sid for '%s', err: %d\n", secctx_name, err);
+        return;
+    }
+    pr_info("sid '%u' is set for secctx_name '%s'\n", *out_sid, secctx_name);
+}
+
+bool susfs_is_sid_equal(const struct cred *cred, u32 sid2)
+{
+#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 18, 0)
+    const struct task_security_struct *tsec = selinux_cred(cred);
+#else
+    const struct cred_security_struct *tsec = selinux_cred(cred);
+#endif
+
+    if (!tsec || !sid2) {
+        return false;
+    }
+    return tsec->sid == sid2;
+}
+
+u32 susfs_get_sid_from_name(const char *secctx_name)
+{
+    u32 out_sid = 0;
+    int err;
+
+    if (!secctx_name) {
+        pr_err("secctx_name is NULL\n");
+        return 0;
+    }
+    err = security_secctx_to_secid(secctx_name, strlen(secctx_name),
+                       &out_sid);
+    if (err) {
+        pr_err("failed getting sid from secctx_name: %s, err: %d\n", secctx_name, err);
+        return 0;
+    }
+    return out_sid;
+}
+
+u32 susfs_get_current_sid(void)
+{
+    return current_sid();
+}
+
+bool susfs_is_current_zygote_domain(void)
+{
+    return unlikely(current_sid() == susfs_zygote_sid);
+}
+
+bool susfs_is_current_zygote_next_domain(void)
+{
+    return unlikely(current_sid() == susfs_zygote_next_sid);
+}
+
+bool susfs_is_current_ksu_domain(void)
+{
+    return unlikely(current_sid() == susfs_ksu_sid);
+}
+
+bool susfs_is_current_init_domain(void)
+{
+    return unlikely(current_sid() == susfs_init_sid);
+}
+
+void susfs_set_batch_sid(void)
+{
+    susfs_set_sid(KERNEL_ZYGOTE_DOMAIN, &susfs_zygote_sid);
+    susfs_set_sid(KERNEL_ZYGOTE_NEXT_DOMAIN, &susfs_zygote_next_sid);
+    susfs_set_sid(KERNEL_SU_CONTEXT, &susfs_ksu_sid);
+    susfs_set_sid(KERNEL_INIT_DOMAIN, &susfs_init_sid);
+    susfs_set_sid(KERNEL_PRIV_APP_DOMAIN, &susfs_priv_app_sid);
+}
+#endif // #ifdef CONFIG_KSU_SUSFS
diff --git a/drivers/kernelsu/selinux/selinux.h b/drivers/kernelsu/selinux/selinux.h
index 99e513b74104..12682364739e 100644
--- a/drivers/kernelsu/selinux/selinux.h
+++ b/drivers/kernelsu/selinux/selinux.h
@@ -65,4 +65,15 @@ void escape_to_root_for_adb_root();
 
 extern u32 ksu_file_sid;
 
+#ifdef CONFIG_KSU_SUSFS
+bool susfs_is_sid_equal(const struct cred *cred, u32 sid2);
+u32 susfs_get_sid_from_name(const char *secctx_name);
+u32 susfs_get_current_sid(void);
+void susfs_set_batch_sid(void);
+bool susfs_is_current_zygote_domain(void);
+bool susfs_is_current_zygote_next_domain(void);
+bool susfs_is_current_ksu_domain(void);
+bool susfs_is_current_init_domain(void);
+#endif // #ifdef CONFIG_KSU_SUSFS
+
 #endif
diff --git a/drivers/kernelsu/supercall/dispatch.c b/drivers/kernelsu/supercall/dispatch.c
index 2d550219b73e..f9b7a73bfb43 100644
--- a/drivers/kernelsu/supercall/dispatch.c
+++ b/drivers/kernelsu/supercall/dispatch.c
@@ -23,6 +23,9 @@
 #include "sulog/event.h"
 #include "sulog/fd.h"
 #include "supercall/supercall.h"
+#ifdef CONFIG_KSU_SUSFS
+#include <linux/susfs.h>
+#endif // #ifdef CONFIG_KSU_SUSFS
 
 static int do_grant_root(void __user *arg)
 {
@@ -135,6 +138,9 @@ static int do_report_event(void __user *arg)
 			} else {
 				pr_info("boot_complete triggered\n");
 				on_boot_completed();
+#ifdef CONFIG_KSU_SUSFS
+				susfs_start_sdcard_monitor_fn();
+#endif // #ifdef CONFIG_KSU_SUSFS
 			}
 		}
 		break;
diff --git a/drivers/kernelsu/supercall/supercall.c b/drivers/kernelsu/supercall/supercall.c
index 0a6ceb06e0ff..db44c8be6b76 100644
--- a/drivers/kernelsu/supercall/supercall.c
+++ b/drivers/kernelsu/supercall/supercall.c
@@ -11,6 +11,9 @@
 #include <linux/uaccess.h>
 #include <linux/version.h>
 #include <linux/utsname.h> // utsname() and uts_sem
+#ifdef CONFIG_KSU_SUSFS
+#include <linux/susfs.h>
+#endif // #ifdef CONFIG_KSU_SUSFS
 
 #include "uapi/supercall.h"
 #include "supercall/internal.h"
@@ -120,6 +123,87 @@ static void ksu_install_fd_tw_func(struct callback_head *cb)
     kfree(tw);
 }
 
+#ifdef CONFIG_KSU_SUSFS
+static int ksu_handle_susfs_cmd(unsigned int cmd, void __user **arg)
+{
+	switch (cmd) {
+#ifdef CONFIG_KSU_SUSFS_SUS_PATH
+	case CMD_SUSFS_ADD_SUS_PATH:
+		susfs_add_sus_path(arg);
+		break;
+	case CMD_SUSFS_ADD_SUS_PATH_LOOP:
+		susfs_add_sus_path_loop(arg);
+		break;
+#endif // #ifdef CONFIG_KSU_SUSFS_SUS_PATH
+#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
+	case CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS:
+		susfs_set_hide_sus_mnts_for_non_su_procs(arg);
+		break;
+#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
+#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
+	case CMD_SUSFS_ADD_SUS_KSTAT:
+	case CMD_SUSFS_ADD_SUS_KSTAT_STATICALLY:
+		susfs_add_sus_kstat(arg);
+		break;
+	case CMD_SUSFS_UPDATE_SUS_KSTAT:
+		susfs_update_sus_kstat(arg);
+		break;
+#endif // #ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
+#ifdef CONFIG_KSU_SUSFS_TRY_UMOUNT
+	case CMD_SUSFS_ADD_TRY_UMOUNT:
+		susfs_add_try_umount(arg);
+		break;
+#endif // #ifdef CONFIG_KSU_SUSFS_TRY_UMOUNT
+#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME
+	case CMD_SUSFS_SET_UNAME:
+		susfs_set_uname(arg);
+		break;
+#endif // #ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME
+#ifdef CONFIG_KSU_SUSFS_ENABLE_LOG
+	case CMD_SUSFS_ENABLE_LOG:
+		susfs_enable_log(arg);
+		break;
+#endif // #ifdef CONFIG_KSU_SUSFS_ENABLE_LOG
+#ifdef CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
+	case CMD_SUSFS_SET_CMDLINE_OR_BOOTCONFIG:
+		susfs_set_cmdline_or_bootconfig(arg);
+		break;
+#endif // #ifdef CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
+#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT
+	case CMD_SUSFS_ADD_OPEN_REDIRECT:
+		susfs_add_open_redirect(arg);
+		break;
+#endif // #ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT
+#ifdef CONFIG_KSU_SUSFS_SUS_MAP
+	case CMD_SUSFS_ADD_SUS_MAP:
+		susfs_add_sus_map(arg);
+		break;
+#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MAP
+#ifdef CONFIG_KSU_SUSFS_SUS_MEMFD
+	case CMD_SUSFS_ADD_SUS_MEMFD:
+		susfs_add_sus_memfd(arg);
+		break;
+#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MEMFD
+	case CMD_SUSFS_ENABLE_AVC_LOG_SPOOFING:
+		susfs_set_avc_log_spoofing(arg);
+		break;
+	case CMD_SUSFS_SHOW_ENABLED_FEATURES:
+		susfs_get_enabled_features(arg);
+		break;
+	case CMD_SUSFS_SHOW_VARIANT:
+		susfs_show_variant(arg);
+		break;
+	case CMD_SUSFS_SHOW_VERSION:
+		susfs_show_version(arg);
+		break;
+	default:
+		break;
+	}
+
+	return 0;
+}
+#endif // #ifdef CONFIG_KSU_SUSFS
+
 int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd,
 			  void __user **arg)
 {
@@ -131,6 +215,16 @@ int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd,
 		magic2);
 #endif
 
+#ifdef CONFIG_KSU_SUSFS
+	// susfs commands are only allowed for root
+	if (magic2 == SUSFS_MAGIC) {
+		if (current_uid().val != 0)
+			return 0;
+
+		return ksu_handle_susfs_cmd(cmd, arg);
+	}
+#endif // #ifdef CONFIG_KSU_SUSFS
+
 	// Check if this is a request to install KSU fd
 	if (magic2 == KSU_INSTALL_MAGIC2) {
 		struct ksu_install_fd_tw *tw;
__SUSFS_PATCH__

cat > "$TMP/kconfig.py" <<'__KCONFIG_PY__'
import re, sys, os
p = 'drivers/kernelsu/Kconfig'
s = open(p).read()
drop = []
if os.environ.get('KEEP_TRY_UMOUNT') != '1':
    drop.append('KSU_SUSFS_TRY_UMOUNT')
if os.environ.get('KEEP_SUS_MEMFD') != '1':
    drop.append('KSU_SUSFS_SUS_MEMFD')
for sym in drop:
    s, n = re.subn(r'config %s\n.*?(?=\nconfig |\nendmenu)' % sym, '', s, flags=re.S)
    print('  Kconfig: %s %s' % (sym, 'removed' if n else 'not found'))
open(p, 'w').write(s)
__KCONFIG_PY__

cat > "$TMP/setuid.py" <<'__SETUID_PY__'
import re, sys
p = 'drivers/kernelsu/hook/setuid_hook.c'
s = open(p).read()
if 'ksu_handle_susfs_zygote_next_setresuid' in s:
    print('  setuid_hook.c: already ported, skipping'); sys.exit(0)

# 1. includes
inc_anchor = '#include "compat/kernel_compat.h"\n'
if s.count(inc_anchor) != 1:
    sys.exit('setuid_hook.c: include anchor not found exactly once')
inc = """#ifdef CONFIG_KSU_SUSFS
#include <linux/susfs_def.h>
#include <linux/workqueue.h>
#include "selinux/selinux.h"
#endif // #ifdef CONFIG_KSU_SUSFS
"""
s = s.replace(inc_anchor, inc_anchor + inc)

# 2. helpers, right before ksu_handle_setresuid()
fn_anchor = 'int ksu_handle_setresuid(uid_t old_uid, uid_t new_uid)'
if s.count(fn_anchor) != 1:
    sys.exit('setuid_hook.c: function anchor not found exactly once')
helpers = """#ifdef CONFIG_KSU_SUSFS
extern u32 susfs_zygote_sid;
extern u32 susfs_zygote_next_sid;
extern struct work_struct susfs_extra_works;

// - Defer extra susfs works (e.g. re-flagging sus_path_loop) to a workqueue so we
//   do not block the zygote child here and reduce the risk of time side channels.
static inline void ksu_handle_extra_susfs_work(void)
{
    if (!work_pending(&susfs_extra_works))
        schedule_work(&susfs_extra_works);
}

// Same conditions ksu_handle_umount() uses to decide whether a zygote child gets umounted
static inline bool ksu_susfs_should_umount_uid(uid_t new_uid)
{
    if (is_isolated_process(new_uid))
        return true;

    return (is_appuid(new_uid) || new_uid == WEBVIEW_ZYGOTE_UID) &&
           ksu_uid_should_umount(new_uid);
}

// - Processes spawned by zygote_next already live in the init mount namespace,
//   so only flag them for susfs and do not umount anything here.
static int ksu_handle_susfs_zygote_next_setresuid(uid_t new_uid)
{
    if (unlikely(is_uid_manager(new_uid)))
        return 0;

    if (ksu_susfs_should_umount_uid(new_uid)) {
        susfs_set_current_proc_no_su();
        susfs_set_current_proc_umounted();
        susfs_set_current_proc_umounted_for_zygote_next();
        ksu_handle_extra_susfs_work();
        return 0;
    }

    if (!ksu_is_allow_uid_for_current(new_uid))
        susfs_set_current_proc_no_su();

    return 0;
}

// - Flag zygote spawned processes for susfs. The setresuid hook may be reached more than
//   once for the same process (syscall + LSM hook), so bail out if it is already flagged.
static void ksu_handle_susfs_zygote_setresuid(uid_t new_uid)
{
    if (!susfs_is_sid_equal(current_cred(), susfs_zygote_sid))
        return;

    if (susfs_is_current_proc_umounted())
        return;

    if (ksu_susfs_should_umount_uid(new_uid)) {
        susfs_set_current_proc_no_su();
        susfs_set_current_proc_umounted();
        ksu_handle_extra_susfs_work();
        return;
    }

    if (!ksu_is_allow_uid_for_current(new_uid))
        susfs_set_current_proc_no_su();
}
#endif // #ifdef CONFIG_KSU_SUSFS

"""
s = s.replace(fn_anchor, helpers + fn_anchor)

# 3. zygote_next early return before the first pr_info of ksu_handle_setresuid()
m = list(re.finditer(r'(?m)^[ \t]*pr_info\("handle_setresuid from', s))
if len(m) != 1:
    sys.exit('setuid_hook.c: pr_info anchor not found exactly once')
early = """#ifdef CONFIG_KSU_SUSFS
    // We only care about processes spawned by zygote_next as root
    if (unlikely(current_uid().val == 0 &&
                 susfs_is_sid_equal(current_cred(), susfs_zygote_next_sid)))
        return ksu_handle_susfs_zygote_next_setresuid(new_uid);
#endif // #ifdef CONFIG_KSU_SUSFS

"""
i = m[0].start()
s = s[:i] + early + s[i:]
open(p, 'w').write(s)
print('  setuid_hook.c: ported')
__SETUID_PY__

info "dry run"
if ! patch -p1 --dry-run --batch --no-backup-if-mismatch -i "$TMP/susfs.patch" > "$TMP/dry.log" 2>&1 \
   || grep -qE 'FAILED|can.t find file|Reversed|previously applied|ignored|malformed' "$TMP/dry.log"; then
  cat "$TMP/dry.log"
  die "dry run failed - nothing was changed. Paste the log above if you need help porting the hunk"
fi
grep -E 'fuzz|offset' "$TMP/dry.log" | sed 's/^/    /' || true
[ "$DRY" = 1 ] && { info "dry run OK"; exit 0; }

info "applying patch"
patch -p1 --batch --no-backup-if-mismatch -i "$TMP/susfs.patch" | sed 's/^/    /'

info "Kconfig: removing options the kernel-side susfs cannot back"
python3 "$TMP/kconfig.py"

info "setuid_hook.c: porting SID helpers by hand"
python3 "$TMP/setuid.py"

# cleanup stray files from older attempts
find -L "$D" \( -name '*.orig' -o -name '*.rej' \) -print -delete | sed 's/^/    removed /'

info "verifying"
n=$(grep -c '^menu "KernelSU - SUSFS"' "$D/Kconfig"); [ "$n" = 1 ] || die "expected 1 SUSFS menu in Kconfig, found $n"
grep -q 'ksu_handle_susfs_zygote_setresuid' "$D/hook/setuid_hook.c" || die "setuid_hook.c port incomplete"
grep -q 'ksu_handle_susfs_cmd' "$D/supercall/supercall.c" || die "supercall.c hunk missing"
echo "    Kconfig options:"; grep '^config KSU_SUSFS' "$D/Kconfig" | sed 's/^config /      /'

cat <<'__DONE__'

[+] done. Next:
    1. defconfig:  CONFIG_KSU_SUSFS=y   (no CONFIG_KSU_SUSFS_TRY_UMOUNT / SUS_MEMFD)
    2. build and boot, then:  su -c 'ksu_susfs show version'  ->  v2.3.0
    3. commit inside the real KSU-Next checkout:  readlink -f drivers/kernelsu
__DONE__
