"""
SNMP v2c 최소 구현 (Python 표준 라이브러리만 사용).

라즈베리파이가 RMU 실물(교수님 PELKOREA-RMU-MIB)과 대화하는 데 필요한 것만 있다.
  - 클라이언트: Get, GetNext, Set           → RmuClient (rmu_client.py)
  - Trap 받기: SNMPv2-Trap 해석             → TrapReceiver (rmu_client.py)
  - 에이전트 쪽 인코딩: 응답, Trap 보내기    → 모의 RMU (mock_pelkorea_rmu.py)

SNMP 메시지는 BER(ASN.1) 형식이다:  SEQUENCE { version, community, PDU }
PDU = [타입] { request-id, error-status, error-index, SEQUENCE { (OID, 값) ... } }
"""

import random
import socket

# ----- BER 태그 -----------------------------------------------------------
INTEGER, OCTET_STRING, NULL, OID, SEQUENCE = 0x02, 0x04, 0x05, 0x06, 0x30
IP_ADDRESS, COUNTER32, GAUGE32, TIMETICKS, COUNTER64 = 0x40, 0x41, 0x42, 0x43, 0x46
NO_SUCH_OBJECT, NO_SUCH_INSTANCE, END_OF_MIB_VIEW = 0x80, 0x81, 0x82
GET, GET_NEXT, RESPONSE, SET, TRAP_V2 = 0xA0, 0xA1, 0xA2, 0xA3, 0xA7

VERSION_2C = 1
SYS_UPTIME_OID = "1.3.6.1.2.1.1.3.0"
SNMP_TRAP_OID = "1.3.6.1.6.3.1.1.4.1.0"

ERROR_NAMES = {0: "noError", 1: "tooBig", 2: "noSuchName", 3: "badValue", 4: "readOnly",
               5: "genErr", 6: "noAccess", 7: "wrongType", 10: "wrongValue",
               12: "inconsistentValue", 17: "notWritable"}


class SnmpError(Exception):
    pass


# ----- 인코딩 -------------------------------------------------------------
def _len(n):
    if n < 0x80:
        return bytes([n])
    out = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([0x80 | len(out)]) + out


def tlv(tag, body):
    return bytes([tag]) + _len(len(body)) + body


