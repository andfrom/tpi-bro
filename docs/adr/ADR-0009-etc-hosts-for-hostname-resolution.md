# ADR-0009: Use `/etc/hosts` for Cluster Hostname Resolution (Not mDNS)

**Status:** Accepted  
**Date:** 2026-05-09

## Context

The cluster has two classes of hostnames that the operator's laptop needs to resolve:
- `turingpi.local` — the BMC (Baseboard Management Controller), used by the `tpi` CLI
- `rk1-node{1..4}` — the RK1 compute modules, used by SSH, kubectl, and Docker push

The TuringPi BMC advertises `turingpi.local` via mDNS (Bonjour/Avahi). mDNS worked in initial testing but is unreliable over WiFi on many home and office networks: routers often don't propagate mDNS across network segments, and some Linux WiFi drivers suppress it intermittently.

The RK1 nodes have no mDNS daemon by default. Their hostnames are only reachable by IP without an explicit `/etc/hosts` entry.

## Decision

The bootstrap script manages `/etc/hosts` entries for all cluster hostnames, using `bootstrap-host-helper.sh`:

- **A1 (`find_bmc`)**: after discovering the BMC IP via nmap, appends `<bmc-ip> turingpi.local` to `/etc/hosts`. This makes `tpi` work regardless of mDNS for all subsequent stages.
- **A6 (`write_hosts_on_laptop`)**: appends `<node-ip> rk1-nodeN` entries for all nodes.
- **Teardown T6**: removes all of the above (symmetric cleanup).
- **`--rediscover`**: removes stale entries and rewrites them with current IPs when DHCP has reassigned addresses.

`bootstrap-host-helper.sh` is idempotent — safe to call on reruns. It appends only if the entry doesn't already exist (checked by IP+hostname pair).

## Consequences

**Positive:**
- `tpi` and SSH work immediately after A1/A6 without depending on mDNS
- Explicit, inspectable state — operator can see exactly what's in `/etc/hosts`
- Survives network changes that break mDNS
- Teardown is clean — no ghost entries left behind

**Negative:**
- `/etc/hosts` entries become stale when DHCP reassigns IPs — mitigated by `--rediscover` and by configuring static DHCP reservations (see ADR-0010)
- Requires `sudo` on the operator's laptop for A1 and A6
- Does not help other machines on the LAN — only the operator's laptop gets the entries

## Alternatives Considered

- **Rely on mDNS only**: proved unreliable in practice (failed silently on WiFi)
- **DNS server on node1**: too heavy for bootstrap; depends on k3s being installed first
- **Static IPs on nodes**: requires modifying Ubuntu's netplan/networkd config; fragile across reflashes
