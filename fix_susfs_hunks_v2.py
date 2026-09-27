#!/usr/bin/env python3
"""
Fixes the hunks that fail when applying JackA1ltman's current
susfs_patch_to_4.14.patch (embeds SUSFS_VERSION v2.3.0 as of this writing)
against this Samsung sm6150 kernel tree + KernelSU-Next v3.4.0-legacy.

Run from kernel root AFTER applying susfs_patch_to_4.14.patch with:
    patch -p1 < susfs_patch_to_4.14.patch || true
(the `|| true` matters — this script expects the 3 known hunks below to
have failed and saved .rej files; a hard patch failure should not stop
the CI step, since this script fixes those exact spots afterward)

Self-verifying: each fix only writes if its anchor text matches exactly
once. Zero or multiple matches abort with a clear message instead of
silently doing the wrong thing — important for unattended CI.
"""
import re, sys

def apply_fix(path, pattern, replacement, label):
    with open(path, "r") as f:
        content = f.read()
    new_content, count = pattern.subn(replacement, content)
    if count == 0:
        print(f"[-] {label}: anchor not found in {path} — source has likely "
              f"drifted again. No changes made; needs manual review.")
        return False
    elif count > 1:
        print(f"[-] {label}: matched {count} times in {path} — ambiguous, "
              f"aborting rather than guessing.")
        return False
    else:
        with open(path, "w") as f:
            f.write(new_content)
        print(f"[+] {label}: applied to {path}")
        return True

results = []

# --- fs/namespace.c: two small additions ---
results.append(apply_fix(
    "fs/namespace.c",
    re.compile(r'(#include <linux/sched/task\.h>\n)'),
    r'\1#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs_def.h>\n#endif // #ifdef CONFIG_KSU_SUSFS\n',
    "fs/namespace.c (susfs_def.h include)"
))
results.append(apply_fix(
    "fs/namespace.c",
    re.compile(r'(#include "internal\.h"\n)'),
    r'\1\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\nextern bool susfs_is_current_ksu_domain(void);\nextern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;\n\n#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */\n\n#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n',
    "fs/namespace.c (externs/define)"
))
results.append(apply_fix(
    "fs/namespace.c",
    re.compile(r'(\t\tcopy_flags \|= CL_SHARED_TO_SLAVE \| CL_UNPRIVILEGED;\n)(#ifdef CONFIG_RKP_NS_PROT\n\tnew = copy_tree\(old, old->mnt->mnt_root, copy_flags\);\n#else\n)'),
    r'\1#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n\tcopy_flags |= CL_COPY_MNT_NS;\n#endif\n\2',
    "fs/namespace.c (copy_mnt_ns flag)"
))

# --- fs/proc/task_mmu.c: one include ---
results.append(apply_fix(
    "fs/proc/task_mmu.c",
    re.compile(r'(#include <linux/ctype\.h>\n)'),
    r'\1#if defined(CONFIG_KSU_SUSFS_SUS_KSTAT) || defined(CONFIG_KSU_SUSFS_SUS_MAP) || defined(CONFIG_KSU_SUSFS_OPEN_REDIRECT)\n#include <linux/susfs_def.h>\n#endif // #if defined(CONFIG_KSU_SUSFS_SUS_KSTAT) || defined(CONFIG_KSU_SUSFS_SUS_MAP) || defined(CONFIG_KSU_SUSFS_OPEN_REDIRECT)\n',
    "fs/proc/task_mmu.c (susfs_def.h include)"
))

