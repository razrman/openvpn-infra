#!/usr/bin/env python3
"""Render infra/vpn/access.yaml into an iptables-restore fragment.

Client names resolve through a JSON object of name to static VPN address.
Missing names are skipped with a warning. The dynamic pool is rejected
if a mapped address falls in it. Established flows are accepted first so
replacing the chain does not cut them.
"""

import json
import sys


def die(message):
    sys.stderr.write("render-access: %s\n" % message)
    sys.exit(1)


def parse_rules(text):
    rules = []
    current = None
    started = False
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.split("#", 1)[0].rstrip()
        if not line.strip():
            continue
        if line.strip() == "rules:":
            if started:
                die("line %d: rules: repeated" % lineno)
            started = True
            continue
        if not started:
            die("line %d: expected rules:" % lineno)
        stripped = line.strip()
        if stripped.startswith("- "):
            if current:
                rules.append(current)
            body = stripped[2:].strip()
            if not body.startswith("from:"):
                die("line %d: a rule must start with from:" % lineno)
            current = {"from": body.split(":", 1)[1].strip(), "line": lineno}
            continue
        if current is not None and ":" in stripped:
            key, value = stripped.split(":", 1)
            current[key.strip()] = value.strip()
            continue
        die("line %d: cannot parse %r" % (lineno, raw))
    if current:
        rules.append(current)
    if not started:
        die("missing rules:")
    return rules


def check_name(name, lineno):
    if name in ("any-client", "gonetlogo", "vpn-server"):
        return
    ok = name[:1].islower() and name[:1].isalpha()
    ok = ok and all(ch.islower() or ch.isdigit() or ch == "-" for ch in name)
    if not ok or len(name) > 32:
        die("line %d: %r is not a client name" % (lineno, name))


def load_clients(path, prefix, low, high):
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        die("client map must be a JSON object")
    clients = {}
    for name, ip in data.items():
        if name == "vpn-server":
            die("vpn-server is the tunnel address, not a client name")
        check_name(name, 0)
        text = str(ip).strip()
        if not text.startswith(prefix + "."):
            die("client %s has address %s outside %s.0/24" % (name, text, prefix))
        octet = text.rsplit(".", 1)[-1]
        if not octet.isdigit() or str(int(octet)) != octet:
            die("client %s has address %s" % (name, text))
        number = int(octet)
        if number < low or number > high:
            die("client %s address %s is in the dynamic pool or reserved" % (name, text))
        clients[name] = text
    return clients


def sources(rule, clients):
    if rule["from"] == "any-client":
        return sorted(clients.items())
    if rule["from"] not in clients:
        sys.stderr.write(
            "render-access: skip line %s, client %s is not active\n"
            % (rule["line"], rule["from"])
        )
        return []
    return [(rule["from"], clients[rule["from"]])]


def destination(rule, clients, gonetlogo, server_ip):
    if rule["to"] == "vpn-server":
        return "vpn-server", server_ip
    if rule["to"] == "gonetlogo":
        return "gonetlogo", gonetlogo
    if rule["to"] not in clients:
        sys.stderr.write(
            "render-access: skip line %s, client %s is not active\n"
            % (rule["line"], rule["to"])
        )
        return None
    return rule["to"], clients[rule["to"]]


def main():
    if len(sys.argv) != 6:
        die("usage: render-access.py rules.yaml clients.json gonetlogo-cidr prefix static-max")
    rules_path, clients_path, gonetlogo, prefix, static_max = sys.argv[1:]
    try:
        high = int(static_max)
    except ValueError:
        die("static-max must be an integer")
    with open(rules_path, encoding="utf-8") as handle:
        rules = parse_rules(handle.read())
    clients = load_clients(clients_path, prefix, 10, high)
    server_ip = prefix + ".1"
    forward = ["-A OPENVPN_FWD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"]
    inbound = ["-A OPENVPN_IN -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"]
    for rule in rules:
        for key in ("from", "to", "proto", "port"):
            if key not in rule or rule[key] == "":
                die("line %s: missing %s" % (rule["line"], key))
        check_name(rule["from"], rule["line"])
        check_name(rule["to"], rule["line"])
        if rule["from"] in ("gonetlogo", "vpn-server"):
            die("line %s: %s cannot open connections" % (rule["line"], rule["from"]))
        if rule["to"] == "any-client":
            die("line %s: any-client is only a source" % rule["line"])
        if rule["proto"] not in ("tcp", "udp"):
            die("line %s: proto must be tcp or udp" % rule["line"])
        if not rule["port"].isdigit() or not 1 <= int(rule["port"]) <= 65535:
            die("line %s: port must be 1-65535" % rule["line"])
        dest = destination(rule, clients, gonetlogo, server_ip)
        if dest is None:
            continue
        dest_name, dest_addr = dest
        chain = inbound if dest_name == "vpn-server" else forward
        prefix_match = "-i tun+ -d %s " % dest_addr if dest_name == "vpn-server" else "-d %s " % dest_addr
        chain_name = "OPENVPN_IN" if dest_name == "vpn-server" else "OPENVPN_FWD"
        for src_name, src_addr in sources(rule, clients):
            if src_addr == dest_addr:
                continue
            comment = "%s->%s %s/%s" % (src_name, dest_name, rule["proto"], rule["port"])
            chain.append(
                '-A %s %s-s %s -p %s --dport %s -m conntrack --ctstate NEW -m comment --comment "%s" -j ACCEPT'
                % (chain_name, prefix_match, src_addr, rule["proto"], rule["port"], comment)
            )
            if dest_name != "vpn-server":
                chain.append(
                    '-A %s -s %s -d %s -p icmp --icmp-type echo-request -m comment --comment "%s" -j ACCEPT'
                    % (chain_name, src_addr, dest_addr, comment + " echo")
                )
    drop = '-m limit --limit 6/min --limit-burst 5 -j LOG --log-prefix "openvpn-drop: " --log-level 4'
    lines = [
        "*filter",
        ":OPENVPN_FWD - [0:0]",
        ":OPENVPN_IN - [0:0]",
        "-F OPENVPN_FWD",
        "-F OPENVPN_IN",
    ]
    lines.extend(forward)
    lines.append("-A OPENVPN_FWD " + drop)
    lines.append("-A OPENVPN_FWD -j DROP")
    lines.extend(inbound)
    lines.append("-A OPENVPN_IN " + drop)
    lines.append("-A OPENVPN_IN -j DROP")
    lines.append("COMMIT")
    sys.stdout.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
