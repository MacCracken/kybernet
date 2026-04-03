//! Kybernet — PID 1 helmsman for AGNOS.
//!
//! The actual init process that boots AGNOS. Uses the argonaut library
//! for service management, boot sequencing, and health checks. Handles
//! the unsafe kernel interactions that argonaut cannot.

mod cgroup;
mod console;
mod eventloop;
mod mount;
mod privdrop;
mod reaper;
mod signals;

use std::collections::VecDeque;
use std::path::Path;
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use tracing::{error, info, warn};

use argonaut::{
    ArgonautConfig, ArgonautInit, BootStage, HealthTracker, NotifyListener, ShutdownType,
};

// Event loop token constants
const TOKEN_SIGNAL: u64 = 1;
const TOKEN_HEALTH: u64 = 2;
const TOKEN_WATCHDOG: u64 = 3;
const TOKEN_RESTART: u64 = 4;

/// A pending service restart with a scheduled time.
struct PendingRestart {
    service_name: String,
    restart_at: Instant,
}

/// Configuration file path.
const CONFIG_PATH: &str = "/etc/argonaut/config.json";

/// Notify socket path.
const NOTIFY_SOCKET: &str = "/run/argonaut/notify";

fn main() {
    // PID 1 must never panic — catch and log everything
    match run() {
        Ok(()) => {}
        Err(e) => {
            eprintln!("kybernet fatal: {e:#}");
            // As PID 1, we can't exit — drop to emergency shell
            drop_to_emergency();
        }
    }
}

/// Write directly to kernel log ring buffer (visible on serial console).
fn kmsg(msg: &str) {
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new().write(true).open("/dev/kmsg") {
        let _ = writeln!(f, "kybernet: {msg}");
    }
}

fn run() -> Result<()> {
    // Immediate output to confirm we're running (before ANY initialization)
    {
        use std::io::Write;
        let _ = std::io::stderr().write_all(b"kybernet: PID 1 starting\n");
    }

    // Phase 1: Mount devtmpfs so /dev/kmsg exists
    mount::mount_devtmpfs().unwrap_or_else(|e| {
        use std::io::Write;
        let _ = writeln!(std::io::stderr(), "kybernet: devtmpfs mount failed: {e}");
    });
    kmsg("phase 1: devtmpfs mounted");

    // Phase 2: Logging
    init_logging();
    kmsg("phase 2: logging initialized");
    info!(pid = std::process::id(), "kybernet starting");

    // Phase 3: Console setup — redirect stdio to serial/console
    console::setup_console().unwrap_or_else(|e| {
        kmsg(&format!("console setup failed: {e}"));
    });
    kmsg("phase 3: console setup done");

    // Phase 4: Mount remaining essential filesystems
    mount::mount_essential_filesystems()?;
    kmsg("phase 4: filesystems mounted");

    // Phase 5: Signal handling
    let signal_fd = signals::setup_signals()?;
    kmsg("phase 5: signals configured");

    // Phase 6: Load configuration
    let config = load_config()?;
    kmsg(&format!(
        "phase 6: config loaded (mode={})",
        config.boot_mode
    ));

    // Phase 7: Initialize argonaut
    let tmpfiles = config.tmpfiles.clone();
    let mut init = ArgonautInit::new(config);
    let mut tracker = HealthTracker::new();
    kmsg("phase 7: argonaut initialized");

    // Phase 8: Execute tmpfiles
    if !tmpfiles.is_empty() {
        let cmds = argonaut::generate_tmpfile_commands(&tmpfiles);
        if let Err(e) = argonaut::run_command_sequence(&cmds) {
            warn!(error = %e, "some tmpfile entries failed");
        }
        init.mark_step_complete(BootStage::StartSecurity);
    }

    // Phase 9: Boot stages
    run_boot_stages(&mut init)?;

    // Phase 8: Notify socket — bind BEFORE starting services so services inherit NOTIFY_SOCKET
    let notify_listener =
        NotifyListener::bind(Path::new(NOTIFY_SOCKET)).context("failed to bind notify socket")?;
    // SAFETY: set_var is unsafe in Rust 2024 edition. We call it before
    // spawning any threads, so there's no data race on the environment.
    unsafe {
        std::env::set_var("NOTIFY_SOCKET", NOTIFY_SOCKET);
    }

    // Phase 9: Start services (wave-based)
    start_services(&mut init)?;

    // Phase 12: Event loop
    kmsg("entering main event loop");
    info!("entering main event loop");
    event_loop(&mut init, &mut tracker, &signal_fd, &notify_listener)?;

    Ok(())
}