# --- fs/notify/fdinfo.c: full rewrite of this hunk for the current patch's
# SUS_KSTAT + SUS_MOUNT block structure. Two things this fixes beyond what
# the raw patch content assumes:
#   1. inotify_mark_user_mask() doesn't exist in this kernel — replaced with
#      the equivalent inline (mark->mask & IN_ALL_EVENTS) everywhere it's used.
#   2. The original `u32 mask = mark->mask & IN_ALL_EVENTS;` declaration is
#      hoisted to the top of the "if (inode) {" block and removed from its
#      later position, so the trailing `orig_flow:` label never sits directly
#      before a declaration (invalid C — a label must precede a statement).
results.append(apply_fix(
    "fs/notify/fdinfo.c",
    re.compile(
        r'(\tinode = igrab\(mark->connector->inode\);\n\tif \(inode\) \{\n)'
        r'(\t\t/\*\n\t\t \* IN_ALL_EVENTS.*?\n\t\t \*/\n)'
        r'\t\tu32 mask = mark->mask & IN_ALL_EVENTS;\n',
        re.DOTALL
    ),
    r'''\1\t\tu32 mask = mark->mask & IN_ALL_EVENTS;
#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
\t\tif (susfs_is_current_app_uid()) {
\t\t\tbool is_fuse = false;
\t\t\tif (susfs_is_inode_sus_kstat(inode, &is_fuse)) {
\t\t\t\tunsigned long ino = inode->i_ino;
\t\t\t\tdev_t dev = inode->i_sb->s_dev;
\t\t\t\tsusfs_sus_kstat_spoof_inotify_fdinfo(&ino, &dev);
\t\t\t\tseq_printf(m, "inotify wd:%x ino:%lx sdev:%x mask:%x ignored_mask:0 ",
\t\t\t\t\t\tinode_mark->wd, ino, dev,
\t\t\t\t\t\t(mark->mask & IN_ALL_EVENTS));
\t\t\t\tshow_mark_fhandle(m, inode);
\t\t\t\tseq_putc(m, '\\n');
\t\t\t\tiput(inode);
\t\t\t\treturn;
\t\t\t}
\t\t}
#endif // #ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
\t\tif (likely(susfs_is_current_proc_umounted())) {
\t\t\tstruct mount *mnt = real_mount(file->f_path.mnt);
\t\t\tif (mnt->mnt_id >= DEFAULT_KSU_MNT_ID) {
\t\t\t\tstruct path path;
\t\t\t\tchar *pathname = kmalloc(PAGE_SIZE, GFP_KERNEL);
\t\t\t\tchar *dpath;
\t\t\t\tif (!pathname) {
\t\t\t\t\tgoto orig_flow;
\t\t\t\t}
\t\t\t\tdpath = d_path(&file->f_path, pathname, PAGE_SIZE);
\t\t\t\tif (!dpath) {
\t\t\t\t\tgoto out_kfree;
\t\t\t\t}
\t\t\t\tif (kern_path(dpath, 0, &path)) {
\t\t\t\t\tgoto out_kfree;
\t\t\t\t}
\t\t\t\tif (!d_backing_inode(path.dentry)) {
\t\t\t\t\tgoto out_path_put;
\t\t\t\t}
\t\t\t\tseq_printf(m, "inotify wd:%x ino:%lx sdev:%x mask:%x ignored_mask:0 ",
\t\t\t\t\t\tinode_mark->wd, d_backing_inode(path.dentry)->i_ino, d_backing_inode(path.dentry)->i_sb->s_dev,
\t\t\t\t\t\t(mark->mask & IN_ALL_EVENTS));
\t\t\t\tshow_mark_fhandle(m, d_backing_inode(path.dentry));
\t\t\t\tseq_putc(m, '\\n');
\t\t\t\tpath_put(&path);
\t\t\t\tkfree(pathname);
\t\t\t\tiput(inode);
\t\t\t\treturn;
out_path_put:
\t\t\t\tpath_put(&path);
out_kfree:
\t\t\t\tkfree(pathname);
\t\t\t}
\t\t}
orig_flow:
#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
''',
    "fs/notify/fdinfo.c (SUS_KSTAT + SUS_MOUNT block, mask hoisted)"
))

print()
if all(results):
    print(f"All {len(results)} fixes applied successfully.")
else:
    failed = len(results) - sum(results)
    print(f"{failed} of {len(results)} fixes failed — see [-] lines above. "
          f"Do not proceed to compile until these are resolved; the source "
          f"has likely drifted since this script was written.")
    sys.exit(1)
