// android_shims_streambuf.cpp — forces explicit instantiation of
// std::basic_streambuf<char>, which provides the non-inline virtual
// seekpos/seekoff definitions that Zig's bundled libc++.a omits from its
// prebuilt object set (M3.4 finding: discovered linking a binary target,
// not previously hit by the cdylib FFI build in M2/M3.1-3.3).
//
// Root cause: barretenberg-rs's get_bn254_crs.cpp (httplib's internal CRS
// HTTP client) defines a std::streambuf subclass whose vtable needs every
// base-class virtual resolved, including ones it doesn't override. We never
// call this code path at runtime — SRS fetching goes through noir_rs's own
// Rust-side netsrs, not barretenberg's internal C++ HTTP client — but the
// linker still needs the symbol to complete the vtable.
//
// Must be compiled with Zig's own c++ (not NDK clang++): Zig's bundled
// libcxx headers/sources produce the NSt3__1-namespaced ABI that
// libbb-external.a expects; NDK's libc++ headers produce the incompatible
// NSt6__ndk1 namespace. See scripts/ndk-cxx-android.sh.
#include <streambuf>
template class std::basic_streambuf<char, std::char_traits<char>>;