/// Initialize tracing/logging.
fn init_logging() {
    use tracing_subscriber::EnvFilter;
    use tracing_subscriber::fmt;
    use tracing_subscriber::prelude::*;

    let filter = EnvFilter::try_from_env("KYBERNET_LOG").unwrap_or_else(|_| EnvFilter::new("info"));

    let _ = tracing_subscriber::registry()
        .with(fmt::layer().with_target(true).with_thread_ids(false))
        .with(filter)
        .try_init();
}

/// Load argonaut configuration from disk or use defaults.
fn load_config() -> Result<ArgonautConfig> {
    load_config_from(Path::new(CONFIG_PATH))
}

/// Load argonaut configuration from a specific path, or return defaults if missing.
fn load_config_from(config_path: &Path) -> Result<ArgonautConfig> {
    if config_path.exists() {
        let content = std::fs::read_to_string(config_path)
            .with_context(|| format!("failed to read {}", config_path.display()))?;
        let config: ArgonautConfig = serde_json::from_str(&content)
            .with_context(|| format!("failed to parse {}", config_path.display()))?;
        Ok(config)
    } else {
        info!("no config file found, using defaults");
        Ok(ArgonautConfig::default())
    }
}

/// Run boot stages (mount filesystems, verify rootfs, etc.)
fn run_boot_stages(init: &mut ArgonautInit) -> Result<()> {
    info!("executing boot stages");

    for step in &init.boot_sequence {
        info!(stage = %step.stage, description = %step.description, "boot stage");
    }

    // Mark early stages as complete (we've already mounted filesystems)
    init.mark_step_complete(BootStage::MountFilesystems);
    init.mark_step_complete(BootStage::StartDeviceManager);

    // Edge boot: rootfs verification + LUKS
    if init.config.verify_on_boot {
        info!("executing edge boot: rootfs lockdown + dm-verity + LUKS");

        // Run readonly rootfs lockdown commands
        let rootfs_cmds = argonaut::configure_readonly_rootfs();
        if let Err(e) = argonaut::run_command_sequence(&rootfs_cmds) {
            warn!(error = %e, "readonly rootfs lockdown failed — continuing");
        }

        // Execute the full edge boot sequence
        let edge_result = argonaut::execute_edge_boot(
            &init.config.edge_boot,
            "/dev/sda1",                         // TODO: make configurable
            "/dev/sda2",                         // TODO: make configurable
            &init.config.edge_boot.pcr_bindings, // used as root hash placeholder
            "/dev/sda3",                         // TODO: make configurable
        );

        if edge_result.verity_verified {
            info!("dm-verity verification passed");
        } else if init.config.boot_mode == argonaut::BootMode::Edge {
            // Verity failure is fatal in edge mode
            init.mark_step_failed(
                BootStage::VerifyRootfs,
                "dm-verity verification failed in edge mode".to_string(),
            );
            error!("dm-verity failed in edge mode — dropping to emergency shell");
            drop_to_emergency();
        } else {
            warn!("dm-verity verification failed — continuing in non-edge mode");
        }

        if !edge_result.errors.is_empty() {
            for err in &edge_result.errors {
                warn!(error = %err, "edge boot error");
            }
        }

        init.mark_step_complete(BootStage::VerifyRootfs);
    } else {
        init.mark_step_complete(BootStage::VerifyRootfs);
    }

    init.mark_step_complete(BootStage::StartSecurity);

    Ok(())
}

