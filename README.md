# ilo4-fan-quiet

Permanently quiet fans for HP ProLiant Gen8/Gen9 servers (DL380p, DL360p, ML350p, …)
running the patched iLO4 firmware from
[kendallgoto/ilo4_unlock](https://github.com/kendallgoto/ilo4_unlock).

The patched firmware exposes `fan` commands over the iLO's SSH CLI, but any
settings you make are lost whenever the iLO resets. This project makes them
stick: a small script caps every fan's PWM at a value you choose, and a
systemd timer reapplies the cap at boot and every 10 minutes -> so the fans
stay quiet forever, even across host reboots and iLO resets.

It also ships `ilo-fan-tui`, a terminal dashboard for monitoring and tuning:

```
 DL380p Gen8 fan control                       iLO 192.168.178.50  ONLINE
 --------------------------------------------------------------------------
 CPU Package id 0:  43.0 C  (hottest core 46 C)
 CPU Package id 1:  45.0 C  (hottest core 47 C)

 FAN CAP: 32/255 (12.5%)

 Fan 1   [##----------------------------]   3.9%
 Fan 2   [##----------------------------]   3.9%
 ...

 iLO SENSORS   ( < 50 ok  50-64 warm  65+ hot )
 ■ 01-Inlet Ambient   33C   ■ 02-CPU 1           40C   ■ 03-CPU 2       40C
 ■ 04-P1 DIMM 1-3     37C   ■ 05-P1 DIMM 4-6     38C   ...

 [+/-] cap +-4   [PgUp/PgDn] +-16   [a]pply   [r]efresh   [q]uit
```

## Requirements

- An iLO4 server already flashed with the
  [ilo4_unlock](https://github.com/kendallgoto/ilo4_unlock) patched firmware
  (this project does **not** flash firmware).
- A network path from the host to the iLO (dedicated iLO port cabled to your
  LAN, or a direct patch cable from the iLO port into one of the host's NICs).
- An iLO user for SSH -> the installer can create one for you via `hponcfg`
  when run on the server itself.
- Debian/Ubuntu packages: `sshpass`, `ipmitool` (for the TUI), `python3`.

## Install

One-liner:

```bash
curl -fsSL https://raw.githubusercontent.com/CK5515/ilo4-fan-quiet/main/install.sh | sudo bash
```

Or from a clone:

```bash
git clone https://github.com/CK5515/ilo4-fan-quiet.git
cd ilo4-fan-quiet
sudo ./install.sh
```

The installer asks for the iLO IP, SSH credentials (or creates the iLO user
for you), and the fan cap, then installs everything and applies the cap
immediately. Non-interactive use:

```bash
ILO_IP=192.168.1.50 ILO_USER=fanctl ILO_PASS=secret FAN_MAX=32 sudo -E ./install.sh
```

## How it works

| File | Purpose |
| --- | --- |
| `/usr/local/sbin/ilo-fan-quiet` | SSHes to the iLO and runs `fan p N max <cap>` for each fan |
| `/etc/systemd/system/ilo-fan-quiet.timer` | reapplies the cap at boot + every 10 min |
| `/etc/default/ilo-fan` | iLO IP and fan count (world-readable) |
| `/etc/ilo-fanctl.conf` | iLO credentials (root-only, mode 600) |
| `/etc/ilo-fan-max` | the cap, 0–255 (world-readable; the TUI edits this) |
| `/usr/local/bin/ilo-fan-tui` | monitoring/tuning dashboard |

The cap scale is 0–255: `25 ≈ 10%`, `32 ≈ 12.5%`, `64 ≈ 25%`. To change it,
run `ilo-fan-tui` (keys `+`/`-`, then `a` to apply) or edit `/etc/ilo-fan-max`
and run `sudo systemctl start ilo-fan-quiet`.

The TUI runs unprivileged if you accept the installer's offer to add a
narrow sudoers entry (`/etc/sudoers.d/ilo-fans`) for `ipmitool` readings and
cap changes.

## A word of caution

Capping fans reduces airflow for **everything** in the chassis -> DIMMs, VRMs,
drives, and PCIe cards don't care how good your CPU cooling is. Watch the
sensor grid in `ilo-fan-tui` after lowering the cap, especially under
sustained load, and raise the cap if anything trends past ~65 °C. The iLO's
thermal protection still overrides the cap at genuinely critical
temperatures, but don't make it do your job.

## Uninstall

```bash
sudo systemctl disable --now ilo-fan-quiet.timer
sudo rm -f /usr/local/sbin/ilo-fan-quiet /usr/local/bin/ilo-fan-tui \
  /etc/systemd/system/ilo-fan-quiet.{service,timer} \
  /etc/default/ilo-fan /etc/ilo-fanctl.conf /etc/ilo-fan-max \
  /etc/sudoers.d/ilo-fans
sudo systemctl daemon-reload
```

The iLO reverts to its stock fan curve at its next reset (or immediately if
you raise the cap to 255 first).

## License

MIT
