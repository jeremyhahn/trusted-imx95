# Local seam trace: what public man pages say about a Unix socket between a listener and a key holder

> **Status: TRACE, facts only; no requirement (R6 and R8 of xkmsd-node.md are proposed, pending owner approval)** · Row: hsm-device-protocol · Issue: #24 · Read: 2026-11-24

This record answers four questions behind R6 and R8 of [xkmsd-node.md](xkmsd-node.md) that the
[survey](on-device-transport-survey.md) §4 left "details unconfirmed". It reads six public man pages and summarises them
in its own words; it copies no page text. Section names are cited from the pages. It names no socket path, port, message
or timeout, and no go-xkms code was read.

## Sources

| # | Title | Version read | URL |
|---|-------|--------------|-----|
| 1 | unix(7), Linux man-pages | 6.19, page dated 2026-02-08 | https://man7.org/linux/man-pages/man7/unix.7.html |
| 2 | socket(7), Linux man-pages | 6.19, page dated 2026-06-05 | https://man7.org/linux/man-pages/man7/socket.7.html |
| 3 | systemd.socket(5) | systemd 262 (latest page, fetched 2026-11-24) | https://www.freedesktop.org/software/systemd/man/latest/systemd.socket.html |
| 4 | sd_listen_fds(3) | man7.org copy, stamped systemd 262~devel | https://man7.org/linux/man-pages/man3/sd_listen_fds.3.html |
| 5 | systemd.exec(5) | systemd 262 (latest page, fetched 2026-11-24) | https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html |
| 6 | udev(7) | man7.org copy; version stamp not read | https://man7.org/linux/man-pages/man7/udev.7.html |

In the text, "S1" is source 1, and so on. The "latest" pages move; a later read can differ from this one.

## (a) What SO_PEERCRED returns, and when

- The option returns the credentials of the process at the other end of a connected socket: process id, user id and group
  id, in a `ucred` structure (S1, section "Socket options", SO_PEERCRED; S2 points to S1 for it).
- The credentials are the ones in effect when that peer called `connect`, `listen` or `socketpair`. They are captured
  then, not at each later message (S1, same section). A peer that changes identity afterwards is not reflected.
- It works only on connected Unix stream sockets and on socket pairs (S1, same section). The call is made on the
  accepted descriptor on the listening side.
- A related option, SO_PASSCRED, instead delivers the sender's credentials with each received message (S1, "Socket
  options"). The two differ in when the identity is taken.
- **Unconfirmed:** behaviour under user namespaces or containers; the pages read do not settle it.

## (b) Filesystem-path sockets and abstract-namespace sockets, for access control

- A path socket is a file. Linux checks the permissions of the directory when it is created, and connecting needs write
  permission on the socket file. Owner, group and mode can be changed like any file (S1, "Pathname socket ownership and
  permissions"). A new socket starts with all permission bits, less the process umask.
- S1 itself says a portable program should not rely on socket-file permissions for security, because other systems
  ignore them. This design targets Linux only; whether to rely on them is for the owner. **Unconfirmed** for the image's
  kernel beyond what the page says.
- An abstract socket has a name that begins with a null byte and has no file. Permissions have no meaning for it:
  umask does not apply and changing ownership or mode has no effect on who can connect (S1, "Abstract sockets"). Access
  control for such a socket therefore rests on something else, such as the peer credentials in (a), or on the network
  namespace, which S1 does not discuss. **Unconfirmed** for namespace effects.
- The abstract namespace is a Linux-only extension and the socket disappears when the last reference closes (S1).

## (c) How systemd hands a listening socket to a service

- The service manager creates, binds and listens on the socket from a socket unit, then starts the matching service and
  passes the open descriptors to it (S3, "Description"; S4). The service need not bind anything itself.
- The service finds them by calling `sd_listen_fds`, which returns how many descriptors it received. The first is
  descriptor 3, the rest follow in order (S4). The call checks that the environment variables meant for it carry this
  process's id, then clears them by default (S4). A name list can tell the descriptors apart (S4, `$LISTEN_FDNAMES`; S3
  FileDescriptorName).
- Owner and mode of the socket file are set by the socket unit: SocketUser and SocketGroup (default: root, in system
  context) and SocketMode (default 0666), plus DirectoryMode for parent directories it creates (S3, "Options"). The
  default mode is wide open, so a unit that wants a narrow socket sets it.
- With Accept set to no, one service gets the listening socket; with yes, a service instance is started per connection
  and gets the accepted socket (S3, Accept). Which one go-xkms wants is its question.
- **Unconfirmed:** how this interacts with a service that is also started without the socket unit; not read.

## (d) A device node reserved for one service account

- On the node: the enclave node is `hsm0_ch0` under `/dev` (see [the enclave trace](enclave-interface-trace.md), (a)).
  Its mode and owner on the image are **unconfirmed** there; the driver sets none, so the device manager decides.
- udev rules can set the node's owner, group and mode with the OWNER, GROUP and MODE keys; each value given replaces the
  compiled-in default (S6, rules "Fields" for OWNER, GROUP, MODE). A rule matches by kernel name, so one rule could name
  that node. This record writes no rule.
- systemd.exec limits what a service can see. User and Group set the account the service runs as; DynamicUser allocates
  a transient account (S5). PrivateDevices gives the service a private `/dev` with only pseudo devices, so a service
  that needs the enclave node cannot turn it on (S5). To allow named nodes, the pages point to the DeviceAllow and
  DevicePolicy options of systemd.resource-control(5) (S5, PrivateDevices and sandboxing text).
- **Unconfirmed:** the exact DeviceAllow syntax and its interaction with a udev-set mode: systemd.resource-control(5) was
  not fetched. Whether a dynamic account can own a udev-set node was not read.
- The two mechanisms are independent: udev sets who the file system allows, the unit sets what the service may reach.

## What this trace does not decide

- Whether xkmsd is one process or two is go-xkms's question ([xkmsd-node.md](xkmsd-node.md) §4 question 2). Nothing here
  needs a second process; it only describes the seam if there is one.
- R6 and R8 stay proposed, pending owner approval. This trace adds, changes and removes no requirement.
- It names no socket path, port, message or timeout. It writes no udev rule or unit file into the image; that is later row
  work, after the owner approves R6 and R8.
- Findings that may bear on their wording, listed for the owner, each proposed input: peer credentials are fixed at
  connect time (a); a path socket's access follows file modes while an abstract one has none (b); the default socket mode
  is wide open (c); the node's mode comes from the device manager, and a private `/dev` hides it (d).
