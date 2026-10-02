package local.shelf.sync;

import android.Manifest;
import android.app.*;
import android.content.*;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.*;
import android.provider.DocumentsContract;
import android.provider.Settings;
import android.view.*;
import android.widget.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.text.SimpleDateFormat;
import java.util.*;
import org.json.*;

public final class MainActivity extends Activity {
    static final int TREE=10,BACKUP=11,PAIR=12,EXPORT=13,REPORT=14;
    final int ink=Color.rgb(26,47,39),green=Color.rgb(33,118,95),muted=Color.rgb(102,116,107);
    LinearLayout content,advanced;TextView sourceText,orderText,nasText,statusText,directStatus,connectionText,summaryText,modeText,changeText;Switch auto,newOnly,directRead,pipeline,unattended;Button directPermission,importBackup,syncNow,pauseNow,reviewOrder,setupNow,detailsToggle,editNasAddress;Spinner batch,lanes,readLanes;Handler handler=new Handler();boolean localBusy=false,updating=false,pendingFull=false,pendingCheck=false;String last="",lastChangeRaw=null,lastChangeHint=null;
    final Runnable refreshTask=new Runnable(){public void run(){refresh();handler.postDelayed(this,1500);}};
    @Override public void onCreate(Bundle saved){super.onCreate(saved);var p=LocalState.prefs(this);if(p.getBoolean("sourceChecking",false)&&!SyncRunner.busy.get())p.edit().putBoolean("sourceChecking",false).putString("sourceError","上次目录检查中断，请重新选择 EhViewer").putString("sourceStatus","目录检查中断，请重新选择 EhViewer；不会自动开始同步").apply();adoptDailyDefaults();build();if(saved!=null&&saved.getBoolean("advancedOpen",false))showAdvanced(true);}
    void adoptDailyDefaults(){
        var p=LocalState.prefs(this);
        if(DailySyncPolicy.canAdopt(p.getBoolean("dailyDefaults048",false),localBusy||SyncRunner.busy.get(),SyncJob.pending(this),p.getBoolean("cyclePending",false)))
            p.edit().putBoolean("newOnly",true).putInt("batchLimit",0).putBoolean("dailyDefaults048",true).commit();
    }
    void showAdvanced(boolean open){advanced.setVisibility(open?View.VISIBLE:View.GONE);detailsToggle.setText(open?"收起连接与高级设置":"连接与高级设置");}
    @Override protected void onSaveInstanceState(Bundle state){state.putBoolean("advancedOpen",advanced!=null&&advanced.getVisibility()==View.VISIBLE);super.onSaveInstanceState(state);}
    String appVersion(){
        try{String version=getPackageManager().getPackageInfo(getPackageName(),0).versionName;return version==null?"版本未知":version;}
        catch(android.content.pm.PackageManager.NameNotFoundException e){return "版本未知";}
    }
    int dp(int v){return Math.round(v*getResources().getDisplayMetrics().density);}
    TextView text(String value,int size,int color){TextView t=new TextView(this);t.setText(value);t.setTextSize(size);t.setTextColor(color);t.setPadding(0,dp(4),0,dp(8));return t;}
    GradientDrawable bg(int color,int radius){GradientDrawable d=new GradientDrawable();d.setColor(color);d.setCornerRadius(dp(radius));return d;}
    LinearLayout card(String label){LinearLayout box=new LinearLayout(this);box.setOrientation(LinearLayout.VERTICAL);box.setPadding(dp(18),dp(16),dp(18),dp(16));box.setBackground(bg(Color.WHITE,18));LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(-1,-2);p.bottomMargin=dp(12);content.addView(box,p);TextView title=text(label,17,ink);title.setTypeface(null,Typeface.BOLD);box.addView(title);return box;}
    Button button(LinearLayout box,String label,Runnable action,boolean primary){Button b=new Button(this);b.setText(label);b.setAllCaps(false);b.setTextSize(15);b.setTextColor(primary?Color.WHITE:green);b.setBackgroundTintList(android.content.res.ColorStateList.valueOf(primary?green:Color.rgb(236,244,238)));LinearLayout.LayoutParams p=new LinearLayout.LayoutParams(-1,dp(50));p.topMargin=dp(5);box.addView(b,p);b.setOnClickListener(v->{try{action.run();}catch(Exception e){error(SyncRunner.friendly(e));}});return b;}
    void build(){
        ScrollView scroll=new ScrollView(this);scroll.setFillViewport(true);scroll.setBackgroundColor(Color.rgb(244,246,242));content=new LinearLayout(this);content.setOrientation(LinearLayout.VERTICAL);content.setPadding(dp(22),dp(22),dp(22),dp(28));scroll.addView(content);
        scroll.setOnApplyWindowInsetsListener((v,insets)->{if(Build.VERSION.SDK_INT>=30){var bars=insets.getInsets(WindowInsets.Type.systemBars());v.setPadding(bars.left,bars.top,bars.right,bars.bottom);}else v.setPadding(insets.getSystemWindowInsetLeft(),insets.getSystemWindowInsetTop(),insets.getSystemWindowInsetRight(),insets.getSystemWindowInsetBottom());return insets;});setContentView(scroll);
        content.addView(text("LOCALSHELF / SYNC",12,green));TextView title=text("让书库保持更新。",28,ink);title.setTypeface(null,Typeface.BOLD);content.addView(title);content.addView(text("导入最新清单，同步顺序、新增与更新",14,muted));
        LinearLayout savedSource=card("已保存的连接");connectionText=text("",14,muted);savedSource.addView(connectionText);
        setupNow=button(savedSource,"完成目录与 NAS 设置",()->showAdvanced(true),false);
        LinearLayout order=card("01  更新下载清单");orderText=text("",14,muted);order.addView(orderText);
        importBackup=button(order,"导入最新 EhViewer .db",()->choose(BACKUP),false);
        reviewOrder=button(order,"核对下载顺序",this::review,false);
        order.addView(text("新增、更新或调整顺序后，导出并导入完整 .db；只读取下载清单，不上传原始数据库。请等 EhViewer 下载完成再同步。",12,muted));
        LinearLayout daily=card("02  同步到 NAS");
        changeText=text("导入最新 .db 后显示变化摘要。",15,ink);daily.addView(changeText);
        TextView changeHelp=text("变化统计说明  ›",13,green);changeHelp.setMinHeight(dp(48));changeHelp.setGravity(Gravity.CENTER_VERTICAL);changeHelp.setOnClickListener(v->new AlertDialog.Builder(this).setTitle("变化摘要如何统计").setMessage(ChangeSummary.HELP).setPositiveButton("知道了",null).show());daily.addView(changeHelp);
        modeText=text("",13,muted);daily.addView(modeText);summaryText=text("",15,ink);daily.addView(summaryText);
        syncNow=button(daily,"同步新增漫画",()->start(false,false),true);
        pauseNow=button(daily,"暂停同步",()->{SyncJob.pause(this);refresh();},false);
        detailsToggle=button(content,"连接与高级设置",()->showAdvanced(advanced.getVisibility()!=View.VISIBLE),false);
        LinearLayout home=content;advanced=new LinearLayout(this);advanced.setOrientation(LinearLayout.VERTICAL);advanced.setVisibility(View.GONE);home.addView(advanced);content=advanced;
        LinearLayout source=card("01  漫画来源");sourceText=text("",14,muted);source.addView(sourceText);button(source,"选择 EhViewer / download 目录",()->choose(TREE),false);
        source.addView(text("漫画较多时，推荐选择上一级 EhViewer 并点「使用此文件夹」。会请求父目录的只读授权，但本应用仅扫描其中的 download，不读取同级其他文件。授权时不扫描全库，正式扫描请运行迁移预检。",12,muted));
        directRead=new Switch(this);directRead.setText("优先直读（源文件只读）");directRead.setTextColor(ink);directRead.setPadding(0,dp(12),0,dp(8));source.addView(directRead);
        directRead.setOnCheckedChangeListener((v,on)->{if(updating)return;try{requireIdle();LocalState.prefs(this).edit().putBoolean("directRead",on).apply();}catch(Exception e){error(SyncRunner.friendly(e));}refresh();});
        directStatus=text("",13,green);source.addView(directStatus);directPermission=button(source,"授权 / 管理直读权限",this::manageDirectPermission,false);
        source.addView(text("默认优先直读已扫描到的文件，不新增全库扫描。需手动授予「所有文件访问」；未授权或打开失败自动使用原方式。读取中途出错、文件变化或校验失败仍会停止。此开关不改变源文件只读原则。",12,muted));
        button(source,"查看完整下载顺序",this::review,false);
        LinearLayout nas=card("03  NAS 连接");nasText=text("",14,muted);nas.addView(nasText);button(nas,"导入 NAS 配对文件",()->choose(PAIR),false);button(nas,"测试 Wi-Fi 连接",()->background(()->{try(Net net=new Net(this,LocalState.pairing(this))){JSONObject result=net.get("/sync/v1/health");LocalState.status(this,String.format(Locale.CHINA,"NAS 连接成功 · 剩余 %.2f GB",result.getLong("freeBytes")/1e9));}}),false);
        editNasAddress=button(nas,"修改 NAS 地址",this::editAddress,false);
        nas.addView(text("地址来自已保存的配对，不固定 IP。同一台 NAS 换 IP 或端口，可直接修改并验证保存；更换 NAS 或证书请重新导入配对文件。",12,muted));
        LinearLayout transfer=card("传输设置与详细状态");statusText=text("",13,muted);transfer.addView(statusText);
        transfer.addView(text("每批最多核验漫画 / 归档组数",14,ink));
        batch=new Spinner(this);batch.setAdapter(new ArrayAdapter<>(this,android.R.layout.simple_spinner_dropdown_item,new String[]{"100 组（首次迁移建议）","500 组","1,000 组","不限，连续同步"}));transfer.addView(batch);
        batch.setOnItemSelectedListener(new AdapterView.OnItemSelectedListener(){public void onNothingSelected(AdapterView<?> p){}public void onItemSelected(AdapterView<?> p,View v,int pos,long id){int limit=new int[]{100,500,1000,0}[pos];if(updating||LocalState.prefs(MainActivity.this).getInt("batchLimit",100)==limit)return;try{requireIdle();LocalState.prefs(MainActivity.this).edit().putInt("batchLimit",limit).apply();}catch(Exception e){error(SyncRunner.friendly(e));}refresh();}});
        transfer.addView(text("批次完成后等待你继续，自动检查不会越过批次暂停。快速增量复用的旧漫画不占本批名额；全库就绪后统一发布下载顺序。",12,muted));
        unattended=new Switch(this);unattended.setText("无人值守续传（下次任务生效）");unattended.setTextColor(ink);transfer.addView(unattended);
        unattended.setOnCheckedChangeListener((v,on)->{if(updating)return;try{requireIdle();LocalState.prefs(this).edit().putBoolean("unattended",on).apply();}catch(Exception e){error(SyncRunner.friendly(e));}refresh();});
        transfer.addView(text("默认开启，适用于 Android 14+ 手动开始的上传。网络或 NAS 暂时不可用时逐步延长重试间隔；系统中止时保存断点，允许后尝试恢复。不会绕过主动暂停、分批上限、权限和校验错误；不会使用移动数据。整夜上传请在暂停时手动选择「不限，连续同步」，不会自动更改现有 100 组设置。",12,muted));
        button(transfer,"后台 / 电池运行检查",()->BackgroundReadiness.show(this),false);
        button(transfer,"通知设置",()->BackgroundReadiness.notifications(this),false);
        transfer.addView(text("小文件读取并发（下次任务生效）",14,ink));
        readLanes=new Spinner(this);readLanes.setAdapter(new ArrayAdapter<>(this,android.R.layout.simple_spinner_dropdown_item,new String[]{"1 路 · 读取对照","2 路 · 默认推荐","4 路 · 读取实验"}));transfer.addView(readLanes);
        readLanes.setOnItemSelectedListener(new AdapterView.OnItemSelectedListener(){public void onNothingSelected(AdapterView<?> p){}public void onItemSelected(AdapterView<?> p,View v,int pos,long id){int count=new int[]{1,2,4}[pos];if(updating||LocalState.prefs(MainActivity.this).getInt("readConcurrency",2)==count)return;try{requireIdle();LocalState.prefs(MainActivity.this).edit().putInt("readConcurrency",count).apply();}catch(Exception e){error(SyncRunner.friendly(e));}refresh();}});
        transfer.addView(text("读取线程各自复用文件服务连接；两块 16 MiB 缓冲交替读取和上传，总数据缓冲约 32 MiB。1 / 2 / 4 路只改变读取并发，均保留双缓冲与校验；4 路可能更热，不一定更快。取消后等待线程退出再恢复，不改变漫画顺序。",12,muted));
        transfer.addView(text("大文件上传并发（下次任务生效）",14,ink));
        lanes=new Spinner(this);lanes.setAdapter(new ArrayAdapter<>(this,android.R.layout.simple_spinner_dropdown_item,new String[]{"1 路 · 默认 / 对照","2 路 · 实验","4 路 · 实验"}));transfer.addView(lanes);
        lanes.setOnItemSelectedListener(new AdapterView.OnItemSelectedListener(){public void onNothingSelected(AdapterView<?> p){}public void onItemSelected(AdapterView<?> p,View v,int pos,long id){int count=new int[]{1,2,4}[pos];if(updating||LocalState.prefs(MainActivity.this).getInt("uploadConcurrency",1)==count)return;try{requireIdle();LocalState.prefs(MainActivity.this).edit().putInt("uploadConcurrency",count).apply();}catch(Exception e){error(SyncRunner.friendly(e));}refresh();}});
        transfer.addView(text("新版 NAS 自动启用小文件批量快传：不超过 4 MiB 的文件读一次、边读校验，每包最多 64 个 / 16 MiB。以上并发选项用于较大文件；不改下载顺序。旧接收端或完整校验自动使用原协议，保留校验、落盘确认与续传。",12,muted));
        pipeline=new Switch(this);pipeline.setText("有界流水线加速（下次任务生效）");pipeline.setTextColor(ink);transfer.addView(pipeline);
        pipeline.setOnCheckedChangeListener((v,on)->{if(updating)return;try{requireIdle();LocalState.prefs(this).edit().putBoolean("pipelineEnabled",on).apply();}catch(Exception e){error(SyncRunner.friendly(e));}refresh();});
        transfer.addView(text("默认开启：小文件超过一包时最多双路发送，仍使用 32 MiB 数据缓冲；大文件上传选择 2 / 4 路且有多个待校验文件时，启用单路校验 + 最多双路上传。单文件、已缓存校验值和完整校验保留原路径。关闭可回到原调度，不清空断点、缓存或配对。",12,muted));
        newOnly=new Switch(this);newOnly.setText("日常增量：顺序、新增与更新");newOnly.setTextColor(ink);newOnly.setPadding(0,dp(12),0,dp(8));transfer.addView(newOnly);
        newOnly.setOnCheckedChangeListener((v,on)->{if(updating)return;try{requireIdle();LocalState.prefs(this).edit().putBoolean("newOnly",on).apply();}catch(Exception e){error(SyncRunner.friendly(e));}refresh();});
        transfer.addView(text("每天使用默认开启，不限批次：对照最新与上次完成的清单，复用未变化旧漫画。新增、顺序移动附近、页数等元数据或目录时间变化的漫画会检查目录；图片大小和修改时间一致时复用 SHA，只读取需要校验的新文件。不是整库逐页审计；不改变元数据的原地改图需完整校验。升级 NAS 后，最新清单移出的漫画只退出当前列表，旧文件仍保留；新 ID 复用手机目录也不会覆盖旧 ID。独立归档仍核对元数据。",12,muted));
        auto=new Switch(this);auto.setText("充电时自动检查");auto.setTextColor(ink);auto.setTextSize(15);auto.setPadding(0,dp(12),0,dp(10));transfer.addView(auto);
        auto.setOnCheckedChangeListener((v,on)->{if(updating)return;try{requireIdle();if(on)configured();SyncJob.automatic(this,on);}catch(Exception e){error(SyncRunner.friendly(e));}refresh();});
        transfer.addView(text("自动检查仅在 Wi-Fi 与充电时运行，间隔至少 15 分钟，由安卓系统调度。首次全库同步请点上方按钮；暂停会同时关闭自动检查。",12,muted));
        button(transfer,"迁移预检 / 差异报告",()->start(false,true),false);button(transfer,"重新校验全部源文件并同步",()->new AlertDialog.Builder(this).setTitle("完整校验").setMessage("将重新读取所有漫画计算校验值，耗时取决于书库大小；已一致的文件不会重复上传。").setPositiveButton("开始",(d,w)->start(true,false)).setNegativeButton("取消",null).show(),false);
        button(transfer,"导出固定排序清单",()->choose(EXPORT),false);
        button(transfer,"导出迁移预检报告",()->choose(REPORT),false);
        content=home;content.addView(text(appVersion()+" · 单向增量 · 手机原文件只读\n目录和配对自动保留，授权失效时才需重新选择。",12,muted));refresh();
    }
    void requireIdle(){if(localBusy||SyncRunner.busy.get()||SyncJob.pending(this))throw new IllegalStateException("请先暂停当前任务并等待其停止，再修改设置；等待系统续传也属于进行中的任务");}
    void editAddress(){
        try{
            requireIdle();String current=LocalState.pairing(this).getString("url");
            LinearLayout box=new LinearLayout(this);box.setOrientation(LinearLayout.VERTICAL);box.setPadding(dp(20),dp(8),dp(20),0);
            box.addView(text("填写 NAS 同步接收端的局域网 IP 和端口，不是管理页面或阅读端地址。可省略 https://，省略端口时使用 8443。\n保留原证书和配对，仅验证通过后保存；不会自动开始同步。地址变化后，下次同步会重新检查进度范围，已一致文件不会重复上传。",13,muted));
            EditText input=new EditText(this);input.setSingleLine(true);input.setInputType(android.text.InputType.TYPE_CLASS_TEXT|android.text.InputType.TYPE_TEXT_VARIATION_URI);input.setText(current);input.setSelectAllOnFocus(true);input.setContentDescription("NAS 同步地址");box.addView(input);
            AlertDialog dialog=new AlertDialog.Builder(this).setTitle("修改 NAS 地址").setView(box).setPositiveButton("验证并保存",null).setNegativeButton("取消",null).create();
            dialog.setOnShowListener(v->dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(button->{
                try{
                    requireIdle();String address=NasAddress.normalize(input.getText().toString());
                    background(()->{
                        LocalState.status(this,"正在验证 NAS 新地址；尚未更改原配对…");
                        try{
                            LocalState.changeAddress(this,address,candidate->{try(Net net=new Net(this,candidate)){net.get("/sync/v1/health").getLong("freeBytes");}});
                            LocalState.status(this,"NAS 地址已验证并保存；目录与同步记录保留，未开始同步。");
                        }catch(Exception e){LocalState.status(this,"NAS 地址未保存，原配对保留。"+SyncRunner.friendly(e));}
                    });dialog.dismiss();
                }catch(Exception e){input.setError(SyncRunner.friendly(e));}
            }));dialog.show();
        }catch(Exception e){error(SyncRunner.friendly(e));}
    }
    void manageDirectPermission(){
        requireIdle();if(Build.VERSION.SDK_INT<30){error("此系统版本使用原方式读取，无需直读授权。");return;}
        new AlertDialog.Builder(this).setTitle("直读权限说明").setMessage("安卓的「所有文件访问」是较广泛的共享存储读写权限，不是系统级只读权限。\n\n本应用的直读代码仅以只读模式打开已授权 EhViewer/download 内已扫描的文件，不修改或删除源文件，也不扫描其他位置。\n\n你可以拒绝或随时撤回，应用会使用原方式（SAF）。授权后不会自动开始同步。").setPositiveButton("前往系统设置",(d,w)->{
            try{requireIdle();try{startActivity(new Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,Uri.parse("package:"+getPackageName())));}catch(ActivityNotFoundException e){startActivity(new Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION));}}
            catch(Exception e){error("无法打开权限设置，请在系统设置中为「书库同步」管理所有文件访问权限。");}
        }).setNegativeButton("暂不授权",null).show();
    }
    void sourceReady()throws IOException{SourceFiles.requireReady(this);}
    void configured()throws Exception{sourceReady();Catalog.manifest(LocalState.read(this,"order.json"));LocalState.pairing(this);}
    void configured(boolean check)throws Exception{if(!check){configured();return;}sourceReady();if(LocalState.prefs(this).getString("backup","").isBlank())throw new IOException("请先导入备份；预检不需要 NAS 配对或确认顺序");}
    void start(boolean full,boolean check){try{if(!check&&LocalState.prefs(this).getBoolean("cyclePending",false))full=full||LocalState.prefs(this).getBoolean("cycleFull",false);requireIdle();configured(check);if(Build.VERSION.SDK_INT>=33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)!=android.content.pm.PackageManager.PERMISSION_GRANTED){pendingFull=full;pendingCheck=check;requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS},20);}else SyncJob.manual(this,full,check);}catch(Exception e){error(SyncRunner.friendly(e));}}
    @Override public void onRequestPermissionsResult(int request,String[] permissions,int[] results){super.onRequestPermissionsResult(request,permissions,results);if(request==20){try{requireIdle();configured(pendingCheck);SyncJob.manual(this,pendingFull,pendingCheck);}catch(Exception e){error(SyncRunner.friendly(e));}}}
    void choose(int kind){requireIdle();if(kind==REPORT&&!new File(getNoBackupFilesDir(),"migration-report.json").isFile())throw new IllegalStateException("请先运行迁移预检，再导出报告");Intent intent;if(kind==TREE){intent=new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE);intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION|Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION);intent.putExtra(DocumentsContract.EXTRA_INITIAL_URI,DocumentsContract.buildDocumentUri("com.android.externalstorage.documents","primary:EhViewer"));}else if(kind==EXPORT||kind==REPORT){intent=new Intent(Intent.ACTION_CREATE_DOCUMENT).setType("application/json").putExtra(Intent.EXTRA_TITLE,kind==REPORT?"localshelf-migration-report.json":"localshelf-order.json");}else{intent=new Intent(Intent.ACTION_OPEN_DOCUMENT).setType("*/*").addCategory(Intent.CATEGORY_OPENABLE);intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION|Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION);}startActivityForResult(intent,kind);}
    @Override protected void onActivityResult(int request,int result,Intent data){super.onActivityResult(request,result,data);if(result!=RESULT_OK||data==null||data.getData()==null){if(request==TREE){String message="目录选择已取消，或系统选择器未完成授权。大量漫画时请在上一级 EhViewer 点「使用此文件夹」。";LocalState.status(this,message);error(message);}return;}Uri uri=data.getData();
        background(()->{
            if(request==TREE){acceptSource(uri);}
            else if(request==BACKUP){JSONObject draft=Catalog.importDb(this,uri);getContentResolver().takePersistableUriPermission(uri,Intent.FLAG_GRANT_READ_URI_PERMISSION);Catalog.save(this,draft);LocalState.prefs(this).edit().putString("backup",uri.toString()).putLong("backupImportedAt",System.currentTimeMillis()).apply();ChangeSummaryStore.prepare(this,draft);int ties=Catalog.unresolved(draft).size();LocalState.status(this,ties>0?"备份已导入；有 "+ties+" 组同时间记录，请先核对顺序":"最新清单已导入，点击同步即可；已保存的目录和 NAS 配对不变");}
            else if(request==PAIR){JSONObject pairing;try(InputStream in=getContentResolver().openInputStream(uri)){if(in==null)throw new IOException("配对文件不可读");pairing=new JSONObject(new String(LocalState.bounded(in,8192),StandardCharsets.UTF_8));}LocalState.savePairing(this,pairing);LocalState.status(this,"NAS 配对已保存，可测试连接");}
            else if(request==EXPORT||request==REPORT){JSONObject manifest=request==REPORT?LocalState.read(this,"migration-report.json"):Catalog.manifest(LocalState.read(this,"order.json"));try(OutputStream out=getContentResolver().openOutputStream(uri,"wt")){if(out==null)throw new IOException("无法写入选定文件");out.write(manifest.toString(2).getBytes(StandardCharsets.UTF_8));}LocalState.status(this,request==REPORT?"迁移预检报告已导出":"固定排序清单已导出");}
        });
    }
    interface Work{void run()throws Exception;}
    void acceptSource(Uri grant)throws Exception{
        var p=LocalState.prefs(this);
        try{
            getContentResolver().takePersistableUriPermission(grant,Intent.FLAG_GRANT_READ_URI_PERMISSION);
            if(!p.edit().putString("sourceGrant",grant.toString()).putBoolean("sourceChecking",true).putString("sourceError","").putString("sourceStatus","已取得只读授权，正在后台定位下载目录…").commit())throw new IOException("无法保存授权状态，请检查手机剩余空间");
            Uri resolved=SourceFiles.resolveSelection(this,grant,message->p.edit().putString("sourceStatus",message).apply());
            if(!p.edit().putString("tree",resolved.toString()).putBoolean("sourceChecking",false).putString("sourceError","").putString("sourceStatus","download 已就绪 · 只读访问\n目录定位完成；授权步骤未扫描漫画内容").commit())throw new IOException("无法保存目录设置，请检查手机剩余空间");
            ChangeSummaryStore.clear(this,"目录已重新选择，请导入最新 .db 后更新变化摘要。");
            LocalState.status(this,"下载目录已保存，未扫描漫画。下次只需导入最新 .db 后点击同步。");
        }catch(Exception e){String message=SyncRunner.friendly(e);p.edit().putBoolean("sourceChecking",false).putString("sourceError",message).putString("sourceStatus","目录检查失败："+message).commit();throw e;}
    }
    void background(Work work){background(work,null);}
    void background(Work work,Runnable completed){requireIdle();if(!SyncRunner.busy.compareAndSet(false,true))throw new IllegalStateException("任务已开始，请先暂停");localBusy=true;refresh();new Thread(()->{boolean success=false;try{work.run();success=true;}catch(Exception e){LocalState.status(this,SyncRunner.friendly(e));}finally{boolean done=success;SyncRunner.busy.set(false);runOnUiThread(()->{localBusy=false;refresh();if(done&&completed!=null&&!isFinishing()&&!isDestroyed())completed.run();});}},"sync-settings").start();}
    void refresh(){if(sourceText==null)return;adoptDailyDefaults();var p=LocalState.prefs(this);sourceText.setText(p.getString("sourceStatus",p.getString("tree","").isBlank()?"尚未选择目录":"已授权下载目录 · 只读访问"));int count=p.getInt("bookCount",0),ties=p.getInt("tieCount",0);String imported=p.getLong("backupImportedAt",0)>0?"\n导入于 "+new SimpleDateFormat("MM-dd HH:mm",Locale.CHINA).format(new Date(p.getLong("backupImportedAt",0))):"";orderText.setText((count==0?"等待完整下载备份":count+" 本漫画 · "+(ties>0?ties+" 组顺序待核对":"下载顺序已固定"))+imported);
        boolean paired=false;String nas="NAS 尚未配对";
        try{nas=LocalState.pairing(this).getString("url");paired=true;nasText.setText(nas+"\n已固定 NAS 证书，传输使用 HTTPS");}catch(Exception e){nasText.setText("等待 NAS 接收端的 pairing.json");}
        boolean sourceOk=!p.getString("tree","").isBlank()&&!p.getBoolean("sourceChecking",false)&&p.getString("sourceError","").isBlank();
        String folder="下载目录尚未就绪";if(sourceOk)try{folder=SourceFiles.rootDocumentId(Uri.parse(p.getString("tree",""))).replaceFirst("^primary:","");}catch(IllegalArgumentException e){folder="已保存下载目录";}
        connectionText.setText(folder+"\n"+nas);setupNow.setVisibility(sourceOk&&paired?View.GONE:View.VISIBLE);
        boolean occupied=localBusy||SyncRunner.busy.get()||SyncJob.pending(this);importBackup.setEnabled(!occupied);reviewOrder.setVisibility(ties>0?View.VISIBLE:View.GONE);reviewOrder.setEnabled(!occupied);syncNow.setEnabled(!occupied&&sourceOk&&paired&&count>0&&ties==0);pauseNow.setVisibility(SyncRunner.busy.get()&&!localBusy||SyncJob.pending(this)?View.VISIBLE:View.GONE);
        editNasAddress.setEnabled(paired&&!occupied);
        String changeRaw=p.getString(ChangeSummaryStore.KEY,""),changeHint=p.getString(ChangeSummaryStore.HINT,"导入最新 .db 后显示变化摘要。");
        if(!Objects.equals(changeRaw,lastChangeRaw)||!Objects.equals(changeHint,lastChangeHint)){changeText.setText(ChangeSummaryStore.display(changeRaw,changeHint));lastChangeRaw=changeRaw;lastChangeHint=changeHint;}
        syncNow.setText(DailySyncPolicy.action(p.getBoolean("cyclePending",false),p.getBoolean("cycleFull",false),p.getBoolean("newOnly",false)));
        modeText.setText(p.getBoolean("cyclePending",false)&&p.getBoolean("cycleFull",false)?"上次完整校验尚未结束；继续保留原校验模式。":p.getBoolean("newOnly",false)?"日常增量 · 同步顺序、新增与更新 · 不默认整库校验":"检查全库变化 · 可在设置中切回增量同步");
        String state=localBusy?"正在处理设置…":p.getString("status","准备好来源、下载清单和 NAS 后，即可开始。");
        if(SyncRunner.active!=null)state=SyncRunner.active.monitor.summary()+"\n\n"+state;
        else if(!localBusy&&!SyncRunner.busy.get()&&p.getString("runState","").equals("running"))state=(SyncJob.pending(this)?"任务中断，系统仍保留续传请求。":"上次任务意外中断，已确认的进度保留。点击「开始 / 继续同步」恢复。")+"\n"+state;
        if(!state.equals(last)){statusText.setText(state);last=state;}
        summaryText.setText(SyncRunner.active!=null?SyncRunner.active.monitor.summary():DailySyncPolicy.compact(p.getString("runState",""),state));
        if(p.getInt("runMissingSources",0)>0&&"complete".equals(p.getString("runState","")))summaryText.append("\n有 "+p.getInt("runMissingSources",0)+" 本源目录缺失，已有 NAS 内容保留。");
        updating=true;unattended.setChecked(p.getBoolean("unattended",true));unattended.setEnabled(!localBusy&&!SyncRunner.busy.get()&&!SyncJob.pending(this));updating=false;
        updating=true;pipeline.setChecked(p.getBoolean("pipelineEnabled",true));pipeline.setEnabled(!localBusy&&!SyncRunner.busy.get());directRead.setChecked(p.getBoolean("directRead",true));directRead.setEnabled(!localBusy&&!SyncRunner.busy.get());directPermission.setEnabled(!localBusy&&!SyncRunner.busy.get()&&Build.VERSION.SDK_INT>=30);directStatus.setText(SourceFiles.directSetting(this));int limit=p.getInt("batchLimit",100);batch.setSelection(limit==100?0:limit==500?1:limit==1000?2:3);int laneCount=p.getInt("uploadConcurrency",1);lanes.setSelection(laneCount==2?1:laneCount==4?2:0);int readers=p.getInt("readConcurrency",2);readLanes.setSelection(readers==1?0:readers==4?2:1);auto.setChecked(p.getBoolean("auto",false));newOnly.setChecked(p.getBoolean("newOnly",false));updating=false;
    }
    void review(){
        try{requireIdle();JSONObject draft=LocalState.read(this,"order.json");var groups=Catalog.unresolved(draft);if(!groups.isEmpty()){var first=groups.firstEntry();tieDialog(draft,first.getKey(),first.getValue(),groups.size());return;}
            JSONArray books=Catalog.manifest(draft).getJSONArray("books");List<String> lines=new ArrayList<>();for(int i=0;i<books.length();i++){JSONObject b=books.getJSONObject(i);lines.add((i+1)+". "+b.getString("title")+"\nID "+b.getString("id"));}
            new AlertDialog.Builder(this).setTitle("下载列表 · "+books.length()+" 本").setAdapter(new ArrayAdapter<>(this,android.R.layout.simple_list_item_1,lines),(d,w)->{}).setPositiveButton("关闭",null).show();
        }catch(Exception e){error(SyncRunner.friendly(e));}
    }
    void tieDialog(JSONObject draft,long time,List<OrderRules.Row> rows,int remaining)throws Exception {
        List<OrderRules.Row> order=new ArrayList<>(rows);LinearLayout box=new LinearLayout(this);box.setOrientation(LinearLayout.VERTICAL);box.setPadding(dp(18),dp(8),dp(18),dp(8));box.addView(text("还有 "+remaining+" 组。请对照 EhViewer 下载列表，用 ↑ ↓ 调整下列漫画的相对位置。这里只处理同一时间的记录。",14,muted));
        ListView list=new ListView(this);BaseAdapter adapter=new BaseAdapter(){public int getCount(){return order.size();}public Object getItem(int i){return order.get(i);}public long getItemId(int i){return i;}public View getView(int pos,View old,android.view.ViewGroup parent){LinearLayout row=new LinearLayout(MainActivity.this);row.setGravity(Gravity.CENTER_VERTICAL);TextView title=text((pos+1)+". "+order.get(pos).title()+"\nID "+order.get(pos).id(),13,ink);row.addView(title,new LinearLayout.LayoutParams(0,-2,1));for(int direction:new int[]{-1,1}){Button b=new Button(MainActivity.this);b.setText(direction<0?"↑":"↓");b.setContentDescription((direction<0?"上移 ":"下移 ")+order.get(pos).title());b.setEnabled(pos+direction>=0&&pos+direction<order.size());row.addView(b,new LinearLayout.LayoutParams(dp(46),dp(48)));b.setOnClickListener(v->{Collections.swap(order,pos,pos+direction);notifyDataSetChanged();});}return row;}};
        list.setAdapter(adapter);box.addView(list,new LinearLayout.LayoutParams(-1,dp(300)));CheckBox checked=new CheckBox(this);checked.setText("已逐项核对，与 EhViewer 当前列表一致");box.addView(checked);
        AlertDialog dialog=new AlertDialog.Builder(this).setTitle("相同下载时间 · 必须核对").setView(box).setPositiveButton("保存本组顺序",null).setNegativeButton("稍后核对",null).create();dialog.setOnShowListener(v->{Button save=dialog.getButton(AlertDialog.BUTTON_POSITIVE);save.setEnabled(false);checked.setOnCheckedChangeListener((view,on)->save.setEnabled(on));save.setOnClickListener(view->{try{JSONArray ids=new JSONArray();for(var row:order)ids.put(row.id());draft.getJSONObject("resolvedTies").put(Long.toString(time),ids);dialog.dismiss();background(()->{Catalog.save(this,draft);ChangeSummaryStore.prepare(this,draft);},this::review);}catch(Exception e){error(SyncRunner.friendly(e));}});});dialog.show();
    }
    void error(String message){new AlertDialog.Builder(this).setTitle("书库同步").setMessage(message).setPositiveButton("知道了",null).show();}
    @Override protected void onResume(){super.onResume();handler.post(refreshTask);}
    @Override protected void onPause(){handler.removeCallbacks(refreshTask);super.onPause();}
}
