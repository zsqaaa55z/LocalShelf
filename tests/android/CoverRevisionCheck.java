package local.shelf;
public class CoverRevisionCheck {
    static int count;
    static void check(boolean value,String name){if(!value)throw new AssertionError(name);count++;System.out.println("PASS "+name);}
    public static void main(String[] args){
        String root=CoverRevision.library("root-a"),book=CoverRevision.book(root,"1","1-title");
        check(root.matches("[a-f0-9]{64}"),"library identity is opaque SHA256");
        check(root.equals(CoverRevision.library("root-a")),"same root survives catalog reimport");
        check(!root.equals(CoverRevision.library("root-b")),"different download roots are isolated");
        check(book.equals(CoverRevision.book(root,"1","1-title")),"book identity independent of rank and display title");
        check(!book.equals(CoverRevision.book(root,"2","1-title")),"different book cannot share cache");
        check(!book.equals(CoverRevision.book(root,"1","new-dir")),"directory changes invalidate identity");
        String etag=CoverRevision.etag(book,"doc",100,1000);
        check(CoverRevision.matches(etag,etag),"same metadata supports zero-body validation");
        check(!CoverRevision.matches(etag,CoverRevision.etag(book,"doc",101,1000)),"size change invalidates validator");
        check(!CoverRevision.matches(etag,CoverRevision.etag(book,"doc",100,1001)),"modification change invalidates validator");
        check(!CoverRevision.matches(etag,CoverRevision.etag(book,"new-doc",100,1000)),"cover file replacement invalidates validator");
        check(CoverRevision.etag(book,"doc",-1,1000)==null,"unknown size requires normal transfer");
        check(CoverRevision.etag(book,"doc",100,0)==null,"unknown timestamp requires normal transfer");
        check(!CoverRevision.matches(null,null) && !CoverRevision.matches(etag,null),"absent validators never return 304");
        System.out.println(count+" cover revision checks passed");
    }
}
