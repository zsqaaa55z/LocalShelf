package local.shelf.sync;

import java.io.IOException;
import java.util.List;
import java.util.function.Consumer;

/** Resolves only the selected directory and, if necessary, its immediate children. */
final class DownloadSelection {
    record Node(String id, String name, boolean directory) {}
    interface Access {
        Node read(String id) throws Exception;
        List<Node> children(String id) throws Exception;
    }
    static String resolve(String selectedId, Access access, Consumer<String> progress) throws Exception {
        progress.accept("已取得只读授权，正在检查所选目录…");
        Node selected=access.read(selectedId);
        if(selected==null || !selected.directory() || !selectedId.equals(selected.id()))
            throw new IOException("选中的不是可读取目录，请重新选择 EhViewer 或其 download 子目录");
        if("download".equals(selected.name())) return selected.id();
        if(!"EhViewer".equalsIgnoreCase(selected.name()))
            throw new IOException("请选择 EhViewer 文件夹，或其中小写的 download 子目录；不是手机公共 Download 目录");
        progress.accept("已授权 EhViewer，正在定位 download 子目录…");
        String found=null;
        for(Node child:access.children(selected.id())) {
            if(child.directory() && "download".equals(child.name())) {
                if(found!=null) throw new IOException("存在多个 download 子目录，无法安全确定来源");
                found=child.id();
            }
        }
        if(found==null) throw new IOException("EhViewer 下没有找到 download 子目录；不会使用其他目录替代");
        Node download=access.read(found);
        if(download==null || !download.directory() || !found.equals(download.id()) || !"download".equals(download.name()))
            throw new IOException("download 子目录不可读或已变化，请重新授权");
        return found;
    }
}
