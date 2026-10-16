# Third-party code and sources

What this project includes from others, what it follows without copying, and what it uses at run
time. The project's own license is in [LICENSE](LICENSE).

## Included in this repository

| File | Origin | License |
|---|---|---|
| `runner/src/vendor/tls_client.zig` | A copy of Zig 0.17.0's `std.crypto.tls.Client`, with one change (it answers a TLS 1.3 CertificateRequest; see the file's header) | MIT, Copyright (c) Zig contributors; [`runner/src/vendor/LICENSE-zig`](runner/src/vendor/LICENSE-zig) |
| `runner/src/hpack_tables.zig` | The HPACK Huffman code and static table from [RFC 7541](https://www.rfc-editor.org/rfc/rfc7541) (Appendix A and B), generated from the RFC's text by `runner/tools/gen_hpack_tables.py` | Protocol constants from the RFC |

## Followed, not copied

- **GitHub Actions' runner protocol** (registration, the broker, the run and results services, the live log feed) is not publicly documented. The runner implements it in new Zig code, based on reading [`actions/runner`](https://github.com/actions/runner) and on running the same workflows on GitHub-hosted runners side by side. A few log messages reproduce `actions/runner`'s wording, so that logs read like GitHub's. `actions/runner` is under the MIT License, Copyright (c) 2019 GitHub, reproduced below.
- **Dagger's client protocol** is implemented in `runner/src/engine.zig`, based on [Dagger](https://github.com/dagger/dagger)'s documentation and source (Apache-2.0).
- Talking to GitHub's services is governed by GitHub's terms of service, which are separate from any of these licenses.

## Used at run time, not included

The Dagger engine pulls these images when jobs run; none of them is part of this repository or its builds:
- the Dagger engine image `registry.dagger.io/engine` (Apache-2.0);
- `ubuntu:24.04` and the Ubuntu packages provisioned into it (their own licenses);
- `busybox` (GPL-2.0), run unmodified inside job containers;
- `oven/bun` (MIT) and `node` (MIT), the JavaScript runtimes for actions;
- whatever images and actions workflows themselves name.

The optional `api/` and `web/` depend on npm packages listed in their `package-lock.json` files, all under open-source licenses (MIT, Apache-2.0, BSD, ISC, MPL-2.0 and similar).

CI installs one more tool, which is in no build: [`wenkokke/setup-agda`](https://github.com/wenkokke/setup-agda) (MIT, Copyright (c) 2022 Wen Kokke), pinned by commit, which puts an Agda of the pinned version on the runner to type-check `proofs/`. That binary distribution carries its own notices (Agda's, under BSD-style terms, with GMP under LGPL-3.0 and ICU under the Unicode license); `proofs/` itself is this project's own code and uses no Agda library.

## actions/runner's license

```
The MIT License (MIT)
Copyright (c) 2019 GitHub

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
