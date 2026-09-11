package local.shelf;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;
public class PairingWindowCheck {
    static int checks;
    static void check(boolean value){if(!value)throw new AssertionError("check "+(checks+1));checks++;}
    public static void main(String[] args)throws Exception{
        long[] now={10};PairingWindow p=new PairingWindow(()->now[0]);
        String code=p.display();check(code.matches("[0-9]{6}"));check(p.exchange(code));check(!p.exchange(code));
        p.renew();code=p.display();now[0]+=PairingWindow.TTL;check(!p.exchange(code));
        p.renew();code=p.display();String wrong=code.equals("000000")?"111111":"000000";
        for(int i=0;i<5;i++)check(!p.exchange(wrong));check(!p.exchange(code));
        p.renew();code=p.display();check(!p.exchange("１２３４５６"));check(!p.exchange("1234567"));check(!p.exchange(null));check(p.exchange(code));
        p.renew();String concurrent=p.display();ExecutorService pool=Executors.newFixedThreadPool(8);AtomicInteger success=new AtomicInteger();
        for(int i=0;i<8;i++)pool.submit(()->{if(p.exchange(concurrent))success.incrementAndGet();});
        pool.shutdown();check(pool.awaitTermination(5,TimeUnit.SECONDS));check(success.get()==1);
        p.renew();p.close();check(!p.exchange(p.display()));
        p.renew();code=p.display();now[0]--;check(!p.exchange(code));
        System.out.println(checks+" six-digit pairing checks passed");
    }
}
