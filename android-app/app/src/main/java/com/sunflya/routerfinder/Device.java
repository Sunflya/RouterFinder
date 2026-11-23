package com.sunflya.routerfinder;

import java.util.ArrayList;
import java.util.List;

public class Device {
    public enum DhcpState { UNKNOWN, YES, NO, FAILED }

    public final String ip;
    public String hostname;
    public String mac;
    public final List<Integer> openPorts = new ArrayList<>();
    public final List<String> sources = new ArrayList<>();
    public boolean likelyRouter;

    public DhcpState dhcpState = DhcpState.UNKNOWN;
    public String dhcpServerId;
    public String dhcpOfferedIp;
    public String dhcpMask;
    public String dhcpGateway;
    public String dhcpDns;
    public int dhcpLease = -1;
    public String dhcpDetail;

    public Device(String ip) {
        this.ip = ip;
    }

    public String portsText() {
        if (openPorts.isEmpty()) return "无";
        StringBuilder sb = new StringBuilder();
        for (int p : openPorts) {
            if (sb.length() > 0) sb.append(", ");
            sb.append(p);
        }
        return sb.toString();
    }
}