/// Start services using wave-based parallel startup.
fn start_services(init: &mut ArgonautInit) -> Result<()> {
    let waves = init.boot_execution_plan_waves()?;
    info!(waves = waves.len(), "starting services");

    for (wave_idx, wave) in waves.iter().enumerate() {
        let names: Vec<&str> = wave.iter().map(|(n, _)| n.as_str()).collect();
        info!(wave = wave_idx, services = ?names, "starting wave");

        for (name, _spec) in wave {
            kmsg(&format!("starting service: {name}"));
            match init.start_service(name) {
                Ok(pid) => {
                    kmsg(&format!("service started: {name} (pid={pid})"));
                    info!(service = %name, pid = pid, "service started");
                    // Move to cgroup
                    if pid > 0
                        && let Err(e) = cgroup::move_to_cgroup(name, pid)
                    {
                        warn!(service = %name, error = %e, "cgroup setup failed");
                    }
                }
                Err(e) => {
                    error!(service = %name, error = %e, "failed to start service");
                    if init.should_drop_to_emergency() {
                        error!("critical boot failure — dropping to emergency shell");
                        drop_to_emergency();
                    }
                }
            }
        }
    }

    // Mark boot complete — even if some services failed, PID 1 must reach the event loop.
    // Individual service failures are tracked separately via argonaut's service state.
    let failed = init.failed_steps();
    if !failed.is_empty() {
        warn!(
            count = failed.len(),
            "some boot steps have failures — continuing to event loop"
        );
    }
    init.mark_step_complete(BootStage::StartDatabaseServices);
    init.mark_step_complete(BootStage::StartAgentRuntime);
    init.mark_step_complete(BootStage::BootComplete);

    if let Some(ms) = init.boot_duration_ms() {
        info!(duration_ms = ms, "boot complete");
    }

    Ok(())
}

/// Main event loop — runs until shutdown.
fn event_loop(
    init: &mut ArgonautInit,
    tracker: &mut HealthTracker,
    signal_fd: &nix::sys::signalfd::SignalFd,
    notify_listener: &NotifyListener,
) -> Result<()> {
    let epfd = eventloop::create_epoll()?;

    // Register signalfd
    let sig_raw = signals::signalfd_raw(signal_fd);
    eventloop::epoll_add(epfd.raw(), sig_raw, TOKEN_SIGNAL)?;

    // Health check timer (10 seconds)
    let health_tfd = eventloop::create_timerfd(Duration::from_secs(10))?;
    eventloop::epoll_add(epfd.raw(), health_tfd.raw(), TOKEN_HEALTH)?;

    // Watchdog timer (30 seconds)
    let watchdog_tfd = eventloop::create_timerfd(Duration::from_secs(30))?;
    eventloop::epoll_add(epfd.raw(), watchdog_tfd.raw(), TOKEN_WATCHDOG)?;

    // Restart check timer (1 second — checks pending restart queue)
    let restart_tfd = eventloop::create_timerfd(Duration::from_secs(1))?;
    eventloop::epoll_add(epfd.raw(), restart_tfd.raw(), TOKEN_RESTART)?;

    // Pending restart queue — services waiting for their backoff delay
    let mut pending_restarts: VecDeque<PendingRestart> = VecDeque::new();

    // SAFETY: zeroing epoll_event is valid — it is a plain C struct with no invariants.
    let mut events = vec![unsafe { std::mem::zeroed::<libc::epoll_event>() }; 8];

    loop {
        let n = eventloop::epoll_wait(epfd.raw(), &mut events, -1)?;

        for event in events.iter().take(n) {
            let token = event.u64;

            match token {
                TOKEN_SIGNAL => {
                    // Drain all queued signals (multiple may arrive between epoll_wait calls)
                    while let Ok(Some(sig_info)) = signal_fd.read_signal() {
                        handle_signal(init, sig_info.ssi_signo, &mut pending_restarts)?;
                    }
                }
                TOKEN_HEALTH => {
                    eventloop::drain_timerfd(health_tfd.raw())?;
                    let results = init.poll_health(tracker);
                    // Check if any services need restarting based on health failures
                    for result in &results {
                        if !result.passed
                            && let Some(svc) = init.get_service(&result.service)
                            && tracker.failure_count(&result.service)
                                >= svc
                                    .definition
                                    .health_check
                                    .as_ref()
                                    .map_or(3, |hc| hc.retries)
                        {
                            warn!(
                                service = %result.service,
                                "health threshold exceeded — scheduling restart"
                            );
                            pending_restarts.push_back(PendingRestart {
                                service_name: result.service.clone(),
                                restart_at: Instant::now() + Duration::from_secs(1),
                            });
                        }
                    }
                }
                TOKEN_WATCHDOG => {
                    eventloop::drain_timerfd(watchdog_tfd.raw())?;
                    let killed = init.enforce_watchdog();
                    for name in &killed {
                        warn!(service = %name, "watchdog killed service — scheduling restart");
                        pending_restarts.push_back(PendingRestart {
                            service_name: name.clone(),
                            restart_at: Instant::now() + Duration::from_secs(2),
                        });
                    }
                }
                TOKEN_RESTART => {
                    eventloop::drain_timerfd(restart_tfd.raw())?;
                    process_pending_restarts(init, &mut pending_restarts);
                }
                _ => {}
            }
        }

        // Drain notify socket
        let messages = notify_listener.drain(64);
        for msg in &messages {
            if msg.ready {
                info!(status = ?msg.status, "service reported READY=1");
            }
            if msg.watchdog {
                // Service is alive — update its health check timestamp
                // (handled by argonaut's poll_health)
            }
        }
    }
}

