//! kybernet benchmark — Rust comparison
//!
//! Standalone Rust program that benchmarks the same operations as bench.cyr
//! for direct Cyrius-vs-Rust comparison. Uses only std (no libc/nix/argonaut).
//!
//! Build: rustc -O -o build/kybernet_bench_rs benches/rust_compare.rs
//! Run:   ./build/kybernet_bench_rs

#![allow(unused_unsafe)]

use std::time::Instant;
use std::arch::asm;

// ================================================================
// Benchmark harness
// ================================================================

fn report(name: &str, elapsed_ns: u128, iterations: u64) {
    let per_op = elapsed_ns / iterations as u128;
    let total_ms = elapsed_ns / 1_000_000;
    println!("  {name}: {per_op} ns/op ({iterations} iters, {total_ms} ms total)");
}

macro_rules! bench {
    ($name:expr, $iters:expr, $body:expr) => {{
        let start = Instant::now();
        for _ in 0..$iters {
            std::hint::black_box($body);
        }
        let elapsed = start.elapsed().as_nanos();
        report($name, elapsed, $iters);
    }};
}

// ================================================================
// Raw syscall (x86_64 Linux)
// ================================================================

#[inline(always)]
unsafe fn syscall0(nr: i64) -> i64 {
    let ret: i64;
    asm!(
        "syscall",
        in("rax") nr,
        out("rcx") _,
        out("r11") _,
        lateout("rax") ret,
    );
    ret
}

// ================================================================
// Equivalent operations
// ================================================================

// --- Syscall baselines ---

fn raw_getpid() -> i64 {
    unsafe { syscall0(39) } // SYS_getpid
}

fn raw_getuid() -> i64 {
    unsafe { syscall0(102) } // SYS_getuid
}

fn is_root() -> bool {
    unsafe { syscall0(107) == 0 } // SYS_geteuid
}

// --- Signal classification ---

const SIGCHLD: i32 = 17;
const SIGTERM: i32 = 15;
const SIGINT: i32 = 2;
const SIGHUP: i32 = 1;
const SIGPWR: i32 = 30;

#[derive(Clone, Copy, PartialEq)]
#[repr(u8)]
enum SigClass {
    None = 0,
    Child = 1,
    Term = 2,
    Int = 3,
    Hup = 4,
    Pwr = 5,
}

#[inline(never)]
fn classify_signal(sig: i32) -> SigClass {
    match sig {
        SIGCHLD => SigClass::Child,
        SIGTERM => SigClass::Term,
        SIGINT => SigClass::Int,
        SIGHUP => SigClass::Hup,
        SIGPWR => SigClass::Pwr,
        _ => SigClass::None,
    }
}

#[inline(never)]
fn is_handled_signal(sig: i32) -> bool {
    matches!(sig, SIGCHLD | SIGTERM | SIGINT | SIGHUP | SIGPWR)
}

// --- Sigset operations ---

struct SigSet(u64);

impl SigSet {
    fn new() -> Self { SigSet(0) }
    fn add(&mut self, sig: i32) { self.0 |= 1 << (sig - 1); }
    fn has(&self, sig: i32) -> bool { (self.0 & (1 << (sig - 1))) != 0 }
}

// --- Wait status macros ---

#[inline(never)] fn wifexited(status: i32) -> bool { (status & 0x7f) == 0 }
#[inline(never)] fn wexitstatus(status: i32) -> i32 { (status >> 8) & 0xff }
#[inline(never)] fn wifsignaled(status: i32) -> bool { let s = status & 0x7f; s > 0 && s != 0x7f }
#[inline(never)] fn wtermsig(status: i32) -> i32 { status & 0x7f }

// --- Epoll event creation ---

#[repr(C)]
struct EpollEvent {
    events: u32,
    data: u64,
}

#[inline(never)]
fn epoll_event_new(events: u32, data: u64) -> EpollEvent {
    EpollEvent { events, data }
}

// --- Timerspec creation ---

#[repr(C)]
struct Timerspec {
    interval_sec: i64,
    interval_nsec: i64,
    value_sec: i64,
    value_nsec: i64,
}

#[inline(never)]
fn timerspec_new(interval: i64, initial: i64) -> Timerspec {
    Timerspec {
        interval_sec: interval,
        interval_nsec: 0,
        value_sec: initial,
        value_nsec: 0,
    }
}

