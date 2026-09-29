# Networking and static addresses

The installer derives the primary interface from the first IPv4 default route and records its global address/prefix, gateway, resolver list, and link type. It then detects the active manager in this order: a connected NetworkManager device, netplan, active systemd-networkd, then ifupdown.

## Safety controls

- The proposed address is parsed with Python's `ipaddress` library.
- It must be private, usable, in the gateway subnet, and distinct from the gateway.
- `ip neigh`, duplicate-address-mode `arping`, and ICMP ping are used when possible. None can prove that a silent device does not own the address.
- All relevant network files are copied to a timestamped directory under `/root`.
- A transient systemd unit schedules rollback in three minutes before changes are applied.
- The new local address, routes, gateway reachability, and public IPv4 reachability are checked before rollback is cancelled.
- DNS is not used for the first connectivity test.

A DHCP reservation remains strongly recommended. Static host configuration prevents the host from moving; the reservation prevents the router from leasing that same address to another client.

## Backend behavior

NetworkManager modifies the active connection profile. Netplan receives a late override file. systemd-networkd receives the first matching `.network` file. For ifupdown, the installer creates a sourced stanza only when no existing IPv4 stanza controls the interface; otherwise it stops and asks for a manual site-aware edit.

Wi-Fi credentials are never rewritten. Existing backend configuration is retained in the backup.

## systemd-resolved

Compose binds port 53 to the selected LAN address instead of `0.0.0.0`. Therefore systemd-resolved's `127.0.0.53`/`127.0.0.54` loopback stub can coexist and remains untouched, preserving host DNS throughout installation. A listener on a non-stub address is treated as a real conflict and the installer stops rather than killing or rewriting that service.

Other DNS listeners are never killed. Stop or reconfigure dnsmasq, host Unbound, BIND, or an earlier DNS server deliberately and rerun.
