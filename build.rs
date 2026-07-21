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
    let major = env::var("CARGO_PKG_VERSION_MAJOR").unwrap();
    let minor = env::var("CARGO_PKG_VERSION_MINOR").unwrap();
    let patch = env::var("CARGO_PKG_VERSION_PATCH").unwrap();
    let version = env::var("CARGO_PKG_VERSION").unwrap();

    fs::write(
        &rc_path,
        format!(
            r#"101 ICON "{escaped_icon_path}"

1 VERSIONINFO
FILEVERSION {major},{minor},{patch},0
PRODUCTVERSION {major},{minor},{patch},0
FILEFLAGSMASK 0x3fL
FILEFLAGS 0x0L
FILEOS 0x40004L
FILETYPE 0x1L
FILESUBTYPE 0x0L
BEGIN
    BLOCK "StringFileInfo"
    BEGIN
        BLOCK "040904b0"
        BEGIN
            VALUE "CompanyName", "SeonkyuIM\0"
            VALUE "FileDescription", "PlainVideo\0"
            VALUE "FileVersion", "{version}.0\0"
            VALUE "InternalName", "plainvideo\0"
            VALUE "LegalCopyright", "Copyright (c) 2026 SeonkyuIM\0"
            VALUE "OriginalFilename", "plainvideo.exe\0"
            VALUE "ProductName", "PlainVideo\0"
            VALUE "ProductVersion", "{version}.0\0"
        END
    END
    BLOCK "VarFileInfo"
    BEGIN
        VALUE "Translation", 0x0409, 1200
    END
END
"#
        ),
    )
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
