//! Console I/O setup for PID 1.
//!
//! Opens `/dev/console` for stdout/stderr and `/dev/null` for stdin.
//! Must run before any logging or output.

use std::fs::OpenOptions;
use std::os::unix::io::AsRawFd;

use anyhow::{Context, Result};
use tracing::info;

/// Set up console I/O for PID 1.
///
/// - stdin  → `/dev/null`
/// - stdout → `/dev/console` (fallback to `/dev/null`)
/// - stderr → `/dev/console` (fallback to `/dev/null`)
pub fn setup_console() -> Result<()> {
    // Close inherited file descriptors 0, 1, 2
    // SAFETY: closing stdin/stdout/stderr is safe at process start
    // before any I/O has occurred. We immediately reopen them below.
    unsafe {
        libc::close(0);
        libc::close(1);
        libc::close(2);
    }

    // Open /dev/null as fd 0 (stdin)
    let null = OpenOptions::new()
        .read(true)
        .write(true)
        .open("/dev/null")
        .context("failed to open /dev/null")?;
    if null.as_raw_fd() != 0 {
        anyhow::bail!(
            "/dev/null opened as fd {} instead of fd 0",
            null.as_raw_fd()
        );
    }

    // Open /dev/console as fd 1 (stdout), fallback to /dev/null
    let console_fd = match OpenOptions::new().write(true).open("/dev/console") {
        Ok(f) => f.as_raw_fd(),
        Err(_) => {
            // Fallback: dup /dev/null to fd 1
            // SAFETY: dup2 is safe when both fds are valid
            unsafe {
                libc::dup2(0, 1);
            }
            1
        }
    };

    if console_fd != 1 {
        // SAFETY: moving the console fd to fd 1
        unsafe {
            libc::dup2(console_fd, 1);
            libc::close(console_fd);
        }
    }

    // Dup stdout to stderr (fd 2)
    // SAFETY: dup2 is safe when source fd is valid
    unsafe {
        libc::dup2(1, 2);
    }

    // Forget the File so it doesn't close our fd 0
    std::mem::forget(null);

    info!("console I/O initialized");
    Ok(())
}
