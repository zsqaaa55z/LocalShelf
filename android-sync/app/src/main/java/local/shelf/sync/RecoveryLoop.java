package local.shelf.sync;

import java.io.IOException;

/** Same request/body is retained; no library rescan or new payload buffer on retry. */
final class RecoveryLoop {
    static class Temporary extends IOException {
        Temporary(String message,Throwable cause){super(message,cause);}
    }
    static final class Exhausted extends IOException {
        Exhausted(Temporary cause){super("网络暂未恢复，等待系统重新安排续传",cause);}
    }
    interface Operation<T>{T run()throws Exception;}
    interface Control {
        void check()throws Exception;
        void waiting(int attempt,long delayMillis);
        void sleep(long millis)throws Exception;
        void recovered();
    }
    static <T>T run(boolean enabled,Operation<T> operation,Control control)throws Exception {
        try{
            for(int attempt=1;;attempt++){
                control.check();
                try {T result=operation.run();control.check();return result;}
                catch(Temporary e){
                    if(!enabled)throw e;
                    if(attempt>=8)throw new Exhausted(e);
                    long delay=RecoveryPolicy.delayMillis(attempt);
                    control.waiting(attempt,delay);
                    // Short interruptible slices also honour cancellation in a sibling pipeline lane.
                    while(delay>0){control.check();long slice=Math.min(250,delay);control.sleep(slice);delay-=slice;}
                }
            }
        }finally{control.recovered();}
    }
}
