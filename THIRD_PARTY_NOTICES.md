# Third-party notices

Snazzy Pro includes the following open-source software. Each is used under its
licence, reproduced below.

## HaishinKit 2.2.5

https://github.com/HaishinKit/HaishinKit.swift (RTMP streaming to YouTube, Twitch, Vimeo and other services)

BSD 3-Clause License

Copyright (c) 2015, shogo4405
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this
  list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above copyright notice,
  this list of conditions and the following disclaimer in the documentation
  and/or other materials provided with the distribution.

* Neither the name of the copyright holder nor the names of its
  contributors may be used to endorse or promote products derived from
  this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

## Logboard 2.6.0

https://github.com/shogo4405/Logboard (logging, used by HaishinKit)

BSD 3-Clause License

Copyright (c) 2017, shogo4405
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this
  list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above copyright notice,
  this list of conditions and the following disclaimer in the documentation
  and/or other materials provided with the distribution.

* Neither the name of the copyright holder nor the names of its
  contributors may be used to endorse or promote products derived from
  this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

## Manrope

The Manrope typeface in the brand assets is used under the SIL Open Font License 1.1 (see docs/brand/fonts).

## Snazzy Pro for Windows and Linux (`desktop/`)

The shared-format crates (`snazzy-core`, `snazzy-remote`) use these Rust crates,
each under the licence named (MIT and Apache-2.0 texts as in each crate's source):

| Crate | Version | Licence | Why |
|---|---|---|---|
| serde, serde_core, serde_derive | 1.0.229 | MIT OR Apache-2.0 | JSON formats |
| serde_json | 1.0.154 | MIT OR Apache-2.0 | JSON formats |
| thiserror, thiserror-impl | 1.0.69 | MIT OR Apache-2.0 | error types |
| flate2 | 1.1.10 | MIT OR Apache-2.0 | `.snazzy` deflate |
| miniz_oxide | 0.9.1 | MIT OR Zlib OR Apache-2.0 | used by flate2 |
| adler2 | 2.0.1 | 0BSD OR MIT OR Apache-2.0 | used by miniz_oxide |
| simd-adler32 | 0.3.10 | MIT | used by miniz_oxide |
| crc32fast | 1.5.2 | MIT OR Apache-2.0 | used by flate2 |
| regex, regex-automata, regex-syntax | 1.13.1, 0.4.18, 0.8.11 | MIT OR Apache-2.0 | deck search |
| aho-corasick, memchr | 1.1.5, 2.8.3 | Unlicense OR MIT | used by regex |
| time, time-core, time-macros | 0.3.45, 0.1.7, 0.2.25 | MIT OR Apache-2.0 | ISO 8601 dates |
| deranged, powerfmt, num-conv | 0.5.8, 0.2.1, 0.1.0 | MIT OR Apache-2.0 | used by time |
| hmac, sha2, digest, crypto-common, block-buffer, cpufeatures | 0.12.1, 0.10.9, 0.10.7, 0.1.7, 0.10.4, 0.2.17 | MIT OR Apache-2.0 | remote `hello` proof |
| generic-array | 0.14.7 | MIT | used by digest |
| typenum | 1.20.1 | MIT OR Apache-2.0 | used by digest |
| subtle | 2.6.1 | BSD-3-Clause | constant-time comparison (hmac) |
| itoa, zmij | 1.0.18, 1.0.23 | MIT OR Apache-2.0, MIT | used by serde_json |
| cfg-if, libc | 1.0.5, 0.2.190 | MIT OR Apache-2.0 | platform glue |
| uuid, getrandom | 1.26.1, 0.4.3 | MIT OR Apache-2.0 | random preview links (deck previews) |
| proc-macro2, quote, syn, unicode-ident | build time only | MIT OR Apache-2.0 (unicode-ident also Unicode-3.0) | derive macros |
| tempfile | 3.27.0 (tests only) | MIT OR Apache-2.0 | temporary folders in tests |
