# CSSH

libssh2, built from source against OpenSSL from [openssl-spm](https://github.com/Lakr233/openssl-spm).

`libssh2/` holds `src`, `include` and `COPYING` from [libssh2](https://github.com/libssh2/libssh2) at commit `298b8b15ed2c24f34ae2b8c27c5587896d43bfba` (2026-10-23, after 1.11.1), without its build files. To move it to another commit, replace those three with the new commit's and update the commit above.

`openssl/` forwards each `<openssl/….h>` libssh2 includes to openssl-spm's framework. A new libssh2 that includes another OpenSSL header needs one more.
