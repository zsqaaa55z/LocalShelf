package local.shelf;
final class IdlePolicy {
    static final long IDLE_MS=60_000;
    static boolean shouldRest(boolean economy,long now,long lastTraffic){return economy && now-lastTraffic>=IDLE_MS;}
}
