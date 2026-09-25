#!/usr/bin/env python3
"""
Fixes the 4 hunks that fail when applying JackA1ltman's
susfs_patch_to_4.14.patch against this Samsung sm6150 kernel tree.
Run from kernel root AFTER applying susfs_patch_to_4.14.patch with
'patch -p1' (answer 'n' to any "file to patch" prompts so it skips
and saves .rej files instead of hanging).

Verified end-to-end against Minha-D/android_kernel_samsung_sm6150.
"""
import re, sys

def apply_fix(path, pattern, replacement, label):
    with open(path, "r") as f:
        content = f.read()
    new_content, count = pattern.subn(replacement, content)
    if count == 0:
        print(f"[-] {label}: pattern not found in {path} — no changes made.")
        return False
    elif count > 1:
        print(f"[-] {label}: matched {count} times in {path} — aborting, refine pattern.")
        return False
    else:
        with open(path, "w") as f:
            f.write(new_content)
        print(f"[+] {label}: applied to {path}")
        return True

results = []

results.append(apply_fix(
    "fs/namespace.c",
    re.compile(r'(#include <linux/sched/task\.h>\n)'),
    r'\1#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n#include <linux/susfs_def.h>\n#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n',
    "fs/namespace.c hunk 1a (susfs_def.h include)"
))

results.append(apply_fix(
    "fs/namespace.c",
    re.compile(r'(#include "internal\.h"\n)'),
    r'\1\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\nextern bool susfs_is_current_ksu_domain(void);\nextern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;\n\n#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */\n\n#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n',
    "fs/namespace.c hunk 1b (externs/define)"
))

results.append(apply_fix(
    "fs/namespace.c",
    re.compile(r'(\t\tcopy_flags \|= CL_SHARED_TO_SLAVE \| CL_UNPRIVILEGED;\n)(#ifdef CONFIG_RKP_NS_PROT\n\tnew = copy_tree\(old, old->mnt->mnt_root, copy_flags\);\n#else\n)'),
    r'\1#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n\tcopy_flags |= CL_COPY_MNT_NS;\n#endif\n\2',
    "fs/namespace.c hunk 10 (copy_mnt_ns flag)"
))

results.append(apply_fix(
    "fs/proc/task_mmu.c",
    re.compile(r'(#include <linux/ctype\.h>\n)'),
    r'\1#if defined(CONFIG_KSU_SUSFS_SUS_KSTAT) || defined(CONFIG_KSU_SUSFS_SUS_MAP) || defined(CONFIG_KSU_SUSFS_OPEN_REDIRECT)\n#include <linux/susfs_def.h>\n#endif // #if defined(CONFIG_KSU_SUSFS_SUS_KSTAT) || defined(CONFIG_KSU_SUSFS_SUS_MAP) || defined(CONFIG_KSU_SUSFS_OPEN_REDIRECT)\n',
    "fs/proc/task_mmu.c (susfs_def.h include)"
))

results.append(apply_fix(
    "fs/notify/fdinfo.c",
    re.compile(r'(\tinode = igrab\(mark->connector->inode\);\n\tif \(inode\) \{\n)'),
    r'''\1#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
\t\tmnt = real_mount(file->f_path.mnt);
\t\tif (mnt->mnt_id >= DEFAULT_KSU_MNT_ID &&
\t\t\tlikely(susfs_is_current_proc_umounted()))
\t\t{
\t\t\tstruct path path;
\t\t\tchar *pathname = kmalloc(PAGE_SIZE, GFP_KERNEL);
\t\t\tchar *dpath;
\t\t\tif (!pathname) {
\t\t\t\tgoto orig_flow;
\t\t\t}
\t\t\tdpath = d_path(&file->f_path, pathname, PAGE_SIZE);
\t\t\tif (!dpath) {
\t\t\t\tgoto out_kfree;
\t\t\t}
\t\t\tif (kern_path(dpath, 0, &path)) {
\t\t\t\tgoto out_kfree;
\t\t\t}
\t\t\tif (!path.dentry->d_inode) {
\t\t\t\tgoto out_path_put;
\t\t\t}
\t\t\tseq_printf(m, "inotify wd:%x ino:%lx sdev:%x mask:%x ignored_mask:0 ",
\t\t\t\t\tinode_mark->wd, path.dentry->d_inode->i_ino, path.dentry->d_inode->i_sb->s_dev,
\t\t\t\t\tinotify_mark_user_mask(mark));
\t\t\tshow_mark_fhandle(m, path.dentry->d_inode);
\t\t\tseq_putc(m, '\\n');
\t\t\tpath_put(&path);
\t\t\tkfree(pathname);
\t\t\tiput(inode);
\t\t\treturn;
out_path_put:
\t\t\tpath_put(&path);
out_kfree:
\t\t\tkfree(pathname);
\t\t}
orig_flow:
#endif
''',
    "fs/notify/fdinfo.c hunk 4 (mount-hiding block)"
))

print()
if all(results):
    print(f"All {len(results)} of {len(results)} fixes applied successfully.")
    print("Remaining: fs/namei.c OPEN_REDIRECT hunk (fs/namei.c.rej) — optional")
    print("susfs feature, not required for core root/module hiding. Disable")
    print("CONFIG_KSU_SUSFS_OPEN_REDIRECT in defconfig to skip it cleanly.")
else:
    failed = len(results) - sum(results)
    print(f"{failed} of {len(results)} fixes failed to apply — see [-] lines above.")
    sys.exit(1)