// --- Notify parse ---

#[derive(Clone, Copy, PartialEq)]
#[repr(u8)]
enum NotifyType {
    Unknown = 0,
    Ready = 1,
    Stopping = 2,
    Watchdog = 3,
    Status = 4,
    Reloading = 5,
}

#[inline(never)]
fn notify_parse(msg: &[u8]) -> NotifyType {
    if msg.starts_with(b"READY=1") { return NotifyType::Ready; }
    if msg.starts_with(b"STOPPING=1") { return NotifyType::Stopping; }
    if msg.starts_with(b"WATCHDOG=1") { return NotifyType::Watchdog; }
    if msg.starts_with(b"RELOADING=1") { return NotifyType::Reloading; }
    if msg.starts_with(b"STATUS=") { return NotifyType::Status; }
    NotifyType::Unknown
}

#[inline(never)]
fn notify_status_value(msg: &[u8]) -> Option<&[u8]> {
    if msg.starts_with(b"STATUS=") {
        Some(&msg[7..])
    } else {
        None
    }
}

// --- Cgroup path building ---

fn cgroup_path(service: &str) -> String {
    format!("/sys/fs/cgroup/kybernet.slice/{service}")
}

fn cgroup_file(service: &str, filename: &str) -> String {
    format!("/sys/fs/cgroup/kybernet.slice/{service}/{filename}")
}

// --- is_mounted ---

fn is_mounted(target: &str) -> bool {
    let Ok(contents) = std::fs::read_to_string("/proc/self/mounts") else {
        return false;
    };
    for line in contents.lines() {
        let mut parts = line.split_whitespace();
        if let Some(mount_point) = parts.nth(1) {
            if mount_point == target {
                return true;
            }
        }
    }
    false
}

// --- Seccomp filter building ---

fn bpf_insn(buf: &mut [u8], offset: usize, code: u16, jt: u8, jf: u8, k: u32) {
    buf[offset..offset+2].copy_from_slice(&code.to_le_bytes());
    buf[offset+2] = jt;
    buf[offset+3] = jf;
    buf[offset+4..offset+8].copy_from_slice(&k.to_le_bytes());
}

fn seccomp_build_filter(allowed: &[u32]) -> Vec<u8> {
    let num = allowed.len();
    let num_insns = num + 3;
    let mut filter = vec![0u8; num_insns * 8];

    // LD syscall nr
    bpf_insn(&mut filter, 0, 0x20, 0, 0, 0);

    let mut off = 8;
    for (i, &nr) in allowed.iter().enumerate() {
        let remaining = num - i - 1;
        let jt = (remaining + 1) as u8;
        bpf_insn(&mut filter, off, 0x15, jt, 0, nr);
        off += 8;
    }

    // Default: KILL
    bpf_insn(&mut filter, off, 0x06, 0, 0, 0x80000000);
    off += 8;

    // ALLOW
    bpf_insn(&mut filter, off, 0x06, 0, 0, 0x7fff0000);

    filter
}

static BASIC_SERVICE_SYSCALLS: &[u32] = &[
    0, 1, 3, 5, 8, 9, 10, 11, 12, 15, 16, 32, 33, 41, 42, 43, 44, 45,
    49, 50, 60, 72, 131, 158, 186, 202, 218, 228, 231, 257, 273, 291,
    232, 233, 293, 318, 334,
];

// --- Sandbox rule building ---

struct SandboxRule {
    _path: &'static str,
    _access: u8,
}

fn sandbox_basic_service() -> Vec<SandboxRule> {
    vec![
        SandboxRule { _path: "/usr", _access: 3 },
        SandboxRule { _path: "/lib", _access: 1 },
        SandboxRule { _path: "/etc", _access: 1 },
        SandboxRule { _path: "/tmp", _access: 2 },
        SandboxRule { _path: "/var", _access: 2 },
        SandboxRule { _path: "/run", _access: 2 },
    ]
}

// --- String builder equivalent ---

fn str_builder_path() -> String {
    let mut s = String::new();
    s.push_str("/sys/fs/cgroup/");
    s.push_str("kybernet.slice/");
    s.push_str("myservice");
    s
}

fn str_builder_int_mix() -> String {
    let mut s = String::new();
    s.push_str("reaped pid=");
    s.push_str(&12345.to_string());
    s.push_str(" exit=");
    s.push_str(&0.to_string());
    s
}

