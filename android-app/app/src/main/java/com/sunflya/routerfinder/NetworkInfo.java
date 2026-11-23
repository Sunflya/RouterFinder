package com.sunflya.routerfinder;

import android.content.Context;
import android.net.DhcpInfo;
import android.net.wifi.WifiManager;

import java.util.ArrayList;
import java.util.List;

public class NetworkInfo {
    public final String ip;
    public final String netmask;
    public final String gateway;
    public final String dns;
    public final String netAddress;
    public final String broadcast;
    public final int prefix;

    private NetworkInfo(String ip, String netmask, String gateway, String dns,
                        String netAddress, String broadcast, int prefix) {
        this.ip = ip;
        this.netmask = netmask;
        this.gateway = gateway;
        this.dns = dns;
        this.netAddress = netAddress;
        this.broadcast = broadcast;
        this.prefix = prefix;
    }

    public static NetworkInfo from(Context context) {
        try {
            WifiManager wm = (WifiManager) context.getApplicationContext()
                    .getSystemService(Context.WIFI_SERVICE);
            if (wm == null) return null;
            DhcpInfo d = wm.getDhcpInfo();
            if (d == null || d.ipAddress == 0) return null;
            int ip = d.ipAddress;
            int mask = d.netmask != 0 ? d.netmask : 0xffffff00;
            int net = ip & mask;
            int bcast = net | (~mask);
            int prefix = Integer.bitCount(mask);
            return new NetworkInfo(
                    NetUtils.ipFromInt(ip),
                    NetUtils.ipFromInt(mask),
                    NetUtils.ipFromInt(d.gateway),
                    NetUtils.ipFromInt(d.dns1),
                    NetUtils.ipFromInt(net),
                    NetUtils.ipFromInt(bcast),
                    prefix);
        } catch (Exception e) {
            return null;
        }
    }

    /** Host addresses to probe, capped at 254 for typical home /24 networks. */
    public List<String> hostIps() {
        List<String> list = new ArrayList<>();
        long net = ipv4ToLong(netAddress);
        long bc = ipv4ToLong(broadcast);
        long start = net + 1;
        long end = Math.min(bc - 1, net + 254);
        if (end < start) return list;
        for (long a = start; a <= end; a++) {
            list.add(longToIp(a));
        }
        return list;
    }

    private static long ipv4ToLong(String ip) {
        String[] p = ip.split("\\.");
        long v = 0;
        for (String s : p) {
            v = (v << 8) | (Long.parseLong(s) & 0xff);
        }
        return v;
    }

    private static String longToIp(long v) {
        return ((v >> 24) & 0xff) + "." + ((v >> 16) & 0xff) + "."
                + ((v >> 8) & 0xff) + "." + (v & 0xff);
    }
}
