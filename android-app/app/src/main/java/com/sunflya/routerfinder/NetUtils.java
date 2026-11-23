package com.sunflya.routerfinder;

public final class NetUtils {
    private NetUtils() {}

    /** Android's DhcpInfo stores IPv4 addresses in little-endian int form. */
    public static String ipFromInt(int addr) {
        return (addr & 0xff) + "."
                + ((addr >> 8) & 0xff) + "."
                + ((addr >> 16) & 0xff) + "."
                + ((addr >> 24) & 0xff);
    }

    public static String ipFromBytes(byte[] b, int off) {
        return (b[off] & 0xff) + "." + (b[off + 1] & 0xff) + "."
                + (b[off + 2] & 0xff) + "." + (b[off + 3] & 0xff);
    }

    public static int readInt(byte[] b, int off) {
        return ((b[off] & 0xff) << 24) | ((b[off + 1] & 0xff) << 16)
                | ((b[off + 2] & 0xff) << 8) | (b[off + 3] & 0xff);
    }

    public static String macToString(byte[] b, int len) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < len; i++) {
            if (i > 0) sb.append(':');
            sb.append(String.format("%02X", b[i] & 0xff));
        }
        return sb.toString();
    }
}
