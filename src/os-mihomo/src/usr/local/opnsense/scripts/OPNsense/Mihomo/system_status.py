#!/usr/local/bin/python3
"""Mihomo system status for configd action [system-status].

输出一行 JSON 供 Status 页面合并展示：
  state/mode/pid 来自状态机文件，memory 为进程 RSS，
  tun_status/api_status/dns_status/proxy_status 为实时探测结果。
TUN 未启用时视为 socks 核心模式（tun_status="SOCKS"、socks_mode=true）。
任何异常均输出 {}，退出码恒为 0，避免探测失败中断 configd action。
"""

import json
import os
import re
import subprocess

STATE_RUN_FILE = "/var/run/mihomo_state.json"
STATE_DB_FILE = "/var/db/os-mihomo/state.json"
PID_FILE = "/var/run/mihomo.pid"
CONF_FILE = "/usr/local/etc/mihomo/config.yaml"
TRANSPORT_MODE_FILE = "/var/db/os-mihomo/transport-mode"

TUN_DEVICE = "tun_mihomo"
HEV_TUN_DEVICE = "tun0"
SOCKS_PORT = 7891
DNS_PORT = 1053
FALLBACK_API_BIND = "127.0.0.1"
FALLBACK_API_PORT = 9090


def load_state():
    """读取状态机 JSON，run 目录优先，其次持久化目录。"""
    for target in (STATE_RUN_FILE, STATE_DB_FILE):
        if not os.path.exists(target):
            continue
        try:
            with open(target, "r") as handle:
                loaded = json.load(handle)
            if isinstance(loaded, dict):
                return loaded
        except (OSError, ValueError):
            continue
    return {}


def read_pid(state):
    pid = state.get("pid")
    if pid:
        try:
            return int(pid)
        except (TypeError, ValueError):
            pass
    try:
        with open(PID_FILE, "r") as handle:
            return int(handle.read().strip())
    except (OSError, ValueError):
        return None


def read_memory(pid):
    """ps -o rss= 输出 KB，换算为 MB。"""
    if not pid:
        return "0 MB"
    try:
        result = subprocess.run(
            ["ps", "-o", "rss=", "-p", str(pid)],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=5,
        )
        rss = result.stdout.decode(errors="replace").strip()
        if rss.isdigit():
            return "%.1f MB" % (int(rss) / 1024.0)
    except (OSError, subprocess.SubprocessError):
        pass
    return "0 MB"


def port_listening(port):
    """sockstat 无匹配时退出码也可能为 0，按输出中的 :port 判断。"""
    try:
        result = subprocess.run(
            ["sockstat", "-l", "-p", str(port)],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    text = result.stdout.decode(errors="replace")
    return re.search(r":%d(?:\s|$)" % port, text) is not None


def read_api_addr():
    """解析 config.yaml 的 external-controller（与 sub_lib.sh 同语义）。

    0.0.0.0 归一化为 127.0.0.1（探测走本机回环）；缺失/损坏回退默认回环地址。
    返回 (host, port)。
    """
    host = None
    port = None
    try:
        with open(CONF_FILE, "r") as handle:
            for line in handle:
                match = re.match(r"^external-controller:\s*(.*)$", line.rstrip("\n"))
                if not match:
                    continue
                value = re.sub(r"\s+#.*$", "", match.group(1)).strip()
                value = value.strip("\"'")
                parts = value.split(":")
                if len(parts) == 2:
                    candidate_host, candidate_port = parts
                    if re.match(r"^\d+\.\d+\.\d+\.\d+$", candidate_host) and candidate_port.isdigit():
                        octets = [int(part) for part in candidate_host.split(".")]
                        if all(0 <= octet <= 255 for octet in octets) and 1 <= int(candidate_port) <= 65535:
                            host = candidate_host
                            port = int(candidate_port)
                break
    except OSError:
        pass
    if host is None or port is None:
        return FALLBACK_API_BIND, FALLBACK_API_PORT
    if host == "0.0.0.0":
        host = "127.0.0.1"
    return host, port


def tun_enabled():
    """判定 config.yaml 的 tun 块内 enable 是否为 true。"""
    try:
        in_tun = False
        with open(CONF_FILE, "r") as handle:
            for line in handle:
                stripped = line.rstrip("\n")
                if stripped.startswith("tun:"):
                    in_tun = True
                    continue
                if in_tun and stripped and stripped[0] not in (" ", "\t", "#"):
                    in_tun = False
                if in_tun and re.match(r"^\s+enable:\s*true\b", stripped):
                    return True
    except OSError:
        pass
    return False


def tun_up():
    try:
        return subprocess.run(
            ["ifconfig", TUN_DEVICE],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=5,
        ).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def read_transport_mode():
    """读取 transport 模式：文件内容 strip 后等于 transparent 才是 transparent，其余均为 proxy。"""
    try:
        if os.path.exists(TRANSPORT_MODE_FILE):
            with open(TRANSPORT_MODE_FILE, "r") as handle:
                content = handle.read().strip()
                if content == "transparent":
                    return "transparent"
    except OSError:
        pass
    return "proxy"


def hev_tun_up():
    """探测 tun0：ifconfig tun0 首行 flags 须同时含 UP 与 RUNNING 才算 UP。"""
    try:
        result = subprocess.run(
            ["ifconfig", HEV_TUN_DEVICE],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=5,
        )
        if result.returncode != 0:
            return False
        first_line = result.stdout.decode(errors="replace").splitlines()[0] if result.stdout else ""
        match = re.search(r"flags=\d+<([^>]+)>", first_line)
        if match:
            flags = match.group(1).split(",")
            return "UP" in flags and "RUNNING" in flags
    except (OSError, subprocess.SubprocessError, IndexError):
        pass
    return False


def collect():
    state = load_state()
    pid = read_pid(state)
    tun_mode = tun_enabled()
    transport_mode = read_transport_mode()
    api_bind, api_port = read_api_addr()

    if tun_mode:
        tun_status = "UP" if tun_up() else "DOWN"
        tun_kind = "mihomo-tun"
    elif transport_mode == "transparent":
        tun_status = "UP" if hev_tun_up() else "DOWN"
        tun_kind = "hev-tun"
    else:
        tun_status = "SOCKS"
        tun_kind = "none"

    return {
        "state": state.get("state", "STOPPED"),
        "mode": state.get("mode", "DIRECT"),
        "pid": pid,
        "memory": read_memory(pid),
        "tun_status": tun_status,
        "tun_kind": tun_kind,
        "transport_mode": transport_mode,
        "api_status": "UP" if port_listening(api_port) else "DOWN",
        "api_bind": api_bind,
        "api_port": api_port,
        "dns_status": "UP" if port_listening(DNS_PORT) else "DOWN",
        "proxy_status": "UP" if port_listening(SOCKS_PORT) else "DOWN",
        "socks_mode": not tun_mode,
    }


def main():
    try:
        print(json.dumps(collect()))
    except Exception:
        print("{}")


if __name__ == "__main__":
    main()
