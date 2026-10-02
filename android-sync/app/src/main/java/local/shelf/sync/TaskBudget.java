package local.shelf.sync;

/** Zero means unlimited only for an unlimited task; a finite exhausted task stays exhausted. */
final class TaskBudget {
    static int remaining(int limit,int used) {
        if(limit<0||used<0)throw new IllegalArgumentException("invalid budget");
        return limit==0?0:Math.max(0,limit-used);
    }
    static boolean exhausted(int limit,int used){return limit>0&&remaining(limit,used)==0;}
}