/// Process pending restarts whose delay has elapsed.
///
/// Scans the entire queue rather than stopping at the first future item,
/// because restarts are pushed with varying delays and the queue is not
/// sorted by `restart_at`.
fn process_pending_restarts(init: &mut ArgonautInit, pending: &mut VecDeque<PendingRestart>) {
    let now = Instant::now();
    let mut ready: Vec<String> = Vec::new();
    pending.retain(|r| {
        if r.restart_at <= now {
            ready.push(r.service_name.clone());
            false
        } else {
            true
        }
    });
    for name in &ready {
        kmsg(&format!("executing restart: {name}"));
        match init.restart_service(name, Duration::from_secs(5)) {
            Ok(pid) => {
                kmsg(&format!("service restarted: {name} (pid={pid})"));
                if pid > 0
                    && let Err(e) = cgroup::move_to_cgroup(name, pid)
                {
                    warn!(service = %name, error = %e, "cgroup setup after restart failed");
                }
            }
            Err(e) => {
                error!(service = %name, error = %e, "delayed restart failed");
            }
        }
    }
}

/// Handle a signal received via signalfd.
fn handle_signal(
    init: &mut ArgonautInit,
    signo: u32,
    pending_restarts: &mut VecDeque<PendingRestart>,
) -> Result<()> {
    match signo as i32 {
        libc::SIGCHLD => {
            // Reap tracked services FIRST (before waitpid(-1) steals them)
            let service_exits = init.reap_services();
            // Then reap any remaining zombies (orphaned processes)
            let _reaped = reaper::reap_zombies();
            for (name, code, action) in &service_exits {
                kmsg(&format!(
                    "service exited: {name} (code={code}, action={action:?})"
                ));
                info!(
                    service = %name,
                    exit_code = code,
                    action = ?action,
                    "service exited"
                );
                // Clean up cgroup
                if let Err(e) = cgroup::kill_cgroup(name) {
                    warn!(service = %name, error = %e, "cgroup cleanup failed");
                }
                let _ = cgroup::remove_service_cgroup(name);

                // Schedule restart if needed (non-blocking, via timerfd)
                if let argonaut::CrashAction::Restart { delay_ms } = action {
                    kmsg(&format!("scheduling restart: {name} (delay={delay_ms}ms)"));
                    pending_restarts.push_back(PendingRestart {
                        service_name: name.clone(),
                        restart_at: Instant::now() + Duration::from_millis(*delay_ms),
                    });
                }
                if let argonaut::CrashAction::GiveUp { reason } = action {
                    kmsg(&format!("giving up on: {name} ({reason})"));
                }
            }
        }
        libc::SIGTERM | libc::SIGINT => {
            info!("shutdown signal received");
            shutdown(init, ShutdownType::Poweroff);
        }
        libc::SIGPWR => {
            warn!("power failure signal — initiating emergency shutdown");
            shutdown(init, ShutdownType::Poweroff);
        }
        libc::SIGHUP => {
            info!("SIGHUP received — reloading configuration");
            match load_config() {
                Ok(new_config) => {
                    // Register any new services from the reloaded config
                    for svc_def in &new_config.services {
                        if init.get_service(&svc_def.name).is_none() {
                            info!(service = %svc_def.name, "registering new service from reloaded config");
                            init.register_service(svc_def.clone());
                        }
                    }
                    info!("configuration reloaded");
                }
                Err(e) => {
                    error!(error = %e, "failed to reload configuration");
                }
            }
        }
        _ => {
            info!(signal = signo, "unhandled signal");
        }
    }
    Ok(())
}

