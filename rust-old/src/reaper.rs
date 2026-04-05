//! Zombie reaping for PID 1.
//!
//! PID 1 MUST reap all children — not just tracked services. Orphaned
//! processes get re-parented to PID 1, and if we don't `waitpid` them,
//! they become zombies that consume PID table entries.

use nix::sys::wait::{WaitPidFlag, WaitStatus, waitpid};
use nix::unistd::Pid;
use tracing::{debug, warn};

/// Reap all exited children without blocking.
///
/// Calls `waitpid(-1, WNOHANG)` in a loop until no more children
/// have exited. Returns the list of (pid, exit_code) pairs reaped.
///
/// This must be called every time SIGCHLD is received.
pub fn reap_zombies() -> Vec<(u32, i32)> {
    let mut reaped = Vec::new();

    loop {
        match waitpid(Pid::from_raw(-1), Some(WaitPidFlag::WNOHANG)) {
            Ok(WaitStatus::Exited(pid, code)) => {
                let p = pid.as_raw() as u32;
                debug!(pid = p, exit_code = code, "reaped exited child");
                reaped.push((p, code));
            }
            Ok(WaitStatus::Signaled(pid, signal, _core_dumped)) => {
                let p = pid.as_raw() as u32;
                let code = -(signal as i32);
                debug!(pid = p, signal = %signal, "reaped signaled child");
                reaped.push((p, code));
            }
            Ok(WaitStatus::StillAlive) => {
                // No more children to reap
                break;
            }
            Ok(other) => {
                debug!(status = ?other, "waitpid returned non-exit status, continuing");
                continue;
            }
            Err(nix::errno::Errno::ECHILD) => {
                // No children at all
                break;
            }
            Err(e) => {
                warn!(error = %e, "waitpid failed");
                break;
            }
        }
    }

    if !reaped.is_empty() {
        debug!(count = reaped.len(), "reaped zombie processes");
    }

    reaped
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Spawn a child, forget the handle so Rust doesn't waitpid it,
    /// then reap via our function. Uses a lock to prevent test
    /// parallelism from interfering with waitpid(-1).
    use std::sync::Mutex;
    static REAP_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn reap_zombies_finds_exited_child() {
        let _guard = REAP_LOCK.lock().unwrap_or_else(|e| e.into_inner());

        // Drain any leftover zombies first
        let _ = reap_zombies();

        // Spawn a child that exits immediately
        let child = std::process::Command::new("/usr/bin/true")
            .spawn()
            .expect("failed to spawn /usr/bin/true");

        let pid = child.id();
        // Forget the Child handle so its Drop doesn't call waitpid
        std::mem::forget(child);

        // Give the child time to exit
        std::thread::sleep(std::time::Duration::from_millis(100));

        let reaped = reap_zombies();

        assert!(
            reaped.iter().any(|&(p, code)| p == pid && code == 0),
            "expected to reap pid {pid} with exit code 0, got: {reaped:?}"
        );
    }

    #[test]
    fn reap_zombies_returns_empty_when_no_children() {
        let _guard = REAP_LOCK.lock().unwrap_or_else(|e| e.into_inner());

        // Drain any leftover zombies from previous tests
        let _ = reap_zombies();

        // With no children pending, should return empty
        let reaped = reap_zombies();
        assert!(reaped.is_empty(), "expected no zombies, got: {reaped:?}");
    }

    #[test]
    fn reap_zombies_captures_nonzero_exit_code() {
        let _guard = REAP_LOCK.lock().unwrap_or_else(|e| e.into_inner());

        // Drain any leftover zombies first
        let _ = reap_zombies();

        let child = std::process::Command::new("/usr/bin/false")
            .spawn()
            .expect("failed to spawn /usr/bin/false");

        let pid = child.id();
        std::mem::forget(child);
        std::thread::sleep(std::time::Duration::from_millis(100));

        let reaped = reap_zombies();

        assert!(
            reaped.iter().any(|&(p, code)| p == pid && code == 1),
            "expected to reap pid {pid} with exit code 1, got: {reaped:?}"
        );
    }
}
