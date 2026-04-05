//! epoll-based event loop for PID 1.
//!
//! Multiplexes signalfd, timerfd, notify socket, and control socket
//! into a single event loop. This is the main runtime of kybernet.

use std::os::unix::io::RawFd;
use std::time::Duration;

use anyhow::{Context, Result};
use tracing::{debug, info};

/// RAII wrapper for a raw file descriptor — closes on drop.
pub struct OwnedFd(RawFd);

impl OwnedFd {
    /// Get the underlying raw file descriptor.
    #[must_use]
    pub fn raw(&self) -> RawFd {
        self.0
    }
}

impl Drop for OwnedFd {
    fn drop(&mut self) {
        // SAFETY: closing a file descriptor we own.
        unsafe {
            libc::close(self.0);
        }
    }
}

/// Event sources registered with epoll.
#[allow(dead_code)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EventSource {
    /// Signal received (SIGCHLD, SIGTERM, etc.)
    Signal,
    /// Health check timer fired
    HealthTimer,
    /// Watchdog timer fired
    WatchdogTimer,
    /// sd_notify message received
    NotifySocket,
}

/// Create an epoll instance.
pub fn create_epoll() -> Result<OwnedFd> {
    // SAFETY: epoll_create1 is safe, returns a new fd.
    let epfd = unsafe { libc::epoll_create1(libc::EPOLL_CLOEXEC) };
    if epfd < 0 {
        return Err(std::io::Error::last_os_error()).context("failed to create epoll instance");
    }
    info!(fd = epfd, "epoll instance created");
    Ok(OwnedFd(epfd))
}

/// Register a file descriptor with epoll for reading.
pub fn epoll_add(epfd: RawFd, fd: RawFd, token: u64) -> Result<()> {
    let mut event = libc::epoll_event {
        events: libc::EPOLLIN as u32,
        u64: token,
    };
    // SAFETY: epoll_ctl with valid fds and event struct
    let ret = unsafe { libc::epoll_ctl(epfd, libc::EPOLL_CTL_ADD, fd, &mut event) };
    if ret < 0 {
        return Err(std::io::Error::last_os_error())
            .context(format!("epoll_ctl ADD failed for fd {fd}"));
    }
    debug!(fd = fd, token = token, "registered fd with epoll");
    Ok(())
}

/// Create a timerfd that fires periodically.
pub fn create_timerfd(interval: Duration) -> Result<OwnedFd> {
    // SAFETY: timerfd_create returns a new fd.
    let tfd = unsafe {
        libc::timerfd_create(
            libc::CLOCK_MONOTONIC,
            libc::TFD_NONBLOCK | libc::TFD_CLOEXEC,
        )
    };
    if tfd < 0 {
        return Err(std::io::Error::last_os_error()).context("failed to create timerfd");
    }

    let secs = interval.as_secs() as libc::time_t;
    let nsecs = interval.subsec_nanos() as libc::c_long;

    let spec = libc::itimerspec {
        it_interval: libc::timespec {
            tv_sec: secs,
            tv_nsec: nsecs,
        },
        it_value: libc::timespec {
            tv_sec: secs,
            tv_nsec: nsecs,
        },
    };

    // SAFETY: timerfd_settime with valid fd and spec.
    let ret = unsafe { libc::timerfd_settime(tfd, 0, &spec, std::ptr::null_mut()) };
    if ret < 0 {
        // SAFETY: closing the fd we just created on error path.
        unsafe {
            libc::close(tfd);
        }
        return Err(std::io::Error::last_os_error()).context("timerfd_settime failed");
    }

    debug!(
        fd = tfd,
        interval_ms = interval.as_millis() as u64,
        "timerfd created"
    );
    Ok(OwnedFd(tfd))
}

/// Drain a timerfd (read the expiration count to reset it).
pub fn drain_timerfd(fd: RawFd) -> Result<u64> {
    let mut buf = [0u8; 8];
    // SAFETY: reading 8 bytes from a valid timerfd
    let n = unsafe { libc::read(fd, buf.as_mut_ptr() as *mut libc::c_void, 8) };
    if n < 0 {
        let err = std::io::Error::last_os_error();
        if err.kind() == std::io::ErrorKind::WouldBlock {
            return Ok(0);
        }
        return Err(err).context("timerfd read failed");
    }
    Ok(u64::from_ne_bytes(buf))
}

