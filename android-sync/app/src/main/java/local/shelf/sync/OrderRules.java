package local.shelf.sync;

import java.util.*;

/** No tie-breaker is invented. Ties require an explicit order observed in EhViewer. */
public final class OrderRules {
    public record Row(String id, String directory, String title, long time) {}
    public static void validName(String name) {
        if(name==null || name.isBlank() || name.equals(".") || name.equals("..") || name.contains("/") || name.contains("\\") || name.codePoints().anyMatch(c->c<32))
            throw new IllegalArgumentException("目录或文件名不合法");
    }
    public static List<Row> order(List<Row> input, Map<Long,List<String>> resolved) {
        if(input.isEmpty() || input.size()>20000) throw new IllegalArgumentException("下载记录为空或超过 20000 本");
        Set<String> ids=new HashSet<>(), dirs=new HashSet<>();
        TreeMap<Long,List<Row>> groups=new TreeMap<>(Comparator.reverseOrder());
        for(Row row:input) {
            validName(row.directory());
            if(row.id()==null || !row.id().matches("[1-9][0-9]{0,18}") || !ids.add(row.id()) || !dirs.add(row.directory()) || row.title()==null || row.title().isBlank())
                throw new IllegalArgumentException("漫画 ID、标题或目录映射缺失/重复");
            groups.computeIfAbsent(row.time(), k->new ArrayList<>()).add(row);
        }
        List<Row> out=new ArrayList<>();
        for(var entry:groups.entrySet()) {
            List<Row> group=entry.getValue();
            if(group.size()>1) {
                List<String> explicit=resolved.get(entry.getKey());
                Set<String> expected=new HashSet<>(); for(Row row:group)expected.add(row.id());
                if(explicit==null || explicit.size()!=group.size() || !expected.equals(new HashSet<>(explicit)))
                    throw new IllegalArgumentException("有下载时间相同的漫画，必须先核对顺序");
                Map<String,Row> byId=new HashMap<>(); for(Row row:group)byId.put(row.id(),row);
                for(String id:explicit)out.add(byId.get(id));
            } else out.add(group.get(0));
        }
        return out;
    }
}
