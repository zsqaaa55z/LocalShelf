package local.shelf.sync;

/** Order-of-magnitude scheduling hint from an existing preflight, never a correctness input. */
final class PayloadEstimate {
    static long from(long[] books,int start,long[] archives,int archiveStart,int limit) {
        if(start<0||start>books.length||archiveStart<0||archiveStart>archives.length||limit<0)return -1;
        long total=0;int count=0;
        try{
            for(int i=start;i<books.length&&(limit==0||count<limit);i++,count++){
                if(books[i]<0)return -1;total=Math.addExact(total,books[i]);
            }
            for(int i=archiveStart;i<archives.length&&(limit==0||count<limit);i++,count++){
                if(archives[i]<0)return -1;total=Math.addExact(total,archives[i]);
            }
            return total;
        }catch(ArithmeticException e){return -1;}
    }
}
