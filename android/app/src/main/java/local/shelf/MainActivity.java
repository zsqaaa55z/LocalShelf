package local.shelf;
import android.app.*;
import android.content.*;
import android.net.Uri;
import android.os.*;
import android.widget.*;
import android.view.View;
import android.graphics.Color;
import org.json.*;
import java.io.*;
import java.nio.charset.StandardCharsets;

public class MainActivity extends Activity {
    TextView status;ImageView qr;EditText connection;CheckBox japanese;boolean importing=false;String shown="";
    final Handler handler=new Handler(Looper.getMainLooper());final Runnable refresh=new Runnable(){public void run(){render();handler.postDelayed(this,1000);}};
    @Override public void onCreate(Bundle b){super.onCreate(b);
        LinearLayout page=new LinearLayout(this);page.setOrientation(LinearLayout.VERTICAL);page.setPadding(32,70,32,50);page.setBackgroundColor(Color.rgb(245,247,252));
        TextView title=new TextView(this);title.setText("LocalShelf\n你的私人书库桥接");title.setTextSize(28);title.setTextColor(Color.rgb(25,40,65));page.addView(title);
        status=new TextView(this);status.setTextSize(17);status.setPadding(0,24,0,24);page.addView(status);
        add(page,"① 选择 EhViewer/download",()->pick(Intent.ACTION_OPEN_DOCUMENT_TREE,null,1));
        japanese=new CheckBox(this);japanese.setText("优先日文标题");japanese.setChecked(getSharedPreferences("shelf",0).getBoolean("japanese",false));page.addView(japanese);
        add(page,"② 导入 EhViewer .db 备份",()->pick(Intent.ACTION_OPEN_DOCUMENT,"*/*",3));
        CheckBox economy=new CheckBox(this);economy.setText("实验性省电模式（下次开启生效）\n空闲约 60 秒释放唤醒锁，锁屏连接可能延迟或中断；默认稳定共享。");economy.setChecked(getSharedPreferences("shelf",0).getBoolean("economy",false));
        economy.setOnCheckedChangeListener((button,checked)->getSharedPreferences("shelf",0).edit().putBoolean("economy",checked).apply());page.addView(economy);
        add(page,"开启后台桥接",()->{if(importing)return;if(BridgeService.running){render();return;}
            if(getSharedPreferences("shelf",0).getString("root",null)==null||!getFileStreamPath("catalog.json").exists()){status.setText("请先授权目录并导入备份。");return;}
            if(Build.VERSION.SDK_INT>=33&&checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS)!=android.content.pm.PackageManager.PERMISSION_GRANTED){requestPermissions(new String[]{android.Manifest.permission.POST_NOTIFICATIONS},4);status.setText("请允许通知后再次开启桥接，以便在通知栏确认状态。");return;}
            try{startForegroundService(new Intent(this,BridgeService.class));}catch(Exception e){status.setText("启动失败："+e.getMessage());}});
        add(page,"停止共享",()->{BridgeService.state="共享已停止";stopService(new Intent(this,BridgeService.class));});
        add(page,"刷新漫画索引",()->{
            if(!BridgeService.running){status.setText("请先开启桥接，再刷新索引。");return;}
            EditText id=new EditText(this);id.setHint("漫画 ID；留空刷新全部索引记录");id.setInputType(android.text.InputType.TYPE_CLASS_NUMBER);
            new AlertDialog.Builder(this).setTitle("刷新文件位置与页数").setMessage("只清除 LocalShelf 索引记录并复查下载目录，不修改漫画或排序。刷新后按需建立索引，不逐页扫描全库。iPhone 请重新打开漫画；新增漫画仍需导入最新 .db。").setView(id).setNegativeButton("取消",null).setPositiveButton("刷新",(dialog,which)->{
                String value=id.getText().toString().trim();if(!value.isEmpty()&&!value.matches("[0-9]{1,20}")){status.setText("请输入正确的数字漫画 ID");return;}
                if(BridgeService.running)startService(new Intent(this,BridgeService.class).setAction("refresh-index").putExtra("book-id",value));
            }).show();
        });
        add(page,"重置配对 / 更换手机",()->new AlertDialog.Builder(this).setTitle("撤销旧配对？").setMessage("将停止共享并更换口令，旧二维码和已配对手机将失效。书库和文件不删除。重新开启后需扫码一次。").setNegativeButton("取消",null).setPositiveButton("重置",(dialog,which)->{
            stopService(new Intent(this,BridgeService.class));
            try{PairingStore.rotate(this);BridgeService.state="配对已重置，请重新开启共享并扫码";}catch(Exception e){BridgeService.state="配对重置失败，请勿开启共享；稍后重试";}
            shown="";render();
        }).show());
        add(page,"通知 / 电池设置",()->startActivity(new Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,Uri.parse("package:"+getPackageName()))));
        add(page,"开源许可与隐私",()->new AlertDialog.Builder(this).setTitle("开源许可与隐私").setItems(new String[]{"隐私与权限","项目 MIT 许可","依赖与来源","NanoHTTPD BSD 许可","ZXing Apache 许可","ZXing NOTICE"},(dialog,which)->{
            String[] files={"PRIVACY.txt","LocalShelf-MIT.txt","DEPENDENCIES.txt","NanoHTTPD-LICENSE.txt","Apache-2.0.txt","ZXing-NOTICE.txt"};
            showLegal(files[which]);
        }).setNegativeButton("关闭",null).show());
        add(page,"生成新的 6 位配对码",()->{
            if(!BridgeService.running){status.setText("请先开启桥接。");return;}
            startService(new Intent(this,BridgeService.class).setAction("renew-pair-code"));
        });
        qr=new ImageView(this);qr.setAdjustViewBounds(true);qr.setContentDescription("配对二维码包含口令，请勿分享");page.addView(qr,new LinearLayout.LayoutParams(-1,(int)(300*getResources().getDisplayMetrics().density)));qr.setVisibility(View.GONE);
        connection=new EditText(this);connection.setTextIsSelectable(true);connection.setHint("开启后显示配对码和备用地址");page.addView(connection);
        TextView note=new TextView(this);note.setText("0.3.5 · 六位数字配对码\n新版 iOS 可复用未变化的封面；重新导入清单不再让全库封面失效。不修改 EhViewer 文件。页索引短期复用，封面位置最长约一天；持续下载时可手动刷新。新增漫画仍需导入最新 .db。\n首次扫码或输入六位码后自动连接；数字码失效不影响已配对手机。停止或重启不更换后台凭据。后台桥接有常驻通知，系统如中断可在应用电池设置中选择不限制。系统强制结束、重启或 Wi-Fi 改变后需手动开启。\nHTTP 未加密，仅用于可信私人 Wi-Fi；列表同值位置待核对。");note.setPadding(0,24,0,0);page.addView(note);
        ScrollView scroll=new ScrollView(this);scroll.addView(page);setContentView(scroll);
        String old=getPreferences(0).getString("root",null);if(old!=null&&!getSharedPreferences("shelf",0).contains("root"))getSharedPreferences("shelf",0).edit().putString("root",old).apply();}
    void add(LinearLayout p,String label,Runnable action){Button button=new Button(this);button.setText(label);button.setAllCaps(false);p.addView(button);button.setOnClickListener(v->action.run());}
    void showLegal(String name){
        try(InputStream in=getAssets().open("licenses/"+name)){
            byte[] bytes=BoundedInput.read(in,64*1024);
            TextView text=new TextView(this);text.setText(new String(bytes,StandardCharsets.UTF_8));text.setTextIsSelectable(true);text.setPadding(32,24,32,24);
            ScrollView scroll=new ScrollView(this);scroll.addView(text);
            new AlertDialog.Builder(this).setTitle("开源许可与隐私").setView(scroll).setPositiveButton("关闭",null).show();
        }catch(IOException e){new AlertDialog.Builder(this).setMessage("无法读取随包说明，请查看源码仓库中的许可文件。").setPositiveButton("关闭",null).show();}
    }
    void pick(String action,String type,int code){if(importing)return;Intent i=new Intent(action);if(type!=null)i.setType(type).addCategory(Intent.CATEGORY_OPENABLE);i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION|Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION);startActivityForResult(i,code);}
    @Override protected void onStart(){super.onStart();handler.post(refresh);}
    @Override protected void onStop(){handler.removeCallbacks(refresh);super.onStop();}
    void render(){if(importing)return;String pin=BridgeService.pairingWindow==null?"":BridgeService.pairingWindow.display();String value=BridgeService.state+BridgeService.secret+pin;if(value.equals(shown))return;shown=value;status.setText(BridgeService.state);
        if(!BridgeService.running){qr.setVisibility(View.GONE);qr.setImageDrawable(null);connection.setText("");return;}connection.setText("http://"+BridgeService.host+":8088\n6 位配对码："+pin+"\n有效期 5 分钟，最多尝试 5 次，成功后失效。配对后自动连接。\n也可扫码；仅用于可信私人 Wi-Fi，HTTP 未加密。");
        try{String payload=new JSONObject().put("app","localshelf").put("version",2).put("deviceId",BridgeService.deviceId).put("address","http://"+BridgeService.host+":8088").put("token",BridgeService.secret).toString();
            com.google.zxing.common.BitMatrix m=new com.google.zxing.qrcode.QRCodeWriter().encode(payload,com.google.zxing.BarcodeFormat.QR_CODE,720,720);int[] px=new int[720*720];for(int y=0;y<720;y++)for(int x=0;x<720;x++)px[y*720+x]=m.get(x,y)?Color.BLACK:Color.WHITE;
            qr.setImageBitmap(android.graphics.Bitmap.createBitmap(px,720,720,android.graphics.Bitmap.Config.ARGB_8888));qr.setVisibility(View.VISIBLE);
        }catch(Exception e){status.append("\n二维码生成失败，请手动连接。");}}
    @Override public void onActivityResult(int request,int result,Intent data){super.onActivityResult(request,result,data);if(result!=RESULT_OK||data==null||data.getData()==null)return;Uri uri=data.getData();
        if(request==1){try{stopService(new Intent(this,BridgeService.class));getContentResolver().takePersistableUriPermission(uri,Intent.FLAG_GRANT_READ_URI_PERMISSION);getSharedPreferences("shelf",0).edit().putString("root",uri.toString()).apply();BridgeService.state="下载目录已授权";shown="";}catch(Exception e){status.setText("授权失败："+e.getMessage());}return;}
        if(request==3){stopService(new Intent(this,BridgeService.class));importing=true;status.setText("正在本机导入备份…");boolean jp=japanese.isChecked();new Thread(()->{try{
            JSONArray books=BackupImporter.read(getApplicationContext(),uri,jp);byte[] bytes=books.toString().getBytes(StandardCharsets.UTF_8);if(bytes.length>8*1024*1024)throw new IOException("清单超过 8 MB");
            android.util.AtomicFile file=new android.util.AtomicFile(getFileStreamPath("catalog.json"));FileOutputStream out=null;try{out=file.startWrite();out.write(bytes);file.finishWrite(out);}catch(Exception e){if(out!=null)file.failWrite(out);throw e;}
            getSharedPreferences("shelf",0).edit().putBoolean("japanese",jp).apply();BridgeService.state="已保存 "+books.length()+" 条记录，可开启后台桥接";
        }catch(Exception e){BridgeService.state="导入失败："+e.getMessage();}runOnUiThread(()->{importing=false;shown="";render();});}).start();}}
}
