#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
RouterFinder - 局域网 DHCP 路由器探测
适用于: iOS 越狱设备 + iSH (App Store 免费安装)
原理: 网关推断 + TCP 端口指纹 + HTTP 标题识别，无需越狱权限也能在 iSH 内运行
"""

import socket
import concurrent.futures
import re
import sys


PORTS = [80, 443, 8080, 8081, 1900, 53, 22, 23]
PORT_NAMES = {
    80: "HTTP管理页", 443: "HTTPS", 8080: "备用管理口", 8081: "备用管理口",
    1900: "UPnP", 53: "DNS转发", 22: "SSH", 23: "Telnet",
}


def get_local_ip():
    """用 UDP connect 技巧获取本机局域网 IP（不真的发包）"""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return None


def infer_gateway(ip):
    """家庭网络里网关几乎总是网段的 .1"""
    parts = ip.split(".")
    return "{}.{}.{}.1".format(parts[0], parts[1], parts[2])


def scan_port(ip, port, timeout=0.5):
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(timeout)
        code = s.connect_ex((ip, port))
        s.close()
        return code == 0
    except Exception:
        return False


def get_http_title(ip, port=80, timeout=1.0):
    """抓取管理页的 <title>，用来认路由器品牌"""
    try:
        s = socket.create_connection((ip, port), timeout)
        req = "GET / HTTP/1.0\r\nHost: {}\r\nUser-Agent: Mozilla/5.0\r\n\r\n".format(ip)
        s.sendall(req.encode())
        data = b""
        while len(data) < 8192:
            chunk = s.recv(4096)
            if not chunk:
                break
            data += chunk
        s.close()
        text = data.decode("utf-8", errors="ignore")
        m = re.search(r"<title[^>]*>(.*?)</title>", text, re.I | re.S)
        if m:
            title = re.sub(r"\s+", " ", m.group(1)).strip()
            return title[:80] if title else None
    except Exception:
        pass
    return None


def is_likely_router(host, ports, gateway):
    if host == gateway:
        return True
    s = set(ports)
    web = s.intersection([80, 443, 8080, 8081])
    if 1900 in s and web:
        return True
    if 53 in s and web:
        return True
    return False


def main():
    local_ip = get_local_ip()
    if not local_ip:
        print("无法获取本机 IP，请确认已连接 Wi-Fi")
        sys.exit(1)

    gateway = infer_gateway(local_ip)
    prefix = ".".join(local_ip.split(".")[:3])
    hosts = ["{}.{}".format(prefix, i) for i in range(1, 255) if "{}.{}".format(prefix, i) != local_ip]

    print("=" * 58)
    print("  RouterFinder - 局域网路由器探测")
    print("=" * 58)
    print("  本机 IP : {}".format(local_ip))
    print("  推测网关: {}".format(gateway))
    print("  扫描范围: {}.1 - {}.254 (共 {} 个主机)".format(prefix, len(hosts)))
    print("  检测端口: {}".format(",".join(map(str, PORTS))))
    print("=" * 58)
    print("  开始扫描，约需 20~40 秒，请稍候...\n")

    results = {}
    tasks = [(h, p) for h in hosts for p in PORTS]
    done = 0

    with concurrent.futures.ThreadPoolExecutor(max_workers=40) as pool:
        futures = {pool.submit(scan_port, h, p): (h, p) for h, p in tasks}
        for future in concurrent.futures.as_completed(futures):
            host, port = futures[future]
            if future.result():
                results.setdefault(host, []).append(port)
            done += 1
            if done % 200 == 0:
                print("  进度 {}/{}".format(done, len(tasks)), end="\r")

    # 网关即使没扫到端口也列出来 —— 它仍是 DHCP 服务器的最强候选
    results.setdefault(gateway, [])

    def rank(host):
        score = 0
        if host == gateway:
            score += 100
        p = set(results[host])
        if 1900 in p:
            score += 10
        if 53 in p:
            score += 10
        if p.intersection([80, 443, 8080, 8081]):
            score += 5
        return score

    ordered = sorted(results, key=rank, reverse=True)

    print("\n" + "=" * 58)
    print("  扫描结果（疑似路由器排在最前）")
    print("=" * 58)
    for host in ordered:
        ports = sorted(results[host])
        router = is_likely_router(host, ports, gateway)
        tag = "  ★ 疑似 DHCP 路由器" if router else ""
        print("\n  {}{}".format(host, tag))
        if ports:
            desc = ", ".join("{} ({})".format(p, PORT_NAMES.get(p, "TCP")) for p in ports)
            print("    开放端口: {}".format(desc))
        else:
            print("    开放端口: 无（网关仍可能是 DHCP 服务端）")
        if 80 in ports:
            title = get_http_title(host)
            if title:
                print("    管理页标题: {}".format(title))

    print("\n" + "=" * 58)
    print("  共发现 {} 台设备。访问管理页: 浏览器打开 http://{}".format(len(ordered), gateway))
    print("=" * 58)


if __name__ == "__main__":
    main()
