package com.sunflya.routerfinder;

import android.content.Context;
import android.net.wifi.WifiManager;

import java.io.ByteArrayOutputStream;
import java.io.DataOutputStream;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetAddress;
import java.net.SocketException;
import java.net.SocketTimeoutException;
import java.security.SecureRandom;

/**
 * Active DHCP server detection: send a real DHCP Discover, wait for DHCP Offer.
 * A reply proves the target is running a DHCP server; option 54 identifies it.
 */
public final class DhcpProber {
    private DhcpProber() {}

    public static class Result {
        public boolean detected;
        public String serverId;
        public String offeredIp;
        public String subnetMask;
        public String gateway;
        public String dns;
        public int leaseSeconds = -1;
        public String detail;
    }

    public static Result probe(Context context, String target) {
        Result result = new Result();
        byte[] mac = getMac(context);
        int xid = new SecureRandom().nextInt();

        DatagramSocket socket = null;
        String bindMode;
        try {
            socket = new DatagramSocket(68);
            bindMode = "端口 68";
        } catch (Exception e) {
            try {
                socket = new DatagramSocket(0);
                bindMode = "高位端口（68 被系统占用）";
            } catch (Exception e2) {
                result.detail = "无法创建 UDP socket: " + e2.getMessage();
                return result;
            }
        }

        try {
            socket.setBroadcast(true);
            socket.setSoTimeout(1200);
            byte[] discover = buildDiscover(mac, xid);
            DatagramPacket out = new DatagramPacket(
                    discover, discover.length, InetAddress.getByName(target), 67);
            socket.send(out);

            long deadline = System.currentTimeMillis() + 4000;
            while (System.currentTimeMillis() < deadline) {
                byte[] buf = new byte[2048];
                DatagramPacket reply = new DatagramPacket(buf, buf.length);
                try {
                    socket.receive(reply);
                } catch (SocketTimeoutException te) {
                    continue;
                }
                Result parsed = parseOffer(reply.getData(), reply.getLength(), xid);
                if (parsed == null) continue;
                if (parsed.serverId == null) {
                    parsed.serverId = reply.getAddress().getHostAddress();
                }
                parsed.detail = "收到 DHCP Offer（绑定" + bindMode
                        + "，源 " + reply.getAddress().getHostAddress() + "）";
                return parsed;
            }
            result.detail = "已发送 Discover，4 秒内未收到 Offer（绑定" + bindMode
                    + "）。该设备可能未运行 DHCP 服务，或对源端口有要求。";
            return result;
        } catch (Exception e) {
            result.detail = "探测异常: " + e.getMessage();
            return result;
        } finally {
            socket.close();
        }
    }

    private static byte[] getMac(Context context) {
        try {
            WifiManager wm = (WifiManager) context.getApplicationContext()
                    .getSystemService(Context.WIFI_SERVICE);
            if (wm != null) {
                String s = wm.getConnectionInfo().getMacAddress();
                if (s != null && s.matches("(?i)[0-9a-f]{2}(:[0-9a-f]{2}){5}")) {
                    byte[] mac = new byte[6];
                    String[] parts = s.split(":");
                    for (int i = 0; i < 6; i++) {
                        mac[i] = (byte) Integer.parseInt(parts[i], 16);
                    }
                    return mac;
                }
            }
        } catch (Exception ignored) { }
        // Locally administered random MAC as fallback
        byte[] mac = new byte[6];
        new SecureRandom().nextBytes(mac);
        mac[0] = (byte) ((mac[0] & 0xfe) | 0x02);
        return mac;
    }

    private static byte[] buildDiscover(byte[] mac, int xid) throws Exception {
        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        DataOutputStream d = new DataOutputStream(bos);
        d.writeByte(1);                 // op: BOOTREQUEST
        d.writeByte(1);                 // htype: Ethernet
        d.writeByte(6);                 // hlen
        d.writeByte(0);                 // hops
        d.writeInt(xid);
        d.writeShort(0);                // secs
        d.writeShort(0x8000);           // flags: broadcast
        d.writeInt(0);                  // ciaddr
        d.writeInt(0);                  // yiaddr
        d.writeInt(0);                  // siaddr
        d.writeInt(0);                  // giaddr
        byte[] chaddr = new byte[16];
        System.arraycopy(mac, 0, chaddr, 0, 6);
        d.write(chaddr);
        d.write(new byte[64]);          // sname
        d.write(new byte[128]);         // file
        d.write(new byte[]{99, (byte) 130, 83, 99}); // magic cookie
        d.writeByte(53); d.writeByte(1); d.writeByte(1);              // Discover
        d.writeByte(55); d.writeByte(4);                              // parameter request
        d.writeByte(1); d.writeByte(3); d.writeByte(6); d.writeByte(51);
        d.writeByte(61); d.writeByte(7); d.writeByte(1); d.write(mac, 0, 6); // client id
        d.writeByte(255);               // END
        d.flush();
        return bos.toByteArray();
    }

    private static Result parseOffer(byte[] p, int len, int xid) {
        if (p == null || len < 240) return null;
        if ((p[0] & 0xff) != 2) return null;             // BOOTREPLY
        if (NetUtils.readInt(p, 4) != xid) return null;
        if ((p[236] & 0xff) != 99 || (p[237] & 0xff) != 130
                || (p[238] & 0xff) != 83 || (p[239] & 0xff) != 99) return null;

        Result r = new Result();
        r.detected = true;
        r.offeredIp = NetUtils.ipFromBytes(p, 16);      // yiaddr
        int i = 240;
        while (i + 1 < len) {
            int code = p[i++] & 0xff;
            if (code == 255) break;
            if (code == 0) continue;
            if (i >= len) break;
            int l = p[i++] & 0xff;
            if (i + l > len) break;
            switch (code) {
                case 1:
                    if (l >= 4) r.subnetMask = NetUtils.ipFromBytes(p, i);
                    break;
                case 3:
                    if (l >= 4) r.gateway = NetUtils.ipFromBytes(p, i);
                    break;
                case 6:
                    if (l >= 4) r.dns = NetUtils.ipFromBytes(p, i);
                    break;
                case 51:
                    if (l >= 4) r.leaseSeconds = NetUtils.readInt(p, i);
                    break;
                case 54:
                    if (l >= 4) r.serverId = NetUtils.ipFromBytes(p, i);
                    break;
                default:
                    break;
            }
            i += l;
        }
        return r;
    }
}
