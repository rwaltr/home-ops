# Network Documentation

Usable Networks

RFC1918

- 192.168.0.0/16
- 10.0.0.0/8
- 172.16.0.0/12

ULA

- fc::/7

## KYZ

### Overview

ULA

- fdfe:dc53:db52::/48

| Vlan | Network                  | Use         |
| ---- | ------------------------ | ----------- |
| 0    | 192.168.1.0/24           | Userland    |
| 10   | 10.10.0.0/24             | RackNet     |
| 0    | fdfe:dc53:db52:42ea::/64 | Userland-v6 |
| 10   | fdfe:dc53:db52:1::/64    | Racknet-v6  |