def enc_int(v, tag=INTEGER):
    if tag in (COUNTER32, GAUGE32, TIMETICKS, COUNTER64):  # 부호 없는 정수
        body = v.to_bytes(max(1, (v.bit_length() + 8) // 8), "big")
    else:
        body = v.to_bytes(max(1, (v.bit_length() + 8) // 8), "big", signed=True)
    return tlv(tag, body)


def enc_oid(oid):
    arcs = [int(x) for x in oid.strip(".").split(".")]
    body = bytes([40 * arcs[0] + arcs[1]])
    for a in arcs[2:]:
        chunk = [a & 0x7F]
        a >>= 7
        while a:
            chunk.insert(0, 0x80 | (a & 0x7F))
            a >>= 7
        body += bytes(chunk)
    return tlv(OID, body)


def enc_value(kind, value):
    """kind: 'i'(정수) 's'(문자열) 'o'(OID) 'n'(Null) 't'(TimeTicks) 'g'(Gauge32) 'c'(Counter32)
    또는 응답 전용 'noSuchObject' 등"""
    if kind == "i":
        return enc_int(int(value))
    if kind == "s":
        return tlv(OCTET_STRING, value.encode("utf-8") if isinstance(value, str) else bytes(value))
    if kind == "o":
        return enc_oid(value)
    if kind == "t":
        return enc_int(int(value), TIMETICKS)
    if kind == "g":
        return enc_int(int(value), GAUGE32)
    if kind == "c":
        return enc_int(int(value), COUNTER32)
    if kind == "noSuchObject":
        return tlv(NO_SUCH_OBJECT, b"")
    if kind == "noSuchInstance":
        return tlv(NO_SUCH_INSTANCE, b"")
    if kind == "endOfMibView":
        return tlv(END_OF_MIB_VIEW, b"")
    return tlv(NULL, b"")


def encode_message(community, pdu_type, request_id, varbinds, error_status=0, error_index=0):
    """varbinds: [(oid, kind, value)]"""
    vb = b"".join(tlv(SEQUENCE, enc_oid(o) + enc_value(k, v)) for o, k, v in varbinds)
    pdu = tlv(pdu_type, enc_int(request_id) + enc_int(error_status) + enc_int(error_index)
              + tlv(SEQUENCE, vb))
    return tlv(SEQUENCE, enc_int(VERSION_2C) + tlv(OCTET_STRING, community.encode()) + pdu)


# ----- 디코딩 -------------------------------------------------------------
def _read(data, pos):
    tag = data[pos]
    length = data[pos + 1]
    pos += 2
    if length & 0x80:
        n = length & 0x7F
        length = int.from_bytes(data[pos:pos + n], "big")
        pos += n
    return tag, data[pos:pos + length], pos + length


def _children(body):
    pos, out = 0, []
    while pos < len(body):
        tag, value, pos = _read(body, pos)
        out.append((tag, value))
    return out


def dec_oid(body):
    arcs = [body[0] // 40, body[0] % 40]
    n = 0
    for b in body[1:]:
        n = (n << 7) | (b & 0x7F)
        if not b & 0x80:
            arcs.append(n)
            n = 0
    return ".".join(str(a) for a in arcs)


def dec_value(tag, body):
    """(종류, 값). 종류: 'i' 's' 'o' 'n' 't' 'g' 'c' 'noSuchObject' ..."""
    if tag == INTEGER:
        return "i", int.from_bytes(body, "big", signed=True) if body else 0
    if tag == OCTET_STRING:
        return "s", body.decode("utf-8", "replace")
    if tag == OID:
        return "o", dec_oid(body)
    if tag in (COUNTER32, GAUGE32, TIMETICKS, COUNTER64):
        return {COUNTER32: "c", GAUGE32: "g", TIMETICKS: "t", COUNTER64: "c"}[tag], int.from_bytes(body, "big")
    if tag == IP_ADDRESS:
        return "s", ".".join(str(b) for b in body)
    if tag == NO_SUCH_OBJECT:
        return "noSuchObject", None
    if tag == NO_SUCH_INSTANCE:
        return "noSuchInstance", None
    if tag == END_OF_MIB_VIEW:
        return "endOfMibView", None
    return "n", None


def decode_message(data):
    """→ dict(community, pdu_type, request_id, error_status, error_index, varbinds=[(oid, kind, value)])"""
    tag, body, _ = _read(data, 0)
    if tag != SEQUENCE:
        raise SnmpError("SNMP 메시지가 아닙니다")
    parts = _children(body)
    version = int.from_bytes(parts[0][1], "big")
    if version != VERSION_2C:
        raise SnmpError(f"SNMP v2c만 지원합니다 (version={version})")
    community = parts[1][1].decode("utf-8", "replace")
    pdu_type, pdu_body = parts[2]
    fields = _children(pdu_body)
    varbinds = []
    for _, vb in _children(fields[3][1]):
        (otag, obody), (vtag, vbody) = _children(vb)
        kind, value = dec_value(vtag, vbody)
        varbinds.append((dec_oid(obody), kind, value))
    return {
        "community": community, "pdu_type": pdu_type,
        "request_id": int.from_bytes(fields[0][1], "big", signed=True),
        "error_status": int.from_bytes(fields[1][1], "big"),
        "error_index": int.from_bytes(fields[2][1], "big"),
        "varbinds": varbinds,
    }


# ----- 클라이언트 ----------------------------------------------------------
class SnmpClient:
    def __init__(self, host, port=161, community="public", timeout=2.0, retries=1):
        self.host, self.port, self.community = host, port, community
        self.timeout, self.retries = timeout, retries

    def _request(self, pdu_type, varbinds, community=None):
        request_id = random.randint(1, 2**31 - 1)
        packet = encode_message(community or self.community, pdu_type, request_id, varbinds)
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.settimeout(self.timeout)
            for _ in range(self.retries + 1):
                sock.sendto(packet, (self.host, self.port))
                try:
                    while True:
                        data, _ = sock.recvfrom(65535)
                        msg = decode_message(data)
                        if msg["request_id"] == request_id:
                            break
                except socket.timeout:
                    continue
                if msg["error_status"]:
                    name = ERROR_NAMES.get(msg["error_status"], str(msg["error_status"]))
                    raise SnmpError(f"{name} (index {msg['error_index']})")
                return msg["varbinds"]
        raise SnmpError(f"{self.host}:{self.port} 응답 없음 (시간 초과)")

    def get(self, oids):
        """→ {oid: 값}. 없는 OID는 None"""
        vbs = self._request(GET, [(o.strip("."), "n", None) for o in oids])
        return {o: (None if k.startswith("noSuch") else v) for o, k, v in vbs}

    def get_next(self, oid):
        (o, k, v), = self._request(GET_NEXT, [(oid.strip("."), "n", None)])
        return None if k == "endOfMibView" else (o, v)

    def set(self, oid, kind, value, community=None):
        self._request(SET, [(oid.strip("."), kind, value)], community)
