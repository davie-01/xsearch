// Install name @rpath/libxs_ffi.dylib: each executable finds the library through its own rpath
// (the app bundle's Frameworks folder; target/release for tests and development builds).
fn main() {
    println!("cargo:rustc-cdylib-link-arg=-Wl,-install_name,@rpath/libxs_ffi.dylib");
}
