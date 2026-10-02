"""Isolated candidate only. Never imported by the production entry point."""
import threading
import time
from collections import deque
from thumbnails import ThumbnailCache


class QueuedThumbnailCache(ThumbnailCache):
    def __init__(self, *args, queue_limit=4, wait_seconds=0.45, **kwargs):
        super().__init__(*args, **kwargs)
        self.condition = threading.Condition()
        self.waiting = deque()
        self.flights = {}
        self.running = False
        self.waiters = 0
        self.queue_limit = max(1, min(4, queue_limit))
        self.wait_seconds = max(0, min(0.75, wait_seconds))
        self.stats.update(coalesced=0, queue_timeout=0, queue_full=0, peak_queue=0)

    def get(self, stream, source_sha, pixels, background=False):
        if background: return super().get(stream, source_sha, pixels, background=True)
        key = self.cache_key(source_sha, pixels)
        hit = self.cached(key)
        if hit: return hit
        deadline = time.monotonic() + self.wait_seconds
        with self.condition:
            flight = self.flights.get(key)
            if self.waiters >= 8:
                self.stats['queue_full'] += 1
                return None
            leader = flight is None
            if leader:
                if len(self.flights) >= self.queue_limit:
                    self.stats['queue_full'] += 1
                    return None
                flight = [threading.Event(), None]
                self.flights[key] = flight
                self.waiting.append(key)
                self.stats['peak_queue'] = max(self.stats['peak_queue'], len(self.flights))
            else:
                self.stats['coalesced'] += 1
            self.waiters += 1
        acquired = False
        try:
            if not leader:
                if not flight[0].wait(max(0, deadline-time.monotonic())):
                    self.stats['queue_timeout'] += 1
                    return None
                return flight[1]
            with self.condition:
                while self.running or self.waiting[0] != key:
                    remaining = deadline-time.monotonic()
                    if remaining <= 0:
                        self.stats['queue_timeout'] += 1
                        return None
                    self.condition.wait(remaining)
                self.waiting.popleft(); self.running = True; acquired = True
            flight[1] = super().get(stream, source_sha, pixels)
            return flight[1]
        finally:
            with self.condition:
                self.waiters -= 1
                if leader:
                    if key in self.waiting: self.waiting.remove(key)
                    if acquired: self.running = False
                    self.flights.pop(key, None)
                    flight[0].set()
                    self.condition.notify_all()
            if not stream.closed: stream.seek(0)
