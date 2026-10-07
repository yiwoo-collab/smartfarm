"""
푸시 알림 (3단계: 앱이 꺼져 있을 때도 알림).

RMU가 경보 이벤트를 HTTP POST로 푸시 서버에 보낸다. 형식은 ntfy(https://ntfy.sh, 오픈소스)를 따른다.
  - 폰에 ntfy 앱을 설치하고 같은 토픽(주소)을 구독하면 우리 앱이 꺼져 있어도 알림이 온다.
  - ntfy 서버는 직접 띄울 수도 있다 (docker run -p 80:80 binwiederhier/ntfy serve).
  - 본문만 받는 일반 웹훅 주소에도 그대로 쓸 수 있다.

실행 예:  python server.py --push-url http://<ntfy 서버>/smartfarm-1dong --farm-name "방울토마토 1동"

보내는 규칙 (앱 알림 규칙과 같게, 제안)
  - min_level(기본 2) 이상 경보 발생, 그 경보의 해소
  - 같은 항목·같은 등급은 최소 간격(기본 5분) 안에 다시 보내지 않는다
  - 긴급 경보(3)는 해소될 때까지 1분마다 다시 보낸다
"""

import threading
import time
import urllib.request

PRIORITY = {0: "default", 1: "default", 2: "high", 3: "urgent"}
TAGS = {0: "white_check_mark", 1: "warning", 2: "warning", 3: "rotating_light"}
LEVEL_NAMES = ["정상", "주의", "경보", "긴급 경보"]


class PushSender:
    def __init__(self, url, farm_name="스마트팜", min_level=2, min_interval=300, emergency_repeat=60,
                 post=None):
        self.url = url
        self.farm_name = farm_name
        self.min_level = min_level
        self.min_interval = min_interval
        self.emergency_repeat = emergency_repeat
        self._post = post or self._http_post  # 테스트에서 바꿔 끼운다
        self._last_sent = {}       # (key, level) → 보낸 시각
        self._sent_levels = {}     # key → 보낸 경보 등급 (해소 알림을 보낼지 판단)

    # ----- 이벤트 → 푸시 -----------------------------------------------------
    def on_event(self, event, now=None):
        now = now or time.time()
        key, level = event["key"], event["level"]
        if event["type"] == "alarm" and level >= self.min_level:
            last = self._last_sent.get((key, level))
            if level >= 3 or last is None or now - last >= self.min_interval:
                self._send(f"[{LEVEL_NAMES[level]}] {event['message']}", event.get("actions", []), level)
                self._last_sent[(key, level)] = now
                self._sent_levels[key] = level
        elif event["type"] == "clear" and key in self._sent_levels:
            # 푸시로 알렸던 경보가 해소되면 해소도 알린다
            self._send(f"[해소] {event['message']}", event.get("actions", []), 0)
            del self._sent_levels[key]

    def remind(self, active, now=None):
        """1초마다 호출: 긴급 경보가 계속되면 1분마다 다시 보낸다"""
        now = now or time.time()
        for key, cond in active.items():
            if cond["level"] >= 3:
                last = self._last_sent.get((key, 3), 0)
                if now - last >= self.emergency_repeat:
                    self._send(f"[긴급 경보 계속] {cond['message']}", [], 3)
                    self._last_sent[(key, 3)] = now
                    self._sent_levels[key] = 3

    # ----- 전송 --------------------------------------------------------------
    def _send(self, title, actions, level):
        body = title if not actions else title + "\n조치: " + " / ".join(actions)
        headers = {
            # HTTP 헤더는 ASCII만 되므로 한글 제목은 ntfy의 RFC 2047 방식으로 인코딩
            "Title": "=?UTF-8?B?" + _b64(f"{self.farm_name}") + "?=",
            "Priority": PRIORITY[level],
            "Tags": TAGS[level],
        }
        threading.Thread(target=self._post, args=(self.url, body, headers), daemon=True).start()

    @staticmethod
    def _http_post(url, body, headers):
        try:
            req = urllib.request.Request(url, data=body.encode("utf-8"), headers=headers, method="POST")
            urllib.request.urlopen(req, timeout=5).close()
        except Exception as e:
            print(f"[push] 전송 실패: {e}")


def _b64(text):
    import base64
    return base64.b64encode(text.encode("utf-8")).decode("ascii")
