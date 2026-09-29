# Troubleshooting

## Port 53 is occupied

Inspect both protocols:

```bash
sudo ss -lntup '( sport = :53 )'
sudo ss -lnup '( sport = :53 )'
```

The installer handles only an isolated systemd-resolved stub conflict. Reconfigure other DNS software intentionally; do not kill an unidentified process.

## A container is unhealthy

```bash
cd /opt/pihole-unbound
sudo docker compose ps
sudo docker compose logs --tail=100 pihole
sudo docker compose logs --tail=100 unbound
sudo docker compose exec unbound dig @127.0.0.1 -p 5335 example.com
sudo docker compose exec pihole dig @unbound -p 5335 example.com
```

The first query tests recursion. The second also proves Docker service discovery and the Pi-hole-to-Unbound path.

## DNSSEC

```bash
dig @SERVER_IP dnssec.works A +dnssec
dig @SERVER_IP fail01.dnssec.works A +dnssec
```

Expected: `NOERROR` then `SERVFAIL`. If both fail, inspect Unbound time, root hints, and logs. If both succeed, validation is not being enforced.

## Clients bypass Pi-hole

Inspect every DNS server assigned to the client, including IPv6 RDNSS/DHCPv6. Remove public secondary servers. Check encrypted DNS/browser “secure DNS,” VPN DNS, and router interception features.

## Recover networking

Each attempted mutation creates `/root/network-backup-TIMESTAMP/rollback-network.sh`. Run the appropriate backup's helper from a local console. It restores the backed-up manager files and restarts that backend. The uninstaller offers the same operation interactively.

## Avoiding data loss

`docker compose down` removes containers and the project network, not bind-mounted Pi-hole data. Do not remove `/opt/pihole-unbound/etc-pihole` unless permanent loss is intended. The generated uninstaller requires the exact word `DELETE` before removing persistent files.
