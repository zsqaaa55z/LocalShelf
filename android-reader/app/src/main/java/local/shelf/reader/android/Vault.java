package local.shelf.reader.android;

import android.content.Context;
import android.content.SharedPreferences;
import android.security.keystore.*;
import android.util.Base64;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.util.*;
import javax.crypto.*;
import javax.crypto.spec.GCMParameterSpec;
import org.json.*;

/** Android Keystore protects the reusable credential; the password is never saved. */
final class Vault {
  private static final String ALIAS = "localshelf-reader-connection-v1";
  private final SharedPreferences prefs;

  Vault(Context context) {
    prefs = context.getSharedPreferences("connection", Context.MODE_PRIVATE);
  }

  private SecretKey key() throws Exception {
    KeyStore store = KeyStore.getInstance("AndroidKeyStore");
    store.load(null);
    if (store.containsAlias(ALIAS))
      return ((KeyStore.SecretKeyEntry) store.getEntry(ALIAS, null)).getSecretKey();
    KeyGenerator generator =
        KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
    generator.init(
        new KeyGenParameterSpec.Builder(
                ALIAS, KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .build());
    return generator.generateKey();
  }

  void save(Api.Session session) throws Exception {
    JSONObject value =
        new JSONObject()
            .put("address", session.address)
            .put("device", session.device)
            .put("token", session.token)
            .put("features", new JSONArray(session.features));
    Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
    cipher.init(Cipher.ENCRYPT_MODE, key());
    cipher.updateAAD(ALIAS.getBytes(StandardCharsets.UTF_8));
    byte[] data = cipher.doFinal(value.toString().getBytes(StandardCharsets.UTF_8));
    if (!prefs
        .edit()
        .putString("iv", Base64.encodeToString(cipher.getIV(), Base64.NO_WRAP))
        .putString("blob", Base64.encodeToString(data, Base64.NO_WRAP))
        .putString("address", session.address)
        .commit()) throw new IllegalStateException("credential save failed");
  }

  Api.Session load() throws Exception {
    if (!prefs.contains("blob")) return null;
    Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
    cipher.init(
        Cipher.DECRYPT_MODE,
        key(),
        new GCMParameterSpec(128, Base64.decode(prefs.getString("iv", ""), Base64.NO_WRAP)));
    cipher.updateAAD(ALIAS.getBytes(StandardCharsets.UTF_8));
    byte[] clear = cipher.doFinal(Base64.decode(prefs.getString("blob", ""), Base64.NO_WRAP));
    try {
      JSONObject value = new JSONObject(new String(clear, StandardCharsets.UTF_8));
      Set<String> features = new HashSet<>();
      JSONArray array = value.getJSONArray("features");
      for (int i = 0; i < array.length(); i++) features.add(array.getString(i));
      return new Api.Session(
          value.getString("address"),
          value.getString("device"),
          value.getString("token"),
          features);
    } finally {
      Arrays.fill(clear, (byte) 0);
    }
  }

  String address() {
    return prefs.getString("address", "");
  }

  void forget() {
    prefs.edit().remove("blob").remove("iv").apply();
  }
}
