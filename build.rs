use std::env;
use std::fs;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-changed=packaging/icons/plainvideo.ico");
    println!("cargo:rerun-if-env-changed=PATH");

    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") {
        return;
    }
    if env::var("CARGO_CFG_TARGET_ENV").as_deref() != Ok("msvc") {
        panic!("PlainVideo's Windows icon resource currently requires the MSVC toolchain");
    }

    let manifest_dir = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").unwrap());
    let icon_path = manifest_dir.join("packaging/icons/plainvideo.ico");
    let icon_path = icon_path
        .canonicalize()
        .expect("PlainVideo icon asset is missing");
    let output_dir = PathBuf::from(env::var_os("OUT_DIR").unwrap());
    let rc_path = output_dir.join("plainvideo.rc");
    let resource_path = output_dir.join("plainvideo.res");
    let escaped_icon_path = icon_path.to_string_lossy().replace('\\', "\\\\");

    fs::write(&rc_path, format!("101 ICON \"{escaped_icon_path}\"\r\n"))
        .expect("PlainVideo could not write its Windows resource script");

    let output = Command::new("rc.exe")
        .arg("/nologo")
        .arg(format!("/fo{}", resource_path.display()))
        .arg(&rc_path)
        .output()
        .expect("PlainVideo needs Windows SDK rc.exe to embed its application icon");
    if !output.status.success() {
        panic!(
            "PlainVideo could not compile its Windows icon resource: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }

    println!(
        "cargo:rustc-link-arg-bin=plainvideo={}",
        resource_path.display()
    );
}
