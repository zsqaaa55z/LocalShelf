package local.shelf.sync;

/** Conservative gates: one frame / one cold large file cannot benefit. */
final class PipelinePolicy {
    static int smallLanes(boolean enabled,int count,long bytes){
        if(count<0||bytes<0)throw new IllegalArgumentException();
        return enabled&&(count>BatchBuffer.MAX_FILES||bytes>BatchBuffer.MAX_BYTES)?2:1;
    }
    static boolean overlapLarge(boolean enabled,int uploadLanes,int coldFiles){
        return enabled&&uploadLanes>=2&&coldFiles>=2;
    }
}
