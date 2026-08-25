#!/usr/bin/env python3
"""Raw TLS1.2 ClientHello with max_fragment_length (RFC6066 ext type 1) to test MFLN support."""
import socket, struct, sys, os

def ext(t, data):
    return struct.pack('!HH', t, len(data)) + data

def client_hello(host, mfl_code=1):
    # mfl_code: 1=512, 2=1024, 3=2048, 4=4096
    ciphers = [
        0xc02f, 0xc030, 0xc02b, 0xc02c,  # ECDHE
        0xc013, 0xc014, 0x009c, 0x009d, 0x002f, 0x0035,
    ]
    cs = b''.join(struct.pack('!H', c) for c in ciphers)
    sni_name = host.encode()
    sni = struct.pack('!HBH', len(sni_name) + 3, 0, len(sni_name)) + sni_name
    exts = b''
    exts += ext(0, sni)                                  # server_name
    exts += ext(1, bytes([mfl_code]))                    # max_fragment_length
    exts += ext(11, bytes([1, 0]))                       # ec_point_formats: uncompressed
    groups = struct.pack('!HHHH', 6, 0x001d, 0x0017, 0x0018)  # x25519,p256,p384
    exts += ext(10, groups)                              # supported_groups
    sigalgs = [0x0403, 0x0503, 0x0603, 0x0401, 0x0501, 0x0601, 0x0201]
    sa = struct.pack('!H', len(sigalgs) * 2) + b''.join(struct.pack('!H', s) for s in sigalgs)
    exts += ext(13, sa)                                  # signature_algorithms
    exts += ext(23, b'')                                 # extended_master_secret
    exts += ext(0x0016, b'')                             # encrypt_then_mac
    body = struct.pack('!H', 0x0303) + os.urandom(32) + b'\x00'  # version + random + sessid len
    body += struct.pack('!H', len(cs)) + cs
    body += bytes([1, 0])                                # compression
    body += struct.pack('!H', len(exts)) + exts
    hs = bytes([1]) + len(body).to_bytes(3, 'big') + body
    rec = bytes([0x16, 0x03, 0x01]) + struct.pack('!H', len(hs)) + hs
    return rec

def recvn(s, n):
    buf = b''
    while len(buf) < n:
        c = s.recv(n - len(buf))
        if not c:
            raise EOFError('closed after %d bytes' % len(buf))
        buf += c
    return buf

def probe(host, port, mfl_code=1):
    s = socket.create_connection((host, port), timeout=15)
    s.settimeout(15)
    try:
        s.sendall(client_hello(host, mfl_code))
        hdr = recvn(s, 5)
        typ, ver, ln = hdr[0], (hdr[1], hdr[2]), struct.unpack('!H', hdr[3:5])[0]
        payload = recvn(s, ln)
        if typ == 21:
            return 'ALERT level=%d desc=%d' % (payload[0], payload[1])
        if typ != 22:
            return 'unexpected record type %d' % typ
        if payload[0] != 2:
            return 'no ServerHello, hs type %d' % payload[0]
        hs_len = int.from_bytes(payload[1:4], 'big')
        sh = payload[4:4 + hs_len]
        p = 2 + 32
        sidlen = sh[p]; p += 1 + sidlen
        cipher = struct.unpack('!H', sh[p:p+2])[0]; p += 2
        p += 1  # compression
        found = None
        extlist = []
        if p + 2 <= len(sh):
            elen = struct.unpack('!H', sh[p:p+2])[0]; p += 2
            end = p + elen
            while p + 4 <= end:
                et = struct.unpack('!H', sh[p:p+2])[0]
                el = struct.unpack('!H', sh[p+2:p+4])[0]
                ed = sh[p+4:p+4+el]
                extlist.append(et)
                if et == 1:
                    found = ed.hex()
                p += 4 + el
        return 'ServerHello ver=0x%04x cipher=0x%04x exts=%s MFLN_echo=%s' % (
            struct.unpack('!H', sh[0:2])[0], cipher, extlist, found if found is not None else 'ABSENT')
    finally:
        s.close()

targets = [
    ('broker.hivemq.com', 8883),
    ('test.mosquitto.org', 8883),
    ('broker.emqx.io', 8883),
    ('mqtt.eclipseprojects.io', 8883),
    ('a3k7odjbnnqk6g-ats.iot.us-east-1.amazonaws.com', 8883),
    ('www.howsmyssl.com', 443),
]
if len(sys.argv) > 1:
    targets = [(sys.argv[1], int(sys.argv[2]))]
for h, p in targets:
    try:
        print('%-50s -> %s' % ('%s:%d' % (h, p), probe(h, p)))
    except Exception as e:
        print('%-50s -> ERROR %s: %s' % ('%s:%d' % (h, p), type(e).__name__, e))
