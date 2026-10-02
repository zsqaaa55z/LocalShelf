package local.shelf.sync;

import java.io.IOException;
import java.net.URI;
import java.net.URISyntaxException;

/** Address only: server identity continues to be the existing certificate pin. */
final class NasAddress {
    private NasAddress() {}
    static String normalize(String input)throws IOException {
        if(input==null||input.isBlank())throw new IOException("请输入 NAS 同步地址");
        String value=input.strip();
        if(!value.contains("://"))value="https://"+value;
        URI uri=parse(value);
        int port=uri.getPort();
        // An omitted port is the receiver's default, never a fixed NAS host.
        if(port==-1&&!uri.getRawAuthority().endsWith(":"))port=8443;
        String result="https://"+uri.getHost()+":"+port;
        requireValid(result);
        return result;
    }
    static void requireValid(String value)throws IOException {
        URI uri=parse(value);
        if(uri.getPort()<1||uri.getPort()>65535)throw new IOException("请输入有效的 NAS 同步端口（1–65535）");
    }
    private static URI parse(String value)throws IOException {
        final URI uri;
        try{uri=new URI(value);}catch(URISyntaxException|NullPointerException e){throw new IOException("NAS 地址格式无效");}
        String host=uri.getHost();
        if(!"https".equalsIgnoreCase(uri.getScheme())||host==null||uri.getRawUserInfo()!=null||uri.getRawQuery()!=null||uri.getRawFragment()!=null||!("".equals(uri.getRawPath())||"/".equals(uri.getRawPath())))
            throw new IOException("仅支持局域网 IPv4 HTTPS 地址，不要包含账号、路径或查询参数");
        String[] parts=host.split("\\.",-1);int[] bytes=new int[4];
        if(parts.length!=4)throw new IOException("请输入家庭局域网 IPv4 地址");
        for(int i=0;i<4;i++){
            if(!parts[i].matches("0|[1-9][0-9]{0,2}"))throw new IOException("IP 地址无效，不支持省略或前导零");
            bytes[i]=Integer.parseInt(parts[i]);if(bytes[i]>255)throw new IOException("IP 地址无效");
        }
        if(!(bytes[0]==10||bytes[0]==192&&bytes[1]==168||bytes[0]==172&&bytes[1]>=16&&bytes[1]<=31))
            throw new IOException("仅允许家庭局域网地址");
        return uri;
    }
}
