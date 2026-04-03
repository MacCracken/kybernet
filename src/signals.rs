//! Signal handling via signalfd for PID 1.
//!
//! PID 1 receives ALL signals. We block them from default handling and
//! read them via signalfd in the event loop.

use std::os::unix::io::{AsRawFd, RawFd};

use anyhow::{Context, Result};
use nix::sys::signal::SigSet;
use nix::sys::signalfd::{SfdFlags, SignalFd};
use tracing::info;

/// Signals that PID 1 must handle.
const HANDLED_SIGNALS: &[nix::sys::signal::Signal] = &[
    nix::sys::signal::Signal::SIGCHLD, // Child process exited
    nix::sys::signal::Signal::SIGTERM, // Shutdown request
    nix::sys::signal::Signal::SIGINT,  // Ctrl+C (console)
    nix::sys::signal::Signal::SIGHUP,  // Terminal hangup / reload
    nix::sys::signal::Signal::SIGPWR,  // Power failure (UPS)
];

/// Set up signal handling for PID 1.
///
/// Blocks handled signals from default processing and creates a
/// signalfd for reading them in the event loop.
///
/// Returns the signalfd file descriptor.
pub fn setup_signals() -> Result<SignalFd> {
    let mut mask = SigSet::empty();
    for &sig in HANDLED_SIGNALS {
        mask.add(sig);
    }

    // Block signals so they queue up for signalfd
    mask.thread_block().context("failed to block signals")?;

    let sfd = SignalFd::with_flags(&mask, SfdFlags::SFD_NONBLOCK | SfdFlags::SFD_CLOEXEC)
        .context("failed to create signalfd")?;

    info!(
        signals = ?HANDLED_SIGNALS.iter().map(|s| s.as_str()).collect::<Vec<_>>(),
        fd = sfd.as_raw_fd(),
        "signalfd created"
    );

    Ok(sfd)
}

/// Get the raw fd from a SignalFd for use with epoll.
pub fn signalfd_raw(sfd: &SignalFd) -> RawFd {
    sfd.as_raw_fd()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn handled_signals_contains_sigchld() {
        assert!(
            HANDLED_SIGNALS.contains(&nix::sys::signal::Signal::SIGCHLD),
            "SIGCHLD must be in HANDLED_SIGNALS for zombie reaping"
        );
    }

    #[test]
    fn handled_signals_contains_sigterm() {
        assert!(
            HANDLED_SIGNALS.contains(&nix::sys::signal::Signal::SIGTERM),
            "SIGTERM must be in HANDLED_SIGNALS for clean shutdown"
        );
    }

    #[test]
    fn handled_signals_are_unique() {
        let mut seen = std::collections::HashSet::new();
        for &sig in HANDLED_SIGNALS {
            assert!(
                seen.insert(sig),
                "duplicate signal in HANDLED_SIGNALS: {sig}"
            );
        }
    }

    #[test]
    fn handled_signals_count() {
        assert_eq!(
            HANDLED_SIGNALS.len(),
            5,
            "expected exactly 5 handled signals (SIGCHLD, SIGTERM, SIGINT, SIGHUP, SIGPWR)"
        );
    }
}
