# shells

A small collection of shell scripts for Linux. Each one runs with bash and standard command-line tools only.

| Script | Description | Root |
|---|---|---|
| `mount_ssd.sh` | Mount registered USB SSDs at their configured mount points | Required |
| `umount_ssd.sh` | Unmount registered SSDs and power them off for safe removal | Required |
| `scan_lan.sh` | List hosts on the LAN and the remote-access ports they accept | Not required |
| `copy_ssh_key.sh` | Copy one of your SSH public keys to user@host interactively | Not required |

## mount_ssd.sh

Mounts USB SSDs at mount points registered per filesystem UUID.
The UUID is stored on the SSD itself, so the same SSD is mounted at the same place on every PC.

```bash
sudo bash mount_ssd.sh          # mount all connected SSDs (asks about unregistered ones)
sudo bash mount_ssd.sh --edit   # change or delete registrations
```

- When an unregistered SSD is found, you are asked for a mount point:
  - Enter a path to register and mount it.
  - Press Enter with no input to skip it this time.
  - Enter `-` to register it as ignored; it will never be mounted or asked about again.
- Mount points must be under `/mnt/` or `/media/` (no spaces, `..`, or symlinks).
- Non-empty directories and mount points already used by another device are never mounted over.
- Desktop auto-mounts (`/media/...`, `/run/media/...`) are unmounted first and then moved to the registered mount point.
- Mount options are `nosuid,nodev`.
- vfat / exfat / NTFS are mounted as owned by the user who ran `sudo`. NTFS uses the kernel's `ntfs3` driver when ntfs-3g is not installed.
- For filesystems such as ext4, if the mount point is owned by a different user than the invoking one (e.g. it was created on another PC), you are asked whether to change the owner.

Requirements: bash, util-linux, awk, coreutils

### Configuration file

Registrations are stored in `mount_ssd.conf` in the same directory as the script, one `<filesystem UUID> <mount point>` per line.

```
1234-ABCD /mnt/data
0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0 /mnt/backup
abcd1234-0000-1111-2222-333344445555 -
```

A mount point of `-` means "ignore". The file may be edited by hand (the same checks are applied when it is read).
It is listed in `.gitignore` so it is never committed.

## umount_ssd.sh

Unmounts SSDs registered in `mount_ssd.conf`, then asks whether to power off each USB disk.

```bash
sudo bash umount_ssd.sh                  # unmount all mounted registered SSDs
sudo bash umount_ssd.sh /mnt/data ...    # unmount only the given mount points
```

- A mount point is not unmounted if the device mounted there does not match the registered UUID.
- If a mount point is busy, the processes using it are shown (when `fuser` is available).
- A disk is not powered off while it still has mounted partitions or active LUKS / LVM / RAID devices.

Requirements: bash, util-linux, awk, coreutils (`fuser` is optional)

## scan_lan.sh

Scans only directly attached subnets (never anything behind the router) and shows the IP, MAC, hostname, and open ports of each host found.

```bash
bash scan_lan.sh                  # scan the subnet of the default-route interface
bash scan_lan.sh 192.168.3.0/24   # scan the given attached subnet (prefix /22 to /30)
```

- Ports checked: 22 (ssh), 445 (smb), 3389 (rdp), 5900 (vnc)
- Hosts that drop ping (e.g. behind the Windows firewall) are still listed if they answer ARP.
- This PC is marked `(this PC)` and the default gateway `(router)`.
- No root privileges are needed.

Example output:

```
IP               MAC                HOSTNAME                        OPEN PORTS
192.168.1.1      aa:bb:cc:dd:ee:01  router.lan (router)             -
192.168.1.10     -                  mypc.lan (this PC)              ssh/22
192.168.1.20     aa:bb:cc:dd:ee:02  nas.lan                         ssh/22 smb/445
```

Requirements: bash 4.3+, iproute2 (`ip`), ping, getent, awk, xargs, coreutils

## copy_ssh_key.sh

Copies one of your SSH public keys in `~/.ssh` to another PC with `ssh-copy-id`, so you can log in there without a password.
Only public keys (`*.pub`) are sent; private keys never leave this PC.

```bash
bash copy_ssh_key.sh
```

1. Pick a key from the list of `~/.ssh/*.pub` (shown with fingerprint and comment).
   Files that are not public keys, and public keys without a matching private key, are skipped.
2. Enter the target as `user@host` (or just `host` to use your own user name) and the SSH port (default 22).
3. The key is copied (you may be asked for the target's password, and for the key's passphrase if it is not in ssh-agent), then a key-only login is tested.
   A key that is already installed is skipped.
4. You can copy the same key to more hosts in a row.

If `~/.ssh` has no key pair, create one first with `ssh-keygen -t ed25519`.

Requirements: bash, OpenSSH client (`ssh`, `ssh-keygen`, `ssh-copy-id`), awk, coreutils
