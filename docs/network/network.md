# Network Documentation

Usable Networks

### RFC1918

- 192.168.0.0/16
- 10.0.0.0/8
- 172.16.0.0/12

### ULA

- fc::/7

## Global Net

- Routernet
  - 172.16.12.0/24
  - fd76:feeb:d6e0::/48

Waltr.Tech ASNs
16 bit

- RFC5398
  - 64512-65534

32 bit
rfc6996 4200000000-4294967294

Waltr.Tech is AS4242421540

## KYZ

### Overview

ULA

- fdfe:dc53:db52::/48

| Vlan | Network                  | Use         |
| ---- | ------------------------ | ----------- |
| 0    | 192.168.1.0/24           | Userland    |
| 0    | fd76:feeb:d6e0:6900::/64 | Userland-v6 |
| 10   | 10.10.0.0/24             | RackNet     |
| 10   | fd76:feeb:d6e0:1100::/64 | Racknet-v6  |
