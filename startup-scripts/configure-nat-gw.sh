#! /bin/bash

echo "Configuring IP Tables for NAT"

sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