// --- Result/Option ---

#[inline(never)] fn result_ok() -> Result<i64, i64> { Ok(42) }
#[inline(never)] fn result_err() -> Result<i64, i64> { Err(22) }
#[inline(never)] fn option_some() -> Option<i64> { Some(99) }

// ================================================================
// Main
// ================================================================

fn main() {
    println!("===================================================");
    println!("  kybernet benchmark — Rust");
    println!("===================================================");
    println!();

    // --- Syscall baselines ---
    println!("Syscall baselines:");
    bench!("getpid", 1_000_000, raw_getpid());
    bench!("getuid", 1_000_000, raw_getuid());
    bench!("is_root", 1_000_000, is_root());
    println!();

    // --- Signal handling ---
    println!("Signal handling:");
    bench!("classify_signal", 1_000_000, classify_signal(std::hint::black_box(SIGCHLD)));
    bench!("is_handled_signal", 1_000_000, is_handled_signal(std::hint::black_box(SIGCHLD)));
    bench!("sigset_new+add+has", 1_000_000, {
        let mut s = SigSet::new();
        s.add(std::hint::black_box(SIGCHLD));
        s.add(std::hint::black_box(SIGTERM));
        s.has(std::hint::black_box(SIGCHLD))
    });
    println!();

    // --- Event loop ---
    println!("Event loop:");
    bench!("epoll_event_new", 1_000_000, epoll_event_new(std::hint::black_box(1), std::hint::black_box(42)));
    bench!("timerspec_new", 1_000_000, timerspec_new(std::hint::black_box(10), std::hint::black_box(1)));
    bench!("W* macros (4 calls)", 1_000_000, {
        wifexited(std::hint::black_box(0));
        wexitstatus(std::hint::black_box(256));
        wifsignaled(std::hint::black_box(9));
        wtermsig(std::hint::black_box(9))
    });
    println!();

    // --- Notify ---
    println!("Notify socket:");
    bench!("notify_parse(READY)", 1_000_000, notify_parse(std::hint::black_box(b"READY=1")));
    bench!("notify_parse+value", 1_000_000, {
        notify_parse(std::hint::black_box(b"STATUS=running ok"));
        notify_status_value(std::hint::black_box(b"STATUS=running ok"))
    });
    println!();

    // --- Cgroup ---
    println!("Cgroup management:");
    bench!("cgroup_path", 100_000, cgroup_path("myservice"));
    bench!("cgroup_file", 100_000, cgroup_file("myservice", "cgroup.procs"));
    println!();

    // --- Mount ---
    println!("Mount operations:");
    bench!("is_mounted(/proc)", 10_000, is_mounted("/proc"));
    println!();

    // --- Security ---
    println!("Security (pre_exec):");
    bench!("seccomp_build(5 syscalls)", 50_000, seccomp_build_filter(&[0, 1, 3, 60, 231]));
    bench!("seccomp_basic_service+build", 5_000, seccomp_build_filter(BASIC_SERVICE_SYSCALLS));
    bench!("sandbox_basic_service", 50_000, sandbox_basic_service());
    println!();

    // --- String building ---
    println!("String operations:");
    bench!("str_builder(3 segments)", 100_000, str_builder_path());
    bench!("str_builder(cstr+int mix)", 100_000, str_builder_int_mix());
    println!();

    // --- Tagged types ---
    println!("Tagged types:");
    bench!("Ok+is_ok", 1_000_000, { let r = result_ok(); std::hint::black_box(r.is_ok()) });
    bench!("Err+is_err_result", 1_000_000, { let r = result_err(); std::hint::black_box(r.is_err()) });
    bench!("Some+is_some+unwrap", 1_000_000, { let o = option_some(); std::hint::black_box(o.is_some()); std::hint::black_box(o.unwrap()) });
    println!();

    // --- Collections ---
    println!("Collections:");
    bench!("vec(push*3+get*2+len)", 100_000, {
        let mut v = Vec::new();
        v.push(std::hint::black_box(1i64));
        v.push(std::hint::black_box(2));
        v.push(std::hint::black_box(3));
        std::hint::black_box(v[0]);
        std::hint::black_box(v[2]);
        v.len()
    });
    println!();

    println!("done");
}
