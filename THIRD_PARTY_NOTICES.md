# Third-party notices

SuperSynch is licensed under the [Mozilla Public License 2.0](LICENSE).

The app embeds [Syncthing](https://syncthing.net/) and its Go dependencies, compiled into `Stbridge.xcframework`. They are used **unmodified**, and each remains under its own license. The source of each is available at the linked repository. Syncthing's source code is at https://github.com/syncthing/syncthing (MPL-2.0).

"Syncthing" is a trademark of the Syncthing Foundation. SuperSynch is not affiliated with or endorsed by the Syncthing Foundation.

| Module | Version | License |
|---|---|---|
| [github.com/Azure/go-ntlmssp](https://github.com/Azure/go-ntlmssp) | v0.1.1 | MIT |
| [github.com/beorn7/perks](https://github.com/beorn7/perks) | v1.0.1 | MIT |
| [github.com/calmh/incontainer](https://github.com/calmh/incontainer) | v1.0.0 | MIT |
| [github.com/calmh/xdr](https://github.com/calmh/xdr) | v1.2.0 | MIT |
| [github.com/ccding/go-stun](https://github.com/ccding/go-stun) | v0.1.6 | Apache-2.0 |
| [github.com/cespare/xxhash/v2](https://github.com/cespare/xxhash/v2) | v2.3.0 | MIT |
| [github.com/ebitengine/purego](https://github.com/ebitengine/purego) | v0.10.2 | Apache-2.0 |
| [github.com/go-asn1-ber/asn1-ber](https://github.com/go-asn1-ber/asn1-ber) | v1.5.8 | MIT |
| [github.com/go-ldap/ldap/v3](https://github.com/go-ldap/ldap/v3) | v3.4.14 | MIT |
| [github.com/gobwas/glob](https://github.com/gobwas/glob) | v0.2.3 | MIT |
| [github.com/golang/snappy](https://github.com/golang/snappy) | v0.0.4 | BSD |
| [github.com/google/uuid](https://github.com/google/uuid) | v1.6.0 | BSD |
| [github.com/hashicorp/golang-lru/v2](https://github.com/hashicorp/golang-lru/v2) | v2.0.7 | MPL-2.0 |
| [github.com/jackpal/gateway](https://github.com/jackpal/gateway) | v1.2.0 | BSD |
| [github.com/jackpal/go-nat-pmp](https://github.com/jackpal/go-nat-pmp) | v1.0.2 | Apache-2.0 |
| [github.com/jmoiron/sqlx](https://github.com/jmoiron/sqlx) | v1.4.0 | MIT |
| [github.com/julienschmidt/httprouter](https://github.com/julienschmidt/httprouter) | v1.3.0 | BSD |
| [github.com/kballard/go-shellquote](https://github.com/kballard/go-shellquote) | v0.0.0-20180428030007-95032a82bc51 | MIT |
| [github.com/mattn/go-sqlite3](https://github.com/mattn/go-sqlite3) | v1.14.50 | MIT |
| [github.com/miscreant/miscreant.go](https://github.com/miscreant/miscreant.go) | v0.0.0-20200214223636-26d376326b75 | MIT |
| [github.com/munnerz/goautoneg](https://github.com/munnerz/goautoneg) | v0.0.0-20191010083416-a7dc8b61c822 | BSD |
| [github.com/pierrec/lz4/v4](https://github.com/pierrec/lz4/v4) | v4.1.29 | BSD |
| [github.com/prometheus/client_golang](https://github.com/prometheus/client_golang) | v1.24.1 | Apache-2.0 |
| [github.com/prometheus/client_model](https://github.com/prometheus/client_model) | v0.6.2 | Apache-2.0 |
| [github.com/prometheus/common](https://github.com/prometheus/common) | v0.70.1 | Apache-2.0 |
| [github.com/quic-go/quic-go](https://github.com/quic-go/quic-go) | v0.61.0 | MIT |
| [github.com/rcrowley/go-metrics](https://github.com/rcrowley/go-metrics) | v0.0.0-20250401214520-65e299d6c5c9 | BSD |
| [github.com/shirou/gopsutil/v4](https://github.com/shirou/gopsutil/v4) | v4.26.7 | BSD |
| [github.com/syncthing/notify](https://github.com/syncthing/notify) | v0.0.0-20250528144937-c7027d4f7465 | MIT |
| [github.com/syncthing/syncthing](https://github.com/syncthing/syncthing) | v2.1.5 (commit 2ca95cf) | MPL-2.0 |
| [github.com/syndtr/goleveldb](https://github.com/syndtr/goleveldb) | v1.0.1-0.20220721030215-126854af5e6d | BSD |
| [github.com/thejerf/suture/v4](https://github.com/thejerf/suture/v4) | v4.0.6 | MIT |
| [github.com/tklauser/go-sysconf](https://github.com/tklauser/go-sysconf) | v0.3.16 | BSD |
| [github.com/vitrun/qart](https://github.com/vitrun/qart) | v0.0.0-20160531060029-bf64b92db6b0 | Apache-2.0 |
| [golang.org/x/crypto](https://cs.opensource.google/go/x/crypto) | v0.57.0 | BSD |
| [golang.org/x/net](https://cs.opensource.google/go/x/net) | v0.59.0 | BSD |
| [golang.org/x/sys](https://cs.opensource.google/go/x/sys) | v0.48.0 | BSD |
| [golang.org/x/text](https://cs.opensource.google/go/x/text) | v0.42.0 | BSD |
| [golang.org/x/time](https://cs.opensource.google/go/x/time) | v0.15.0 | BSD |
| [google.golang.org/protobuf](https://github.com/protocolbuffers/protobuf-go) | v1.36.12 | BSD |

Also included: the Go standard library (BSD-3-Clause) and [golang.org/x/mobile](https://cs.opensource.google/go/x/mobile) bindings (BSD-3-Clause), used to build the framework.

_Generated from `go list -deps ./stbridge` (build tag `noassets`). Regenerate it when dependencies change; see CLAUDE.md._
