use serde::Serialize;
use std::process::Command;

#[derive(Serialize)]
struct CommandOutput {
    success: bool,
    stdout: String,
    stderr: String,
}

fn run_mo(args: &[&str]) -> CommandOutput {
    let output = Command::new("mo").args(args).output();

    match output {
        Ok(o) => CommandOutput {
            success: o.status.success(),
            stdout: String::from_utf8_lossy(&o.stdout).to_string(),
            stderr: String::from_utf8_lossy(&o.stderr).to_string(),
        },
        Err(e) => CommandOutput {
            success: false,
            stdout: String::new(),
            stderr: e.to_string(),
        },
    }
}

#[tauri::command]
fn run_clean(dry_run: bool, verbose: bool) -> CommandOutput {
    let mut args = vec!["clean"];
    if dry_run { args.push("--dry-run"); }
    if verbose { args.push("--verbose"); }
    run_mo(&args)
}

#[tauri::command]
fn run_analyze(path: Option<String>) -> CommandOutput {
    let mut args = vec!["analyze", "--json"];
    let path_str = path.unwrap_or_default();
    if !path_str.is_empty() {
        args.push(&path_str);
    }
    run_mo(&args)
}

#[tauri::command]
fn run_status(json: bool) -> CommandOutput {
    let mut args = vec!["status"];
    if json { args.push("--json"); }
    run_mo(&args)
}

#[tauri::command]
fn run_optimize(dry_run: bool) -> CommandOutput {
    let mut args = vec!["optimize"];
    if dry_run { args.push("--dry-run"); }
    run_mo(&args)
}

#[tauri::command]
fn run_uninstall(dry_run: bool) -> CommandOutput {
    let mut args = vec!["uninstall"];
    if dry_run { args.push("--dry-run"); }
    run_mo(&args)
}

#[tauri::command]
fn run_purge(dry_run: bool) -> CommandOutput {
    let mut args = vec!["purge"];
    if dry_run { args.push("--dry-run"); }
    run_mo(&args)
}

#[tauri::command]
fn run_installer(dry_run: bool) -> CommandOutput {
    let mut args = vec!["installer"];
    if dry_run { args.push("--dry-run"); }
    run_mo(&args)
}

#[tauri::command]
fn get_mole_version() -> CommandOutput {
    run_mo(&["--version"])
}

#[tauri::command]
fn open_finder(path: String) {
    let _ = Command::new("open").arg("-R").arg(&path).output();
}

#[tauri::command]
fn copy_to_clipboard(text: String) {
    let _ = Command::new("pbcopy").stdin(std::process::Stdio::piped()).spawn()
        .and_then(|mut child| {
            use std::io::Write;
            child.stdin.as_mut().unwrap().write_all(text.as_bytes())
        });
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
fn main() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            run_clean,
            run_analyze,
            run_status,
            run_optimize,
            run_uninstall,
            run_purge,
            run_installer,
            get_mole_version,
            open_finder,
            copy_to_clipboard,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
