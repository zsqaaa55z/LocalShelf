import local.shelf.sync.OrderRules;
import java.util.*;

public class OrderRulesTest {
    static int checks=0;
    static void check(boolean good){if(!good)throw new AssertionError();checks++;}
    static void reject(Runnable run){try{run.run();throw new AssertionError("accepted invalid order");}catch(IllegalArgumentException expected){checks++;}}
    static OrderRules.Row row(String id,long time){return new OrderRules.Row(id,id+"-漫画","漫画 "+id,time);}
    public static void main(String[] args){
        var shuffled=List.of(row("20",1),row("7",3),row("100",2));
        check(OrderRules.order(shuffled,Map.of()).stream().map(OrderRules.Row::id).toList().equals(List.of("7","100","20")));
        var tied=List.of(row("9",7),row("2",7),row("3",1));
        reject(()->OrderRules.order(tied,Map.of()));
        check(OrderRules.order(tied,Map.of(7L,List.of("2","9"))).stream().map(OrderRules.Row::id).toList().equals(List.of("2","9","3")));
        reject(()->OrderRules.order(tied,Map.of(7L,List.of("9","9"))));
        reject(()->OrderRules.order(tied,Map.of(7L,List.of("2","8"))));
        reject(()->OrderRules.order(List.of(row("1",2),row("1",1)),Map.of()));
        reject(()->OrderRules.order(List.of(new OrderRules.Row("1","../escape","title",1)),Map.of()));
        reject(()->OrderRules.order(List.of(),Map.of()));
        reject(()->OrderRules.order(List.of(new OrderRules.Row("1","folder"," ",1)),Map.of()));
        check(OrderRules.order(List.of(row("1",Long.MIN_VALUE),row("2",Long.MAX_VALUE)),Map.of()).get(0).id().equals("2"));
        // A new download goes in front; previous relative positions stay intact.
        check(OrderRules.order(List.of(row("40",4),row("20",1),row("7",3),row("100",2)),Map.of()).stream().map(OrderRules.Row::id).toList().equals(List.of("40","7","100","20")));
        for(String bad:List.of(".","..","a/b","a\\b","a\u0000b"))reject(()->OrderRules.validName(bad));
        System.out.println("PASS "+checks+" strict download-order checks");
    }
}
