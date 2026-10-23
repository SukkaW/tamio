// swift-tools-version:5.9

import PackageDescription

let package = Package(
    name: "CSSH",
    products: [
        .library(name: "CSSH", targets: ["CSSH"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Lakr233/openssl-spm.git", exact: "4.0.1"),
    ],
    targets: [
        .target(
            name: "CSSH",
            dependencies: [.product(name: "OpenSSL", package: "openssl-spm")],
            path: ".",
            exclude: ["README.md", "LICENSE", "libssh2/COPYING", "openssl"],
            sources: ["libssh2/src"],
            publicHeadersPath: "libssh2/include",
            cSettings: [
                // openssl-spm puts the headers in libssl.framework, where
                // they are <libssl/openssl/…>; libssh2 asks for <openssl/…>.
                .headerSearchPath("openssl"),
                .define("LIBSSH2_OPENSSL"),
                .define("HAVE_UNISTD_H"),
                .define("HAVE_INTTYPES_H"),
                .define("HAVE_SYS_SELECT_H"),
                .define("HAVE_SYS_UIO_H"),
                .define("HAVE_SYS_IOCTL_H"),
                .define("HAVE_SYS_TIME_H"),
                .define("HAVE_SYS_UN_H"),
                .define("HAVE_ARPA_INET_H"),
                .define("HAVE_NETINET_IN_H"),
                .define("HAVE_MEMSET_S"),
                .define("HAVE_O_NONBLOCK"),
                // libssh2 now leaves these out by default. Older servers and
                // keys still depend on them, and libssh2 prefers the stronger
                // algorithms whenever the server offers them.
                .define("LIBSSH2_RSA_SHA1_ENABLE"),
                .define("LIBSSH2_KEX_SHA1_ENABLE"),
                .define("LIBSSH2_HMAC_SHA1_ENABLE"),
                .define("LIBSSH2_DSA_ENABLE"),
                .define("LIBSSH2_MD5_ENABLE"),
                .define("LIBSSH2_MD5_PEM_ENABLE"),
                .define("LIBSSH2_3DES_ENABLE"),
                .define("LIBSSH2_HMAC_RIPEMD_ENABLE"),
                .define("LIBSSH2_BLOWFISH_ENABLE"),
                .define("LIBSSH2_RC4_ENABLE"),
                .define("LIBSSH2_CAST_ENABLE"),
            ]
        ),
    ]
)
