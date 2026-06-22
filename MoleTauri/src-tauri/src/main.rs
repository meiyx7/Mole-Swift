use serde::Serialize;
use std::process::Command;

#[derive(Serialize)]
struct CommandOutput {
    success: bool,
    stdout: String,
    stderr: String,
}

#[derive(Serialize)]
struct UpdateInfo {
    version: String,
    download_url: String,
    notes: String,
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
    if !path_str.is_empty() { args.push(&path_str); }
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

#[tauri::command]
fn check_for_update(current_version: String) -> Result<UpdateInfo, String> {
    let output = Command::new("curl")
        .args(["-s", "https://api.github.com/repos/meiyx7/Mole-Swift/releases/latest"])
        .output()
        .map_err(|e| e.to_string())?;

    let json_str = String::from_utf8_lossy(&output.stdout).to_string();
    let v: serde_json::Value = serde_json::from_str(&json_str).map_err(|e| e.to_string())?;

    let tag = v["tag_name"].as_str().unwrap_or("").trim_start_matches('v');
    let notes = v["body"].as_str().unwrap_or("新版本已发布").to_string();

    if tag <= current_version.as_str() {
        return Err("已是最新版本".to_string());
    }

    // Find the zip asset URL
    let assets = v["assets"].as_array().ok_or("无法获取版本信息")?;
    let zip_url = assets.iter()
        .find(|a| a["name"].as_str().unwrap_or("").ends_with(".zip"))
        .and_then(|a| a["browser_download_url"].as_str())
        .ok_or("未找到下载包")?
        .to_string();

    Ok(UpdateInfo {
        version: tag.to_string(),
        download_url: zip_url,
        notes,
    })
}

#[tauri::command]
fn download_and_install(url: String) -> Result<String, String> {
    let home = std::env::var("HOME").map_err(|e| e.to_string())?;
    let app_path = format!("{}/Applications/Mole.app", home);
    let zip_path = format!("{}/Downloads/Mole-update.zip", home);

    // Download
    let dl = Command::new("curl")
        .args(["-L", "-o", &zip_path, &url])
        .output()
        .map_err(|e| format!("下载失败: {}", e))?;

    if !dl.status.success() {
        return Err(format!("下载失败: {}", String::from_utf8_lossy(&dl.stderr)));
    }

    // Remove old app
    let _ = Command::new("rm")
        .args(["-rf", &app_path])
        .output();

    // Extract
    let ext = Command::new("ditto")
        .args(["-x", "-k", &zip_path, &format!("{}/Applications", home)])
        .output()
        .map_err(|e| format!("解压失败: {}", e))?;

    if !ext.status.success() {
        return Err(format!("解压失败: {}", String::from_utf8_lossy(&ext.stderr)));
    }

    // Cleanup
    let _ = Command::new("rm").arg(&zip_path).output();

    Ok(app_path)
}

#[tauri::command]
fn restart_app() {
    let home = std::env::var("HOME").unwrap_or_default();
    let app_path = format!("{}/Applications/Mole.app", home);
    let _ = Command::new("open").arg(&app_path).output();
    std::process::exit(0);
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
            check_for_update,
            download_and_install,
            restart_app,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
