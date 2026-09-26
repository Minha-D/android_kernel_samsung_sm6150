#!/usr/bin/env python3
"""
Adds the missing susfs_is_current_ksu_domain(), susfs_ksu_sid, and
susfs_priv_app_sid definitions to KernelSU-Next/kernel/selinux/selinux.c.
These are referenced (extern) throughout susfs_patch_to_4.14.patch's
kernel-side changes but never defined there — they need to live in
KernelSU-Next's own selinux.c since only it knows the KSU domain SID.

Run from your KernelSU-Next/ directory (where kernel/selinux/selinux.c lives).
"""
import re, sys

path = "KernelSU-Next/kernel/selinux/selinux.c"
header_path = "KernelSU-Next/kernel/selinux/selinux.h"

with open(path, "r") as f:
    content = f.read()
with open(header_path, "r") as f:
    header = f.read()

ok = True

# Add PRIV_APP_CONTEXT to the header, next to the existing context defines
new_header, n = re.subn(
    r'(#define INIT_CONTEXT "u:r:init:s0"\n)',
    r'\1#define PRIV_APP_CONTEXT "u:r:priv_app:s0"\n',
    header
)
if n == 1:
    with open(header_path, "w") as f:
        f.write(new_header)
    print(f"[+] PRIV_APP_CONTEXT added to {header_path}")
else:
    print(f"[-] PRIV_APP_CONTEXT: anchor not found in {header_path} ({n} matches) — no changes made.")
    ok = False

# Add the two new global SID variables, right after ksu_file_sid
content, n = re.subn(
    r'(u32 ksu_file_sid __read_mostly = 0;\n)',
    r'\1\n#ifdef CONFIG_KSU_SUSFS\nu32 susfs_ksu_sid __read_mostly = 0;\nu32 susfs_priv_app_sid __read_mostly = 0;\n#endif\n',
    content
)
print(f"[{'+' if n == 1 else '-'}] susfs SID globals: {n} match(es)")
ok &= (n == 1)

# Resolve susfs_priv_app_sid in cache_sid(), and mirror cached_su_sid into
# susfs_ksu_sid (same context, avoids a redundant secctx_to_secid call)
content, n = re.subn(
    r'(    } else \{\n        pr_info\("Cached su SID: %u\\n", cached_su_sid\);\n    \}\n)',
    r'''\1
#ifdef CONFIG_KSU_SUSFS
    susfs_ksu_sid = cached_su_sid;

    err = security_secctx_to_secid(PRIV_APP_CONTEXT, strlen(PRIV_APP_CONTEXT),
                                   &susfs_priv_app_sid);
    if (err) {
        pr_warn("Failed to cache priv_app SID: %d\\n", err);
        susfs_priv_app_sid = 0;
    } else {
        pr_info("Cached priv_app SID: %u\\n", susfs_priv_app_sid);
    }
#endif
''',
    content
)
print(f"[{'+' if n == 1 else '-'}] susfs SID resolution in cache_sid(): {n} match(es)")
ok &= (n == 1)

# Add susfs_is_current_ksu_domain() as a thin wrapper around the existing,
# already-correct is_ksu_domain() — right after is_ksu_domain()'s definition.
content, n = re.subn(
    r'(bool is_ksu_domain\(void\)\n\{\n    return is_task_ksu_domain\(current_cred\(\)\);\n\}\n)',
    r'''\1
#ifdef CONFIG_KSU_SUSFS
bool susfs_is_current_ksu_domain(void)
{
    return is_ksu_domain();
}
#endif
''',
    content
)
print(f"[{'+' if n == 1 else '-'}] susfs_is_current_ksu_domain(): {n} match(es)")
ok &= (n == 1)

if ok:
    with open(path, "w") as f:
        f.write(content)
    print("\nAll edits applied to kernel/selinux/selinux.c and selinux.h.")
else:
    print("\nOne or more anchors not found — no changes written to selinux.c.")
    print("(selinux.h may have been written already if its part matched — check git diff.)")
    sys.exit(1)