/// Execute shutdown sequence.
///
/// This function does not return — it ends with a `reboot` syscall.
fn shutdown(init: &mut ArgonautInit, shutdown_type: ShutdownType) -> ! {
    kmsg(&format!("shutdown: {shutdown_type}"));
    info!(shutdown_type = %shutdown_type, "executing shutdown");

    match init.plan_shutdown(shutdown_type) {
        Ok(plan) => {
            let _result = init.execute_shutdown(plan);
        }
        Err(e) => {
            error!(error = %e, "shutdown plan failed");
        }
    }

    // Sync filesystems
    // SAFETY: sync() is always safe to call.
    unsafe {
        libc::sync();
    }

    info!("shutdown complete");

    // Final kernel action
    // SAFETY: reboot syscall — valid command constants for the running kernel.
    match shutdown_type {
        ShutdownType::Poweroff => unsafe {
            libc::reboot(libc::RB_POWER_OFF);
        },
        ShutdownType::Reboot => unsafe {
            libc::reboot(libc::RB_AUTOBOOT);
        },
        ShutdownType::Halt => unsafe {
            libc::reboot(libc::RB_HALT_SYSTEM);
        },
        _ => {
            warn!(shutdown_type = %shutdown_type, "unsupported shutdown type, halting");
            unsafe {
                libc::reboot(libc::RB_HALT_SYSTEM);
            }
        }
    }

    // Fallback: reboot should not return, but if it does (not PID 1), exit
    std::process::exit(0);
}

/// Drop to emergency shell when boot fails critically.
///
/// If `require_auth` is configured, prompts for password before granting access.
fn drop_to_emergency() {
    eprintln!("\n*** KYBERNET EMERGENCY ***");
    eprintln!("Critical boot failure. Dropping to emergency shell.");

    // Check emergency shell authentication
    let shell_config = argonaut::EmergencyShellConfig::default();
    if shell_config.require_auth {
        eprintln!("Authentication required for emergency shell access.");
        // Read password from console
        let mut password = String::new();
        eprint!("Password: ");
        if std::io::stdin().read_line(&mut password).is_ok() {
            let password = password.trim();
            if !argonaut::verify_emergency_auth(&shell_config, password) {
                eprintln!("Authentication failed. Rebooting.");
                // SAFETY: reboot after failed auth
                unsafe {
                    libc::reboot(libc::RB_AUTOBOOT);
                }
                loop {
                    unsafe {
                        libc::pause();
                    }
                }
            }
        }
    }

    eprintln!("Type 'exit' to attempt reboot.\n");

    // Display the emergency banner
    eprint!("{}", shell_config.banner);

    // Try to exec agnoshi
    let shell = std::process::Command::new(shell_config.shell_path.as_os_str())
        .envs(&shell_config.environment)
        .env("PS1", "kybernet-emergency# ")
        .status();

    match shell {
        Ok(status) => {
            eprintln!("Emergency shell exited with {status}. Rebooting.");
        }
        Err(_) => {
            // Fallback to /bin/sh
            let _ = std::process::Command::new("/bin/sh")
                .env("PS1", "kybernet-emergency# ")
                .status();
        }
    }

    // Reboot after emergency shell exits
    // SAFETY: reboot syscall to restart the system after emergency shell.
    unsafe {
        libc::reboot(libc::RB_AUTOBOOT);
    }

    // If reboot fails (not PID 1, or permission denied), halt
    loop {
        // SAFETY: pause() is always safe — blocks until a signal is delivered.
        unsafe {
            libc::pause();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn load_config_missing_file_returns_default() {
        let dir = tempfile::tempdir().expect("failed to create tempdir");
        let path = dir.path().join("nonexistent.json");
        let config =
            load_config_from(&path).expect("load_config_from should return Ok for missing file");
        // Default config should have sensible values — just verify we got one
        let default = ArgonautConfig::default();
        assert_eq!(config.boot_mode, default.boot_mode);
    }

    #[test]
    fn load_config_valid_json() {
        let dir = tempfile::tempdir().expect("failed to create tempdir");
        let path = dir.path().join("config.json");
        let mut f = std::fs::File::create(&path).expect("failed to create config file");
        // Write minimal valid ArgonautConfig JSON — use default serialized
        let default = ArgonautConfig::default();
        let json =
            serde_json::to_string_pretty(&default).expect("failed to serialize default config");
        f.write_all(json.as_bytes())
            .expect("failed to write config");
        drop(f);

        let config = load_config_from(&path).expect("load_config_from should parse valid JSON");
        assert_eq!(config.boot_mode, default.boot_mode);
    }

    #[test]
    fn load_config_invalid_json_returns_err() {
        let dir = tempfile::tempdir().expect("failed to create tempdir");
        let path = dir.path().join("bad.json");
        std::fs::write(&path, "not valid json {{{").expect("failed to write bad config");

        let result = load_config_from(&path);
        assert!(result.is_err(), "expected Err for invalid JSON");
    }
}
