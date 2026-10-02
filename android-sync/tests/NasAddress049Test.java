package local.shelf.sync;

import java.io.IOException;

public final class NasAddress049Test {
    static int checks;
    static void check(boolean yes){if(!yes)throw new AssertionError("address check "+checks);checks++;}
    static void rejects(String value){try{NasAddress.normalize(value);throw new AssertionError("accepted invalid address");}catch(IOException expected){checks++;}}
    public static void main(String[] args)throws Exception {
        check(NasAddress.normalize(" 192.168.20.8 ").equals("https://192.168.20.8:8443"));
        check(NasAddress.normalize("10.3.4.5:9443").equals("https://10.3.4.5:9443"));
        check(NasAddress.normalize("https://172.16.1.8:5443/").equals("https://172.16.1.8:5443"));
        check(NasAddress.normalize("HTTPS://172.31.255.254").equals("https://172.31.255.254:8443"));
        for(String value:new String[]{null,""," ","http://192.168.1.1:8443","ftp://192.168.1.1:8443","https://example.org:8443","https://192.168.1.1.evil.test:8443","127.0.0.1","169.254.1.1","172.15.1.1","172.32.1.1","192.169.1.1","8.8.8.8","0.0.0.0","[::1]","2130706433","0x7f000001","192.168.1","192.168.1.256","192.168.01.1","192.168.1.1:0","192.168.1.1:65536","192.168.1.1:","192.168.1.1:-1","https://user@192.168.1.1:8443","https://192.168.1.1:8443/path","https://192.168.1.1:8443?token=secret","https://192.168.1.1:8443#fragment","https://192.168.1.1:8443/%2e%2e","192.168.1.1\n:8443","https://192.168.1.1:8443\\evil","https://192.168.1.1:8443//"})rejects(value);
        for(String value:new String[]{"https://10.0.0.1:1","https://192.168.255.254:65535/","https://172.16.0.1:8443"}){NasAddress.requireValid(value);checks++;}
        try{NasAddress.requireValid("https://192.168.1.1");throw new AssertionError("pairing imports require explicit port");}catch(IOException expected){checks++;}
        System.out.println("NasAddress049: "+checks+" checks passed");
    }
}
