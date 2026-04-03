//! Cgroup v2 per-service isolation.
//!
//! Creates `/sys/fs/cgroup/kybernet.slice/<service>/` for each managed
//! service. Moves the service process into its cgroup after spawn.
//! Enables clean process killing (kill the cgroup, not individual PIDs).

use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use tracing::{debug, info, warn};

const CGROUP_ROOT: &str = "/sys/fs/cgroup";
const KYBERNET_SLICE: &str = "kybernet.slice";

/// Get the cgroup path for a service.
#[allow(dead_code)]
#[must_use]
pub fn service_cgroup_path(service_name: &str) -> PathBuf {
    Path::new(CGROUP_ROOT)
        .join(KYBERNET_SLICE)
        .join(service_name)
}

/// Create the kybernet slice and a service cgroup within it.
pub fn create_service_cgroup(service_name: &str) -> Result<PathBuf> {
    let slice_path = Path::new(CGROUP_ROOT).join(KYBERNET_SLICE);
    if !slice_path.exists() {
        fs::create_dir_all(&slice_path).with_context(|| {
            format!("failed to create kybernet slice: {}", slice_path.display())
        })?;
        info!(path = %slice_path.display(), "created kybernet cgroup slice");
    }

    let cgroup_path = slice_path.join(service_name);
    if !cgroup_path.exists() {
        fs::create_dir_all(&cgroup_path).with_context(|| {
            format!("failed to create service cgroup: {}", cgroup_path.display())
        })?;
        debug!(service = service_name, path = %cgroup_path.display(), "created service cgroup");
    }

    Ok(cgroup_path)
}

/// Move a process into a service cgroup.
///
/// Writes the PID to `cgroup.procs` in the service's cgroup directory.
pub fn move_to_cgroup(service_name: &str, pid: u32) -> Result<()> {
    let cgroup_path = create_service_cgroup(service_name)?;
    let procs_path = cgroup_path.join("cgroup.procs");

    fs::write(&procs_path, pid.to_string()).with_context(|| {
        format!(
            "failed to move pid {pid} into cgroup {}",
            cgroup_path.display()
        )
    })?;

    debug!(service = service_name, pid = pid, "moved process to cgroup");
    Ok(())
}

/// Kill all processes in a service cgroup.
///
/// Writes "1" to `cgroup.kill` (cgroup v2 feature, kernel 5.14+).
/// Falls back to reading `cgroup.procs` and sending SIGKILL individually.
#[allow(dead_code)]
pub fn kill_cgroup(service_name: &str) -> Result<()> {
    let cgroup_path = service_cgroup_path(service_name);
    if !cgroup_path.exists() {
        return Ok(());
    }

    let kill_path = cgroup_path.join("cgroup.kill");
    if kill_path.exists() {
        // Fast path: kernel 5.14+ cgroup.kill
        if let Err(e) = fs::write(&kill_path, "1") {
            warn!(service = service_name, error = %e, "cgroup.kill failed, falling back to individual SIGKILL");
        } else {
            info!(service = service_name, "killed cgroup via cgroup.kill");
            return Ok(());
        }
    }

    // Fallback: read pids and kill individually
    let procs_path = cgroup_path.join("cgroup.procs");
    if let Ok(content) = fs::read_to_string(&procs_path) {
        for line in content.lines() {
            if let Ok(pid) = line.trim().parse::<i32>() {
                // SAFETY: sending SIGKILL to a valid PID is safe
                unsafe {
                    libc::kill(pid, libc::SIGKILL);
                }
                debug!(
                    service = service_name,
                    pid = pid,
                    "sent SIGKILL to cgroup member"
                );
            }
        }
    }

    info!(service = service_name, "killed cgroup processes");
    Ok(())
}

/// Remove a service cgroup (after all processes have exited).
#[allow(dead_code)]
pub fn remove_service_cgroup(service_name: &str) -> Result<()> {
    let cgroup_path = service_cgroup_path(service_name);
    if cgroup_path.exists() {
        fs::remove_dir(&cgroup_path)
            .with_context(|| format!("failed to remove cgroup: {}", cgroup_path.display()))?;
        debug!(service = service_name, "removed service cgroup");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn service_cgroup_path_basic() {
        let path = service_cgroup_path("myservice");
        assert_eq!(
            path,
            PathBuf::from("/sys/fs/cgroup/kybernet.slice/myservice")
        );
    }

    #[test]
    fn service_cgroup_path_with_dots() {
        let path = service_cgroup_path("my.service.name");
        assert_eq!(
            path,
            PathBuf::from("/sys/fs/cgroup/kybernet.slice/my.service.name")
        );
    }

    #[test]
    fn service_cgroup_path_with_hyphens() {
        let path = service_cgroup_path("my-service");
        assert_eq!(
            path,
            PathBuf::from("/sys/fs/cgroup/kybernet.slice/my-service")
        );
    }

    #[test]
    fn service_cgroup_path_constants() {
        // Verify the root and slice are what we expect
        let path = service_cgroup_path("test");
        assert!(path.starts_with(CGROUP_ROOT));
        assert!(path.to_string_lossy().contains(KYBERNET_SLICE));
    }
}
