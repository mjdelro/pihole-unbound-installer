# Automatic updater

The optional updater is a systemd timer, never cron. `/opt/pihole-unbound/configure-updater.sh` validates daily, weekly, and monthly schedules and rewrites only the timer. Monthly days are limited to 1–28.

The oneshot service logs to journald and serializes runs with `/run/lock/pihole-unbound-update.lock`. Pull/build happens before Compose replaces containers, so an unavailable registry does not interrupt working DNS. Current image IDs receive local rollback tags before updates. Actual queries verify Unbound and the LAN endpoint; only a successful run performs conservative dangling-image cleanup.

Useful commands:

```bash
systemctl list-timers pihole-unbound-update.timer
sudo systemctl start pihole-unbound-update.service
journalctl -u pihole-unbound-update.service --since today
sudo /opt/pihole-unbound/configure-updater.sh
sudo systemctl disable --now pihole-unbound-update.timer
```

To roll back manually, inspect `docker image ls local/pihole-unbound-rollback`, set the desired image reference in `compose.yaml`, and run `docker compose up -d`. Preserve `/opt/pihole-unbound/etc-pihole` throughout.
