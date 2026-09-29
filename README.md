# Pi-hole + Unbound installer

An interactive, defensive installer for a DNS-only Pi-hole v6 deployment backed by a true recursive Unbound resolver. It installs Docker Engine from Docker's official apt repository, makes the host address static using the existing network manager, starts and verifies the DNS stack, and can optionally install a systemd-based updater.

> This script changes host networking. Run it from a console when possible. If it detects SSH, it displays an additional warning and arms a three-minute automatic rollback before applying the change.

## Architecture

```text
LAN clients
     |
     | DNS :53
     v
  Pi-hole
     |
     | private Docker network :5335
     v
   Unbound
     |
     v
DNS root/TLD/authoritative servers
```

Unbound does not forward to Cloudflare, Google, the router, or Pi-hole. Its port is not published. Pi-hole reaches it by the Compose service name `unbound`; no container IP is hard-coded. The host's own resolver remains independent, avoiding `host -> Pi-hole -> host` loops.

## Supported systems

- Debian 11, 12, and 13
- Ubuntu 22.04 and 24.04

The script reads `/etc/os-release` and stops on other releases. Supported network backends are NetworkManager, netplan, systemd-networkd, and ifupdown. An existing ifupdown interface stanza is not automatically rewritten because doing so safely requires site-specific knowledge.

## Install

Download or clone this repository, review the script, then run:

```bash
chmod +x install-pihole-unbound.sh
sudo ./install-pihole-unbound.sh
```

The installer shows the detected interface, address/prefix, gateway, current DNS servers, link type, and network backend before asking for a static address. The current address is offered as the default. Reserve the selected address in the router's DHCP configuration or choose an address outside its DHCP pool.

The generated runtime installation is under `/opt/pihole-unbound`. Pi-hole state persists in `/opt/pihole-unbound/etc-pihole`; `.env` is mode `600`. Existing state is preserved on reruns, generated configuration is backed up, and the web password is reused.

## Security model

- DNS and the web UI bind only to the selected private LAN IPv4 address, not every host interface.
- The installer refuses a public static address, preventing an accidental open resolver.
- Unbound accepts queries only from its dynamically selected private Compose subnet and publishes no host port.
- Pi-hole gets no `NET_ADMIN` capability because DHCP is not enabled.
- Port 53 conflicts are reported rather than killed. systemd-resolved's loopback-only stub can coexist with the exact LAN-address binding, so it remains untouched.
- Existing nftables policy is never flushed. Active UFW/firewalld is augmented; review Docker/firewall interaction for custom policies.
- Unbound validates DNSSEC and uses current root hints downloaded from InterNIC.

The Pi-hole image uses the stable `latest` channel rather than development/nightly tags. For a change-controlled environment, pin an image digest in `/opt/pihole-unbound/compose.yaml` and update it deliberately.

## Router setup

Set the router's **LAN DHCP DNS server** to the exact IPv4 address printed by the installer. Do not add `8.8.8.8`, `1.1.1.1`, or `9.9.9.9` as a secondary unless bypass is intentional—clients commonly use either advertised server.

If the router requires two DNS fields, use the Pi-hole address twice if accepted, leave the second field empty, or deploy a second independent Pi-hole. Some routers advertise themselves as DNS, proxy DNS, intercept port 53, or implement “DNS Director.” Those features can collapse all clients into the router in Pi-hole statistics, permit bypass, or create a loop. If the router redirects all LAN DNS to Pi-hole, exempt the Pi-hole/Unbound host itself.

See [docs/router-setup.md](docs/router-setup.md) for a checklist.

## IPv6

The initial release publishes DNS over IPv4. It does not disable IPv6. If the router advertises another resolver through IPv6 RDNSS/DHCPv6, clients can bypass Pi-hole. Configure the router's IPv6 DNS advertisements to point to Pi-hole (after deliberately publishing/configuring an appropriate stable IPv6 address), or stop advertising a separate IPv6 resolver. The installer prints a warning when global IPv6 is detected.

## Updates

After the installation summary, the installer can create a systemd oneshot service and timer. Schedules can be daily, weekly, or monthly (days 1–28), with a 15-minute randomized delay and persistent catch-up after downtime.

The updater:

1. takes a `flock` lock;
2. tags current images for rollback;
3. pulls/builds without stopping working DNS first;
4. refreshes and validates root hints;
5. runs `docker compose up -d --remove-orphans`;
6. waits for both health checks and runs real DNS queries;
7. prunes only dangling images after success.

It never uses `docker system prune`, removes volumes, or brings the stack down during a normal update. Registry failure leaves current containers untouched.

Schedule examples:

```ini
OnCalendar=*-*-* 03:30:00
OnCalendar=Sat *-*-* 03:30:00
OnCalendar=*-*-15 03:30:00
```

Management commands:

```bash
systemctl status pihole-unbound-update.timer
systemctl list-timers pihole-unbound-update.timer
sudo systemctl start pihole-unbound-update.service
sudo systemctl disable --now pihole-unbound-update.timer
journalctl -u pihole-unbound-update.service
sudo /opt/pihole-unbound/configure-updater.sh
```

Manual update:

```bash
cd /opt/pihole-unbound
sudo docker compose pull pihole
sudo docker compose build --pull unbound
sudo docker compose up -d --remove-orphans
sudo docker compose ps
# Only after verifying health:
sudo docker image prune -f --filter dangling=true
```

## Uninstall and rollback

Run:

```bash
sudo /opt/pihole-unbound/uninstall.sh
```

It distinguishes container removal, updater removal, network restoration, Docker package removal, and deletion of persistent DNS data. Pi-hole data and Docker data are retained unless separately and explicitly confirmed. Network backups are stored in `/root/network-backup-YYYYMMDD-HHMMSS/` with an executable rollback helper.

## Troubleshooting

Start with:

```bash
cd /opt/pihole-unbound
sudo docker compose ps
sudo docker compose logs --tail=100 pihole unbound
sudo ss -lntup '( sport = :53 )'
dig @SERVER_IP example.com
dig @SERVER_IP dnssec.works +dnssec
dig @SERVER_IP fail01.dnssec.works +dnssec
```

The valid DNSSEC domain must return `NOERROR`; the deliberately broken domain must return `SERVFAIL`. More cases are covered in [docs/troubleshooting.md](docs/troubleshooting.md), and networking details are in [docs/networking.md](docs/networking.md).

## Repository layout

- `install-pihole-unbound.sh` — production installer and file generator
- `examples/` — illustrative generated configuration (do not copy manually)
- `docs/` — network, router, updater, and troubleshooting guides

## License

MIT. See [LICENSE](LICENSE).

## Upstream references

- [Official Pi-hole Docker image and stable tags](https://github.com/pi-hole/docker-pi-hole)
- [Pi-hole v6 Docker configuration](https://docs.pi-hole.net/docker/configuration/)
- [Docker Engine installation for Debian](https://docs.docker.com/engine/install/debian/)
