# Router and DHCP setup

The intended flow is:

```text
DHCP clients -> Pi-hole LAN IPv4 -> Unbound -> authoritative DNS
```

1. Reserve the Pi-hole host address in the router's DHCP server, or ensure it lies outside the pool.
2. Put the Pi-hole address in the router's **LAN/DHCP DNS** field—not its WAN upstream DNS field.
3. Renew a test client's DHCP lease and inspect its assigned DNS servers.
4. Query Pi-hole and confirm the client appears in the query log.

Do not advertise a public secondary resolver unless client bypass is intentional. If the UI requires two fields, try the same Pi-hole address twice, an empty second field, or a second independently hosted Pi-hole.

Review features called DNS proxy, DNS relay, DNS Director, DNS filtering, DNS interception, or “force clients to use router DNS.” A router proxy can make every request appear to come from the router. Redirection can create `router -> Pi-hole -> router` loops if the router is also selected as an upstream. Pi-hole in this project always uses Unbound directly, but the DNS host should still be exempted from router port-53 interception.

IPv6 is separate: inspect router advertisements and DHCPv6 DNS options. Advertising a public IPv6 resolver permits bypass even when IPv4 is correct.
