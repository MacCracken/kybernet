//! Essential filesystem mounting for PID 1.
//!
//! Mounts `/proc`, `/sys`, `/dev`, `/run`, and cgroup v2 filesystem
//! before any services start.

use std::path::Path;

use anyhow::{Context, Result};
use nix::mount::{MsFlags, mount};
use tracing::{info, warn};

/// Mount an essential filesystem if not already mounted.
fn mount_if_needed(
    source: &str,
    target: &str,
    fstype: &str,
    flags: MsFlags,
    data: Option<&str>,
) -> Result<()> {
    let target_path = Path::new(target);

    // Create mount point if it doesn't exist
    if !target_path.exists() {
        std::fs::create_dir_all(target_path)
            .with_context(|| format!("failed to create mount point: {target}"))?;
    }

    // Check if already mounted (simple heuristic: /proc/self/mounts)
    if is_mounted(target) {
        info!(target = target, "already mounted, skipping");
        return Ok(());
    }

    mount(Some(source), target, Some(fstype), flags, data)
        .with_context(|| format!("failed to mount {fstype} on {target}"))?;

    info!(source = source, target = target, fstype = fstype, "mounted");
    Ok(())
}

/// Check if a path is already a mount point.
fn is_mounted(target: &str) -> bool {
    std::fs::read_to_string("/proc/self/mounts")
        .map(|content| {
            content
                .lines()
                .any(|line| line.split_whitespace().nth(1) == Some(target))
        })
        .unwrap_or(false)
}

/// Mount all essential filesystems for PID 1.
///
/// Order matters:
/// 1. `/proc` — needed for process info and mount checks
/// 2. `/sys` — needed for device info and cgroups
/// 3. `/dev` — needed for device nodes (devtmpfs)
/// 4. `/dev/pts` — pseudo-terminals
/// 5. `/dev/shm` — shared memory
/// 6. `/run` — runtime state (PID files, sockets)
/// 7. `/sys/fs/cgroup` — cgroup v2 unified hierarchy
pub fn mount_essential_filesystems() -> Result<()> {
    info!("mounting essential filesystems");

    // /proc — mount unconditionally first (can't check /proc/self/mounts before /proc exists)
    mount(
        Some("proc"),
        "/proc",
        Some("proc"),
        MsFlags::MS_NOSUID | MsFlags::MS_NODEV | MsFlags::MS_NOEXEC,
        None::<&str>,
    )
    .or_else(|e| if is_mounted("/proc") { Ok(()) } else { Err(e) })
    .context("failed to mount /proc")?;

    // /sys
    mount_if_needed(
        "sysfs",
        "/sys",
        "sysfs",
        MsFlags::MS_NOSUID | MsFlags::MS_NODEV | MsFlags::MS_NOEXEC,
        None,
    )?;

    // /dev (devtmpfs — kernel populates device nodes)
    mount_if_needed(
        "devtmpfs",
        "/dev",
        "devtmpfs",
        MsFlags::MS_NOSUID,
        Some("mode=0755"),
    )?;

    // /dev/pts
    if !Path::new("/dev/pts").exists() {
        std::fs::create_dir_all("/dev/pts")?;
    }
    mount_if_needed(
        "devpts",
        "/dev/pts",
        "devpts",
        MsFlags::MS_NOSUID | MsFlags::MS_NOEXEC,
        Some("gid=5,mode=0620"),
    )?;

    // /dev/shm
    if !Path::new("/dev/shm").exists() {
        std::fs::create_dir_all("/dev/shm")?;
    }
    mount_if_needed(
        "tmpfs",
        "/dev/shm",
        "tmpfs",
        MsFlags::MS_NOSUID | MsFlags::MS_NODEV,
        Some("mode=1777"),
    )?;

    // /run
    mount_if_needed(
        "tmpfs",
        "/run",
        "tmpfs",
        MsFlags::MS_NOSUID | MsFlags::MS_NODEV,
        Some("mode=0755,size=20%"),
    )?;

    // /sys/fs/cgroup (cgroup v2 unified)
    if !Path::new("/sys/fs/cgroup").exists() {
        std::fs::create_dir_all("/sys/fs/cgroup")?;
    }
    mount_if_needed(
        "cgroup2",
        "/sys/fs/cgroup",
        "cgroup2",
        MsFlags::MS_NOSUID | MsFlags::MS_NODEV | MsFlags::MS_NOEXEC,
        None,
    )
    .unwrap_or_else(|e| {
        warn!(error = %e, "cgroup2 mount failed — cgroup isolation unavailable");
    });

    info!("essential filesystems mounted");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn root_is_mounted() {
        assert!(is_mounted("/"), "/ should always be mounted");
    }

    #[test]
    fn proc_is_mounted() {
        // /proc should be mounted on any Linux system running tests
        assert!(is_mounted("/proc"), "/proc should be mounted");
    }

    #[test]
    fn nonexistent_path_is_not_mounted() {
        assert!(
            !is_mounted("/nonexistent_mount_point_12345"),
            "nonexistent path should not be mounted"
        );
    }

    #[test]
    fn is_mounted_does_not_match_partial_paths() {
        // "/pro" should not match "/proc"
        assert!(
            !is_mounted("/pro"),
            "partial path should not match a real mount point"
        );
    }
}
