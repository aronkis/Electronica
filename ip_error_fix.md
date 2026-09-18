 ./anyssh.sh 10.0.0.146 'ip addr replace 10.66.0.1 peer 10.66.0.2 dev tun0
  ip link set tun0 up mtu 1516
  ip route replace 10.66.0.2 dev tun0 advmss 1476 rto_min 25ms 2>/dev/null
  echo ---
  ip -4 addr show tun0' 2>/dev/null | grep -v "post-quantum\|store now, decrypt later\|may need to be upgraded\|openssh.com/pq")
---
29: tun0: <POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP> mtu 1516 qdisc pfifo_fast state UNKNOWN group default qlen 500
    inet 10.66.0.1 peer 10.66.0.2/32 scope global tun0
       valid_lft forever preferred_lft forever