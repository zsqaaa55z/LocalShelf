package local.shelf.sync;

import java.io.*;
import java.net.*;
import java.security.GeneralSecurityException;
import javax.net.ssl.SSLException;

/** Fail closed: this policy is used only for failures inside the HTTP transport. */
final class RecoveryPolicy {
    static boolean exhausted(Throwable error){for(Throwable t=error;t!=null;t=t.getCause())if(t instanceof RecoveryLoop.Exhausted)return true;return false;}
    static boolean cancellation(Throwable error){for(Throwable t=error;t!=null;t=t.getCause())if(t instanceof InterruptedException||t instanceof InterruptedIOException)return true;return false;}
    static long delayMillis(int attempt) {
        if(attempt<1)throw new IllegalArgumentException("attempt");
        return attempt>=6?300_000L:Math.min(300_000L,15_000L<<(attempt-1));
    }
    static boolean temporaryHttp(int status,String code) {
        if(status==401||status==403||status==507)return false;
        if(code!=null&&(code.contains("hash")||code.contains("space")||code.contains("storage")||
            code.contains("order")||code.contains("inventory")||code.contains("unauthorized")||
            code.contains("source")||code.contains("directory")||code.contains("backup")))return false;
        return status==408||status==429||status==500||status==502||status==503||status==504;
    }
    static boolean temporaryTransport(IOException error) {
        for(Throwable cause=error;cause!=null;cause=cause.getCause())
            if(cause instanceof SSLException||cause instanceof GeneralSecurityException||
               cause instanceof ProtocolException||cause instanceof FileNotFoundException)return false;
        return error.getClass()==IOException.class||error instanceof SocketException||error instanceof SocketTimeoutException||
            error instanceof UnknownHostException||error instanceof EOFException;
    }
    // Stop reasons are diagnostic, not a promise that Android will restart us.
    static boolean reschedule(boolean requested,boolean unattended,int reason) {
        return requested&&unattended&&reason!=1&&reason!=13; // app cancel / user stop
    }
    static String stopReason(int reason) {
        return switch(reason){
            case 1 -> "应用取消";case 2 -> "系统调整任务优先级";case 3,16 -> "系统运行时限";
            case 4 -> "设备状态限制（可能涉及温度或电量）";case 5 -> "电量条件不满足";
            case 6 -> "充电条件不满足";case 7 -> "Wi-Fi 连接条件不满足";
            case 8 -> "设备空闲条件变化";case 9 -> "设备存储条件不满足";
            case 10 -> "系统后台额度";case 11 -> "后台运行受限";case 12 -> "应用待机限制";
            case 13 -> "用户在系统中停止";case 14 -> "系统维护";case 15 -> "系统调度条件变化";
            default -> "系统停止任务（原因码 "+reason+"）";
        };
    }
}
