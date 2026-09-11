package local.shelf;
public class PairingIdentityCheck {
    static void check(boolean ok){if(!ok)throw new AssertionError();}
    public static void main(String[] args)throws Exception{
        PairingIdentity identity=new PairingIdentity("0123456789abcdef0123456789abcdef","abcdefghijklmnopqrstuvwxyzABCDEF");
        String nonce="0".repeat(64),proof=identity.proof(nonce);
        check(proof.equals("4158f25901741dac27207668651dbf5cea7a26608c06f30291ea1d642bb569a6"));
        check(!proof.equals(identity.proof("1".repeat(64))));
        PairingIdentity fresh=PairingIdentity.create();check(!fresh.id.equals(identity.id)&&!fresh.token.equals(identity.token));
        check(!proof.equals(fresh.proof(nonce)));
        try{identity.proof("short");throw new AssertionError();}catch(IllegalArgumentException expected){}
        try{new PairingIdentity("bad",identity.token);throw new AssertionError();}catch(IllegalArgumentException expected){}
        System.out.println("6 pairing identity checks passed");
    }
}
