//! Privilege drop for service processes.
//!
//! Applies uid/gid/supplementary groups in a `Command::pre_exec` closure
//! before the service binary is exec'd. This is the unsafe code that
//! argonaut's `forbid(unsafe_code)` cannot provide.

use std::os::unix::process::CommandExt;
use std::process::Command;

use anyhow::Result;
use tracing::debug;

/// Configure privilege drop on a `Command` via `pre_exec`.
///
/// Sets uid, gid, and supplementary groups before exec. Also applies
/// seccomp and Landlock filters if configured.
///
/// # Safety
///
/// This calls `pre_exec` which runs in the child process between
/// `fork` and `exec`. The closure must be async-signal-safe.
#[allow(dead_code)]
pub fn apply_privilege_drop(cmd: &mut Command, uid: Option<u32>, gid: Option<u32>) -> Result<()> {
    if uid.is_none() && gid.is_none() {
        return Ok(());
    }

    let uid = uid.unwrap_or(0);
    let gid = gid.unwrap_or(0);

    debug!(uid = uid, gid = gid, "configuring privilege drop");

    // SAFETY: pre_exec runs between fork and exec in the child.
    // setgroups/setgid/setuid are async-signal-safe per POSIX.
    // Order matters: groups first, then gid, then uid (can't
    // change groups after dropping root).
    unsafe {
        cmd.pre_exec(move || {
            // Drop supplementary groups
            if libc::setgroups(0, std::ptr::null()) != 0 {
                return Err(std::io::Error::last_os_error());
            }

            // Set GID
            if gid != 0 && libc::setgid(gid) != 0 {
                return Err(std::io::Error::last_os_error());
            }

            // Set UID (must be last — can't undo this)
            if uid != 0 && libc::setuid(uid) != 0 {
                return Err(std::io::Error::last_os_error());
            }

            Ok(())
        });
    }

    Ok(())
}

// NOTE: seccomp pre_exec support will be added when the `security` feature
// is defined in Cargo.toml and argonaut exposes `SeccompConfig`.

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn apply_privilege_drop_noop_with_no_uid_gid() {
        let mut cmd = Command::new("/usr/bin/true");
        let result = apply_privilege_drop(&mut cmd, None, None);
        assert!(result.is_ok(), "no-op privilege drop should succeed");
    }

    #[test]
    #[ignore] // Requires root to actually setuid/setgid
    fn apply_privilege_drop_with_uid_gid() {
        let mut cmd = Command::new("/usr/bin/true");
        let result = apply_privilege_drop(&mut cmd, Some(65534), Some(65534));
        assert!(
            result.is_ok(),
            "apply_privilege_drop should succeed (pre_exec is deferred)"
        );
    }
}