/// Wait for events on the epoll instance.
///
/// Returns the number of ready events. Events are written to `events`.
/// Timeout of -1 means block indefinitely.
pub fn epoll_wait(epfd: RawFd, events: &mut [libc::epoll_event], timeout_ms: i32) -> Result<usize> {
    // SAFETY: epoll_wait with valid fd, buffer, and count
    let n = unsafe {
        libc::epoll_wait(
            epfd,
            events.as_mut_ptr(),
            events.len() as libc::c_int,
            timeout_ms,
        )
    };
    if n < 0 {
        let err = std::io::Error::last_os_error();
        if err.kind() == std::io::ErrorKind::Interrupted {
            return Ok(0); // EINTR — signal interrupted, retry
        }
        return Err(err).context("epoll_wait failed");
    }
    Ok(n as usize)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn owned_fd_closes_on_drop() {
        // Create a timerfd, grab the raw fd, then drop the OwnedFd
        let tfd = create_timerfd(Duration::from_secs(60)).expect("create_timerfd failed");
        let raw = tfd.raw();
        assert!(raw >= 0, "expected valid fd, got {raw}");

        drop(tfd);

        // After drop, the fd should be invalid — fcntl F_GETFD should fail
        let ret = unsafe { libc::fcntl(raw, libc::F_GETFD) };
        assert_eq!(ret, -1, "fd {raw} should be closed after drop");
    }

    #[test]
    fn create_timerfd_returns_valid_fd() {
        let tfd = create_timerfd(Duration::from_secs(5)).expect("create_timerfd failed");
        assert!(tfd.raw() >= 0, "expected valid fd, got {}", tfd.raw());

        // Verify it is a valid fd via fcntl
        let ret = unsafe { libc::fcntl(tfd.raw(), libc::F_GETFD) };
        assert!(ret >= 0, "fcntl F_GETFD failed on timerfd");
    }

    #[test]
    fn drain_timerfd_returns_zero_immediately() {
        // A freshly created timerfd with a long interval should not have fired yet
        let tfd = create_timerfd(Duration::from_secs(3600)).expect("create_timerfd failed");
        let count = drain_timerfd(tfd.raw()).expect("drain_timerfd failed");
        assert_eq!(
            count, 0,
            "expected 0 expirations immediately after creation"
        );
    }

    #[test]
    fn create_epoll_returns_valid_fd() {
        let epfd = create_epoll().expect("create_epoll failed");
        assert!(
            epfd.raw() >= 0,
            "expected valid epoll fd, got {}",
            epfd.raw()
        );

        let ret = unsafe { libc::fcntl(epfd.raw(), libc::F_GETFD) };
        assert!(ret >= 0, "fcntl F_GETFD failed on epoll fd");
    }

    #[test]
    fn epoll_add_registers_timerfd() {
        let epfd = create_epoll().expect("create_epoll failed");
        let tfd = create_timerfd(Duration::from_secs(60)).expect("create_timerfd failed");

        let result = epoll_add(epfd.raw(), tfd.raw(), 42);
        assert!(result.is_ok(), "epoll_add failed: {result:?}");
    }

    #[test]
    fn epoll_wait_returns_zero_with_no_events() {
        let epfd = create_epoll().expect("create_epoll failed");
        // SAFETY: zeroing epoll_event is valid — it is a plain C struct.
        let mut events = vec![unsafe { std::mem::zeroed::<libc::epoll_event>() }; 4];

        // Timeout of 0 means return immediately
        let n = epoll_wait(epfd.raw(), &mut events, 0).expect("epoll_wait failed");
        assert_eq!(n, 0, "expected no events with empty epoll and 0 timeout");
    }

    #[test]
    fn create_timerfd_subsecond_interval() {
        let tfd = create_timerfd(Duration::from_millis(100)).expect("create_timerfd failed");
        assert!(tfd.raw() >= 0);
    }

    #[test]
    fn drain_timerfd_returns_nonzero_after_expiration() {
        let tfd = create_timerfd(Duration::from_millis(10)).expect("create_timerfd failed");
        // Wait for at least one expiration
        std::thread::sleep(Duration::from_millis(50));
        let count = drain_timerfd(tfd.raw()).expect("drain_timerfd failed");
        assert!(count >= 1, "expected at least 1 expiration, got {count}");
    }

    #[test]
    fn into_raw_fd_keeps_fd_open() {
        // Documents the console.rs fix: into_raw_fd transfers ownership
        // so the File destructor does NOT close the fd.
        use std::fs::OpenOptions;
        use std::os::unix::io::IntoRawFd;

        let file = OpenOptions::new()
            .read(true)
            .open("/dev/null")
            .expect("failed to open /dev/null");
        let raw = file.into_raw_fd();

        // fd should still be valid after into_raw_fd
        let ret = unsafe { libc::fcntl(raw, libc::F_GETFD) };
        assert!(ret >= 0, "fd should be open after into_raw_fd");

        // Clean up
        unsafe {
            libc::close(raw);
        }
    }
}
